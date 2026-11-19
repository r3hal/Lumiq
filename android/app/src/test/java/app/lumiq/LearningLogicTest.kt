package app.lumiq

import app.lumiq.aishot.AIShotLogic
import app.lumiq.aishot.AIShotRequest
import app.lumiq.aishot.LearningLogic
import app.lumiq.aishot.ShotOutcome
import app.lumiq.aishot.ShotResult
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LearningLogicTest {
    private val result = ShotResult(
        model = "gemini-flash-lite-latest", technique = "detail", subject = "red mug", aiZoom = 2.5, startZoom = 1.0,
        crop = 0.4, aspect = 0.75, outcome = ShotOutcome.Taken, reachedReady = true, secondsToReady = 3.21234, userZoom = 2.6,
    )

    @Test fun feedbackHasTheServerFieldsAndNoImage() {
        val json = JSONObject(LearningLogic.feedbackJson(result, "a1b2c3d4-0000", "3.2.1-android"))
        assertEquals("taken", json.getString("outcome"))
        assertEquals("a1b2c3d4-0000", json.getString("session"))
        assertEquals(2.5, json.getDouble("aiZoom"), 1e-9)
        assertEquals(3.212, json.getDouble("secondsToReady"), 1e-9)
        assertTrue(json.getBoolean("reachedReady"))
        val keys = json.keys().asSequence().toSet()
        assertEquals(
            setOf("session", "model", "technique", "subject", "aiZoom", "startZoom", "crop", "aspect", "outcome", "reachedReady", "secondsToReady", "userZoom", "app"),
            keys,
        )
    }

    @Test fun missingValuesAreLeftOut() {
        val json = JSONObject(LearningLogic.feedbackJson(result.copy(outcome = ShotOutcome.NewShot, secondsToReady = null, userZoom = null), "a1b2c3d4-0000", "x"))
        assertEquals("new_shot", json.getString("outcome"))
        assertFalse(json.has("secondsToReady"))
        assertFalse(json.has("userZoom"))
    }

    @Test fun guidanceIsLimitedAndCleaned() {
        val body = """{"samples":50,"guidance":["Choose tighter crops.","line\nbreak","","${"x".repeat(300)}","4","5","6"]}"""
        val rules = LearningLogic.parseGuidance(body)
        assertEquals(5, rules.size)
        assertEquals("Choose tighter crops.", rules[0])
        assertEquals("line break", rules[1])
        assertEquals(160, rules[2].length)
        assertEquals(emptyList<String>(), LearningLogic.parseGuidance("not json"))
    }

    @Test fun promptIncludesLearnedRulesOnlyWhenThereAreSome() {
        val plain = AIShotRequest(ByteArray(0), 0.75, 1.0, 0.5, 6.0)
        assertFalse(AIShotLogic.prompt(plain).contains("Lumiq users"))
        val learned = AIShotLogic.prompt(AIShotRequest(ByteArray(0), 0.75, 1.0, 0.5, 6.0, listOf("Choose tighter crops.")))
        assertTrue(learned.endsWith("What Lumiq users have chosen recently (apply when relevant):\n- Choose tighter crops."))
    }
}
