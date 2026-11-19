package app.lumiq.update

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.FileProvider
import app.lumiq.BuildConfig
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONException
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.security.MessageDigest
import javax.net.ssl.SSLException

sealed class UpdateError(val userMessage: String) : Exception(userMessage) {
    object Offline : UpdateError("No internet connection. Connect and try again.")
    object Timeout : UpdateError("GitHub took too long to respond. Try again.")
    object RateLimited : UpdateError("GitHub's update-check limit was reached. Try again in an hour.")
    object NoReleases : UpdateError("No Android releases were found. If the release repository is private, the app cannot see it.")
    object InvalidResponse : UpdateError("GitHub's answer could not be read. Try again later.")
    object Interrupted : UpdateError("The download was interrupted. Try again.")
    object NoSpace : UpdateError("Not enough free storage to download the update.")
    object NoChecksum : UpdateError("This release has no checksum, so it cannot be verified. Update skipped.")
    object Corrupt : UpdateError("The downloaded file is damaged (checksum mismatch). Try again.")
    object NotLumiq : UpdateError("The downloaded file is not a valid Lumiq update.")
    object WrongSignature : UpdateError("The update is signed with a different key, so Android would refuse it. Update skipped.")
    object NoInstaller : UpdateError("No app on this phone can install APK files.")
    class Http(code: Int) : UpdateError("GitHub error $code. Try again later.")
}

sealed interface UpdateState {
    /** Nothing to show. */
    object Idle : UpdateState
    object Checking : UpdateState
    object UpToDate : UpdateState
    data class Available(val update: AvailableUpdate) : UpdateState
    data class Downloading(val update: AvailableUpdate, val downloaded: Long, val total: Long) : UpdateState {
        val fraction: Float? get() = if (total > 0) (downloaded.toFloat() / total).coerceIn(0f, 1f) else null
    }
    data class Verifying(val update: AvailableUpdate) : UpdateState
    /** Verified APK on disk; [needsPermission] when "Install unknown apps" must be allowed first. */
    data class ReadyToInstall(val update: AvailableUpdate, val file: File, val needsPermission: Boolean) : UpdateState
    data class Failed(val message: String, val update: AvailableUpdate?) : UpdateState
}

/**
 * Optional in-app updates from GitHub Releases (Android personal builds only).
 *
 * Checks [BuildConfig.UPDATE_REPO] for a release tagged `android-b<versionCode>` that is newer than this
 * build, downloads its APK into app cache, verifies size, SHA-256, package name, versionCode and signing
 * certificate, then hands the file to Android's own package installer. Nothing is installed silently.
 */
class AppUpdater(context: Context) {
    private val context = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val directory = File(this.context.cacheDir, "updates")
    private var job: Job? = null
    private var silentCheckRunning = false

    var state by mutableStateOf<UpdateState>(UpdateState.Idle); private set

    val currentVersionCode: Int get() = BuildConfig.VERSION_CODE
    val isEnabled: Boolean get() = BuildConfig.UPDATE_REPO.isNotBlank()
    val isBusy: Boolean get() = job?.isActive == true

    /** App start: silent unless a newer version exists. */
    fun checkAutomatically() = check(interactive = false)

    /** Settings › Check for Updates: reports progress, "up to date" and errors. */
    fun checkNow() = check(interactive = true)

