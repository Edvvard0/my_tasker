package com.edvvard.mytasker

import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        configureBanks(messenger)
        configureScreenSecurity(messenger)
    }

    /**
     * Защита экрана «Финансов»: пока раздел открыт или включено «скрыть суммы»,
     * окно помечено FLAG_SECURE (нет скриншотов, записи экрана и превью в
     * «последних приложениях»). Управляет Dart: `setSecure(true|false)`.
     */
    private fun configureScreenSecurity(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, "my_tasker/screen_security").setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecure" -> {
                    val secure = call.arguments as? Boolean ?: false
                    runOnUiThread {
                        if (secure) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Мост «Банков» (Этап 6): слушатель уведомлений и системные настройки доступа. */
    private fun configureBanks(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, "my_tasker/banks").setMethodCallHandler { call, result ->
            when (call.method) {
                "setPackages" -> {
                    val packages = (call.arguments as? List<*>)?.filterIsInstance<String>() ?: emptyList()
                    BankNotificationQueue.setPackages(applicationContext, packages)
                    result.success(null)
                }
                "isListenerEnabled" -> {
                    val enabled = Settings.Secure.getString(
                        contentResolver, "enabled_notification_listeners"
                    ) ?: ""
                    result.success(enabled.split(":").any { it.startsWith("$packageName/") })
                }
                "openListenerSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                "isIgnoringBatteryOptimizations" -> {
                    val power = getSystemService(POWER_SERVICE) as PowerManager
                    result.success(power.isIgnoringBatteryOptimizations(packageName))
                }
                "openBatterySettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                "drain" -> result.success(BankNotificationQueue.drain(applicationContext))
                // Пачка, выданная последним drain, обработана: очередь на диске можно удалить.
                "ack" -> {
                    BankNotificationQueue.ack(applicationContext)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "my_tasker/banks/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                private val main = Handler(Looper.getMainLooper())

                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    BankNotificationQueue.wake = { main.post { events?.success(true) } }
                }

                override fun onCancel(arguments: Any?) {
                    BankNotificationQueue.wake = null
                }
            }
        )
    }
}
