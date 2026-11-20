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


/**
 * How the phone is tilted for the level line. [base] is the way the phone is held (0 upright, ±90 sideways,
 * 180 upside down) and [tilt] the small deviation from it, so the line works in any orientation.
 */
data class DeviceTilt(val base: Float = 0f, val tilt: Float = 0f) {
    val isLevel: Boolean get() = abs(tilt) < 1.5f
}

/** Pure angle math for the level (degrees), shared with unit tests. */
object LevelMath {
    /** Angle in (-180, 180]. */
    fun wrap(degrees: Float): Float {
        var a = degrees % 360f
        if (a <= -180f) a += 360f
        if (a > 180f) a -= 360f
        return a
    }

    /** Low-pass that takes the short way round, so passing upside down (±180°) does not spin the line. */
    fun smooth(previous: Float, measured: Float, alpha: Float): Float = wrap(previous + wrap(measured - previous) * alpha)

    /**
     * The orientation the phone is held in, a multiple of 90°. It changes only once the phone is turned
     * more than 55° away from the current one, so it does not flip back and forth around 45°.
     */
    fun base(roll: Float, previousBase: Float): Float {
        if (abs(wrap(roll - previousBase)) <= 55f) return previousBase
        return wrap(Math.round(roll / 90f) * 90f)
    }

    fun tilt(roll: Float, previousBase: Float): DeviceTilt {
        val base = base(roll, previousBase)
        return DeviceTilt(base, wrap(roll - base))
    }
}
