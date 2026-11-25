package app.lumiq

import app.lumiq.aishot.AIShotError
import app.lumiq.aishot.AIShotLogic
import app.lumiq.aishot.AIShotModel
import app.lumiq.aishot.AIShotRequest
import app.lumiq.aishot.LumaFrame
import app.lumiq.aishot.NRect
import app.lumiq.aishot.TemplateTracker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.math.abs
import kotlin.random.Random

class AIShotLogicTest {
    private val request = AIShotRequest(ByteArray(0), aspect = 0.75, zoom = 1.0, minimumZoom = 0.5, maximumZoom = 6.0)

    @Test fun modelBoxBecomesSquareFrameAndZoom() {
        val s = AIShotLogic.parseModelJson(
            """Here: {"subject":"Red Mug","tip":"Fill the frame.","technique":"detail","box_2d":[400,300,600,500]}""",
            request, "gemini",
        )
        assertEquals("red mug", s.subject)
        assertEquals(0.2, s.frame.width, 1e-9)
        assertEquals(s.frame.width, s.frame.height, 1e-9)
        assertEquals(0.4, s.frame.midX, 1e-9)
        assertEquals(0.5, s.frame.midY, 1e-9)
        assertEquals(5.0, s.zoom, 1e-9)
    }

    @Test fun handZoomedSonyStillGetsATighterCrop() {
        // A Sony over Wi-Fi: the app cannot zoom (zoom 1, lens zoomed by hand), but the pick may be tighter.
        val sony = AIShotRequest(ByteArray(0), 1.5, 1.0, 1.0, 1.0 * AIShotModel.HAND_ZOOM_LIMIT, zoomsByHand = true)
        assertTrue(AIShotLogic.prompt(sony).contains("zooms by hand"))
        assertTrue(!AIShotLogic.prompt(request).contains("zooms by hand"))
        val s = AIShotLogic.parseModelJson("""{"tip":"Fill the frame.","box_2d":[300,300,700,700]}""", sony, "gemini")
        assertTrue("crop ${s.frame.width}", s.frame.width < 0.6)
        assertTrue("zoom ${s.zoom}", s.zoom > 1.5 && s.zoom <= AIShotModel.HAND_ZOOM_LIMIT)
        assertTrue(!AIShotModel.isWholeView(s, 1.0))
    }

    @Test fun nearlyFullViewBecomesFullFrame() {
        val s = AIShotLogic.parseModelJson("""{"box_2d":[0.02,0.03,0.97,0.96]}""", request, "x")
        assertEquals(NRect(0.0, 0.0, 1.0, 1.0), s.frame)
        assertEquals(1.0, s.zoom, 1e-9)
        assertEquals("your shot", s.subject)
    }

    @Test fun frameIsLimitedByMaximumZoomAndKeptOnScreen() {
        val s = AIShotLogic.parseModelJson("""{"box_2d":[0,960,20,1000]}""", request, "x")
        assertEquals(1.0 / 6.0, s.frame.width, 1e-9)
        assertTrue(s.frame.maxX <= 1.0 + 1e-9 && s.frame.x >= 0)
        assertEquals(0.0, s.frame.y, 1e-9)
    }

    @Test fun serverResponseIsValidated() {
        val s = AIShotLogic.parseServer(
            """{"subject":"bed","tip":"Isolate the textures.","frame":{"x":0.31,"y":0.42,"width":0.4,"height":0.4},"zoom":2.5,"provider":"gemini"}""",
            request,
        )
        assertEquals(0.4, s.frame.width, 1e-9)
        assertEquals(2.5, s.zoom, 1e-9)
        assertEquals("gemini", s.provider)
    }

    @Test fun garbageIsRejected() {
        for (text in listOf("no json", """{"box_2d":[1,2,3]}""", """{"box_2d":[500,500,501,501]}""")) {
            try { AIShotLogic.parseModelJson(text, request, "x"); fail(text) } catch (_: AIShotError.InvalidResponse) {}
        }
    }

