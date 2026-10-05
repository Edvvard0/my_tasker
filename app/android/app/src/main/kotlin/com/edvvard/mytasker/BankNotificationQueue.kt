package com.edvvard.mytasker

import android.content.Context
import org.json.JSONException
import org.json.JSONObject
import java.io.File

/**
 * Очередь уведомлений банков на устройстве (Этап 6, «Банки»).
 *
 * Слушатель [BankNotificationListener] живёт отдельно от интерфейса и может
 * получать уведомления, пока Flutter-часть не запущена, поэтому текст
 * складывается в файл приватного хранилища приложения, а Dart забирает его
 * вызовом `drain` (и очередь очищается). Белый список пакетов задаёт Dart
 * из `notification_rules.json` (`setPackages`); пока список пуст, не
 * сохраняется ничего. Разбор, дедупликация и срок хранения (30 дней) —
 * в Dart; здесь только перенос текста.
 */
object BankNotificationQueue {
    private const val QUEUE_FILE = "bank_notifications.jsonl"
    private const val PREFS = "bank_notifications"
    private const val KEY_PACKAGES = "packages"

    /** Страховка от разрастания файла, если приложение долго не запускали. */
    private const val MAX_ITEMS = 500

    private val lock = Any()

    /** Сигнал Flutter-части «пришло новое»; задаётся при подписке на EventChannel. */
    @Volatile
    var wake: (() -> Unit)? = null

    fun setPackages(context: Context, packages: List<String>) {
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putStringSet(KEY_PACKAGES, packages.toSet())
            .apply()
    }

    fun packages(context: Context): Set<String> =
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(KEY_PACKAGES, emptySet()) ?: emptySet()

    private fun file(context: Context): File =
        File(context.applicationContext.noBackupFilesDir, QUEUE_FILE)

    fun push(context: Context, pkg: String, title: String, text: String, postedAtMs: Long) {
        val line = JSONObject()
            .put("package", pkg)
            .put("title", title)
            .put("text", text)
            .put("posted_at_ms", postedAtMs)
            .toString()
        synchronized(lock) {
            val f = file(context)
            val lines = if (f.exists()) f.readLines().filter { it.isNotBlank() } else emptyList()
            val kept = (lines + line).takeLast(MAX_ITEMS)
            f.writeText(kept.joinToString("\n") + "\n")
        }
        wake?.invoke()
    }

    /** Все накопленные уведомления; очередь очищается. */
    fun drain(context: Context): List<Map<String, Any>> = synchronized(lock) {
        val f = file(context)
        if (!f.exists()) return@synchronized emptyList<Map<String, Any>>()
        val items = f.readLines()
            .filter { it.isNotBlank() }
            .mapNotNull { line ->
                try {
                    val json = JSONObject(line)
                    mapOf<String, Any>(
                        "package" to json.getString("package"),
                        "title" to json.optString("title", ""),
                        "text" to json.optString("text", ""),
                        "posted_at_ms" to json.getLong("posted_at_ms"),
                    )
                } catch (e: JSONException) {
                    null
                }
            }
        f.delete()
        items
    }
}
