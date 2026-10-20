package app.deskbar.workbench

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal class AppUpdater(private val activity: MainActivity) {
    private val executor = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    private var selected: ReleaseManifest? = null
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .callTimeout(5, TimeUnit.MINUTES)
        .followSslRedirects(false)
        .build()
    private val installed get() = activity.packageManager.getPackageInfo(
        activity.packageName, PackageManager.GET_SIGNING_CERTIFICATES
    )

    fun call(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "version") {
            result.success(installed.versionName)
            return
        }
        if (call.method !in listOf("check", "install")) {
            result.notImplemented()
            return
        }
        if (!busy.compareAndSet(false, true)) {
            result.error("busy", "更新操作正在进行", null)
            return
        }
        executor.execute {
            try {
                val response = when (call.method) {
                    "check" -> check()
                    else -> prepareInstall()
                }
                activity.runOnUiThread {
                    try {
                        if (!activity.isDestroyed) {
                            if (call.method == "install") {
                                if (!activity.packageManager.canRequestPackageInstalls()) {
                                    activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                        Uri.parse("package:${activity.packageName}")))
                                    result.success("permission_required")
                                } else {
                                    val uri = FileProvider.getUriForFile(activity,
                                        "${activity.packageName}.updates", apkFile())
                                    activity.startActivity(Intent(Intent.ACTION_VIEW)
                                        .setDataAndType(uri, "application/vnd.android.package-archive")
                                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                    result.success("installer_opened")
                                }
                            } else result.success(response)
                        }
                    } catch (_: Exception) {
                        result.error("install_failed", "无法打开安装程序，请稍后重试", null)
                    } finally {
                        busy.set(false)
                    }
                }
            } catch (_: Exception) {
                if (call.method == "check") selected = null
                busy.set(false)
                activity.runOnUiThread {
                    if (!activity.isDestroyed) result.error("update_failed",
                        if (call.method == "check") "无法检查更新，请稍后重试；首次发布前可能还没有可用版本"
                        else "更新包下载或验证失败，请重新检查更新", null)
                }
            }
        }
    }

    private fun check(): Map<String, Any?> {
        selected = null
        val request = Request.Builder().url(ReleaseManifest.ENDPOINT).build()
        val text = client.newCall(request).apply { timeout().timeout(30, TimeUnit.SECONDS) }
            .execute().use { response ->
                check(response.isSuccessful)
                val body = checkNotNull(response.body)
                require(body.contentLength() <= 1024 * 1024)
                body.byteStream().use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count == -1) break
                        require(output.size() + count <= 1024 * 1024)
                        output.write(buffer, 0, count)
                    }
                    output.toString("UTF-8")
                }
            }
        val info = installed
        selected = ReleaseManifest.parse(text, checkNotNull(info.versionName), info.longVersionCode)
        return mapOf("currentVersion" to info.versionName, "version" to selected?.version)
    }

    private fun apkFile(): File = File(activity.cacheDir, "updates/deskbar.apk")

    private fun prepareInstall(): String {
        val release = checkNotNull(selected)
        val apk = apkFile()
        apk.parentFile!!.mkdirs()
        // Reuse a verified download when returning from install permission settings.
        if (!apk.exists() || !validDownload(apk, release)) {
            val partial = File(apk.parentFile, "download.part")
            try {
                client.newCall(Request.Builder().url(release.url).build()).execute().use { response ->
                    check(response.isSuccessful)
                    val body = checkNotNull(response.body)
                    require(body.contentLength() == -1L || body.contentLength() == release.size)
                    body.byteStream().use { input ->
                        partial.outputStream().use { output ->
                            val buffer = ByteArray(64 * 1024)
                            var total = 0L
                            while (true) {
                                val count = input.read(buffer)
                                if (count == -1) break
                                total += count
                                require(total <= release.size)
                                output.write(buffer, 0, count)
                            }
                        }
                    }
                }
                require(validDownload(partial, release))
                apk.delete()
                check(partial.renameTo(apk))
            } finally {
                partial.delete()
            }
        }
        val archive = checkNotNull(activity.packageManager.getPackageArchiveInfo(
            apk.path, PackageManager.GET_SIGNING_CERTIFICATES))
        val current = installed
        require(archive.packageName == activity.packageName)
        require(archive.versionName == release.version && archive.longVersionCode == release.versionCode)
        require(archive.longVersionCode > current.longVersionCode)
        fun signers(info: android.content.pm.PackageInfo) = checkNotNull(info.signingInfo)
            .apkContentsSigners.map { it.toCharsString() }.toSet()
        require(signers(archive).isNotEmpty() && signers(archive) == signers(current))
        return "ready"
    }

    private fun validDownload(file: File, release: ReleaseManifest): Boolean {
        if (file.length() != release.size) return false
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count == -1) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) } == release.sha256
    }

    fun close() {
        client.dispatcher.cancelAll()
        executor.shutdownNow()
    }
}
