package ro.chimeraerp.companion

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.math.BigInteger

/** Persistent signing key. The private key never leaves Android Keystore. */
object CompanionIdentity {
    private const val alias = "chimera-companion-identity-v1"
    private fun store(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    @Synchronized private fun ensureKey(): KeyStore {
        val store = store()
        if (!store.containsAlias(alias)) {
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
                initialize(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .setUserAuthenticationRequired(false).build())
            }.generateKeyPair()
        }
        return store()
    }
    private fun encode(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    private fun coordinate(value: BigInteger): ByteArray {
        val raw = value.toByteArray()
        return ByteArray(32).also { out ->
            val count = minOf(raw.size, 32)
            System.arraycopy(raw, raw.size - count, out, 32 - count, count)
        }
    }
    fun publicKey(): Map<String, String> {
        val key = ensureKey().getCertificate(alias).publicKey as ECPublicKey
        return mapOf("kty" to "EC", "crv" to "P-256", "x" to encode(coordinate(key.w.affineX)), "y" to encode(coordinate(key.w.affineY)))
    }
    fun sign(message: String): String {
        require(message.toByteArray(Charsets.UTF_8).size <= 32768)
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(ensureKey().getKey(alias, null) as java.security.PrivateKey)
        signer.update(message.toByteArray(Charsets.UTF_8))
        val der = signer.sign()
        // P-256 signatures have short DER lengths. JWS/Web Crypto use r || s.
        require(der[0].toInt() == 0x30 && der[2].toInt() == 0x02)
        val rLength = der[3].toInt() and 0xff
        val sOffset = 4 + rLength
        require(der[sOffset].toInt() == 0x02)
        val sLength = der[sOffset + 1].toInt() and 0xff
        val r = BigInteger(1, der.copyOfRange(4, sOffset))
        val s = BigInteger(1, der.copyOfRange(sOffset + 2, sOffset + 2 + sLength))
        return encode(coordinate(r) + coordinate(s))
    }
}
