package ro.tabusociety.chimera_companion

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.content.Intent
import java.io.File
import org.json.JSONObject
import org.json.JSONTokener
import android.webkit.WebView
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Run on a disposable emulator with a simulated secondary display and overlay
 * permission. Exercises real Android windows; never contacts an ECR or terminal.
 */
class CustomerDisplayTestRunner : Instrumentation() {
    private var foregroundOnly = false
    private var bundleOnly = false
    private var bootMode: String? = null
    override fun onCreate(arguments: Bundle?) { bootMode = arguments?.getString("mode"); foregroundOnly = bootMode == "foreground"; bundleOnly=bootMode=="bundle";super.onCreate(arguments); start() }
    override fun onStart() {
        if (bootMode == "boot" || bootMode == "headless") { BootStartupTrials.run(this, bootMode == "headless"); return }
        if(bundleOnly){bundleTrial();return}
        if (foregroundOnly) { foregroundTrial(); return }
        var display: CustomerDisplay? = null
        val prefs = targetContext.getSharedPreferences("customer_display", 0)
        val enabled = prefs.getBoolean("enabled", false)
        try {
            runOnMainSync {
                display = CustomerDisplay(targetContext.applicationContext)
                display!!.enable(true)
                check(display!!.status()["state"] == "ready") { "Enable requires a presentation display and overlay permission: ${display!!.status()}" }
                val basket = mapOf("posId" to "synthetic-pos", "revision" to 10L, "currency" to "RON", "totalMinor" to 2000,
                    "lines" to listOf(mapOf("name" to "Cafea cu lapte", "quantity" to 1.5, "totalMinor" to 2000), mapOf("name" to "Apă gratuită", "quantity" to 1, "totalMinor" to 0)))
                check(display!!.update(basket)["state"] == "showing")
                check(display!!.update(basket + ("revision" to 9L))["applied"] == false)
                check(display!!.update(basket + mapOf("revision" to 11L, "totalMinor" to 0, "lines" to emptyList<Any>()))["state"] == "ready")
                check(display!!.update(basket + ("revision" to 12L))["state"] == "showing")
            }
            // No Activity owns this window; verify it remains visible in background.
            Thread.sleep(1000)
            runOnMainSync { check(display!!.status()["state"] == "showing") }
            sendStatus(0, Bundle().apply { putString("stream", "Presentation shown; stale revision ignored; clear and background passed. Waiting for expiry.\n") })
            Thread.sleep(30000)
            runOnMainSync { check(display!!.status()["state"] == "ready"); display!!.enable(false); check(display!!.status()["state"] == "disabled") }
            finish(Activity.RESULT_OK, Bundle().apply { putString("stream", "Customer display: rendering, revision, clear, background, expiry and disable passed.\n") })
        } catch (error: Throwable) {
            finish(Activity.RESULT_CANCELED, Bundle().apply { putString("stream", "FAILED: ${error.message}\n") })
        } finally {
            runOnMainSync { display?.enable(false); prefs.edit().putBoolean("enabled", enabled).apply() }
        }
    }
    private fun bundleTrial() {
        var display:CustomerDisplay?=null
        val directory=File(targetContext.filesDir,"customer-displays/synthetic-test/"+"a".repeat(64))
        val prefs=targetContext.getSharedPreferences("customer_display",0)
        val previous=prefs.getString("bundleDirectory",null)
        val enabled=prefs.getBoolean("enabled",true)
        try {
            directory.mkdirs()
            // Deliberately different from the APK page: status alone cannot prove
            // that the downloaded script, rather than the built-in one, ran.
            File(directory,"index.html").writeText("""<!doctype html><html><body><output id="quote"></output><script>
                window.downloadedPageSentinel='unique-managed-script';window.frameCount=0;
                window.addEventListener('chimera:customer-display',function(event){
                    window.frameCount++;var value=event.detail;
                    document.body.style.backgroundColor=value.presentation.backgroundColor;
                    document.getElementById('quote').style.color=value.presentation.accent;
                    document.getElementById('quote').textContent=String(value.totalMinor);
                });
                </script></body></html>""")
            File(directory,"manifest.json").writeText(JSONObject(mapOf("schema" to 1,"key" to "a".repeat(64),"assets" to emptyList<Any>(),"config" to mapOf("title" to "Test bundle","message" to "Offline","layout" to "receipt","theme" to "dark","backgroundColor" to "#16263b","accent" to "#ffca56","playlist" to emptyList<Any>()))).toString())
            val bundle=DisplayBundle.load(targetContext,directory.path)!!
            check(bundle.response(android.net.Uri.parse("https://untrusted.example/test")).statusCode==403)
            runOnMainSync {
                display=CustomerDisplay(targetContext.applicationContext)
                display!!.useBundle(directory.path);display!!.enable(true)
            }
            // Longer than the old eight-second fallback timer: loaded local pages
            // must not be replaced by an error page after the first basket update.
            Thread.sleep(10000)
            val before=readDownloadedPage(display!!)
            check(before.getString("sentinel")=="unique-managed-script"){"Downloaded script did not execute: $before"}
            check(before.getString("url")==bundle.url){"Wrong document loaded: $before"}
            // A stale completion for the same-origin built-in root must not
            // republish a frame or mark the wrong page ready.
            runOnMainSync {
                val web=displayWebView(display!!)
                web.webViewClient.onPageFinished(web,"https://appassets.androidplatform.net/customer-display/")
            }
            check(readDownloadedPage(display!!).getInt("frames")==before.getInt("frames")){"Accepted wrong root-page completion"}
            runOnMainSync {
                check(display!!.status()["pageState"]=="ready"){"Local bundle load failed: ${display!!.status()}"}
                display!!.update(mapOf("posId" to "synthetic","revision" to 1L,"lines" to listOf(mapOf("name" to "Coffee","quantity" to 1,"totalMinor" to 650)),"currency" to "RON","totalMinor" to 650,"presentation" to mapOf("url" to "https://untrusted.example/")))
            }
            Thread.sleep(1000)
            runOnMainSync {check(display!!.status()["pageState"]=="ready");check(display!!.status()["state"]=="showing")}
            val rendered=readDownloadedPage(display!!)
            check(rendered.getString("sentinel")=="unique-managed-script" && rendered.getString("url")==bundle.url){"Managed page replaced: $rendered"}
            check(rendered.getString("quote")=="650"){"Quoted basket not received: $rendered"}
            check(rendered.getString("background")=="rgb(22, 38, 59)" && rendered.getString("accent")=="rgb(255, 202, 86)"){"Managed colors not applied: $rendered"}
            finish(Activity.RESULT_OK,Bundle().apply{putString("stream","Unique downloaded script and quoted basket executed; managed colors, exact page completion and legacy-presentation isolation passed.\n")})
        }catch(error:Throwable){finish(Activity.RESULT_CANCELED,Bundle().apply{putString("stream","FAILED: ${error.message}\n")})}
        finally{runOnMainSync{display?.clear();prefs.edit().putBoolean("enabled",enabled).putString("bundleDirectory",previous).commit()};directory.deleteRecursively()}
    }
    // Test-only reflection avoids adding a JavaScript/native bridge to production.
    private fun displayWebView(display:CustomerDisplay):WebView {
        val page=CustomerDisplay::class.java.getDeclaredField("presentation").apply{isAccessible=true}.get(display)!!
        return page.javaClass.getDeclaredField("web").apply{isAccessible=true}.get(page) as WebView
    }
    private fun readDownloadedPage(display:CustomerDisplay):JSONObject {
        val latch=CountDownLatch(1)
        var value:String?=null
        runOnMainSync {
            displayWebView(display).evaluateJavascript("JSON.stringify({sentinel:window.downloadedPageSentinel||'',frames:window.frameCount||0,url:location.href,quote:document.getElementById('quote')?.textContent||'',background:getComputedStyle(document.body).backgroundColor,accent:document.getElementById('quote')?getComputedStyle(document.getElementById('quote')).color:''})") {
                value=it;latch.countDown()
            }
        }
        check(latch.await(5,TimeUnit.SECONDS)){"WebView script probe timed out"}
        return JSONObject(JSONTokener(value!!).nextValue() as String)
    }
    private fun foregroundTrial() {
        val prefs = targetContext.getSharedPreferences("customer_display", 0)
        val hadSetting = prefs.contains("enabled")
        val enabled = prefs.getBoolean("enabled", true)
        prefs.edit().remove("enabled").commit()
        var activity: MainActivity? = null
        var result = Activity.RESULT_OK
        var message = "Automatic welcome before enrollment, foreground without overlay permission and explicit disable passed."
        try {
            activity = startActivitySync(Intent(targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
            waitForIdleSync()
            runOnMainSync {
                val display = (activity!!.application as CompanionApplication).customerDisplay
                check(display.status()["backgroundAllowed"] == false) { "Test requires overlay permission disabled" }
                check(display.status()["state"] == "ready") { "Welcome did not start automatically: ${display.status()}" }
                display.enable(false)
                check(display.status()["state"] == "disabled")
                display.enable(true)
                check(display.status()["state"] == "ready")
            }
            sendStatus(0, Bundle().apply { putString("stream", "Foreground welcome shown without enrollment or overlay permission.\n") })
            Thread.sleep(5000)
        } catch (error: Throwable) {
            result = Activity.RESULT_CANCELED
            message = "FAILED: ${error.message}"
        } finally {
            runOnMainSync { activity?.finish() }
            if (hadSetting) prefs.edit().putBoolean("enabled", enabled).commit() else prefs.edit().remove("enabled").commit()
        }
        finish(result, Bundle().apply { putString("stream", "$message\n") })
    }
}
