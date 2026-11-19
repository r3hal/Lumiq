package app.lumiq.update

import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.DialogProperties
import app.lumiq.BuildConfig
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
            confirm = { Action("Cancel", updater::dismiss) },
        ) { LinearProgressIndicator(Modifier.fillMaxWidth(), color = Palette.yellow) }

        UpdateState.UpToDate -> UpdateAlert(
            title = "Lumiq is up to date",
            onDismiss = updater::dismiss,
            confirm = { Action("OK", updater::dismiss) },
        ) { Body("You have the newest version (${BuildConfig.VERSION_NAME}, build ${updater.currentVersionCode}).") }

        is UpdateState.Available -> UpdateAlert(
            title = "Update available",
            onDismiss = updater::dismiss,
            confirm = { Action("Update Now", { updater.download(state.update) }) },
            dismiss = { Action("Later", updater::dismiss, muted = true) },
        ) {
            val u = state.update
            Body(
                "Lumiq ${u.versionName} (build ${u.versionCode}) is available. You have build ${updater.currentVersionCode}." +
                    (if (u.apk.size > 0) " Download size ${size(u.apk.size)}." else "") +
                    " Your photos and settings are kept.",
            )
            if (u.notes.isNotBlank()) {
                Column(Modifier.heightIn(max = 180.dp).verticalScroll(rememberScrollState())) {
                    Text(u.notes, color = Palette.muted, fontSize = 13.sp, lineHeight = 18.sp)
                }
            }
        }

        is UpdateState.Downloading -> UpdateAlert(
            title = "Downloading update",
            onDismiss = {},
            confirm = { Action("Cancel", updater::dismiss, muted = true) },
        ) {
            val fraction = state.fraction
            if (fraction != null) {
                LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth(), color = Palette.yellow)
                Body("${(fraction * 100).toInt()}% · ${size(state.downloaded)} of ${size(state.total)}")
            } else {
                LinearProgressIndicator(Modifier.fillMaxWidth(), color = Palette.yellow)
                Body(size(state.downloaded))
            }
        }

        is UpdateState.Verifying -> UpdateAlert(
            title = "Verifying update…",
            onDismiss = {},
            confirm = { Action("Cancel", updater::dismiss, muted = true) },
        ) { LinearProgressIndicator(Modifier.fillMaxWidth(), color = Palette.yellow) }

        is UpdateState.ReadyToInstall -> UpdateAlert(
            title = "Ready to install",
            onDismiss = updater::dismiss,
            confirm = { Action(if (state.needsPermission) "Allow & Install" else "Install", updater::install) },
            dismiss = { Action("Later", updater::dismiss, muted = true) },
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
            confirm = { Action("Try Again", updater::retry) },
            dismiss = { Action("Close", updater::dismiss, muted = true) },
        ) { Body(state.message) }
    }
}

@Composable
private fun UpdateAlert(
    title: String,
    onDismiss: () -> Unit,
    confirm: @Composable () -> Unit,
    dismiss: (@Composable () -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = confirm,
        dismissButton = dismiss,
        title = { Text(title) },
        text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) { content() } },
        properties = DialogProperties(dismissOnClickOutside = false),
    )
}

@Composable
private fun Action(label: String, onClick: () -> Unit, muted: Boolean = false) {
    TextButton(onClick) { Text(label, color = if (muted) Palette.muted else Palette.yellow) }
}

@Composable
private fun Body(text: String) = Text(text, lineHeight = 21.sp)
