package app.lumiq.update

import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.lumiq.BuildConfig
import app.lumiq.ui.DialogText
import app.lumiq.ui.LumiqDialog
import app.lumiq.ui.Palette

/** Update popup shared by the start-up check and Settings › Check for Updates. */
@Composable
fun UpdateDialog(updater: AppUpdater) {
    val context = LocalContext.current
    fun size(bytes: Long) = Formatter.formatShortFileSize(context, bytes)

    when (val state = updater.state) {
        UpdateState.Idle -> Unit

        UpdateState.Checking -> UpdateAlert(
            title = "Checking for updates…",
            onDismiss = updater::dismiss,
            primary = null, secondary = "Cancel" to updater::dismiss,
        ) { LinearProgressIndicator(Modifier.fillMaxWidth(), color = Palette.accent, trackColor = Color.White.copy(alpha = 0.12f)) }

        UpdateState.UpToDate -> UpdateAlert(
            title = "Lumiq is up to date",
            onDismiss = updater::dismiss,
            primary = "OK" to updater::dismiss,
        ) { Body("You have the newest version (${BuildConfig.VERSION_NAME}, build ${updater.currentVersionCode}).") }

        is UpdateState.Available -> UpdateAlert(
            title = "Update available",
            onDismiss = updater::dismiss,
            primary = "Update Now" to { updater.download(state.update) },
            secondary = "Later" to updater::dismiss,
        ) {
            val u = state.update
            Body(
                "Lumiq ${u.versionName} (build ${u.versionCode}) is available. You have build ${updater.currentVersionCode}." +
                    (if (u.apk.size > 0) " Download size ${size(u.apk.size)}." else "") +
                    " Your photos and settings are kept.",
            )
            if (u.notes.isNotBlank()) {
                Column(Modifier.heightIn(max = 180.dp).verticalScroll(rememberScrollState())) {
                    Text(u.notes, color = Palette.muted.copy(alpha = 0.8f), fontSize = 13.sp, lineHeight = 18.sp)
                }
            }
        }

        is UpdateState.Downloading -> UpdateAlert(
            title = "Downloading update",
            onDismiss = {},
            primary = null, secondary = "Cancel" to updater::dismiss,
        ) {
            val fraction = state.fraction
            if (fraction != null) {
                LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth(), color = Palette.accent, trackColor = Color.White.copy(alpha = 0.12f))
                Body("${(fraction * 100).toInt()}% · ${size(state.downloaded)} of ${size(state.total)}")
            } else {
                LinearProgressIndicator(Modifier.fillMaxWidth(), color = Palette.accent, trackColor = Color.White.copy(alpha = 0.12f))
                Body(size(state.downloaded))
            }
        }

        is UpdateState.Verifying -> UpdateAlert(
            title = "Verifying update…",
            onDismiss = {},
            primary = null, secondary = "Cancel" to updater::dismiss,
        ) { LinearProgressIndicator(Modifier.fillMaxWidth(), color = Palette.accent, trackColor = Color.White.copy(alpha = 0.12f)) }

        is UpdateState.ReadyToInstall -> UpdateAlert(
            title = "Ready to install",
            onDismiss = updater::dismiss,
            primary = (if (state.needsPermission) "Allow & Install" else "Install") to updater::install,
            secondary = "Later" to updater::dismiss,
        ) {
            Body(
                if (state.needsPermission) {
                    "Android needs permission for Lumiq to install updates. Turn on \"Allow from this source\", come back, then tap Install."
                } else {
                    "The download was verified. Confirm in Android's installer to update Lumiq ${state.update.versionName}."
                },
            )
        }

        is UpdateState.Failed -> UpdateAlert(
            title = "Update failed",
            onDismiss = updater::dismiss,
            primary = "Try Again" to updater::retry,
            secondary = "Close" to updater::dismiss,
        ) { Body(state.message) }
    }
}

@Composable
private fun UpdateAlert(
    title: String,
    onDismiss: () -> Unit,
    primary: Pair<String, () -> Unit>?,
    secondary: Pair<String, () -> Unit>? = null,
    content: @Composable () -> Unit,
) {
    LumiqDialog(title, onDismiss, primary, secondary, closeOnOutsideTap = false) { content() }
}

@Composable
private fun Body(text: String) = DialogText(text)
