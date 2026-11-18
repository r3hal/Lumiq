package app.lumiq.ui

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/** Small haptic vocabulary matching the iPhone feedback generators. */
class Haptics(context: Context) {
    private val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= 31) {
        (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }

    private fun play(predefined: Int, fallbackMs: Long, amplitude: Int) {
        val v = vibrator ?: return
        if (!v.hasVibrator()) return
        runCatching {
            if (Build.VERSION.SDK_INT >= 29) v.vibrate(VibrationEffect.createPredefined(predefined))
            else v.vibrate(VibrationEffect.createOneShot(fallbackMs, amplitude))
        }
    }

    fun soft() = play(VibrationEffect.EFFECT_TICK, 10, 60)
    fun medium() = play(VibrationEffect.EFFECT_CLICK, 18, 140)
    fun success() = play(VibrationEffect.EFFECT_DOUBLE_CLICK, 25, 120)
    fun warning() = play(VibrationEffect.EFFECT_HEAVY_CLICK, 35, 200)
}
