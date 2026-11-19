package app.lumiq.update

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.Locale

/** One downloadable file attached to a GitHub release. */
data class ReleaseAsset(
    val name: String,
    val size: Long,
    val downloadUrl: String,
    /** GitHub's own "sha256:…" digest of the uploaded file, when GitHub provides it. */
    val digest: String?,
)

/** A newer Android build published on GitHub Releases. */
data class AvailableUpdate(
    val versionCode: Int,
    val versionName: String,
    val tag: String,
    val notes: String,
    val apk: ReleaseAsset,
    /** Lumiq-android.apk.sha256, written by the release workflow. */
    val checksum: ReleaseAsset?,
)

/**
 * Pure parsing and comparison for the GitHub Releases update check, shared with unit tests.
 *
 * The release workflow (.github/workflows/android-release.yml) tags each build `android-b<versionCode>`,
 * names it `Lumiq <versionName> (build <versionCode>)`, and attaches the APK plus its SHA-256.
 */
object UpdateLogic {
    const val APK_NAME = "Lumiq-android.apk"
    const val CHECKSUM_NAME = "$APK_NAME.sha256"

    private val tagPattern = Regex("^android-b(\\d{1,9})$")
    private val namePattern = Regex("^Lumiq (\\S+) \\(build \\d+\\)$")
    private val sha256Pattern = Regex("^[0-9a-f]{64}$")

    fun versionCodeFromTag(tag: String): Int? = tagPattern.matchEntire(tag.trim())?.groupValues?.get(1)?.toIntOrNull()

    /**
     * The newest published Android release whose versionCode is greater than [currentVersionCode],
     * or null when this build is already the newest. Drafts, prereleases, releases without the
     * APK and tags that are not Android build tags (for example future iPhone releases) are ignored.
     *
     * @throws org.json.JSONException when [json] is not a GitHub releases array.
     */
    fun newestUpdate(json: String, currentVersionCode: Int): AvailableUpdate? {
        val releases = JSONArray(json)
        var best: AvailableUpdate? = null
        for (i in 0 until releases.length()) {
            val release = releases.optJSONObject(i) ?: continue
            if (release.optBoolean("draft") || release.optBoolean("prerelease")) continue
            val tag = release.optString("tag_name")
            val code = versionCodeFromTag(tag) ?: continue
            if (code <= currentVersionCode || (best != null && code <= best.versionCode)) continue
            val assets = assets(release)
            val apk = assets.firstOrNull { it.name == APK_NAME } ?: continue
            best = AvailableUpdate(
                versionCode = code,
                versionName = namePattern.matchEntire(release.optString("name").trim())?.groupValues?.get(1) ?: "build $code",
                tag = tag,
                notes = release.optString("body").takeUnless { release.isNull("body") }.orEmpty().trim(),
                apk = apk,
                checksum = assets.firstOrNull { it.name == CHECKSUM_NAME },
            )
        }
        return best
    }

    private fun assets(release: JSONObject): List<ReleaseAsset> {
        val array = release.optJSONArray("assets") ?: return emptyList()
        return (0 until array.length()).mapNotNull { i ->
            val a = array.optJSONObject(i) ?: return@mapNotNull null
            val url = a.optString("browser_download_url")
            if (!url.startsWith("https://")) return@mapNotNull null
            ReleaseAsset(
                name = a.optString("name"),
                size = a.optLong("size", -1),
                downloadUrl = url,
                digest = if (a.isNull("digest")) null else a.optString("digest"),
            )
        }
    }

    /** Lowercase hex from GitHub's asset digest ("sha256:<hex>"), or null when absent or not SHA-256. */
    fun sha256FromDigest(digest: String?): String? {
        val value = digest?.trim() ?: return null
        if (!value.startsWith("sha256:", ignoreCase = true)) return null
        return value.substring(7).lowercase(Locale.US).takeIf { sha256Pattern.matches(it) }
    }

    /** Parses `sha256sum` output ("<hex>  Lumiq-android.apk") or a bare hex digest. */
    fun sha256FromChecksumFile(text: String): String? {
        val first = text.trim().lineSequence().firstOrNull()?.trim() ?: return null
        val hex = first.split(Regex("\\s+")).first().lowercase(Locale.US)
        return hex.takeIf { sha256Pattern.matches(it) }
    }

    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    fun sha256(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))
}
