package com.hrround.streetsight_ar

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import java.security.MessageDigest
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Config
import com.google.ar.core.Session
import com.google.ar.core.VpsAvailability
import com.google.ar.core.exceptions.UnavailableException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native half of lib/services/arcore_channel.dart.
 *
 * `checkVpsAvailability` is a geographic lookup against Google's VPS
 * coverage data — it does not need a running camera session, so we build a
 * throwaway [Session], ask it, and close it again. This deliberately never
 * calls `session.resume()`, so it does not contend with the Flutter
 * `camera` plugin for the camera device.
 *
 * Any ARCore unavailability (not installed, device unsupported, Play
 * Services for AR outdated) is reported to Dart as `null`/unknown, not as
 * "indoors" — see the caller in scene_gate.dart for why.
 */
class ArCoreGeospatialChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "streetsight/arcore"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(isSupported())
            "signingInfo" -> result.success(signingInfo())
            "checkVpsAvailability" -> {
                val lat = call.argument<Double>("lat")
                val lng = call.argument<Double>("lng")
                if (lat == null || lng == null) {
                    result.error("bad_args", "lat/lng required", null)
                    return
                }
                checkVps(lat, lng, result)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Package name + SHA-1 of the signing cert, sent as `X-Android-Package` /
     * `X-Android-Cert` on Google REST calls so an Android-app-restricted API
     * key accepts them.
     */
    @Suppress("DEPRECATION")
    private fun signingInfo(): Map<String, String?> {
        val pm = activity.packageManager
        val pkg = activity.packageName
        val sig = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES)
                    .signingInfo?.apkContentsSigners?.firstOrNull()
            } else {
                pm.getPackageInfo(pkg, PackageManager.GET_SIGNATURES).signatures?.firstOrNull()
            }
        } catch (e: Exception) {
            null
        }
        val sha1 = sig?.let {
            MessageDigest.getInstance("SHA-1").digest(it.toByteArray())
                .joinToString("") { b -> "%02X".format(b) }
        }
        return mapOf("package" to pkg, "sha1" to sha1)
    }

    private fun isSupported(): Boolean =
        ArCoreApk.getInstance().checkAvailability(activity) == ArCoreApk.Availability.SUPPORTED_INSTALLED

    private fun checkVps(lat: Double, lng: Double, result: MethodChannel.Result) {
        if (ArCoreApk.getInstance().checkAvailability(activity) != ArCoreApk.Availability.SUPPORTED_INSTALLED) {
            result.success(null)
            return
        }
        var session: Session? = null
        try {
            session = Session(activity)
            session.configure(Config(session).apply { geospatialMode = Config.GeospatialMode.ENABLED })
            session.checkVpsAvailabilityAsync(lat, lng) { availability ->
                activity.runOnUiThread {
                    when (availability) {
                        VpsAvailability.AVAILABLE -> result.success(true)
                        VpsAvailability.UNAVAILABLE -> result.success(false)
                        else -> result.success(null) // ERROR_* cases: unknown, not "indoors"
                    }
                    session.close()
                }
            }
        } catch (e: UnavailableException) {
            session?.close()
            result.success(null)
        } catch (e: Exception) {
            session?.close()
            result.success(null)
        }
    }
}
