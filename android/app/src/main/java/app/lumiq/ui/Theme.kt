package app.lumiq.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

/**
 * Lumiq's color system. App chrome uses the brand's ink surfaces and iris accent;
 * amber `yellow` is reserved for guidance on the camera image (the AI Shot box, Ready),
 * so it always means "aim here".
 */
object Palette {
    /** Screen background. */
    val ink = Color(0xFF0B0B10)
    /** Cards and grouped rows. */
    val panel = Color(0xFF16161F)
    /** Menus, dialogs and other surfaces floating above a card. */
    val raised = Color(0xFF1F1F2B)
    /** Hairline edge around cards and floating surfaces. */
    val stroke = Color.White.copy(alpha = 0.07f)
    /** Frosted controls drawn over the camera image or the background. */
    val glass = Color.White.copy(alpha = 0.10f)
    val text = Color(0xFFF6F5FA)
    val muted = Color(0xFF9C9AAB)
    /** Brand accent for selection, switches and primary buttons (Soft Iris). */
    val accent = Color(0xFFAEA2FF)
    /** Filled brand surfaces (Iris). */
    val accentStrong = Color(0xFF6551D8)
    val danger = Color(0xFFFF6B6B)
    val paper = Color(0.95f, 0.94f, 0.90f)
    val mint = Color(0.45f, 0.74f, 0.58f)
    /** Viewfinder guidance only. */
    val yellow = Color(237, 202, 103)
    val orange = Color(0xFFFF9F0A)

    /** The AI Shot button and other signature brand fills. */
    val irisGradient: Brush get() = Brush.linearGradient(listOf(Color(0xFF7B67F0), Color(0xFF5140C4)))
}

/** Lumiq logo system: Ink #15151D, Porcelain #F6F5FA, Iris #6551D8, Soft Iris #AEA2FF. */
object Brand {
    val ink = Color(0xFF15151D)
    val porcelain = Color(0xFFF6F5FA)
    val iris = Color(0xFF6551D8)
    val softIris = Color(0xFFAEA2FF)
}

@Composable
fun LumiqTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Palette.accent,
            onPrimary = Color(0xFF14102E),
            secondary = Palette.mint,
            background = Palette.ink,
            onBackground = Palette.text,
            surface = Palette.ink,
            onSurface = Palette.text,
            surfaceVariant = Palette.panel,
            onSurfaceVariant = Palette.muted,
            surfaceTint = Color.Transparent,
            surfaceContainerLowest = Palette.ink,
            surfaceContainerLow = Palette.panel,
            surfaceContainer = Palette.raised,
            surfaceContainerHigh = Palette.raised,
            surfaceContainerHighest = Palette.raised,
            outline = Palette.stroke,
            outlineVariant = Palette.stroke,
            error = Palette.danger,
        ),
        content = content,
    )
}
