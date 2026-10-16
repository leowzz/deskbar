package app.deskbar.workbench

import android.content.Context
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Base64
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.net.*
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

class ConnectionRuntime(private val context: Context) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val store = CredentialStore(context)
    private val generation = AtomicLong()
    private var events: EventChannel.EventSink? = null
    @Volatile private var socket: WebSocket? = null
    @Volatile private var client: OkHttpClient? = null
    @Volatile private var connecting = false
    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { events = sink }
    override fun onCancel(arguments: Any?) { events = null }
    private fun emit(value: JSONObject, ticket: Long = generation.get()) {
        main.post { if (ticket == generation.get()) events?.success(value.toString()) }
    }
    private fun state(type: String, text: String = "", ticket: Long = generation.get()) = emit(JSONObject().put("type", type).put("message", text), ticket)
    @Synchronized private fun stop() {
        generation.incrementAndGet()
        socket?.cancel(); socket = null
        client?.dispatcher?.cancelAll(); client = null
        connecting = false
    }
    fun close() { stop(); io.shutdownNow() }

    fun call(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pause", "cancel" -> { stop(); result.success(null) }
            "forget" -> {
                stop()
                io.execute { try { store.clear(); main.post { result.success(null) } } catch (_: Exception) { main.post { result.error("storage", "未能移除连接，请重试", null) } } }
            }
            "restore" -> io.execute { try {
                val host = store.load()
                main.post { result.success(host?.let { JSONObject().put("name", it.getString("name")).put("host_id", it.getString("host_id")).put("snapshot", it.optJSONObject("snapshot")).toString() }) }
            } catch (_: Exception) { main.post { result.error("storage", "无法读取已保存的连接，请重试或移除后重新配对", null) } } }
            "pair" -> {
                stop()
                val ticket = generation.get()
                val invitation = call.argument<String>("invitation") ?: ""
                val name = call.argument<String>("name") ?: "Android 工作台"
                io.execute { try { pair(invitation, name, ticket); main.post { result.success(null) } }
                    catch (e: Exception) { main.post { if (ticket == generation.get()) result.error("pairing", friendly(e), null) else result.success(null) } } }
            }
            "connect" -> {
                if (!connecting && socket == null) {
                    connecting = true
                    val ticket = generation.get()
                    io.execute { try { connect(ticket) } catch (e: Exception) { if (e !is RevokedError) state("offline", friendly(e), ticket) } finally { if (ticket == generation.get()) connecting = false } }
                }
                result.success(null)
            }
            "command" -> {
                val ticket = generation.get()
                val input = JSONObject(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()).put("command_id", UUID.randomUUID().toString())
                io.execute {
                    try {
                        val response = command(input, ticket)
                        main.post { result.success(response.toString()) }
                    } catch (e: Exception) {
                        if (e is RevokedError) {
                            synchronized(this) { if (ticket == generation.get()) store.clear() }
                            state("revoked", "电脑已移除这台设备，请重新配对", ticket)
                        }
                        main.post { result.error("command", if (e is UserError) e.message else "结果未知，请先查看电脑；不会自动重试", null) }
                    }
                }
            }
            "discover" -> io.execute { try { val found = discover(); main.post { result.success(found.toString()) } }
                catch (_: Exception) { main.post { result.error("discovery", "未能搜索局域网，请检查 Wi-Fi 后重试；也可以直接扫码连接", null) } } }
            else -> result.notImplemented()
        }
    }

    private open class UserError(message: String) : Exception(message)
    private class RevokedError : UserError("这台设备已取消连接，请重新配对")
    private fun friendly(error: Exception): String = when (error) {
        is UserError -> error.message ?: "连接未完成，请重试"
        is javax.net.ssl.SSLException -> "无法核验这台电脑，请重新生成邀请；已配对电脑换了身份时需要重新配对"
        else -> "未能连接电脑，请确认两端在同一局域网，电脑上的 DeskBar 连接助手正在运行"
    }
    private fun randomSecret(): String = ByteArray(32).also { SecureRandom().nextBytes(it) }.let { Base64.encodeToString(it, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING) }

    /** Pin verification is the trust anchor; an offered address never changes it. */
    private fun pinnedClient(pin: String): OkHttpClient {
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) { throw CertificateException("Client certificates are unsupported") }
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                if (chain.isEmpty()) throw CertificateException("Missing certificate")
                chain[0].checkValidity()
                val actual = "sha256/" + Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(chain[0].publicKey.encoded), Base64.NO_WRAP)
                if (!MessageDigest.isEqual(actual.toByteArray(), pin.toByteArray())) throw CertificateException("Host key changed")
            }
        }
        val ssl = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), SecureRandom()) }
        return OkHttpClient.Builder().sslSocketFactory(ssl.socketFactory, trust)
            // The pinned key is verified before this address-independent hostname policy.
            .hostnameVerifier { _, _ -> true }.followRedirects(false).followSslRedirects(false)
            .connectionSpecs(listOf(ConnectionSpec.MODERN_TLS)).connectTimeout(4, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS).callTimeout(6, TimeUnit.SECONDS).pingInterval(10, TimeUnit.SECONDS).build()
    }

    private fun request(http: OkHttpClient, endpoint: String, path: String, body: JSONObject? = null, token: String? = null): JSONObject {
        val builder = Request.Builder().url(endpoint + path)
        if (body != null) builder.post(body.toString().toRequestBody("application/json".toMediaType()))
        if (token != null) builder.header("Authorization", "Bearer $token")
        http.newCall(builder.build()).execute().use { response ->
            if (response.code == 401) throw RevokedError()
            val json = JSONObject(response.body?.string() ?: "{}")
            if (!response.isSuccessful) throw UserError(json.optString("message", "连接未完成，请重试"))
            return json
        }
    }

    private fun pair(text: String, name: String, ticket: Long) {
        val uri = Uri.parse(text.trim())
        fun field(key: String) = uri.getQueryParameter(key) ?: throw UserError("邀请不完整，请重新复制或扫码")
        if (uri.scheme != "deskbar" || uri.host != "pair" || field("v") != "1") throw UserError("这不是 DeskBar 连接邀请")
        val expires = field("expires").toLongOrNull() ?: throw UserError("邀请不完整")
        if (expires <= System.currentTimeMillis() / 1000) throw UserError("邀请已过期，请在电脑上重新生成")
        val pin = field("pin")
        if (!pin.startsWith("sha256/") || pin.length != 51) throw UserError("邀请不完整")
        val hostId = field("host")
        val endpoints = uri.getQueryParameters("endpoint").take(8).filter { endpoint ->
            val candidate = Uri.parse(endpoint)
            candidate.scheme == "https" && candidate.host != null && candidate.userInfo == null && candidate.query == null && candidate.fragment == null && candidate.path.orEmpty().isEmpty()
        }
        if (endpoints.isEmpty()) throw UserError("邀请没有可用地址，请在电脑上重新生成")
        val http = pinnedClient(pin); client = http
        val claim = randomSecret()
        val input = JSONObject().put("session_id", field("session")).put("secret", field("secret")).put("claim", claim).put("name", name.trim())
        var chosen = ""
        var pending: JSONObject? = null
        var last: Exception? = null
        for (endpoint in endpoints) {
            if (ticket != generation.get()) return
            try { pending = request(http, endpoint, "/v1/pairing/request", input); chosen = endpoint; break }
            catch (e: Exception) { last = e; if (e is UserError) throw e }
        }
        val approval = pending ?: throw (last ?: UserError("未能连接电脑"))
        state("approval", "请回到电脑，允许这台设备连接", ticket)
        val statusInput = JSONObject().put("request_id", approval.getString("id")).put("claim", claim)
        while (ticket == generation.get() && System.currentTimeMillis() / 1000 < expires) {
            val status = request(http, chosen, "/v1/pairing/status", statusInput)
            if (!status.isNull("token")) {
                val token = status.getString("token")
                val snapshot = request(http, chosen, "/v1/snapshot", token = token)
                if (snapshot.getString("host_id") != hostId || snapshot.getInt("protocol_version") != 1) throw UserError("电脑身份或版本不一致，请重新配对")
                val host = JSONObject().put("host_id", hostId).put("name", snapshot.getString("name")).put("pin", pin).put("endpoint", chosen).put("token", token)
                synchronized(this) { if (ticket != generation.get()) return; store.save(host) }
                emit(JSONObject().put("type", "paired").put("name", host.getString("name")), ticket)
                subscribe(http, host, ticket)
                return
            }
            Thread.sleep(1000)
        }
        if (ticket == generation.get()) throw UserError("连接邀请已结束，请重新生成")
    }

    private fun connect(ticket: Long) {
        if (ticket != generation.get()) return
        val host = store.load() ?: return
        state("connecting", ticket = ticket)
        val http = pinnedClient(host.getString("pin")); client = http
        fun attempt(endpoint: String): Boolean {
            if (ticket != generation.get()) return false
            return try {
                val snapshot = request(http, endpoint, "/v1/snapshot", token = host.getString("token"))
                if (snapshot.getString("host_id") != host.getString("host_id") || snapshot.getInt("protocol_version") != 1) throw UserError("电脑版本或身份不一致，请检查后重新配对")
                host.put("endpoint", endpoint)
                synchronized(this) { if (ticket != generation.get()) return false; store.save(host) }
                subscribe(http, host, ticket); true
            } catch (e: UserError) {
                if (e.message?.contains("取消连接") == true) {
                    synchronized(this) { if (ticket == generation.get()) store.clear() }
                    state("revoked", "电脑已移除这台设备，请重新配对", ticket)
                }
                throw e
            } catch (_: Exception) { false }
        }
        val recent = host.getString("endpoint")
        if (attempt(recent)) return
        if (ticket != generation.get()) return
        val offers = discover()
        for (i in 0 until offers.length()) {
            val offer = offers.getJSONObject(i)
            if (offer.getString("host_id") == host.getString("host_id") && offer.getString("endpoint") != recent && attempt(offer.getString("endpoint"))) return
        }
        if (ticket == generation.get()) state("offline", "电脑暂时离线，恢复连接后会自动重连", ticket)
    }

    @Synchronized private fun subscribe(http: OkHttpClient, host: JSONObject, ticket: Long) {
        if (ticket != generation.get()) return
        val request = Request.Builder().url(host.getString("endpoint").replaceFirst("https://", "wss://") + "/v1/events")
            .header("Authorization", "Bearer " + host.getString("token")).build()
        socket = http.newWebSocket(request, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                if (ticket != generation.get()) return
                try {
                    val json = JSONObject(text)
                    if (json.optString("type") == "revoked") {
                        synchronized(this@ConnectionRuntime) { if (ticket != generation.get()) return; store.clear() }
                        socket = null; webSocket.cancel()
                        state("revoked", "电脑已移除这台设备，请重新配对", ticket)
                    } else if (json.getString("host_id") == host.getString("host_id") && json.getInt("protocol_version") == 1) {
                        synchronized(this@ConnectionRuntime) {
                            if (ticket != generation.get() || socket !== webSocket) return
                            val saved = store.load() ?: return
                            json.put("received_at", System.currentTimeMillis() / 1000)
                            saved.put("snapshot", json)
                            store.save(saved)
                        }
                        emit(JSONObject().put("type", "snapshot").put("snapshot", json), ticket)
                    } else { webSocket.cancel(); socket = null; state("offline", "电脑版本不兼容，请更新 DeskBar 连接助手", ticket) }
                } catch (_: Exception) { webSocket.cancel(); socket = null; state("offline", "未能读取电脑状态，请重试", ticket) }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                synchronized(this@ConnectionRuntime) {
                    if (ticket != generation.get() || socket !== webSocket) return
                    socket = null
                }
                if (response?.code == 401) {
                    try { synchronized(this@ConnectionRuntime) { if (ticket == generation.get()) store.clear() } } catch (_: Exception) { }
                    state("revoked", "电脑已移除这台设备，请重新配对", ticket)
                } else state("offline", "连接已中断，正在等待电脑恢复", ticket)
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                synchronized(this@ConnectionRuntime) {
                    if (ticket == generation.get() && socket === webSocket) { socket = null; state("offline", "连接已中断，正在等待电脑恢复", ticket) }
                }
            }
        })
    }

    private fun command(input: JSONObject, ticket: Long): JSONObject {
        if (ticket != generation.get() || socket == null) throw UserError("电脑离线，连接后才能打开")
        val host = store.load() ?: throw UserError("请重新连接电脑")
        val http = client ?: throw UserError("电脑离线，连接后才能打开")
        val endpoint = host.getString("endpoint")
        val token = host.getString("token")
        val id = input.getString("command_id")
        // Submit once. A lost response is resolved only by querying this ID.
        var response = try { request(http, endpoint, "/v1/commands", input, token) }
            catch (e: UserError) { throw e }
            catch (_: Exception) { request(http, endpoint, "/v1/commands/$id", token = token) }
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(7)
        while (response.optString("status") == "accepted" && ticket == generation.get() && System.nanoTime() < deadline) {
            Thread.sleep(200)
            response = request(http, endpoint, "/v1/commands/$id", token = token)
        }
        if (response.optString("status") == "accepted") return JSONObject().put("status", "unknown").put("message", "电脑已接收，结果暂未确认；请先查看电脑")
        return response
    }

    private fun discover(): JSONArray {
        val nonce = UUID.randomUUID().toString()
        val query = JSONObject().put("product", "deskbar").put("version", 1).put("type", "query").put("nonce", nonce).toString().toByteArray()
        val found = linkedMapOf<String, JSONObject>()
        val wifi = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val lock = wifi.createMulticastLock("deskbar-discovery").apply { setReferenceCounted(false); acquire() }
        try {
            DatagramSocket().use { udp ->
                udp.soTimeout = 250
                udp.send(DatagramPacket(query, query.size, InetAddress.getByName("239.77.68.76"), 42831))
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
                val buffer = ByteArray(2048)
                while (System.nanoTime() < deadline) {
                    try {
                        val packet = DatagramPacket(buffer, buffer.size); udp.receive(packet)
                        val offer = JSONObject(String(packet.data, 0, packet.length, Charsets.UTF_8))
                        if (offer.optString("product") != "deskbar" || offer.optInt("version") != 1 || offer.optString("type") != "offer" || offer.optString("nonce") != nonce) continue
                        val port = offer.getInt("port")
                        if (port !in 1..65535 || found.size >= 32) continue
                        offer.put("endpoint", "https://${packet.address.hostAddress}:$port")
                        found[offer.getString("host_id") + packet.address.hostAddress] = offer
                    } catch (_: SocketTimeoutException) { } catch (_: org.json.JSONException) { }
                }
            }
        } finally { lock.release() }
        return JSONArray(found.values.toList())
    }
}
