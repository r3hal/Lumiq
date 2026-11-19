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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import app.lumiq.AppState
import app.lumiq.ui.FootNote
import app.lumiq.ui.NavigationRow
import app.lumiq.ui.Palette
import app.lumiq.ui.RowSeparator
import app.lumiq.ui.SettingToggle
import app.lumiq.ui.SettingsSection
import app.lumiq.ui.SheetHeader
import app.lumiq.update.UpdateState
import kotlinx.coroutines.launch

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
            Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 15.dp).navigationBarsPadding().padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(26.dp),
        ) {
            SettingsSection("Camera") {
                SettingToggle("Classic live guide", s.guide, "On-device subject guide (rule of thirds)") { s.updateGuide(it) }
                RowSeparator()
                SettingToggle("Optional grid", s.grid) { s.updateGrid(it) }
                RowSeparator()
                SettingToggle("Optional level", s.level) { s.updateLevel(it) }
                RowSeparator()
                SettingToggle("Shutter sound", s.shutterSound) { s.updateShutterSound(it) }
                RowSeparator()
                SettingToggle("Review after capture", s.reviewAfterCapture) { s.updateReview(it) }
            }
            FootNote(
                "The shutter is always yours. Tap ✦ AI Shot and Lumiq picks the best shot in view, marks it with a yellow box and guides you " +
                    "to center it, zooms in and says Ready. Long-press ✦ for more. Optional grid/level guides are off by default. Pinch to zoom, tap to focus.",
            )
            SettingsSection("Library") {
                SettingToggle("Also save to Gallery", s.autoSaveToGallery, "Copies new photos to Pictures/Lumiq") { on ->
                    val needsPermission = Build.VERSION.SDK_INT < 29 &&
                        ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
                    if (on && needsPermission) storagePermission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE) else s.updateAutoSave(on)
                }
                RowSeparator()
                Row(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 15.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Storage", color = Color.White, fontSize = 16.sp, modifier = Modifier.weight(1f))
                    Text(Formatter.formatShortFileSize(context, app.store.storageBytes), color = Palette.muted, fontSize = 14.sp)
                }
            }
            SettingsSection("Explore") {
                NavigationRow("Golden hour", onClick = onGoldenHour)
            }
            SettingsSection("Lumiq") {
                NavigationRow("How to use Lumiq") { showGuide = true }
                RowSeparator()
                NavigationRow("Send Feedback") {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/r3hal/Lumiq/issues/new")))
                }
                RowSeparator()
                NavigationRow("Privacy Policy") { showPrivacy = true }
                if (app.updater.isEnabled) {
                    RowSeparator()
                    NavigationRow("Check for Updates", value = if (app.updater.state is UpdateState.Checking) "Checking…" else null) { app.updater.checkNow() }
                }
            }
            val version = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: ""
            FootNote("Lumiq $version · Android personal build")
        }
    }
    if (showGuide) InfoDialog("How to use Lumiq", FIELD_GUIDE) { showGuide = false }
    if (showPrivacy) InfoDialog("Privacy Policy", PRIVACY) { showPrivacy = false }
}

@Composable
private fun InfoDialog(title: String, text: String, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onDismiss) { Text("Done") } },
        title = { Text(title) },
        text = { Column(Modifier.verticalScroll(rememberScrollState())) { Text(text, lineHeight = 21.sp) } },
    )
}

private const val FIELD_GUIDE =
    "✦ AI Shot\nTap ✦ and hold the phone still for a moment. The AI picks the best photo in view and marks it with a yellow box. " +
        "Follow the arrow to center the box; Lumiq zooms in automatically and shows Ready. Then press the shutter. " +
        "Tap ↻ to find a different shot, or long-press ✦ to exit.\n\n" +
        "Classic live guide\nAn on-device guide that finds the main subject and helps you place it on a rule-of-thirds point. Turn it on in the ⋯ menu or Settings.\n\n" +
        "Camera\nPinch to zoom, tap to focus, use the lens buttons for 0.5×/1×/2×/5× when your phone has those cameras. " +
        "The aperture button shows exposure compensation. The aspect button changes the photo shape.\n\n" +
        "Library and editing\nYour photos stay in Lumiq's library. Open one to share, edit with film looks and light/color controls, or delete. " +
        "Turn on 'Also save to Gallery' to copy new photos to Pictures/Lumiq."

private const val PRIVACY =
    "Camera frames, subject detection and tracking are processed on your phone. Lumiq has no analytics and no account. " +
        "AI Shot sends one compressed frame only when you tap ✦, to Google Gemini; it is not stored by Lumiq. " +
        "Photos are stored in Lumiq's private app storage, and copied to your Gallery only if you turn that on. " +
        "Golden-hour location is requested only when you ask; it is not stored, uploaded or added to photos. " +
        "To look for updates, Lumiq asks GitHub for its newest release when it starts and when you tap Check for Updates; nothing about you or your photos is sent. " +
        "Sharing and feedback happen only when you start them. Lumiq (formerly Focal) is an independent personal app."
