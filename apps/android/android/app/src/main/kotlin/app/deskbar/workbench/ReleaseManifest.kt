package app.deskbar.workbench

import org.json.JSONObject

internal data class ReleaseManifest(
    val version: String,
    val versionCode: Long,
    val url: String,
    val sha256: String,
    val size: Long,
) {
    companion object {
        const val ENDPOINT = "https://github.com/leowzz/deskbar/releases/latest/download/latest.json"
        const val MAX_APK = 512L * 1024 * 1024

        private fun versionParts(value: String): List<Long> {
            require(Regex("(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})").matches(value))
            return value.split(".").map(String::toLong)
        }

        fun parse(text: String, currentVersion: String, currentCode: Long): ReleaseManifest? {
            val root = JSONObject(text)
            val version = root.getString("version")
            val next = versionParts(version)
            val current = versionParts(currentVersion)
            val android = root.getJSONObject("android")
            val code = android.getLong("version_code")
            val url = android.getString("url")
            val hash = android.getString("sha256")
            val size = android.getLong("size")
            require(code in 1..2100000000L && size in 1..MAX_APK)
            require(Regex("[0-9a-f]{64}").matches(hash))
            require(url == "https://github.com/leowzz/deskbar/releases/download/v$version/deskbar-android-arm64-v$version.apk")
            val difference = next.zip(current).firstOrNull { (a, b) -> a != b }
            if (difference == null || difference.first < difference.second || code <= currentCode) return null
            return ReleaseManifest(version, code, url, hash, size)
        }
    }
}
