package app.lumiq.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** Same palette as the iPhone app (Focal/Design/Theme.swift). */
object Palette {
    val ink = Color(16, 17, 18)
    val panel = Color(35, 37, 39)
    val text = Color(247, 247, 247)
    val muted = Color(158, 163, 168)
    val paper = Color(0.95f, 0.94f, 0.90f)
    val mint = Color(0.45f, 0.74f, 0.58f)
    val yellow = Color(237, 202, 103)
    val orange = Color(0xFFFF9F0A)
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
            primary = Palette.yellow,
            onPrimary = Color.Black,
            secondary = Palette.mint,
            background = Palette.ink,
            onBackground = Palette.text,
            surface = Palette.ink,
            onSurface = Palette.text,
            surfaceVariant = Palette.panel,
            onSurfaceVariant = Palette.muted,
            surfaceContainer = Palette.panel,
            surfaceContainerHigh = Color(0xFF2C2E31),
            surfaceContainerLow = Color(0xFF1A1B1D),
        ),
        content = content,
    )
}
