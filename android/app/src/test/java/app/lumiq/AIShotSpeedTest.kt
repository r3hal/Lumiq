package app.lumiq

import app.lumiq.aishot.AIShotError
import app.lumiq.aishot.AIShotModel
import app.lumiq.aishot.AIShotSuggestion
import app.lumiq.aishot.ModelRace
import app.lumiq.aishot.NRect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Collections

/** How AI Shot gets an answer quickly when Google is busy or slow, and whole-view picks. */
class AIShotSpeedTest {
    private val plan = listOf("lite" to 6_000, "lite" to 6_000, "gemma" to 8_000, "lite" to 6_000)

    private fun elapsed(block: () -> Unit): Long {
        val start = System.nanoTime(); block(); return (System.nanoTime() - start) / 1_000_000
    }

    @Test fun busyAnswersAreRetriedQuickly() {
        val calls = Collections.synchronizedList(mutableListOf<String>())
        var result = ""
        val ms = elapsed {
            result = ModelRace.run(plan, hedgeMs = 2_500, retryPauseMs = 50) { model, _ ->
                calls += model
                Thread.sleep(100)
                if (calls.size < 3) throw AIShotError.Busy
                "answer from $model #${calls.size}"
            }
        }
        assertEquals("answer from gemma #3", result)
        assertTrue("took $ms ms", ms < 1_000) // Two fast "busy" answers, then success: no long waits.
    }

    @Test fun aSlowRequestGetsAParallelBackup() {
        var result = ""
        val ms = elapsed {
            result = ModelRace.run(plan, hedgeMs = 300) { model, _ ->
                if (Thread.currentThread().name.isNotEmpty() && model == "lite" && !backupStarted) {
                    backupStarted = true
                    Thread.sleep(5_000) // The first request hangs.
                    "slow"
                } else {
                    Thread.sleep(100)
                    "fast backup"
                }
            }
        }
        assertEquals("fast backup", result)
        assertTrue("took $ms ms", ms < 1_500)
    }

    @Volatile private var backupStarted = false

    @Test fun givesUpAfterTheTotalTime() {
        val ms = elapsed {
            try {
                ModelRace.run(plan, hedgeMs = 100, totalMs = 600) { _, _ -> Thread.sleep(5_000); "never" }
                fail("expected a timeout")
            } catch (e: AIShotError) {
                assertTrue(e is AIShotError.Timeout)
            }
        }
        assertTrue("took $ms ms", ms < 1_500)
    }

    @Test fun refusedKeyStopsAtOnce() {
        var calls = 0
        try {
            ModelRace.run(plan, retryPauseMs = 10) { _, _ -> calls++; throw AIShotError.Unauthorized }
            fail("expected Unauthorized")
        } catch (e: AIShotError) {
            assertTrue(e is AIShotError.Unauthorized)
        }
        assertEquals(1, calls)
    }

    @Test fun allBusyReportsBusy() {
        try {
            ModelRace.run(plan, retryPauseMs = 10) { _, _ -> throw AIShotError.Busy }
            fail("expected Busy")
        } catch (e: AIShotError) {
            assertTrue(e is AIShotError.Busy)
        }
    }

    private fun pick(frame: NRect, zoom: Double) = AIShotSuggestion("cobblestones", "Fill the frame.", "fill the frame", frame, zoom, "lite")

    @Test fun wholeViewPicksNeedNoAiming() {
        assertTrue(AIShotModel.isWholeView(pick(NRect(0.0, 0.0, 1.0, 1.0), 1.0), zoom = 1.0))
        assertTrue(AIShotModel.isWholeView(pick(NRect(0.02, 0.0, 0.96, 0.95), 0.5), zoom = 0.5))
        assertFalse(AIShotModel.isWholeView(pick(NRect(0.3, 0.3, 0.4, 0.4), 2.5), zoom = 1.0))
        assertFalse(AIShotModel.isWholeView(pick(NRect(0.0, 0.0, 1.0, 1.0), 2.0), zoom = 1.0)) // Still needs zooming in.
    }

    @Test fun groqAnswersAreParsedLikeGemini() {
        val groq = """{"choices":[{"message":{"role":"assistant","content":"{\"subject\": \"wooden boat bow\", \"tip\": \"Fill the frame.\", \"technique\": \"fill the frame\", \"box_2d\": [450, 0, 950, 1000]}"}}]}"""
        val text = app.lumiq.aishot.AIShotLogic.openAIText(groq)
        val request = app.lumiq.aishot.AIShotRequest(ByteArray(0), 0.75, 1.0, 0.5, 6.0)
        val s = app.lumiq.aishot.AIShotLogic.parseModelJson(text, request, app.lumiq.aishot.GROQ_MODEL)
        assertEquals("wooden boat bow", s.subject)
        assertEquals(app.lumiq.aishot.GROQ_MODEL, s.provider)
        try {
            app.lumiq.aishot.AIShotLogic.openAIText("""{"choices":[]}""")
            fail("expected InvalidResponse")
        } catch (e: AIShotError) {
            assertTrue(e is AIShotError.InvalidResponse)
        }
    }

    @Test fun groqIsTheEarlyBackupInThePlan() {
        val models = app.lumiq.aishot.GEMINI_MODELS.map { it.first }
        assertEquals("gemini-flash-lite-latest", models[0]) // Gemini first,
        assertEquals(app.lumiq.aishot.GROQ_MODEL, models[1]) // Groq as the first backup.
        assertEquals(1, models.count { it == app.lumiq.aishot.GROQ_MODEL })
    }
}
