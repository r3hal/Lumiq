package app.lumiq.editing

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.lumiq.AppState
import app.lumiq.library.PhotoStore
import app.lumiq.ui.Glyph
import app.lumiq.ui.GlyphIcon
import app.lumiq.ui.Palette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale

private enum class Tool(val title: String) { Looks("Looks"), Light("Light"), Color("Color"), Effects("Effects") }

/** Capture review and editor: looks, light, color, effects and rotation (non-destructive until saved). */
@Composable
fun PhotoEditorScreen(app: AppState, file: File, captureReview: Boolean, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    var source by remember { mutableStateOf<Bitmap?>(null) }
    var preview by remember { mutableStateOf<Bitmap?>(null) }
    var recipe by remember { mutableStateOf(EditRecipe()) }
    var look by remember { mutableStateOf(Look.Original) }
    var tool by remember { mutableStateOf(Tool.Looks) }
    var saving by remember { mutableStateOf(false) }

    LaunchedEffect(file) { source = withContext(Dispatchers.IO) { PhotoStore.decodeUpright(file, 1600) } }
    LaunchedEffect(source, recipe) {
        val s = source ?: return@LaunchedEffect
        preview = withContext(Dispatchers.Default) { ImageEditor.render(s, recipe) }
    }
    val edited = recipe != EditRecipe()

    fun save(asCopy: Boolean) {
        if (saving) return
        saving = true
        scope.launch {
            withContext(Dispatchers.IO) {
                val full = PhotoStore.decodeUpright(file, 4096)
                if (full != null) {
                    val out = ImageEditor.render(full, recipe)
                    app.store.saveEdited(out, if (asCopy) null else file)
                    out.recycle(); full.recycle()
                }
            }
            saving = false
            onClose()
        }
    }

    Column(Modifier.fillMaxSize().background(Palette.ink)) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClose) { Text(if (captureReview && !edited) "Done" else "Cancel", color = Color.White) }
            Spacer(Modifier.weight(1f))
            if (edited) {
                TextButton({ recipe = EditRecipe(); look = Look.Original }) { Text("Reset", color = Palette.muted) }
                TextButton({ save(asCopy = true) }, enabled = !saving) { Text("Save copy", color = Palette.muted) }
                TextButton({ save(asCopy = false) }, enabled = !saving) { Text("Save", color = Palette.accent, fontWeight = FontWeight.SemiBold) }
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 12.dp), contentAlignment = Alignment.Center) {
            val p = preview
            if (p != null) Image(p.asImageBitmap(), contentDescription = "Photo preview", contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
            else CircularProgressIndicator(color = Palette.accent)
            if (saving) CircularProgressIndicator(color = Palette.accent)
        }
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom = 8.dp)) {
            when (tool) {
                Tool.Looks -> LookStrip(source, look) { chosen -> look = chosen; recipe = chosen.recipe.copy(quarterTurns = recipe.quarterTurns) }
                Tool.Light -> SliderPanel(
                    listOf(
                        Adj("Exposure", recipe.exposure, -1.0, 1.0) { recipe = recipe.copy(exposure = it) },
                        Adj("Contrast", recipe.contrast, 0.5, 1.5) { recipe = recipe.copy(contrast = it) },
                        Adj("Fade", recipe.fade, 0.0, 1.0) { recipe = recipe.copy(fade = it) },
                    ),
                )
                Tool.Color -> SliderPanel(
                    listOf(
                        Adj("Saturation", recipe.saturation, 0.0, 2.0) { recipe = recipe.copy(saturation = it) },
                        Adj("Warmth", recipe.warmth, -1.0, 1.0) { recipe = recipe.copy(warmth = it) },
                        Adj("Tint", recipe.tint, -1.0, 1.0) { recipe = recipe.copy(tint = it) },
                    ),
                )
                Tool.Effects -> Column {
                    SliderPanel(
                        listOf(
                            Adj("Vignette", recipe.vignette, 0.0, 1.0) { recipe = recipe.copy(vignette = it) },
                            Adj("Grain", recipe.grain, 0.0, 1.0) { recipe = recipe.copy(grain = it) },
                        ),
                    )
                    Row(
                        Modifier.padding(horizontal = 20.dp).clip(RoundedCornerShape(10.dp)).clickable { recipe = recipe.copy(quarterTurns = recipe.quarterTurns + 1) }
                            .padding(8.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        GlyphIcon(Glyph.Rotate, Color.White, 20.dp)
                        Text("Rotate", color = Color.White, fontSize = 14.sp)
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 10.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
                Tool.entries.forEach { t ->
                    Text(
                        t.title, color = if (t == tool) Palette.accent else Palette.muted, fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold, letterSpacing = 1.5.sp,
                        modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { tool = t }.padding(horizontal = 10.dp, vertical = 8.dp),
                    )
                }
            }
        }
    }
}

private class Adj(val title: String, val value: Double, val min: Double, val max: Double, val set: (Double) -> Unit)

@Composable
private fun SliderPanel(items: List<Adj>) {
    Column(Modifier.padding(horizontal = 20.dp)) {
        items.forEach { a ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(a.title, color = Color.White, fontSize = 13.sp, modifier = Modifier.width(84.dp))
                Slider(
                    value = a.value.toFloat(), onValueChange = { a.set(it.toDouble()) },
                    valueRange = a.min.toFloat()..a.max.toFloat(), modifier = Modifier.weight(1f),
                    colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Palette.accent, inactiveTrackColor = Color.White.copy(alpha = 0.15f)),
                )
            }
        }
    }
}

@Composable
private fun LookStrip(source: Bitmap?, selected: Look, onSelect: (Look) -> Unit) {
    val thumb = remember(source) { source?.let { Bitmap.createScaledBitmap(it, 120, (120f * it.height / it.width).toInt().coerceAtLeast(1), true) } }
    Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 14.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Look.entries.forEach { look ->
            var rendered by remember(thumb, look) { mutableStateOf<Bitmap?>(null) }
            LaunchedEffect(thumb, look) { rendered = thumb?.let { withContext(Dispatchers.Default) { ImageEditor.render(it, look.recipe) } } }
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.clickable { onSelect(look) }) {
                Box(
                    Modifier.size(64.dp).clip(RoundedCornerShape(10.dp)).background(Palette.panel)
                        .border(if (look == selected) 2.dp else 0.dp, if (look == selected) Palette.accent else Color.Transparent, RoundedCornerShape(10.dp)),
                ) {
                    rendered?.let { Image(it.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
                }
                Spacer(Modifier.height(5.dp))
                Text(look.title, color = if (look == selected) Color.White else Palette.muted, fontSize = 11.sp)
            }
        }
    }
}
