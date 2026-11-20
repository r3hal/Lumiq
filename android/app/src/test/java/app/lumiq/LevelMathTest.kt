package app.lumiq

import app.lumiq.aishot.LevelMath
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LevelMathTest {
    @Test fun uprightTiltIsMeasuredFromUpright() {
        val t = LevelMath.tilt(3f, 0f)
        assertEquals(0f, t.base, 0f)
        assertEquals(3f, t.tilt, 1e-4f)
        assertFalse(t.isLevel)
        assertTrue(LevelMath.tilt(0.8f, 0f).isLevel)
    }

    @Test fun sidewaysTiltIsMeasuredFromSideways() {
        // Turned to landscape either way: the reticle turns 90° and the line shows only the small tilt.
        val right = LevelMath.tilt(92f, 0f)
        assertEquals(90f, right.base, 0f)
        assertEquals(2f, right.tilt, 1e-4f)
        val left = LevelMath.tilt(-89.5f, 0f)
        assertEquals(-90f, left.base, 0f)
        assertTrue(left.isLevel)
    }

    @Test fun upsideDownWorks() {
        val t = LevelMath.tilt(-178f, 90f)
        assertEquals(180f, t.base, 0f)
        assertEquals(2f, t.tilt, 1e-4f)
    }

    @Test fun doesNotFlipBackAndForthNear45Degrees() {
        // Still counted as upright until clearly sideways (more than 55°), and stays sideways down to 35°.
        assertEquals(0f, LevelMath.tilt(50f, 0f).base, 0f)
        assertEquals(90f, LevelMath.tilt(60f, 0f).base, 0f)
        assertEquals(90f, LevelMath.tilt(40f, 90f).base, 0f)
        assertEquals(0f, LevelMath.tilt(30f, 90f).base, 0f)
    }

    @Test fun smoothingTakesTheShortWayRound() {
        // From 179° to -179° is a 2° step, not a 358° spin.
        val next = LevelMath.smooth(179f, -179f, 0.5f)
        assertEquals(180f, kotlin.math.abs(next), 1e-3f)
        assertEquals(10f, LevelMath.smooth(0f, 20f, 0.5f), 1e-4f)
        assertEquals(-170f, LevelMath.wrap(190f), 1e-4f)
        assertEquals(180f, LevelMath.wrap(-180f), 1e-4f)
    }
}
