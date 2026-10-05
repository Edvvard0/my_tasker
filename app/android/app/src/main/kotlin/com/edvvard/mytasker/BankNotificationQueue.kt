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
 * складывается в файл приватного хранилища приложения (`noBackupFilesDir`:
 * недоступен другим приложениям и не попадает в резервные копии), а Dart
 * забирает его вызовом `drain`. Белый список пакетов задаёт Dart из
 * `notification_rules.json` (`setPackages`); пока список пуст, не
 * сохраняется ничего. Разбор, дедупликация и срок хранения (30 дней) — в
 * Dart; здесь только перенос текста.
 *
 * Надёжность: запись — дозапись одной строки (сбой посреди записи портит
 * максимум последнюю строку, а не всё); `drain` не удаляет данные, а
 * переименовывает файл в `.processing`, и он удаляется только после `ack` из
 * Dart, когда пачка обработана. Если приложение упало между `drain` и `ack`,
 * следующий `drain` отдаст те же уведомления снова (повторы отсекает Dart по
 * отпечатку). Урезание очереди до [MAX_ITEMS] идёт через временный файл с
 * атомарной заменой.
 */
object BankNotificationQueue {
    private const val QUEUE_FILE = "bank_notifications.jsonl"
    private const val PROCESSING_FILE = "bank_notifications.processing"
    private const val TEMP_FILE = "bank_notifications.tmp"
    private const val PREFS = "bank_notifications"
    private const val KEY_PACKAGES = "packages"

    /** Страховка от разрастания файла, если приложение долго не запускали. */
    private const val MAX_ITEMS = 500

    /** Предел длины заголовка и текста одного уведомления (символов). */
    private const val MAX_FIELD_CHARS = 4096

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

    private fun dir(context: Context): File = context.applicationContext.noBackupFilesDir

    private fun file(context: Context): File = File(dir(context), QUEUE_FILE)

    private fun processingFile(context: Context): File = File(dir(context), PROCESSING_FILE)

    fun push(
        context: Context,
        pkg: String,
        title: String,
        text: String,
        postedAtMs: Long,
        key: String? = null,
        whenMs: Long = 0L,
    ) {
        val json = JSONObject()
            .put("package", pkg)
            .put("title", title.take(MAX_FIELD_CHARS))
            .put("text", text.take(MAX_FIELD_CHARS))
            .put("posted_at_ms", postedAtMs)
        if (key != null) json.put("key", key)
        if (whenMs > 0L) json.put("when_ms", whenMs)
        synchronized(lock) {
            val f = file(context)
            f.appendText(json.toString() + "\n")
            trimToLimit(context, f)
        }
        wake?.invoke()
    }

    /**
     * Все накопленные уведомления. Данные остаются на диске (в `.processing`), пока Dart
     * не вызовет [ack]; незавершённая прошлая выдача (приложение упало до `ack`) отдаётся
     * снова вместе с новыми.
     */
    fun drain(context: Context): List<Map<String, Any>> = synchronized(lock) {
        val queue = file(context)
        val processing = processingFile(context)
        if (queue.exists()) {
            if (processing.exists()) {
                processing.appendText(queue.readText())
                queue.delete()
                trimToLimit(context, processing)
            } else if (!queue.renameTo(processing)) {
                processing.writeText(queue.readText())
                queue.delete()
            }
        }
        if (!processing.exists()) return@synchronized emptyList<Map<String, Any>>()
        processing.readLines()
            .filter { it.isNotBlank() }
            .mapNotNull { line ->
                try {
                    val json = JSONObject(line)
                    val item = mutableMapOf<String, Any>(
                        "package" to json.getString("package"),
                        "title" to json.optString("title", ""),
                        "text" to json.optString("text", ""),
                        "posted_at_ms" to json.getLong("posted_at_ms"),
                    )
                    if (json.has("key")) item["key"] = json.getString("key")
                    if (json.has("when_ms")) item["when_ms"] = json.getLong("when_ms")
                    item
                } catch (e: JSONException) {
                    null // оборванная строка (сбой при записи) пропускается
                }
            }
    }

    /** Выданная последним [drain] пачка обработана: файл `.processing` удаляется. */
    fun ack(context: Context) {
        synchronized(lock) { processingFile(context).delete() }
    }

    /** Оставляет последние [MAX_ITEMS] строк; запись через временный файл и переименование. */
    private fun trimToLimit(context: Context, target: File) {
        val lines = target.readLines().filter { it.isNotBlank() }
        if (lines.size <= MAX_ITEMS) return
        val temp = File(dir(context), TEMP_FILE)
        temp.writeText(lines.takeLast(MAX_ITEMS).joinToString("\n") + "\n")
        if (!temp.renameTo(target)) {
            // Переименование не удалось: оставляем как есть (лучше длинный файл, чем потеря).
            temp.delete()
        }
    }
}
