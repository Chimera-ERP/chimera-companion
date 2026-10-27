package ro.tabusociety.chimera_companion

import android.content.Context
import android.net.Uri
import android.webkit.WebResourceResponse
import org.json.JSONObject
import org.json.JSONArray
import java.io.ByteArrayInputStream
import java.io.File

/** Private, verified downloads only. Neither a PWA nor a web page supplies paths. */
class DisplayBundle private constructor(val directory: File, val manifest: JSONObject) {
    val key = manifest.getString("key")
    val origin = "https://appassets.androidplatform.net"
    val base = "$origin/customer-display/$key/"
    val url = "${base}index.html"
    private val media = manifest.getJSONArray("assets").let { a -> (0 until a.length()).associate { i -> val item=a.getJSONObject(i);item.getString("sha256") to item.getString("mime") } }
    fun settings(): Map<String, Any?> {
        val config=JSONObject(manifest.getJSONObject("config").toString())
        config.put("url",url)
        config.put("logoUrl",config.optString("logoAsset").takeIf { media.containsKey(it) }?.let { base+it } ?: "")
        val slides=config.getJSONArray("playlist")
        for(i in 0 until slides.length()) { val slide=slides.getJSONObject(i);slide.put("src",base+slide.getString("asset")) }
        return objectMap(config)
    }
    fun response(uri: Uri): WebResourceResponse {
        val text=uri.toString()
        val name=if(text.startsWith(base))text.removePrefix(base) else ""
        val mime=if(name=="index.html")"text/html" else media[name]
        if(mime==null || (name!="index.html"&&!name.matches(Regex("[a-f0-9]{64}")))) {
            return WebResourceResponse("text/plain","UTF-8",403,"Forbidden",mapOf("Cache-Control" to "no-store"),ByteArrayInputStream(ByteArray(0)))
        }
        return runCatching { WebResourceResponse(mime,if(mime=="text/html")"UTF-8" else null,File(directory,name).inputStream()) }
            .getOrElse { WebResourceResponse("text/plain","UTF-8",404,"Not found",emptyMap(),ByteArrayInputStream(ByteArray(0))) }
    }
    companion object {
        fun load(context:Context,path:String?):DisplayBundle? {
            if(path.isNullOrEmpty())return null
            val root=File(context.filesDir,"customer-displays").canonicalFile
            val directory=File(path).canonicalFile
            require(directory.path.startsWith(root.path+File.separator)) { "Invalid bundle root" }
            val manifest=JSONObject(File(directory,"manifest.json").readText())
            require(manifest.getInt("schema")==1 && manifest.getString("key")==directory.name && directory.name.matches(Regex("[a-f0-9]{64}")))
            require(File(directory,"index.html").isFile)
            return DisplayBundle(directory,manifest)
        }
        private fun objectMap(value:JSONObject):Map<String,Any?> = value.keys().asSequence().associateWith { decode(value.get(it)) }
        private fun decode(value:Any?):Any? = when(value) {
            JSONObject.NULL -> null
            is JSONObject -> objectMap(value)
            is JSONArray -> (0 until value.length()).map { decode(value.get(it)) }
            else -> value
        }
    }
}
