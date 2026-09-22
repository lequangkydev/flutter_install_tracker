package com.dreamskydev.flutter_install_tracker

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Đọc Google Play Install Referrer — nguồn cài đặt của app (organic vs
 * paid network). Thay thế Adjust SDK cho bài toán phân loại full-ads.
 *
 * Referrer string do Play Store lưu tại thời điểm INSTALL:
 * - Organic (search/browse Play): "utm_source=google-play&utm_medium=organic"
 * - Google Ads (UAC): chứa "gclid=..." / "gbraid=..."
 * - Meta ads: "utm_source=apps.facebook.com..." (hoặc payload mã hoá)
 * - Network khác: utm_source/click-id riêng của network đó.
 *
 * ⚠ Ràng buộc của API:
 * - Referrer chỉ query được trong ~90 ngày sau install, và Play giới hạn số
 *   lần gọi → PHẢI cache lần đọc thành công đầu tiên (SharedPreferences,
 *   sống theo install — clear data thì mất, nhưng khi đó vẫn query lại được
 *   nếu trong 90 ngày).
 *
 * Plugin tự đăng ký qua Flutter plugin registry (kể cả engine pre-warm ở
 * Application.onCreate — FlutterEngine constructor auto-register plugins)
 * → app KHÔNG cần sửa MainApplication/MainActivity.
 *
 * Methods:
 * - `getInstallReferrer` → {referrer: String, clickTs: Long, installTs: Long,
 *   fromCache: Boolean}. Trả null nếu API unavailable / lỗi (Dart side tự
 *   phân loại theo options.useNull).
 * - `getAndroidId` → ANDROID_ID (String?) — key dedupe install cho telemetry.
 */
class FlutterInstallTrackerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var applicationContext: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "flutter_install_tracker")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getInstallReferrer" -> fetch(applicationContext, result)
            "getAndroidId" -> result.success(readAndroidId(applicationContext))
            else -> result.notImplemented()
        }
    }

    /**
     * ANDROID_ID — ổn định theo (máy, user, app-signing key) từ Android 8:
     * sống qua cài lại / clear data, chỉ đổi khi factory reset → dedupe install
     * trọn đời được. (device_info_plus `androidInfo.id` là Build.ID — tên bản
     * firmware, hàng nghìn máy trùng nhau — KHÔNG dùng làm ID máy được.)
     */
    @SuppressLint("HardwareIds")
    private fun readAndroidId(context: Context): String? =
        try {
            Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
        } catch (e: Exception) {
            android.util.Log.e(TAG, "read ANDROID_ID failed", e)
            null
        }

    private companion object {
        const val TAG = "InstallTracker"
        const val PREFS_NAME = "install_referrer_cache"
        const val KEY_REFERRER = "referrer"
        const val KEY_CLICK_TS = "click_ts"
        const val KEY_INSTALL_TS = "install_ts"
    }

    private fun fetch(context: Context, result: MethodChannel.Result) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (prefs.contains(KEY_REFERRER)) {
            result.success(
                mapOf(
                    "referrer" to (prefs.getString(KEY_REFERRER, "") ?: ""),
                    "clickTs" to prefs.getLong(KEY_CLICK_TS, 0L),
                    "installTs" to prefs.getLong(KEY_INSTALL_TS, 0L),
                    "fromCache" to true,
                )
            )
            return
        }

        val client = InstallReferrerClient.newBuilder(context).build()
        val mainHandler = Handler(Looper.getMainLooper())
        // MethodChannel.Result chỉ được resolve 1 lần — guard vì listener có
        // thể fire lại (disconnect → reconnect nội bộ của Play Services).
        var resolved = false

        fun resolveOnce(payload: Any?) {
            if (resolved) return
            resolved = true
            mainHandler.post {
                try {
                    result.success(payload)
                } catch (e: Exception) {
                    android.util.Log.e(TAG, "installReferrer result failed", e)
                }
            }
            try {
                client.endConnection()
            } catch (_: Exception) {
            }
        }

        try {
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(responseCode: Int) {
                    when (responseCode) {
                        InstallReferrerClient.InstallReferrerResponse.OK -> {
                            try {
                                val response = client.installReferrer
                                val referrer = response.installReferrer ?: ""
                                val clickTs = response.referrerClickTimestampSeconds
                                val installTs = response.installBeginTimestampSeconds
                                prefs.edit()
                                    .putString(KEY_REFERRER, referrer)
                                    .putLong(KEY_CLICK_TS, clickTs)
                                    .putLong(KEY_INSTALL_TS, installTs)
                                    .apply()
                                android.util.Log.d(TAG, "installReferrer OK — referrer=$referrer")
                                resolveOnce(
                                    mapOf(
                                        "referrer" to referrer,
                                        "clickTs" to clickTs,
                                        "installTs" to installTs,
                                        "fromCache" to false,
                                    )
                                )
                            } catch (e: Exception) {
                                android.util.Log.e(TAG, "installReferrer read failed", e)
                                resolveOnce(null)
                            }
                        }
                        // FEATURE_NOT_SUPPORTED / SERVICE_UNAVAILABLE / khác:
                        // không có referrer (device không có Play, sideload...).
                        else -> {
                            android.util.Log.w(
                                TAG,
                                "installReferrer unavailable — responseCode=$responseCode"
                            )
                            resolveOnce(null)
                        }
                    }
                }

                override fun onInstallReferrerServiceDisconnected() {
                    // Không retry — Dart side có timeout + fallback useNull.
                    resolveOnce(null)
                }
            })
        } catch (e: Exception) {
            // startConnection có thể throw SecurityException trên vài ROM lạ.
            android.util.Log.e(TAG, "installReferrer startConnection failed", e)
            resolveOnce(null)
        }
    }
}
