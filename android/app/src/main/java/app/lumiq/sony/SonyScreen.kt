package app.lumiq.sony

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.lumiq.AppState
import app.lumiq.camera.CameraSource
import app.lumiq.ui.FootNote
import app.lumiq.ui.Glyph
import app.lumiq.ui.GlyphIcon
import app.lumiq.ui.GlyphTile
import app.lumiq.ui.LumiqMenu
import app.lumiq.ui.MenuRow
import app.lumiq.ui.Palette
import app.lumiq.ui.PrimaryButton
import app.lumiq.ui.RowSeparator
import app.lumiq.ui.SecondaryButton
import app.lumiq.ui.SettingsSection
import app.lumiq.ui.SheetHeader

/** Connect a Sony over its DIRECT Wi-Fi, and use its exposure controls and autofocus. */
@Composable
fun SonyScreen(app: AppState, onClose: () -> Unit) {
    val sony = app.sony
    val connecting = sony.state == SonyRemoteCamera.State.Connecting || sony.state == SonyRemoteCamera.State.Reconnecting
    Column(Modifier.fillMaxSize().background(Palette.ink)) {
        SheetHeader("Sony camera", onClose)
        Column(
            Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).navigationBarsPadding().padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            StatusCard(sony)
            if (!sony.isConnected) ConnectSection(app, connecting)
            else {
                ControlsSection(sony)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    SecondaryButton("Refresh", sony::refreshSettings, Modifier.weight(1f))
                    SecondaryButton("Disconnect", { sony.disconnect() }, Modifier.weight(1f))
                }
            }
            if (app.cameraSource == CameraSource.Sony) {
                SecondaryButton("Use the phone camera", { sony.disconnect(); app.cameraSource = CameraSource.Phone; onClose() }, Modifier.fillMaxWidth())
            } else {
                PrimaryButton("Use the Sony as the camera", { app.cameraSource = CameraSource.Sony; onClose() }, Modifier.fillMaxWidth())
            }
            FootNote(
                "Lumiq uses the camera's own Wi-Fi remote (Ctrl w/ Smartphone), tested against Sony's documented protocol " +
                    "but not yet on a physical camera. Models such as the A7 III and A6100 list this remote; others may differ. " +
                    "Change shooting mode and zoom on the camera. Each shutter press takes one photo on the camera and copies its JPEG into Lumiq; " +
                    "RAW files stay on the camera's card.",
            )
        }
    }
}

@Composable
private fun StatusCard(sony: SonyRemoteCamera) {
    SettingsSection("Status") {
        Row(Modifier.fillMaxWidth().padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            val color = when (sony.state) {
                SonyRemoteCamera.State.Streaming -> Palette.mint
                SonyRemoteCamera.State.Connected, SonyRemoteCamera.State.Connecting, SonyRemoteCamera.State.Reconnecting -> Palette.yellow
                SonyRemoteCamera.State.Failed -> Palette.danger
                SonyRemoteCamera.State.Disconnected -> Palette.muted
            }
            Box(Modifier.size(10.dp).clip(CircleShape).background(color))
            Column(Modifier.weight(1f)) {
                Text(
                    when (sony.state) {
                        SonyRemoteCamera.State.Streaming -> "Live · ${sony.model}"
                        SonyRemoteCamera.State.Connected -> "Connected · ${sony.model}"
                        SonyRemoteCamera.State.Connecting -> "Connecting…"
                        SonyRemoteCamera.State.Reconnecting -> "Reconnecting…"
                        SonyRemoteCamera.State.Failed -> "Not connected"
                        SonyRemoteCamera.State.Disconnected -> "Not connected"
                    },
                    color = Palette.text, fontSize = 16.sp, fontWeight = FontWeight.Medium,
                )
                if (sony.hasFrame) {
                    Text("${sony.resolution}${sony.fps?.let { " · %.0f fps".format(it) } ?: ""}", color = Palette.muted, fontSize = 13.sp)
                }
                sony.message?.let { Text(it, color = Palette.muted, fontSize = 13.sp, lineHeight = 18.sp) }
                sony.controlFeedback?.let { Text(it, color = Palette.accent, fontSize = 13.sp, lineHeight = 18.sp) }
            }
            if (sony.state == SonyRemoteCamera.State.Connecting || sony.state == SonyRemoteCamera.State.Reconnecting) {
                CircularProgressIndicator(Modifier.size(18.dp), color = Palette.accent, strokeWidth = 2.dp)
            }
        }
    }
}

