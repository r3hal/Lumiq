package app.lumiq

import app.lumiq.update.UpdateLogic
import org.json.JSONException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class UpdateLogicTest {
    private val hash = "a".repeat(64)

    private fun release(
        tag: String,
        name: String = "Lumiq 3.2.1-android (build ${tag.removePrefix("android-b")})",
        draft: Boolean = false,
        prerelease: Boolean = false,
        assets: String = apkAssets(),
        body: String = "\"Built from abc123\"",
    ) = """{"tag_name":"$tag","name":"$name","draft":$draft,"prerelease":$prerelease,"body":$body,"assets":[$assets]}"""

    private fun apkAssets(digest: String = "\"sha256:${hash.uppercase()}\"") =
        """{"name":"Lumiq-android.apk","size":1234,"browser_download_url":"https://github.com/o/r/releases/download/x/Lumiq-android.apk","digest":$digest},""" +
            """{"name":"Lumiq-android.apk.sha256","size":84,"browser_download_url":"https://github.com/o/r/releases/download/x/Lumiq-android.apk.sha256","digest":null}"""

    @Test fun picksHighestNewerAndroidRelease() {
        val json = "[" + listOf(release("android-b105"), release("android-b110"), release("android-b103")).joinToString(",") + "]"
        val update = UpdateLogic.newestUpdate(json, currentVersionCode = 104)!!
        assertEquals(110, update.versionCode)
        assertEquals("3.2.1-android", update.versionName)
        assertEquals("android-b110", update.tag)
        assertEquals(1234L, update.apk.size)
        assertEquals("Lumiq-android.apk.sha256", update.checksum?.name)
        assertEquals("Built from abc123", update.notes)
    }

    @Test fun noUpdateWhenCurrentIsNewestOrEqual() {
        val json = "[" + release("android-b105") + "]"
        assertNull(UpdateLogic.newestUpdate(json, currentVersionCode = 105))
        assertNull(UpdateLogic.newestUpdate(json, currentVersionCode = 200))
        assertNull(UpdateLogic.newestUpdate("[]", currentVersionCode = 2))
    }

    @Test fun ignoresDraftsPrereleasesForeignTagsAndMissingApk() {
        val json = "[" + listOf(
            release("android-b300", draft = true),
            release("android-b301", prerelease = true),
            release("ios-b302"),
            release("v3.2.1"),
            release("android-b303", assets = """{"name":"other.zip","size":1,"browser_download_url":"https://x/other.zip"}"""),
            release("android-b120"),
        ).joinToString(",") + "]"
        assertEquals(120, UpdateLogic.newestUpdate(json, currentVersionCode = 2)?.versionCode)
    }

    @Test fun rejectsNonHttpsDownloadUrls() {
        val assets = """{"name":"Lumiq-android.apk","size":1,"browser_download_url":"http://insecure/Lumiq-android.apk"}"""
        assertNull(UpdateLogic.newestUpdate("[" + release("android-b120", assets = assets) + "]", currentVersionCode = 2))
    }

    @Test fun unknownNameFallsBackToBuildNumberAndNullBodyIsEmpty() {
        val update = UpdateLogic.newestUpdate("[" + release("android-b120", name = "Nightly", body = "null") + "]", 2)!!
        assertEquals("build 120", update.versionName)
        assertEquals("", update.notes)
    }

    @Test fun invalidJsonThrows() {
        try {
            UpdateLogic.newestUpdate("""{"message":"Not Found"}""", 2)
            fail("expected JSONException")
        } catch (_: JSONException) {
        }
    }

    @Test fun tagParsing() {
        assertEquals(105, UpdateLogic.versionCodeFromTag("android-b105"))
        assertNull(UpdateLogic.versionCodeFromTag("android-b"))
        assertNull(UpdateLogic.versionCodeFromTag("android-b12x"))
        assertNull(UpdateLogic.versionCodeFromTag("android-b9999999999"))
    }

    @Test fun digestParsing() {
        assertEquals(hash, UpdateLogic.sha256FromDigest("sha256:${hash.uppercase()}"))
        assertNull(UpdateLogic.sha256FromDigest(null))
        assertNull(UpdateLogic.sha256FromDigest("sha512:$hash"))
        assertNull(UpdateLogic.sha256FromDigest("sha256:abc"))
    }

    @Test fun checksumFileParsing() {
        assertEquals(hash, UpdateLogic.sha256FromChecksumFile("$hash  Lumiq-android.apk\n"))
        assertEquals(hash, UpdateLogic.sha256FromChecksumFile("  ${hash.uppercase()}\n"))
        assertNull(UpdateLogic.sha256FromChecksumFile(""))
        assertNull(UpdateLogic.sha256FromChecksumFile("<html>Not Found</html>"))
    }

    @Test fun sha256MatchesKnownVector() {
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            UpdateLogic.sha256("abc".toByteArray()),
        )
    }
}