    @Test fun busyModelsFallThroughButBadKeysStop() {
        assertTrue(AIShotLogic.errorFor(503) is AIShotError.Busy)
        assertTrue(AIShotLogic.tryNextModel(AIShotLogic.errorFor(503)))
        assertTrue(AIShotLogic.tryNextModel(AIShotLogic.errorFor(429)))
        assertTrue(AIShotLogic.tryNextModel(AIShotLogic.errorFor(400)))
        assertTrue(!AIShotLogic.tryNextModel(AIShotLogic.errorFor(403)))
        // The fast model goes first and is retried last.
        assertEquals("gemini-flash-lite-latest", app.lumiq.aishot.GEMINI_MODELS.first().first)
        assertEquals("gemini-flash-lite-latest", app.lumiq.aishot.GEMINI_MODELS.last().first)
    }

    @Test fun failedModelsAreSkippedForAWhile() {
        val cooldown = app.lumiq.aishot.ModelCooldown(seconds = 120.0)
        val models = app.lumiq.aishot.GEMINI_MODELS
        cooldown.failed("gemini-flash-latest", now = 10.0)
        assertTrue(cooldown.plan(models, 20.0).none { it.first == "gemini-flash-latest" })
        assertEquals(models, cooldown.plan(models, 131.0)) // Cooled down again after two minutes.
        cooldown.failed("gemini-flash-latest", 200.0)
        cooldown.succeeded("gemini-flash-latest")
        assertEquals(models, cooldown.plan(models, 201.0))
        for ((m, _) in models) cooldown.failed(m, 300.0)
        assertEquals(models.take(1), cooldown.plan(models, 301.0)) // Never nothing to try.
        assertTrue(app.lumiq.aishot.ModelCooldown.coolsDown(AIShotLogic.errorFor(429)))
        assertTrue(!app.lumiq.aishot.ModelCooldown.coolsDown(AIShotLogic.errorFor(503))) // Busy is retried, not skipped.
        assertTrue(!app.lumiq.aishot.ModelCooldown.coolsDown(AIShotLogic.errorFor(400)))
    }

    @Test fun modelAnswerWrappedInArrayIsAccepted() {
        val s = AIShotLogic.parseModelJson("""[{"subject":"boat","box_2d":[500,0,645,1000]}]""", request, "gemma")
        assertEquals(1.0, s.frame.width, 1e-9) // 1000 wide → full frame
    }

    @Test fun geminiThoughtsAreSkipped() {
        val text = AIShotLogic.geminiText("""{"candidates":[{"content":{"parts":[{"text":"thinking","thought":true},{"text":"{\"a\":1}"}]}}]}""")
        assertEquals("""{"a":1}""", text)
    }

    @Test fun rescaleAboutCenter() {
        val r = AIShotModel.rescale(NRect(0.6, 0.6, 0.2, 0.2), 2.0)
        assertEquals(NRect(0.7, 0.7, 0.4, 0.4), r)
        val part = AIShotModel.trackedPart(NRect(0.2, 0.2, 0.4, 0.4))
        assertEquals(0.4, part.midX, 1e-9)
        assertEquals(0.26, part.width, 1e-9)
    }
}

class TemplateTrackerTest {
    private fun scene(shiftX: Int, shiftY: Int): LumaFrame {
        val w = 160
        val h = 213
        val random = Random(42)
        val base = Array(h + 40) { IntArray(w + 40) { random.nextInt(256) } }
        // Smooth the noise so it looks like real texture.
        val data = ByteArray(w * h)
        for (y in 0 until h) for (x in 0 until w) {
            val sx = x + 20 - shiftX
            val sy = y + 20 - shiftY
            var sum = 0
            for (dy in -1..1) for (dx in -1..1) sum += base[(sy + dy).coerceIn(0, h + 39)][(sx + dx).coerceIn(0, w + 39)]
            data[y * w + x] = (sum / 9).toByte()
        }
        return LumaFrame(w, h, data)
    }

    @Test fun followsAPannedScene() {
        val tracker = TemplateTracker()
        val start = NRect(0.4, 0.4, 0.2, 0.15)
        assertTrue(tracker.seed(scene(0, 0), start))
        val observation = tracker.update(scene(9, -6))
        assertNotNull(observation)
        observation!!
        assertTrue("confidence ${observation.confidence}", observation.confidence > 0.8)
        assertEquals(start.midX + 9.0 / 160, observation.rect.midX, 1.5 / 160)
        assertEquals(start.midY - 6.0 / 213, observation.rect.midY, 1.5 / 213)
    }
}