    private fun check(interactive: Boolean) {
        if (!isEnabled) return
        if (isBusy) {
            // A tap in Settings takes over a silent start-up check; anything else is already on screen.
            if (interactive && silentCheckRunning) job?.cancel() else return
        }
        if (interactive) state = UpdateState.Checking
        silentCheckRunning = !interactive
        job = scope.launch {
            state = try {
                val update = withContext(Dispatchers.IO) {
                    removeStaleDownloads()
                    fetchNewest()
                }
                when {
                    update != null -> UpdateState.Available(update)
                    interactive -> UpdateState.UpToDate
                    else -> UpdateState.Idle
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (interactive) UpdateState.Failed(errorFor(e).userMessage, null) else UpdateState.Idle
            } finally {
                silentCheckRunning = false
            }
        }
    }

    /** "Update Now": download, verify, then open Android's install prompt. */
    fun download(update: AvailableUpdate) {
        if (isBusy) return
        state = UpdateState.Downloading(update, 0, update.apk.size)
        job = scope.launch {
            try {
                val file = withContext(Dispatchers.IO) { downloadAndVerify(update) }
                state = UpdateState.ReadyToInstall(update, file, needsPermission = !canInstall())
                install()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                state = UpdateState.Failed(errorFor(e).userMessage, update)
            }
        }
    }

    /** Re-run whatever failed: the download when a release is known, otherwise the check. */
    fun retry() {
        when (val s = state) {
            is UpdateState.Failed -> if (s.update != null) download(s.update) else checkNow()
            else -> Unit
        }
    }

    /** "Later", "Close" or "Cancel": stops any download and hides the dialog. The app keeps working normally. */
    fun dismiss() {
        job?.cancel()
        job = null
        state = UpdateState.Idle
    }

    /** Opens the system installer, or the "Install unknown apps" switch for Lumiq when it is still off. */
    fun install() {
        val ready = state as? UpdateState.ReadyToInstall ?: return
        if (!canInstall()) {
            state = ready.copy(needsPermission = true)
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            runCatching { context.startActivity(intent) }
            return
        }
        state = ready.copy(needsPermission = false)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", ready.file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            state = UpdateState.Failed(UpdateError.NoInstaller.userMessage, ready.update)
        }
    }

    fun release() = scope.cancel()

    private fun canInstall(): Boolean = context.packageManager.canRequestPackageInstalls()

    // region Network

    private fun fetchNewest(): AvailableUpdate? {
        requireNetwork()
        val connection = open("https://api.github.com/repos/${BuildConfig.UPDATE_REPO}/releases?per_page=30", "application/vnd.github+json")
        try {
            connection.setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
            val code = connection.responseCode
            if (code != 200) throw httpError(connection, code)
            val body = connection.inputStream.bufferedReader().use { it.readText() }
            return try {
                UpdateLogic.newestUpdate(body, currentVersionCode)
            } catch (_: JSONException) {
                throw UpdateError.InvalidResponse
            }
        } finally {
            connection.disconnect()
        }
    }

    private suspend fun downloadAndVerify(update: AvailableUpdate): File {
        val expectedHash = expectedSha256(update)
        directory.mkdirs()
        val target = File(directory, "lumiq-${update.versionCode}.apk")
        // A verified APK from an earlier attempt (for example when the installer was cancelled) is reused.
        if (target.isFile && target.length() == update.apk.size && sha256(target) == expectedHash) {
            verifyPackage(target, update)
            return target
        }
        target.delete()
        if (update.apk.size > 0 && directory.usableSpace < update.apk.size + SPACE_MARGIN) throw UpdateError.NoSpace

        val partial = File(directory, "lumiq-${update.versionCode}.apk.part")
        val digest = MessageDigest.getInstance("SHA-256")
        var downloaded = 0L
        try {
            requireNetwork()
            val connection = open(update.apk.downloadUrl, "application/octet-stream")
            try {
                val code = connection.responseCode
                if (code != 200) throw httpError(connection, code)
                val total = connection.contentLengthLong.takeIf { it > 0 } ?: update.apk.size
                var lastReport = 0L
                connection.inputStream.use { input ->
                    partial.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            coroutineContext.ensureActive()
                            val read = input.read(buffer)
                            if (read < 0) break
                            output.write(buffer, 0, read)
                            digest.update(buffer, 0, read)
                            downloaded += read
                            val now = System.nanoTime()
                            if (now - lastReport > 100_000_000L) {
                                lastReport = now
                                val progress = downloaded
                                scope.launch { reportProgress(update, progress, total) }
                            }
                        }
                    }
                }
            } finally {
                connection.disconnect()
            }
            scope.launch { if (state is UpdateState.Downloading) state = UpdateState.Verifying(update) }

