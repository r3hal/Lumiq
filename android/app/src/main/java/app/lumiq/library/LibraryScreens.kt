package app.lumiq.library

import android.graphics.Bitmap
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.lumiq.AppState
import app.lumiq.ui.Glyph
import app.lumiq.ui.GlyphIcon
import app.lumiq.ui.Palette
import app.lumiq.ui.SheetHeader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.text.DateFormat
import java.util.Date

@Composable
fun LibraryScreen(app: AppState, onClose: () -> Unit, onOpen: (File) -> Unit) {
    val photos = app.store.photos
    Column(Modifier.fillMaxSize().background(Palette.ink)) {
        SheetHeader("Library", onClose)
        if (photos.isEmpty()) {
            Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                GlyphIcon(Glyph.Photo, Palette.muted, 40.dp)
                Text("No photos yet", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 14.dp))
                Text("Photos you take with Lumiq appear here.", color = Palette.muted, fontSize = 14.sp, modifier = Modifier.padding(top = 6.dp))
            }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                contentPadding = PaddingValues(start = 2.dp, end = 2.dp, bottom = 24.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
                modifier = Modifier.navigationBarsPadding(),
            ) {
                items(photos, key = { it.path }) { file ->
                    Thumbnail(app, file, Modifier.aspectRatio(1f).clickable { onOpen(file) })
                }
            }
        }
    }
}

@Composable
private fun Thumbnail(app: AppState, file: File, modifier: Modifier) {
    var bitmap by remember(file, file.lastModified()) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(file, file.lastModified()) { bitmap = withContext(Dispatchers.IO) { app.store.thumbnail(file) } }
    Box(modifier.background(Palette.panel)) {
        bitmap?.let { Image(it.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PhotoViewerScreen(app: AppState, start: File, onClose: () -> Unit, onEdit: (File) -> Unit) {
    val context = LocalContext.current
    val photos = app.store.photos
    if (photos.isEmpty()) { LaunchedEffect(Unit) { onClose() }; return }
    val pager = rememberPagerState(initialPage = photos.indexOf(start).coerceAtLeast(0)) { photos.size }
    var confirmDelete by remember { mutableStateOf<File?>(null) }
    val current = photos.getOrNull(pager.currentPage.coerceIn(0, photos.size - 1))

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        HorizontalPager(pager, modifier = Modifier.fillMaxSize(), key = { photos.getOrNull(it)?.path ?: it.toString() }) { page ->
            val file = photos.getOrNull(page) ?: return@HorizontalPager
            var bitmap by remember(file, file.lastModified()) { mutableStateOf<Bitmap?>(null) }
            LaunchedEffect(file, file.lastModified()) { bitmap = withContext(Dispatchers.IO) { PhotoStore.decodeUpright(file, 2400) } }
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                val b = bitmap
                if (b != null) Image(b.asImageBitmap(), contentDescription = "Photo", contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
                else CircularProgressIndicator(color = Palette.yellow)
            }
        }
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            ViewerButton(Glyph.Back, "Back", onClose)
            Text(
                current?.let { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it.lastModified())) } ?: "",
                color = Color.White, fontSize = 13.sp, modifier = Modifier.padding(start = 12.dp).weight(1f),
            )
        }
        Row(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding().padding(horizontal = 40.dp, vertical = 18.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            ViewerButton(Glyph.Share, "Share") { current?.let { context.startActivity(app.store.shareIntent(it)) } }
            ViewerButton(Glyph.Edit, "Edit") { current?.let(onEdit) }
            ViewerButton(Glyph.Trash, "Delete") { confirmDelete = current }
        }
    }
    confirmDelete?.let { file ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text("Delete photo?") },
            text = { Text("This removes it from the Lumiq library. Copies already saved to your Gallery stay there.") },
            confirmButton = { TextButton({ app.store.delete(file); confirmDelete = null }) { Text("Delete", color = Color(0xFFFF6B6B)) } },
            dismissButton = { TextButton({ confirmDelete = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun ViewerButton(glyph: Glyph, label: String, onClick: () -> Unit) {
    Box(
        Modifier.clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.55f)).clickable(onClickLabel = label, onClick = onClick).padding(12.dp),
        contentAlignment = Alignment.Center,
    ) { GlyphIcon(glyph, Color.White, 22.dp) }
}
