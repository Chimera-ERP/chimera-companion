package ro.tabusociety.chimera_companion

import android.app.Presentation
import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Display
import android.view.WindowManager
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebSettings
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebResourceError
import android.webkit.SslErrorHandler
import android.net.http.SslError
import android.net.Uri
import org.json.JSONObject
import java.io.ByteArrayInputStream

/** Android Presentation works on iMin dual-screen models without a vendor SDK.
 * Application-owned: Chrome/PWA can occupy the main screen independently.
 * No customer identities, fiscal instructions or payment data are accepted here.
 */
class CustomerDisplay(private val context: Context) : DisplayManager.DisplayListener {
    private val manager = context.getSystemService(DisplayManager::class.java)
    private val prefs = context.getSharedPreferences("customer_display", Context.MODE_PRIVATE)
    private val handler = Handler(Looper.getMainLooper())
    private var presentation: BasketPresentation? = null
    private var basket: Map<*, *>? = null
    private val revisions = mutableMapOf<String, Long>()
    private var failure: String? = null
    private var foregroundActivity: Activity? = null
    private var activityOwnedPresentation = false
    private var pageSettings: Map<*, *> = runCatching {
        val json = JSONObject(prefs.getString("presentation", "{}")!!)
        json.keys().asSequence().associateWith { json.get(it) }
    }.getOrDefault(emptyMap<String, Any>())
    private var bundle: DisplayBundle? = runCatching { DisplayBundle.load(context,prefs.getString("bundleDirectory",null)) }.getOrNull()
    private val expire = Runnable { basket = null; presentation?.render(null) }

    init { manager.registerDisplayListener(this, handler) }
    private fun displays() = manager.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
        .filter { it.displayId != Display.DEFAULT_DISPLAY && it.isValid }
    private fun enabled() = prefs.getBoolean("enabled", true)
    fun foreground(activity: Activity?) {
        if (foregroundActivity === activity) return
        foregroundActivity = activity
        // An application-owned display must not reload its webpage every time
        // the operator switches between Companion and the PWA.
        if(activityOwnedPresentation || !Settings.canDrawOverlays(context)) {
            presentation?.dismiss()
            presentation = null
        }
        reconcile()
    }
    fun enable(value: Boolean) {
        prefs.edit().putBoolean("enabled", value).apply()
        if (!value) clear()
        reconcile()
    }
    fun clear() {
        handler.removeCallbacks(expire)
        basket = null
        presentation?.dismiss()
        presentation = null
    }
    fun useBundle(directory:String?) {
        val next=DisplayBundle.load(context,directory)
        if(next?.key==bundle?.key)return
        bundle=next
        prefs.edit().putString("bundleDirectory",directory).commit()
        presentation?.dismiss();presentation=null
        reconcile()
    }
    private fun reconcile() {
        val target = displays().firstOrNull()
        val overlay = Settings.canDrawOverlays(context)
        if (!enabled() || (!overlay && foregroundActivity == null) || target == null) {
            clear()
            return
        }
        if (presentation?.display?.displayId == target.displayId && presentation?.isShowing == true) return
        presentation?.dismiss()
        presentation = null
        try {
            // Keep Presentation's window type and window context paired. Changing
            // setType after construction fails on Android 12+ (InvalidDisplayException).
            val next = BasketPresentation(if (overlay) context else foregroundActivity!!, target, pageSettings, bundle)
            activityOwnedPresentation = !overlay
            next.show()
            presentation = next
            next.render(basket)
            failure = null
        } catch (error: Exception) {
            presentation?.dismiss(); presentation = null
            failure = when (error) {
                is WindowManager.InvalidDisplayException -> "display_rejected"
                is WindowManager.BadTokenException -> "window_rejected"
                is SecurityException -> "permission_denied"
                else -> "display_unavailable"
            }
            android.util.Log.w("ChimeraDisplay", "Cannot open secondary display: $failure (${error.javaClass.simpleName})")
        }
    }
    fun status(): Map<String, Any> {
        reconcile()
        val found = displays()
        val state = when {
            !enabled() -> "disabled"
            found.isEmpty() -> "no_display"
            !Settings.canDrawOverlays(context) && foregroundActivity == null -> "permission_required"
            failure != null || presentation == null -> "error"
            basket != null && (basket?.get("lines") as? List<*>)?.isNotEmpty() == true -> "showing"
            else -> "ready"
        }
        return mapOf("state" to state, "enabled" to enabled(), "bundleKey" to (bundle?.key ?: ""), "pageState" to (presentation?.pageState ?: "inactive"), "backgroundAllowed" to Settings.canDrawOverlays(context), "errorCode" to (if (state == "error") failure ?: "display_unavailable" else ""), "displays" to found.map {
            val size = android.graphics.Point()
            @Suppress("DEPRECATION")
            it.getSize(size)
            mapOf("id" to it.displayId, "name" to it.name, "width" to size.x, "height" to size.y)
        })
    }
    fun update(value: Map<*, *>): Map<String, Any> {
        // Dart validates the bounded, allowlisted shape before crossing this channel.
        val pos = value["posId"] as String
        val revision = (value["revision"] as Number).toLong()
        val previous = revisions[pos]
        if (previous != null && revision <= previous) return status() + mapOf("applied" to false)
        val current = status()
        if (current["state"] !in listOf("ready", "showing")) return current + mapOf("applied" to false)
        // Bound memory even if assignments change repeatedly during one app lifetime.
        if (revisions.size >= 32 && !revisions.containsKey(pos)) revisions.clear()
        revisions[pos] = revision
        val settings = value["presentation"] as? Map<*, *>
        if (bundle == null && settings != null && settings != pageSettings) {
            pageSettings = settings
            prefs.edit().putString("presentation", JSONObject(settings).toString()).apply()
        }
        basket = value
        presentation?.render(value)
        handler.removeCallbacks(expire)
        handler.postDelayed(expire, 30000)
        return status() + mapOf("applied" to true)
    }
    override fun onDisplayAdded(displayId: Int) = reconcile()
    override fun onDisplayChanged(displayId: Int) = reconcile()
    override fun onDisplayRemoved(displayId: Int) { clear(); reconcile() }
}

