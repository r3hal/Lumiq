package app.lumiq.settings

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import app.lumiq.AppState
import app.lumiq.ui.DialogText
import app.lumiq.ui.Glyph
import app.lumiq.ui.GlyphTile
import app.lumiq.ui.LumiqDialog
import app.lumiq.ui.LumiqLogo
import app.lumiq.ui.NavigationRow
import app.lumiq.ui.Palette
import app.lumiq.ui.RowSeparator
import app.lumiq.ui.SettingToggle
import app.lumiq.ui.SettingsSection
import app.lumiq.ui.SheetHeader
import app.lumiq.ui.ValueRow
import app.lumiq.update.UpdateState

@Composable
fun SettingsScreen(app: AppState, onClose: () -> Unit, onGoldenHour: () -> Unit) {
    val context = LocalContext.current
    val s = app.settings
    var showGuide by remember { mutableStateOf(false) }
    var showPrivacy by remember { mutableStateOf(false) }
    val storagePermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok -> if (ok) s.updateAutoSave(true) }

    Column(Modifier.fillMaxSize().background(Palette.ink)) {
        SheetHeader("Settings", onClose)
        Column(
            Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).navigationBarsPadding().padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            SettingsSection("Camera") {
                SettingToggle("Classic live guide", s.guide, "On-device rule-of-thirds guide", Glyph.Aperture) { s.updateGuide(it) }
                RowSeparator()
                SettingToggle("Grid", s.grid, glyph = Glyph.Grid) { s.updateGrid(it) }
                RowSeparator()
                SettingToggle("Level", s.level, glyph = Glyph.Level) { s.updateLevel(it) }
                RowSeparator()
                SettingToggle("Shutter sound", s.shutterSound, glyph = Glyph.Speaker) { s.updateShutterSound(it) }
                RowSeparator()
                SettingToggle("Review after capture", s.reviewAfterCapture, glyph = Glyph.Eye) { s.updateReview(it) }
            }
            if (app.learning.isAvailable) {
                SettingsSection("AI Shot") {
                    SettingToggle(
                        "Help AI Shot learn", app.learning.consent == true,
                        "Shares anonymous AI Shot results, never photos", Glyph.Aperture,
                    ) { app.learning.updateConsent(it) }
                }
            }
            SettingsSection("Library") {
                SettingToggle("Also save to Gallery", s.autoSaveToGallery, "Copies new photos to Pictures/Lumiq", Glyph.Photo) { on ->
                    val needsPermission = Build.VERSION.SDK_INT < 29 &&
                        ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
                    if (on && needsPermission) storagePermission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE) else s.updateAutoSave(on)
                }
                RowSeparator()
                ValueRow("Storage", Formatter.formatShortFileSize(context, app.store.storageBytes), Glyph.Disk)
            }
            SettingsSection("Explore") {
                NavigationRow("Golden hour", glyph = Glyph.Sun, onClick = onGoldenHour)
            }
            SettingsSection("Lumiq") {
                NavigationRow("How to use Lumiq", glyph = Glyph.Info) { showGuide = true }
                RowSeparator()
                NavigationRow("Send feedback", glyph = Glyph.Chat) {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/r3hal/Lumiq/issues/new")))
                }
                RowSeparator()
                NavigationRow("Privacy", glyph = Glyph.Shield) { showPrivacy = true }
                if (app.updater.isEnabled) {
                    RowSeparator()
                    NavigationRow("Check for updates", value = if (app.updater.state is UpdateState.Checking) "Checking…" else null, glyph = Glyph.Download) {
                        app.updater.checkNow()
                    }
                }
            }
            val version = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: ""
            Column(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                LumiqLogo(height = 18.dp, textColor = Palette.muted, starColor = Palette.accent)
                Text("Version $version", color = Palette.muted.copy(alpha = 0.7f), fontSize = 12.sp)
            }
        }
    }
    if (showGuide) GuideDialog { showGuide = false }
    if (showPrivacy) {
        LumiqDialog("Privacy", onDismiss = { showPrivacy = false }, primary = "Done" to { showPrivacy = false }) { DialogText(PRIVACY) }
    }
}

@Composable
private fun GuideDialog(onDismiss: () -> Unit) {
    LumiqDialog("How to use Lumiq", onDismiss = onDismiss, primary = "Got it" to onDismiss) { GuideContent() }
}

/** The field guide as titled sections. */
@Composable
fun GuideContent() {
    Column(Modifier.heightIn(max = 460.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        for ((glyph, title, body) in FIELD_GUIDE) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                GlyphTile(glyph)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(title, color = Palette.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    Text(body, color = Palette.muted, fontSize = 14.sp, lineHeight = 20.sp)
                }
            }
        }
    }
}

private val FIELD_GUIDE = listOf(
    Triple(
        Glyph.Aperture, "AI Shot",
        "Tap AI Shot and hold the phone still for a moment. The AI picks the best photo in view and marks it with a yellow box. " +
            "Follow the arrow to center it; Lumiq zooms in and shows Ready. Then press the shutter. Tap ↻ for a different shot, or long-press AI Shot to exit.",
    ),
    Triple(Glyph.Grid, "Classic live guide", "An on-device guide that finds the main subject and helps you place it on a rule-of-thirds point. Turn it on in the ⋯ menu or Settings."),
    Triple(
        Glyph.Photo, "Camera",
        "Pinch to zoom, tap to focus, and use the lens buttons for 0.5×/1×/2×/5× when your phone has those cameras. " +
            "The aperture button sets exposure; the aspect button changes the photo shape.",
    ),
    Triple(
        Glyph.Edit, "Library and editing",
        "Your photos stay in Lumiq's library. Open one to share, edit with film looks and light/color controls, or delete. " +
            "Turn on Also save to Gallery to copy new photos to Pictures/Lumiq.",
    ),
)

private const val PRIVACY =
    "Camera frames, subject detection and tracking are processed on your phone. Lumiq has no analytics and no account. " +
        "AI Shot sends one compressed frame only when you tap AI Shot, to Google Gemini; it is not stored by Lumiq. " +
        "If you turn on Help AI Shot learn, Lumiq sends the result of each AI Shot to the Lumiq learning server: the AI's suggestion " +
        "(subject words, technique, zoom, crop size, model), the photo shape, whether you took the photo or asked for another shot, and your zoom. " +
        "No photos, location or device details are sent, and nothing is saved on your phone; a random id links the results of one app session. " +
        "The server combines everyone's results into short rules that improve AI Shot's picks. " +
        "Photos are stored in Lumiq's private app storage, and copied to your Gallery only if you turn that on. " +
        "Golden-hour location is requested only when you ask; it is not stored, uploaded or added to photos. " +
        "To look for updates, Lumiq asks GitHub for its newest release when it starts and when you tap Check for Updates; nothing about you or your photos is sent. " +
        "Sharing and feedback happen only when you start them. Lumiq (formerly Focal) is an independent personal app."
