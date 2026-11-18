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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import app.lumiq.AppState
import app.lumiq.aishot.AIShotService
import app.lumiq.ui.FootNote
import app.lumiq.ui.Glyph
import app.lumiq.ui.NavigationRow
import app.lumiq.ui.Palette
import app.lumiq.ui.RowSeparator
import app.lumiq.ui.SettingToggle
import app.lumiq.ui.SettingsSection
import app.lumiq.ui.SheetHeader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun SettingsScreen(app: AppState, onClose: () -> Unit, onAIShot: () -> Unit, onGoldenHour: () -> Unit) {
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
                NavigationRow("AI Shot (free AI setup)", value = if (app.aiConfig.isConfigured) "On" else "Set up", onClick = onAIShot)
                RowSeparator()
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

/** AI Shot setup, same fields as iPhone AIShotSettingsView. */
@Composable
fun AIShotSettingsScreen(app: AppState, onClose: () -> Unit) {
    val config = app.aiConfig
    val scope = rememberCoroutineScope()
    var server by remember { mutableStateOf(config.serverText) }
    var token by remember { mutableStateOf(config.tokenText) }
    var gemini by remember { mutableStateOf(config.geminiKey() ?: "") }
    var testing by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<String?>(null) }

    fun persist() {
        config.serverText = server
        config.tokenText = token
        config.setGeminiKey(gemini)
    }

    Column(Modifier.fillMaxSize().background(Palette.ink)) {
        SheetHeader("AI Shot", { persist(); onClose() }, closeGlyph = Glyph.Back)
        Column(
            Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).navigationBarsPadding().padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                "AI Shot sends one small, compressed frame of the current view to a free AI, which picks the best shot. " +
                    "Use your own free Lumiq AI server (recommended) or a free Gemini key.",
                color = Palette.muted, fontSize = 14.sp, lineHeight = 20.sp,
            )
            Text("LUMIQ AI SERVER", color = Palette.muted, fontSize = 11.sp, letterSpacing = 2.sp)
            Field("Server URL (https://…workers.dev)", server, KeyboardType.Uri) { server = it; result = null }
            Field("App token", token, KeyboardType.Password, secret = true) { token = it }
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton({
                    persist(); testing = true; result = null
                    scope.launch {
                        result = withContext(Dispatchers.IO) { AIShotService(config).testServer() }
                        testing = false
                    }
                }, enabled = !testing) { Text("Test server", color = Palette.yellow) }
                if (testing) CircularProgressIndicator(Modifier.padding(start = 8.dp).height(16.dp), color = Palette.yellow, strokeWidth = 2.dp)
                result?.let { Text(it, color = if (it.startsWith("Server OK")) Palette.mint else Palette.orange, fontSize = 13.sp, modifier = Modifier.padding(start = 8.dp)) }
            }
            Text("OR: GEMINI KEY ON THIS PHONE", color = Palette.muted, fontSize = 11.sp, letterSpacing = 2.sp, modifier = Modifier.padding(top = 10.dp))
            Field("Gemini API key (aistudio.google.com/apikey)", gemini, KeyboardType.Password, secret = true) { gemini = it }
            Text(
                "The server is better: your key stays off the phone and it falls back to Groq and Cloudflare Workers AI when Gemini's free quota runs out. " +
                    "A key typed here is encrypted with the Android Keystore. See ai-server/README.md to deploy the free server in about 5 minutes.",
                color = Palette.muted, fontSize = 12.sp, lineHeight = 17.sp,
            )
            Text(
                "Privacy: frames are sent only when you tap ✦, are not stored by Lumiq, and are processed by the AI provider you configured.",
                color = Palette.muted, fontSize = 12.sp, lineHeight = 17.sp,
            )
            TextButton({ persist(); onClose() }) { Text("Save", color = Palette.yellow, fontSize = 16.sp) }
        }
    }
}

@Composable
private fun Field(label: String, value: String, type: KeyboardType, secret: Boolean = false, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value, onValueChange = onChange, label = { Text(label) }, singleLine = true,
        visualTransformation = if (secret) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = type, autoCorrectEnabled = false),
        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Palette.yellow, focusedLabelColor = Palette.yellow, cursorColor = Palette.yellow),
        modifier = Modifier.fillMaxWidth(),
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
        "AI Shot sends one compressed frame only when you tap ✦, to the AI server or Gemini key you set up yourself; it is not stored by Lumiq. " +
        "Photos are stored in Lumiq's private app storage, and copied to your Gallery only if you turn that on. " +
        "Golden-hour location is requested only when you ask; it is not stored, uploaded or added to photos. " +
        "Sharing and feedback happen only when you start them. Lumiq (formerly Focal) is an independent personal app."
