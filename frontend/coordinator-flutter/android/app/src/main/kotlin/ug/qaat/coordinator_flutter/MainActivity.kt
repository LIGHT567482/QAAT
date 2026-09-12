package ug.qaat.coordinator_flutter

import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The one platform channel this app needs: the stable per-device facts behind the
 * `X-Device-Fingerprint` header the QA monitor sends on every patrol call.
 *
 * This mirrors the native coordinator-android app's `Fingerprint.get()` exactly:
 * the SHA-256 of `"qaat-student|<ANDROID_ID>|<Build.MODEL>"`, computed below so the
 * two builds produce byte-identical fingerprints for the same handset. ANDROID_ID is
 * stable for this install and app-signing key, survives "clear app data" and factory
 * reset only when the backup restore carries it, and uniquely identifies the device
 * to the gateway's patroller-binding table. The Dart side does NOT need to know the
 * secret recipe — it receives the ingredients and hashes them itself with the `crypto`
 * package so the logic stays testable on the host.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "qaat/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deviceFacts" -> {
                        val androidId = runCatching {
                            Settings.Secure.getString(
                                contentResolver, Settings.Secure.ANDROID_ID)
                        }.getOrNull().orEmpty()
                        result.success(
                            mapOf("androidId" to androidId, "model" to Build.MODEL))
                    }
                    else -> result.notImplemented()
                }
            }
    }
}