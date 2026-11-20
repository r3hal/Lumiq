package app.lumiq.editing

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.gestures.snapping.SnapPosition
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlin.math.abs
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import app.lumiq.ui.DialogText
import app.lumiq.ui.LumiqDialog
import app.lumiq.ui.LumiqMenu
import app.lumiq.ui.MenuRow
import app.lumiq.ui.Pill
import app.lumiq.ui.SecondaryButton
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

private enum class Tool(val title: String) { Looks("Looks"), Adjust("Adjust"), Effects("Effects") }

/** One step in the editor's undo history. */
private data class EditState(val recipe: EditRecipe = EditRecipe(), val look: Look = Look.Original)

/**
 * Capture review and editor: the photo, a tab bar (Looks · Adjust · Effects), the tool, and a bottom row
 * with Delete (Cancel when editing from the library), undo/redo and Save. Non-destructive until saved.
 */
@Composable
fun PhotoEditorScreen(app: AppState, file: File, captureReview: Boolean, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    var source by remember { mutableStateOf<Bitmap?>(null) }
    var preview by remember { mutableStateOf<Bitmap?>(null) }
    var state by remember { mutableStateOf(EditState()) }
    val history = remember { mutableStateListOf(EditState()) }
    var position by remember { mutableIntStateOf(0) }
    var tool by remember { mutableStateOf(Tool.Looks) }
    var saving by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var showSaveMenu by remember { mutableStateOf(false) }
    val recipe = state.recipe

    LaunchedEffect(file) { source = withContext(Dispatchers.IO) { PhotoStore.decodeUpright(file, 1600) } }
    LaunchedEffect(source, recipe) {
        val s = source ?: return@LaunchedEffect
        preview = withContext(Dispatchers.Default) { ImageEditor.render(s, recipe) }
    }
    val edited = recipe != EditRecipe()

    /** Records the current state as an undo step (after a look, a finished slider drag or a rotation). */
    fun commit() {
        if (history.getOrNull(position) == state) return
        while (history.size > position + 1) history.removeAt(history.lastIndex)
        history.add(state)
        position = history.lastIndex
    }
    fun undo() { if (position > 0) { position--; state = history[position] } }
    fun redo() { if (position < history.lastIndex) { position++; state = history[position] } }
    fun setRecipe(r: EditRecipe) { state = state.copy(recipe = r) }

    fun save(asCopy: Boolean) {
        if (saving) return
        if (!edited) { onClose(); return } // Nothing changed: the photo is already in the library.
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

    Column(Modifier.fillMaxSize().background(Palette.ink).statusBarsPadding().navigationBarsPadding()) {
        // The photo.
        Box(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp), contentAlignment = Alignment.Center) {
            val p = preview
            if (p != null) {
                Image(
                    p.asImageBitmap(), contentDescription = "Photo preview", contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize().clip(RoundedCornerShape(14.dp)),
                )
            } else {
                CircularProgressIndicator(color = Palette.accent)
            }
            if (saving) {
                Pill { Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(Modifier.size(14.dp), color = Palette.text, strokeWidth = 2.dp)
                    Text("Saving…", color = Palette.text, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                } }
            }
        }
        // Tab bar.
        Row(
            Modifier.align(Alignment.CenterHorizontally).padding(vertical = 6.dp).clip(RoundedCornerShape(50)).background(Palette.panel)
                .border(1.dp, Palette.stroke, RoundedCornerShape(50)).padding(4.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Tool.entries.forEach { t ->
                val selected = t == tool
                Text(
                    t.title, color = if (selected) Palette.text else Palette.muted, fontSize = 14.sp,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                    modifier = Modifier.clip(RoundedCornerShape(50)).background(if (selected) Color.White.copy(alpha = 0.12f) else Color.Transparent)
                        .clickable { tool = t }.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
        }
        // The tool.
        Box(Modifier.fillMaxWidth().height(150.dp), contentAlignment = Alignment.Center) {
            when (tool) {
                Tool.Looks -> LookStrip(source, state.look) { chosen ->
                    state = EditState(chosen.recipe.copy(quarterTurns = recipe.quarterTurns), chosen)
                    commit()
                }
                Tool.Adjust -> SliderPanel(
                    listOf(
                        Adj("Exposure", recipe.exposure, -1.0, 1.0) { setRecipe(recipe.copy(exposure = it)) },
                        Adj("Contrast", recipe.contrast, 0.5, 1.5) { setRecipe(recipe.copy(contrast = it)) },
                        Adj("Saturation", recipe.saturation, 0.0, 2.0) { setRecipe(recipe.copy(saturation = it)) },
                        Adj("Warmth", recipe.warmth, -1.0, 1.0) { setRecipe(recipe.copy(warmth = it)) },
                        Adj("Tint", recipe.tint, -1.0, 1.0) { setRecipe(recipe.copy(tint = it)) },
                    ),
                    onDone = ::commit,
                )
                Tool.Effects -> Column {
                    SliderPanel(
                        listOf(
                            Adj("Fade", recipe.fade, 0.0, 1.0) { setRecipe(recipe.copy(fade = it)) },
                            Adj("Vignette", recipe.vignette, 0.0, 1.0) { setRecipe(recipe.copy(vignette = it)) },
                            Adj("Grain", recipe.grain, 0.0, 1.0) { setRecipe(recipe.copy(grain = it)) },
                        ),
                        onDone = ::commit,
                    )
                    Row(
                        Modifier.padding(horizontal = 20.dp).clip(RoundedCornerShape(10.dp))
                            .clickable { setRecipe(recipe.copy(quarterTurns = recipe.quarterTurns + 1)); commit() }.padding(8.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        GlyphIcon(Glyph.Rotate, Palette.text, 20.dp)
                        Text("Rotate", color = Palette.text, fontSize = 14.sp)
                    }
                }
            }
        }
        // Delete/Cancel · undo/redo · Save.
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            if (captureReview) SecondaryButton("Delete", { confirmDelete = true }) else SecondaryButton("Cancel", onClose)
            Spacer(Modifier.weight(1f))
            HistoryButton(Glyph.Undo, "Undo", enabled = position > 0, onClick = ::undo)
            HistoryButton(Glyph.Redo, "Redo", enabled = position < history.lastIndex, onClick = ::redo)
            Spacer(Modifier.weight(1f))
            Box {
                Row(
                    Modifier.heightIn(min = 46.dp).clip(RoundedCornerShape(50)).background(Palette.accent)
                        .clickable(enabled = !saving) { if (!captureReview && edited) showSaveMenu = true else save(asCopy = false) }
                        .padding(horizontal = 20.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    GlyphIcon(Glyph.Tick, Color(0xFF14102E), 16.dp)
                    Text("Save", color = Color(0xFF14102E), fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
                LumiqMenu(showSaveMenu, onDismiss = { showSaveMenu = false }) {
                    MenuRow("Save", Glyph.Tick) { showSaveMenu = false; save(asCopy = false) }
                    MenuRow("Save as copy", Glyph.Photo) { showSaveMenu = false; save(asCopy = true) }
                }
            }
        }
    }
    if (confirmDelete) {
        LumiqDialog(
            "Delete photo?", onDismiss = { confirmDelete = false },
            primary = "Delete" to { confirmDelete = false; app.store.delete(file); onClose() },
            secondary = "Keep" to { confirmDelete = false }, destructive = true,
        ) { DialogText("This removes it from the Lumiq library. Copies already saved to your Gallery stay there.") }
    }
}

@Composable
private fun HistoryButton(glyph: Glyph, label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(44.dp).clip(CircleShape).clickable(enabled = enabled, onClickLabel = label, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { GlyphIcon(glyph, if (enabled) Palette.text else Palette.muted.copy(alpha = 0.4f), 20.dp) }
}

private class Adj(val title: String, val value: Double, val min: Double, val max: Double, val set: (Double) -> Unit)

@Composable
private fun SliderPanel(items: List<Adj>, onDone: () -> Unit) {
    Column(Modifier.padding(horizontal = 20.dp).verticalScroll(rememberScrollState())) {
        items.forEach { a ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(a.title, color = Color.White, fontSize = 13.sp, modifier = Modifier.width(84.dp))
                Slider(
                    value = a.value.toFloat(), onValueChange = { a.set(it.toDouble()) },
                    valueRange = a.min.toFloat()..a.max.toFloat(), onValueChangeFinished = onDone, modifier = Modifier.weight(1f),
                    colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Palette.accent, inactiveTrackColor = Color.White.copy(alpha = 0.15f)),
                )
            }
        }
    }
}

/**
 * Looks carousel: the look in the middle is the chosen one, so scrolling previews each look on the photo
 * as it passes the center. Tapping a look scrolls it to the middle.
 */
@Composable
private fun LookStrip(source: Bitmap?, selected: Look, onSelect: (Look) -> Unit) {
    val thumb = remember(source) { source?.let { Bitmap.createScaledBitmap(it, 120, (120f * it.height / it.width).toInt().coerceAtLeast(1), true) } }
    val looks = Look.entries
    val state = rememberLazyListState(initialFirstVisibleItemIndex = looks.indexOf(selected).coerceAtLeast(0))
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val current by rememberUpdatedState(selected)
    val choose by rememberUpdatedState(onSelect)

    LaunchedEffect(state) {
        snapshotFlow { centeredIndex(state) }.filterNotNull().distinctUntilChanged().collect { index ->
            val look = looks.getOrNull(index) ?: return@collect
            if (look != current) {
                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                choose(look)
            }
        }
    }
    // Reset (or any outside change) brings the chosen look back to the middle.
    LaunchedEffect(selected) {
        val index = looks.indexOf(selected)
        if (!state.isScrollInProgress && centeredIndex(state) != index) state.animateScrollToItem(index)
    }

    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val itemWidth = 64.dp
        val side = ((maxWidth - itemWidth) / 2).coerceAtLeast(0.dp)
        LazyRow(
            state = state,
            flingBehavior = rememberSnapFlingBehavior(state, SnapPosition.Center),
            contentPadding = PaddingValues(horizontal = side),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            itemsIndexed(looks) { index, look ->
                var rendered by remember(thumb, look) { mutableStateOf<Bitmap?>(null) }
                LaunchedEffect(thumb, look) { rendered = thumb?.let { withContext(Dispatchers.Default) { ImageEditor.render(it, look.recipe) } } }
                val isSelected = look == selected
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.width(itemWidth).clip(RoundedCornerShape(12.dp)).clickable { scope.launch { state.animateScrollToItem(index) } },
                ) {
                    Box(
                        Modifier.size(itemWidth).clip(RoundedCornerShape(12.dp)).background(Palette.panel)
                            .border(if (isSelected) 2.dp else 0.dp, if (isSelected) Palette.accent else Color.Transparent, RoundedCornerShape(12.dp)),
                    ) {
                        rendered?.let { Image(it.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(
                        look.title, color = if (isSelected) Palette.text else Palette.muted, fontSize = 11.sp,
                        fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1,
                    )
                }
            }
        }
    }
}

/** Index of the item whose center is closest to the middle of the strip. */
private fun centeredIndex(state: LazyListState): Int? {
    val info = state.layoutInfo
    val center = (info.viewportStartOffset + info.viewportEndOffset) / 2
    return info.visibleItemsInfo.minByOrNull { abs(it.offset + it.size / 2 - center) }?.index
}
