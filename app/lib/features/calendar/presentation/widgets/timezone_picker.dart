import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:timezone/timezone.dart' as tz;

/// Смещение зоны вида «UTC+3» в момент [at].
String utcOffsetLabel(tz.Location zone, DateTime at) {
  final offset = offsetAt(zone, at);
  final sign = offset.isNegative ? '-' : '+';
  final abs = offset.abs();
  final minutes = abs.inMinutes % 60;
  return 'UTC$sign${abs.inHours}'
      '${minutes == 0 ? '' : ':${minutes.toString().padLeft(2, '0')}'}';
}

/// Названия зон, показанные первыми (Россия и ближайшие).
const List<String> commonZones = [
  'Europe/Kaliningrad',
  'Europe/Moscow',
  'Europe/Samara',
  'Asia/Yekaterinburg',
  'Asia/Omsk',
  'Asia/Novosibirsk',
  'Asia/Krasnoyarsk',
  'Asia/Irkutsk',
  'Asia/Yakutsk',
  'Asia/Vladivostok',
  'Asia/Magadan',
  'Asia/Kamchatka',
  'Europe/Kyiv',
  'Europe/Minsk',
  'Europe/Berlin',
  'Europe/London',
  'America/New_York',
  'Asia/Tokyo',
  'UTC',
];

/// Выбор часового пояса: поиск по названию IANA, наверху — пояс
/// устройства и часто используемые.
Future<String?> showTimeZonePicker(
  BuildContext context, {
  required String current,
  required String deviceZone,
}) => showEditorSheet<String>(
  context,
  builder: (_) => _TimeZonePicker(current: current, deviceZone: deviceZone),
);

class _TimeZonePicker extends StatefulWidget {
  const _TimeZonePicker({required this.current, required this.deviceZone});

  final String current;
  final String deviceZone;

  @override
  State<_TimeZonePicker> createState() => _TimeZonePickerState();
}

class _TimeZonePickerState extends State<_TimeZonePicker> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<String> _names() {
    ensureTimeZones();
    final q = _query.text.trim().toLowerCase();
    final all = tz.timeZoneDatabase.locations.keys.toList()..sort();
    if (q.isNotEmpty) {
      return [
        for (final n in all)
          if (n.toLowerCase().contains(q)) n,
      ];
    }
    return [
      if (findLocation(widget.deviceZone) != null) widget.deviceZone,
      for (final n in commonZones)
        if (n != widget.deviceZone) n,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final now = DateTime.now().toUtc();
    final names = _names();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Часовой пояс'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
            child: FormTextField(
              key: const Key('tz-search'),
              controller: _query,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Найти: Europe/Berlin',
                prefixIcon: Icon(
                  LucideIcons.search,
                  size: 18,
                  color: c.textTertiary,
                ),
              ),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: names.length,
              itemBuilder: (context, i) {
                final name = names[i];
                final zone = requireLocation(name);
                return ListTile(
                  key: Key('tz-$name'),
                  title: Text(name, style: context.text.body),
                  subtitle: Text(
                    name == widget.deviceZone
                        ? 'Часовой пояс устройства · ${utcOffsetLabel(zone, now)}'
                        : utcOffsetLabel(zone, now),
                    style: context.text.bodyS.copyWith(color: c.textSecondary),
                  ),
                  trailing: name == widget.current
                      ? const Icon(LucideIcons.check, size: 18)
                      : null,
                  onTap: () => Navigator.of(context).pop(name),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
