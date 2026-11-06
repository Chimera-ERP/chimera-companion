package ro.chimeraerp.companion

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.FileProvider
import java.io.File

@Suppress("DEPRECATION")
class CompanionUpdates(private val activity: Activity) {
    private val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    private fun installed() = activity.packageManager.getPackageInfo(activity.packageName, flags)
    private fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    private fun signatures(info: PackageInfo): Set<String> =
        (if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures)
            ?.map { it.toCharsString() }?.toSet() ?: emptySet()
    fun versionCode(): Long = code(installed())
    fun canInstall(): Boolean = Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls()

    fun install(path: String, expectedVersion: Long): Boolean {
        val file = File(path).canonicalFile
        require(file == File(activity.cacheDir, "updates/companion.apk").canonicalFile && file.isFile) { "APK în afara directorului de actualizări." }
        val candidate = activity.packageManager.getPackageArchiveInfo(file.path, flags)
            ?: throw IllegalArgumentException("APK invalid.")
        val current = installed()
        require(candidate.packageName == activity.packageName) { "APK pentru altă aplicație." }
        require(code(candidate) == expectedVersion && code(candidate) > code(current)) { "Versiune APK incorectă sau deja instalată." }
        val trusted = signatures(current)
        require(trusted.isNotEmpty() && signatures(candidate) == trusted) { "Semnătura APK nu corespunde aplicației instalate." }
        if (!canInstall()) {
            CompanionSettings.open(activity, "install")
            return false
        }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
        activity.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
        return true
    }
}
