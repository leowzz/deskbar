package app.deskbar.workbench

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Connection and per-computer identities, encrypted by a non-exportable Keystore key. */
class CredentialStore(context: Context) {
    private val prefs = context.getSharedPreferences("deskbar-connection", Context.MODE_PRIVATE)
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("deskbar-host", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("deskbar-host", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    private fun read(entry: String): JSONObject? {
        val encoded = prefs.getString(entry, null) ?: return null
        val packed = JSONObject(encoded)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(packed.getString("iv"), Base64.NO_WRAP)))
        return JSONObject(String(cipher.doFinal(Base64.decode(packed.getString("data"), Base64.NO_WRAP)), Charsets.UTF_8))
    }
    private fun write(entry: String, value: JSONObject) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val packed = JSONObject().put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("data", Base64.encodeToString(cipher.doFinal(value.toString().toByteArray(Charsets.UTF_8)), Base64.NO_WRAP))
        check(prefs.edit().putString(entry, packed.toString()).commit()) { "未能保存连接，请重试" }
    }
    @Synchronized fun load(): JSONObject? = read("host")
    @Synchronized fun save(host: JSONObject) = write("host", host)
    /** Pairing identity is private to each computer and survives forgetting its connection. */
    @Synchronized fun identity(hostId: String): String {
        val identities = read("identities") ?: JSONObject()
        if (identities.has(hostId)) return identities.getString(hostId)
        val identity = Base64.encodeToString(
            ByteArray(32).also { SecureRandom().nextBytes(it) },
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
        )
        write("identities", identities.put(hostId, identity))
        return identity
    }
    @Synchronized fun clear() { check(prefs.edit().remove("host").commit()) { "未能移除连接，请重试" } }
}