@Composable
private fun ConnectSection(app: AppState, connecting: Boolean) {
    val sony = app.sony
    SettingsSection("Connect") {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Steps()
            OutlinedTextField(
                value = sony.host, onValueChange = { sony.host = it.trim(); sony.discoveredDescriptorUrl = null },
                label = { Text("Camera address") }, singleLine = true, enabled = !connecting,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, autoCorrectEnabled = false),
                shape = RoundedCornerShape(14.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Palette.accent, focusedLabelColor = Palette.accent, cursorColor = Palette.accent, unfocusedBorderColor = Palette.stroke,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SecondaryButton(if (sony.searching) "Searching…" else "Find camera", { if (!sony.searching) sony.search() }, Modifier.weight(1f))
                PrimaryButton(if (connecting) "Connecting…" else "Connect", { sony.connect() }, Modifier.weight(1f), enabled = !connecting)
            }
            sony.discoveryMessage?.let { Text(it, color = Palette.muted, fontSize = 13.sp, lineHeight = 18.sp) }
            sony.discovered.forEach { found ->
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(if (found.host == sony.host) Palette.accent.copy(alpha = 0.14f) else Palette.raised)
                        .clickable { sony.choose(found) }.padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    GlyphIcon(Glyph.Aperture, Palette.accent, 18.dp)
                    Column(Modifier.weight(1f)) {
                        Text(found.model, color = Palette.text, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                        Text(found.host, color = Palette.muted, fontSize = 12.sp)
                    }
                    if (found.host == sony.host) GlyphIcon(Glyph.Tick, Palette.accent, 16.dp)
                }
            }
        }
    }
}

@Composable
private fun Steps() {
    val steps = listOf(
        "On the camera, turn on Network › Ctrl w/ Smartphone and open its Connection screen. Keep it awake, with a memory card and still-photo mode.",
        "In Android Settings › Wi-Fi, join the DIRECT network the camera shows. If Android says the network has no internet, choose to stay connected.",
        "Come back here, tap Find camera (or type the camera's address), then Connect.",
    )
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        steps.forEachIndexed { i, text ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.size(22.dp).clip(CircleShape).background(Palette.accent.copy(alpha = 0.16f)), contentAlignment = Alignment.Center) {
                    Text("${i + 1}", color = Palette.accent, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
                Text(text, color = Palette.muted, fontSize = 13.sp, lineHeight = 18.sp, modifier = Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun ControlsSection(sony: SonyRemoteCamera) {
    SettingsSection("Camera controls · ${sony.remote.telemetry.mode ?: "mode not reported"}") {
        SonyRemoteSetting.entries.forEachIndexed { i, setting ->
            if (i > 0) RowSeparator()
            SettingRow(sony, setting)
        }
        RowSeparator()
        Row(
            Modifier.fillMaxWidth().clickable(enabled = sony.canTriggerAF) { sony.triggerAutofocus() }.heightIn(min = 56.dp).padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            GlyphTile(Glyph.Aperture, if (sony.canTriggerAF) Palette.accent else Palette.muted)
            Column(Modifier.weight(1f)) {
                Text("Autofocus", color = if (sony.canTriggerAF) Palette.text else Palette.muted, fontSize = 16.sp, fontWeight = FontWeight.Medium)
                Text(
                    if (sony.canTriggerAF) "Focus the camera now (tap the live view to choose a point when supported)"
                    else "This camera mode does not offer remote autofocus; focus on the camera or lens.",
                    color = Palette.muted, fontSize = 13.sp, lineHeight = 17.sp,
                )
            }
            if (sony.isFocusing) CircularProgressIndicator(Modifier.size(18.dp), color = Palette.accent, strokeWidth = 2.dp)
        }
    }
}

@Composable
private fun SettingRow(sony: SonyRemoteCamera, setting: SonyRemoteSetting) {
    val state = sony.remote.settings[setting]
    val reason = sony.settingDisabledReason(setting)
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.fillMaxWidth().clickable(enabled = reason == null) { open = true }.heightIn(min = 58.dp).padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(setting.title, color = if (reason == null) Palette.text else Palette.muted, fontSize = 16.sp, fontWeight = FontWeight.Medium)
                val note = when {
                    setting in sony.pendingSettings -> "Waiting for the camera to confirm…"
                    reason != null -> reason
                    else -> state?.issue?.let { "Last confirmed value · $it" }
                }
                note?.let { Text(it, color = Palette.muted, fontSize = 12.sp, lineHeight = 16.sp) }
            }
            Text(state?.displayValue ?: "—", color = if (reason == null) Palette.accent else Palette.muted, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            if (setting in sony.pendingSettings) CircularProgressIndicator(Modifier.size(16.dp), color = Palette.accent, strokeWidth = 2.dp)
            else if (reason == null) GlyphIcon(Glyph.Chevron, Palette.muted, 10.dp)
        }
        LumiqMenu(open, onDismiss = { open = false }) {
            (state?.choices ?: emptyList()).take(200).forEach { choice ->
                MenuRow(choice.label, selected = choice == state?.current) { open = false; sony.change(setting, choice) }
            }
        }
    }
    Spacer(Modifier.width(0.dp))
}
