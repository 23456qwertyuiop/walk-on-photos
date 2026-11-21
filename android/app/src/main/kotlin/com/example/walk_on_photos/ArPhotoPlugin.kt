package com.example.walk_on_photos

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.ar.core.ArCoreApk
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** Channel "walk_on_photos/ar" + platform view "walk_on_photos/ar_view". */
class ArPhotoPlugin(private val activity: MainActivity) : FlutterPlugin {
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ch = MethodChannel(binding.binaryMessenger, "walk_on_photos/ar")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> checkArCore(result, 0)
                "requestCameraPermission" -> activity.requestCameraPermission(result)
                else -> result.notImplemented()
            }
        }
        channel = ch
        binding.platformViewRegistry.registerViewFactory(
            "walk_on_photos/ar_view",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
                    ArPhotoView(activity, binding.binaryMessenger, viewId)
            },
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    @Suppress("DEPRECATION")
    private fun checkArCore(result: MethodChannel.Result, attempt: Int) {
        val availability = ArCoreApk.getInstance().checkAvailability(activity)
        if (availability.isTransient && attempt < 25) {
            main.postDelayed({ checkArCore(result, attempt + 1) }, 200)
            return
        }
        when (availability) {
            ArCoreApk.Availability.SUPPORTED_INSTALLED -> result.success(true)
            ArCoreApk.Availability.SUPPORTED_APK_TOO_OLD,
            ArCoreApk.Availability.SUPPORTED_NOT_INSTALLED -> {
                // Opens the Play Store page for "Google Play Services for AR".
                // The app falls back to gyro mode until it is installed.
                try {
                    ArCoreApk.getInstance().requestInstall(activity, true)
                } catch (e: Exception) {
                }
                result.success(false)
            }
            else -> result.success(false)
        }
    }
}
