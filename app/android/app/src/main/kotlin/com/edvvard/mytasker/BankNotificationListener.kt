package com.edvvard.mytasker

import android.app.Notification
import android.content.ComponentName
import android.os.Build
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Слушатель уведомлений банков (Этап 6). Обрабатывает **только** пакеты из
 * белого списка, который задаёт Dart ([BankNotificationQueue.setPackages]);
 * чужие уведомления не читаются и нигде не сохраняются. Доступ выдаёт
 * пользователь в системных настройках («Доступ к уведомлениям»).
 */
class BankNotificationListener : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        val pkg = sbn.packageName ?: return
        if (pkg !in BankNotificationQueue.packages(applicationContext)) return
        val notification = sbn.notification ?: return
        // Сводка группы дублирует отдельные уведомления.
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = notification.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        // Развёрнутый текст полнее краткого: банки кладут остаток именно туда.
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""
        if (title.isEmpty() && text.isEmpty()) return
        // Ключ и `when` не меняются, когда банк повторно публикует то же уведомление
        // (postTime меняется): по ним Dart отличает повтор от новой операции.
        BankNotificationQueue.push(
            applicationContext, pkg, title, text, sbn.postTime, sbn.key, notification.`when`
        )
    }

    override fun onListenerDisconnected() {
        // Система отключила слушатель (нехватка памяти, оптимизация батареи):
        // просим подключить снова.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            requestRebind(ComponentName(this, BankNotificationListener::class.java))
        }
    }
}
