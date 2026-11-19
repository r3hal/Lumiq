package app.lumiq.aishot

import kotlin.math.PI
import kotlin.math.abs

/**
 * Adaptive low-pass filter ("1€ filter", Casiez et al. 2012). When the input barely moves, it smooths
 * heavily, which removes hand tremor and tracker noise. When the input moves fast, the cutoff rises, so
 * the output follows a real pan without lagging behind.
 *
 * @param minCutoff cutoff in Hz while still (lower = steadier)
 * @param beta how quickly the cutoff rises with speed (higher = less lag while moving)
 * @param derivativeCutoff cutoff in Hz for the speed estimate
 */
class OneEuroFilter(
    private val minCutoff: Double,
    private val beta: Double,
    private val derivativeCutoff: Double = 1.0,
) {
    private var value = 0.0
    private var speed = 0.0
    private var lastTime = Double.NaN

    val isPrimed get() = !lastTime.isNaN()

    fun reset(to: Double? = null, time: Double = Double.NaN) {
        speed = 0.0
        if (to == null) { lastTime = Double.NaN; return }
        value = to
        lastTime = time
    }

    /** Filters [input] observed at [time] seconds. */
    fun filter(input: Double, time: Double): Double {
        if (lastTime.isNaN()) {
            value = input; speed = 0.0; lastTime = time
            return input
        }
        val dt = (time - lastTime).coerceIn(1e-3, 0.5)
        lastTime = time
        val rawSpeed = (input - value) / dt
        speed += alpha(derivativeCutoff, dt) * (rawSpeed - speed)
        val cutoff = minCutoff + beta * abs(speed)
        value += alpha(cutoff, dt) * (input - value)
        return value
    }

    private fun alpha(cutoff: Double, dt: Double): Double {
        val tau = 1.0 / (2 * PI * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}

