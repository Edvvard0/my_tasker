import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';

/// Блок разобранного markdown.
sealed class MdBlock {
  const MdBlock();
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);
  final String text;
}

class MdHeading extends MdBlock {
  const MdHeading(this.text);
  final String text;
}

class MdListItem extends MdBlock {
  const MdListItem(this.text, {this.marker = '•'});
  final String text;
  final String marker;
}

class MdQuote extends MdBlock {
  const MdQuote(this.text);
  final String text;
}

class MdCode extends MdBlock {
  const MdCode(this.code, {this.language = ''});
  final String code;
  final String language;
}

class MdTable extends MdBlock {
  const MdTable(this.rows);

  /// Первая строка — заголовок.
  final List<List<String>> rows;
}

final RegExp _listPattern = RegExp(r'^\s*([-*+]|\d+[.)])\s+(.*)$');
final RegExp _tableSeparator = RegExp(
  r'^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$',
);

/// Разбирает подмножество markdown ответа ИИ: заголовки (до h3), списки,
/// цитаты, код, таблицы, абзацы. Незакрытый блок кода (ответ ещё
/// стримится) тоже показывается как код.
List<MdBlock> parseMarkdown(String source) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final blocks = <MdBlock>[];
  final paragraph = <String>[];

  void flush() {
    if (paragraph.isEmpty) return;
    blocks.add(MdParagraph(paragraph.join('\n')));
    paragraph.clear();
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      flush();
      final language = trimmed.substring(3).trim();
      final code = <String>[];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        code.add(lines[i]);
        i++;
      }
      blocks.add(MdCode(code.join('\n'), language: language));
      i++;
      continue;
    }
    if (trimmed.isEmpty) {
      flush();
      i++;
      continue;
    }
    final heading = RegExp(r'^#{1,6}\s+(.*)$').firstMatch(trimmed);
    if (heading != null) {
      flush();
      blocks.add(MdHeading(heading[1]!));
      i++;
      continue;
    }
    if (trimmed.startsWith('>')) {
      flush();
      blocks.add(MdQuote(trimmed.replaceFirst(RegExp(r'^>\s?'), '')));
      i++;
      continue;
    }
    if (trimmed.startsWith('|') &&
        i + 1 < lines.length &&
        _tableSeparator.hasMatch(lines[i + 1].trim())) {
      flush();
      final rows = <List<String>>[_cells(trimmed)];
      i += 2;
      while (i < lines.length && lines[i].trim().startsWith('|')) {
        rows.add(_cells(lines[i].trim()));
        i++;
      }
      blocks.add(MdTable(rows));
      continue;
    }
    final item = _listPattern.firstMatch(line);
    if (item != null) {
      flush();
      final marker = item[1]!;
      blocks.add(
        MdListItem(
          item[2]!,
          marker: RegExp(r'^\d').hasMatch(marker) ? marker : '•',
        ),
      );
      i++;
      continue;
    }
    paragraph.add(line);
    i++;
  }
  flush();
  return blocks;
}

List<String> _cells(String row) {
  var r = row.trim();
  if (r.startsWith('|')) r = r.substring(1);
  if (r.endsWith('|')) r = r.substring(0, r.length - 1);
  return [for (final c in r.split('|')) c.trim()];
}

/// Текст ответа ИИ с оформлением markdown (02, 5.2.4): без пузыря, во всю
/// ширину; ссылки — акцентным цветом с подчёркиванием.
class MarkdownText extends StatelessWidget {
  const MarkdownText(this.text, {this.cursor = false, super.key});

  final String text;

  /// Блочный курсор `▍` в конце (идёт стриминг).
  final bool cursor;

  @override
  Widget build(BuildContext context) {
    final blocks = parseMarkdown(text);
    final t = context.text;
    final c = context.colors;
    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final isLast = i == blocks.length - 1;
      final tail = cursor && isLast ? '▍' : '';
      children.add(switch (blocks[i]) {
        MdParagraph(:final text) => _rich(context, text, t.body, tail),
        MdHeading(:final text) => Padding(
          padding: const EdgeInsets.only(top: AppSpacing.s1),
          child: _rich(context, text, t.h3, tail),
        ),
        MdListItem(:final text, :final marker) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 22,
              child: Text(
                marker,
                style: t.body.copyWith(color: c.textSecondary),
              ),
            ),
            Expanded(child: _rich(context, text, t.body, tail)),
          ],
        ),
        MdQuote(:final text) => Container(
          padding: const EdgeInsets.only(left: AppSpacing.s3),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: c.borderStrong, width: 2)),
          ),
          child: _rich(
            context,
            text,
            t.body.copyWith(color: c.textSecondary),
            tail,
          ),
        ),
        MdCode() => _CodeBlock(block: blocks[i] as MdCode, tail: tail),
        MdTable(:final rows) => _TableBlock(rows: rows),
      });
      if (!isLast) children.add(const SizedBox(height: AppSpacing.s2));
    }
    if (blocks.isEmpty && cursor) {
      children.add(Text('▍', style: t.body.copyWith(color: c.accent)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _rich(BuildContext context, String text, TextStyle base, String tail) {
    final c = context.colors;
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          ..._inline(context, text, base),
          if (tail.isNotEmpty)
            TextSpan(
              text: tail,
              style: base.copyWith(color: c.accent),
            ),
        ],
      ),
    );
  }

  List<InlineSpan> _inline(BuildContext context, String text, TextStyle base) {
    final c = context.colors;
    final spans = <InlineSpan>[];
    final pattern = RegExp(
      r'\*\*([^*]+)\*\*|`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)',
    );
    var last = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      if (m[1] != null) {
        spans.add(
          TextSpan(
            text: m[1],
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        );
      } else if (m[2] != null) {
        spans.add(
          TextSpan(
            text: m[2],
            style: TextStyle(
              backgroundColor: c.surface3,
              fontSize: (base.fontSize ?? 15) - 1,
            ),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: m[3],
            style: TextStyle(
              color: c.accent,
              decoration: TextDecoration.underline,
              decorationColor: c.accent,
            ),
          ),
        );
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return spans;
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.block, required this.tail});

  final MdCode block;
  final String tail;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Container(
      key: const Key('md-code'),
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: AppRadii.borderS,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  block.language,
                  style: t.caption.copyWith(color: c.textTertiary),
                ),
              ),
              InkResponse(
                key: const Key('md-code-copy'),
                onTap: () => Clipboard.setData(ClipboardData(text: block.code)),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.s1),
                  child: Icon(
                    LucideIcons.copy,
                    size: 16,
                    color: c.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              '${block.code}$tail',
              style: t.bodyS.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TableBlock extends StatelessWidget {
  const _TableBlock({required this.rows});

  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final width = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    return SingleChildScrollView(
      key: const Key('md-table'),
      scrollDirection: Axis.horizontal,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: c.borderDefault),
          borderRadius: AppRadii.borderS,
        ),
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder(
            horizontalInside: BorderSide(color: c.borderSubtle),
          ),
          children: [
            for (var r = 0; r < rows.length; r++)
              TableRow(
                decoration: r == 0 ? BoxDecoration(color: c.surface1) : null,
                children: [
                  for (var col = 0; col < width; col++)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s3,
                        vertical: AppSpacing.s2,
                      ),
                      child: Text(
                        col < rows[r].length ? rows[r][col] : '',
                        style: r == 0
                            ? t.overline.copyWith(color: c.textTertiary)
                            : t.bodyS,
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
