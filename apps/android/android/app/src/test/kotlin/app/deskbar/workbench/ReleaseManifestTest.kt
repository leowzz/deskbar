package app.deskbar.workbench

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ReleaseManifestTest {
    private fun manifest(version: String = "0.1.1", code: Long = 2) = JSONObject()
        .put("version", version)
        .put("android", JSONObject()
            .put("url", "https://github.com/leowzz/deskbar/releases/download/v$version/deskbar-android-arm64-v$version.apk")
            .put("version_code", code)
            .put("size", 100)
            .put("sha256", "a".repeat(64)))

    @Test fun newerStableRelease() {
        val offer = ReleaseManifest.parse(manifest().toString(), "0.1.0", 1)!!
        assertEquals("0.1.1", offer.version)
        assertEquals(2L, offer.versionCode)
    }

    @Test fun noDowngradesOrRepeatedBuildNumbers() {
        for (version in listOf("0.0.9", "0.1.0")) {
            assertNull(ReleaseManifest.parse(manifest(version).toString(), "0.1.0", 1))
        }
        assertNull(ReleaseManifest.parse(manifest(code = 1).toString(), "0.1.0", 1))
    }

    @Test fun rejectsPrereleasesAndMalformedVersions() {
        for (version in listOf("0.2.0-rc.1", "0.2.0+local", "v0.2.0", "00.2.0")) {
            assertThrows(IllegalArgumentException::class.java) {
                ReleaseManifest.parse(manifest(version).toString(), "0.1.0", 1)
            }
        }
    }

    @Test fun rejectsForeignUrlsMissingHashesAndOversizedPackages() {
        for ((key, value) in listOf(
            "url" to "https://example.com/update.apk",
            "url" to "https://github.com/leowzz/orbit/releases/download/v0.1.1/app.apk",
            "sha256" to "",
            "size" to 0,
            "size" to ReleaseManifest.MAX_APK + 1,
        )) {
            val json = manifest()
            json.getJSONObject("android").put(key, value)
            assertThrows(IllegalArgumentException::class.java) {
                ReleaseManifest.parse(json.toString(), "0.1.0", 1)
            }
        }
    }
}