private class BasketPresentation(context: Context, display: Display, initialSettings: Map<*, *>, private val bundle:DisplayBundle?=null) : Presentation(context, display) {
    private lateinit var web: WebView
    private var pageConfig = bundle?.settings() ?: initialSettings
    private var snapshot: Map<*, *>? = null
    private var requestedUrl: String? = null
    private var loaded = false
    private var fallback = false
    private val handler = Handler(Looper.getMainLooper())
    private val loadTimeout = Runnable {
        if (!loaded && !fallback) {
            android.util.Log.w("ChimeraDisplay", "Page load timed out: expected=$requestedUrl; actual=${web.url}; managed=${bundle!=null}")
            showBuiltin(true)
        }
    }
    var pageState = "loading"
        private set
    private val builtinUrl = "https://appassets.androidplatform.net/customer-display/"
    private fun validUrl(url: String): Boolean = runCatching {
        val parsed = Uri.parse(url)
        parsed.scheme == "https" && !parsed.host.isNullOrBlank() && parsed.userInfo == null && parsed.fragment == null
    }.getOrDefault(false)
    private fun sameOrigin(url: String, target: String): Boolean = runCatching {
        val a = Uri.parse(url); val b = Uri.parse(target)
        a.scheme == "https" && a.host == b.host && (if(a.port == -1) 443 else a.port) == (if(b.port == -1) 443 else b.port)
    }.getOrDefault(false)
    private fun pageReady(view: WebView, url: String) {
        val expected = if(fallback || requestedUrl.isNullOrEmpty()) builtinUrl else requestedUrl!!
        // The built-in and managed pages share an origin. An old root-page
        // callback must never cancel the managed page's timer or publish to it.
        if (view.url != url) return
        val exactPage = bundle != null || fallback || requestedUrl.isNullOrEmpty()
        if (if(exactPage) url != expected else !sameOrigin(url, expected)) return
        handler.removeCallbacks(loadTimeout)
        loaded = true
        pageState = if(fallback) "fallback" else "ready"
        android.util.Log.i("ChimeraDisplay", "Page ready: $url; managed=${bundle!=null}; fallback=$fallback")
        publish()
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window?.addFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
        web = WebView(context).apply {
            setBackgroundColor(Color.rgb(18, 21, 19))
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = false
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            settings.setSupportMultipleWindows(false)
            settings.javaScriptCanOpenWindowsAutomatically = false
            // No addJavascriptInterface: custom content never receives a native API.
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                    !validUrl(request.url.toString()) || !sameOrigin(request.url.toString(), requestedUrl ?: builtinUrl)
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                    if(request.url.toString()==builtinUrl) return WebResourceResponse("text/html","UTF-8",context.assets.open("flutter_assets/assets/customer-display/index.html"))
                    // Managed pages are completely local, including every image/GIF.
                    // Unknown resources never escape to the network.
                    if(bundle!=null){
                        val response=bundle.response(request.url)
                        if(request.isForMainFrame)android.util.Log.i("ChimeraDisplay", "Managed page response: ${request.url}; status=${response.statusCode}")
                        return response
                    }
                    if (request.url.scheme in listOf("https", "data", "about")) return null
                    return WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(ByteArray(0)))
                }
                override fun onPageCommitVisible(view: WebView, url: String) {
                    // The document is committed even if a slow image prevents
                    // onPageFinished. Do not replace a working local renderer.
                    pageReady(view, url)
                }
                override fun onPageFinished(view: WebView, url: String) {
                    pageReady(view, url)
                }
                override fun onReceivedSslError(view: WebView, error: SslErrorHandler, details: SslError) {
                    error.cancel(); showBuiltin(true)
                }
                override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if(request.isForMainFrame)android.util.Log.w("ChimeraDisplay","Page load failed: ${error.errorCode}; managed=${bundle!=null}; fallback=$fallback")
                    if(request.isForMainFrame && !fallback) showBuiltin(true)
                }
                override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
                    if(request.isForMainFrame)android.util.Log.w("ChimeraDisplay","Page HTTP failure: ${response.statusCode}; managed=${bundle!=null}; fallback=$fallback")
                    if(request.isForMainFrame && response.statusCode >= 400 && !fallback) showBuiltin(true)
                }
            }
        }
        setContentView(web)
        window?.setLayout(-1, -1)
        render(null)
    }
    private fun showBuiltin(failed: Boolean) {
        handler.removeCallbacks(loadTimeout)
        loaded = false; fallback = failed; pageState = if(failed) "fallback" else "loading"
        web.stopLoading()
        web.loadUrl(builtinUrl)
    }
    fun render(value: Map<*, *>?) {
        if (!::web.isInitialized) return
        snapshot = value
        if(bundle==null)(value?.get("presentation") as? Map<*, *>)?.let { pageConfig = it }
        val url = bundle?.url ?: (pageConfig["url"] as? String).orEmpty()
        if(requestedUrl != url) {
            requestedUrl = url; loaded = false; fallback = false; pageState = "loading"
            if(url.isEmpty() || !validUrl(url)) showBuiltin(url.isNotEmpty()) else {
                handler.removeCallbacks(loadTimeout)
                handler.postDelayed(loadTimeout, 8000)
                web.loadUrl(url)
            }
        }
        publish()
    }
    private fun publish() {
        if (!loaded) return
        val value = mutableMapOf<String, Any?>("lines" to emptyList<Any>(), "totalMinor" to 0, "currency" to "RON", "presentation" to pageConfig)
        // Only public display fields cross into web content, never posId or auth.
        for(key in listOf("lines", "totalMinor", "currency", "revision")) snapshot?.get(key)?.let { value[key] = it }
        val json = JSONObject.quote(JSONObject(value).toString())
        web.evaluateJavascript("window.chimeraCustomerDisplay=JSON.parse($json);window.dispatchEvent(new CustomEvent('chimera:customer-display',{detail:window.chimeraCustomerDisplay}));", null)
    }
    override fun dismiss() {
        handler.removeCallbacksAndMessages(null)
        if(::web.isInitialized) { web.stopLoading(); web.destroy() }
        super.dismiss()
    }
}