            if (update.apk.size > 0 && downloaded != update.apk.size) throw UpdateError.Corrupt
            if (UpdateLogic.hex(digest.digest()) != expectedHash) throw UpdateError.Corrupt
            verifyPackage(partial, update)
            if (!partial.renameTo(target)) throw IOException("rename failed")
            return target
        } catch (e: Exception) {
            partial.delete()
            throw e
        }
    }

    private fun reportProgress(update: AvailableUpdate, downloaded: Long, total: Long) {
        val current = state as? UpdateState.Downloading ?: return
        if (current.update == update) state = UpdateState.Downloading(update, downloaded, total)
    }

    /** GitHub's own asset digest when present, otherwise the workflow's .sha256 file; both must agree. */
    private fun expectedSha256(update: AvailableUpdate): String {
        val fromGitHub = UpdateLogic.sha256FromDigest(update.apk.digest)
        val fromFile = update.checksum?.let { asset ->
            requireNetwork()
            val connection = open(asset.downloadUrl, "application/octet-stream")
            try {
                val code = connection.responseCode
                if (code != 200) throw httpError(connection, code)
                val text = connection.inputStream.bufferedReader().use { it.readText().take(4096) }
                UpdateLogic.sha256FromChecksumFile(text) ?: throw UpdateError.NoChecksum
            } finally {
                connection.disconnect()
            }
        }
        if (fromGitHub != null && fromFile != null && fromGitHub != fromFile) throw UpdateError.Corrupt
        return fromGitHub ?: fromFile ?: throw UpdateError.NoChecksum
    }

    private fun open(url: String, accept: String): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 30_000
            instanceFollowRedirects = true
            setRequestProperty("Accept", accept)
            setRequestProperty("User-Agent", "Lumiq-Android-Updater/${BuildConfig.VERSION_NAME}")
        }

    private fun httpError(connection: HttpURLConnection, code: Int): UpdateError = when {
        (code == 403 || code == 429) && connection.getHeaderField("X-RateLimit-Remaining") == "0" -> UpdateError.RateLimited
        code == 429 -> UpdateError.RateLimited
        code == 404 -> UpdateError.NoReleases
        else -> UpdateError.Http(code)
    }

    private fun requireNetwork() {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork)
        if (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) != true) throw UpdateError.Offline
    }

    private fun errorFor(e: Exception): UpdateError = when (e) {
        is UpdateError -> e
        is SocketTimeoutException -> UpdateError.Timeout
        is UnknownHostException, is ConnectException, is SSLException -> UpdateError.Offline
        is InterruptedIOException, is IOException -> if (isOutOfSpace(e)) UpdateError.NoSpace else UpdateError.Interrupted
        else -> UpdateError.Interrupted
    }

    private fun isOutOfSpace(e: Exception) = e.message?.contains("ENOSPC") == true || e.message?.contains("No space left") == true

    // endregion

    // region Verification

    /** The APK must be Lumiq, newer than this build and signed with the same certificate as this install. */
    private fun verifyPackage(file: File, update: AvailableUpdate) {
        val pm = context.packageManager
        val archive = archiveInfo(pm, file) ?: throw UpdateError.NotLumiq
        if (archive.packageName != context.packageName) throw UpdateError.NotLumiq
        val archiveCode = versionCode(archive)
        if (archiveCode != update.versionCode.toLong() || archiveCode <= currentVersionCode) throw UpdateError.NotLumiq
        val installed = certificateHashes(installedInfo(pm))
        val downloaded = certificateHashes(archive)
        // Android refuses an update signed with another key; checking here gives a clear message first.
        if (installed.isNotEmpty() && downloaded.isNotEmpty() && installed != downloaded) throw UpdateError.WrongSignature
    }

    @Suppress("DEPRECATION")
    private fun archiveInfo(pm: PackageManager, file: File): PackageInfo? {
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        return pm.getPackageArchiveInfo(file.absolutePath, flags)
    }

    @Suppress("DEPRECATION")
    private fun installedInfo(pm: PackageManager): PackageInfo {
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        return pm.getPackageInfo(context.packageName, flags)
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun certificateHashes(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) {
            val signing = info.signingInfo
            when {
                signing == null -> info.signatures
                signing.hasMultipleSigners() -> signing.apkContentsSigners
                else -> signing.signingCertificateHistory
            }
        } else {
            info.signatures
        }
        return signatures.orEmpty().map { UpdateLogic.sha256(it.toByteArray()) }.toSet()
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return UpdateLogic.hex(digest.digest())
    }

    /** Deletes partial downloads and APKs that are not newer than the installed build. */
    private fun removeStaleDownloads() {
        directory.listFiles()?.forEach { file ->
            val code = Regex("^lumiq-(\\d+)\\.apk$").matchEntire(file.name)?.groupValues?.get(1)?.toIntOrNull()
            if (code == null || code <= currentVersionCode) file.delete()
        }
    }

    // endregion

    private companion object {
        const val SPACE_MARGIN = 20L * 1024 * 1024
    }
}
