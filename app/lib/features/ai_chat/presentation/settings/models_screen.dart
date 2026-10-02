import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_format.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';

/// Цена модели для показа: «вход 250 ₽ · выход 1 000 ₽ за 1 млн токенов».
String priceLabel(ModelInfo m) {
  final input = m.priceInputKopecksPerMtok;
  final output = m.priceOutputKopecksPerMtok;
  if (input == null && output == null) return 'цена не указана';
  return [
    if (input != null) 'вход ${formatCost(input)}',
    if (output != null) 'выход ${formatCost(output)}',
  ].join(' · ');
}

/// «Модели быстрого выбора»: избранные (порядок, удаление) и каталог
/// провайдера с поиском.
class ModelsScreen extends ConsumerStatefulWidget {
  const ModelsScreen({super.key});

  @override
  ConsumerState<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends ConsumerState<ModelsScreen> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final favorites = ref.watch(favoritesProvider).value ?? const [];
    final catalog = ref.watch(modelCatalogProvider);
    final repo = ref.read(aiRepositoryProvider);
    final known = catalog.value;
    final query = _query.text.trim().toLowerCase();
    final favoriteIds = {for (final f in favorites) f.modelId};
    final found = known == null
        ? const <ModelInfo>[]
        : [
            for (final m in known.models)
              if (query.isEmpty ||
                  m.id.toLowerCase().contains(query) ||
                  m.name.toLowerCase().contains(query))
                m,
          ].take(60).toList();
    return ScreenScaffold(
      title: 'Модели',
      parentLabel: 'Настройки ИИ',
      onBack: () => context.go('/ai/settings'),
      actions: [
        IconButton(
          key: const Key('catalog-refresh'),
          tooltip: 'Обновить каталог',
          onPressed: catalog.isLoading
              ? null
              : () => ref.read(modelCatalogProvider.notifier).refresh(),
          icon: const Icon(LucideIcons.refreshCw, size: 20),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Быстрый выбор',
            style: t.overline.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: AppSpacing.s2),
          Container(
            decoration: BoxDecoration(
              color: c.surface1,
              borderRadius: AppRadii.borderL,
            ),
            child: favorites.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(AppSpacing.s4),
                    child: Text(
                      'Пока пусто. Отметьте звёздочкой модели из каталога ниже.',
                      key: const Key('favorites-empty'),
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                  )
                : Column(
                    children: [
                      for (final f in favorites)
                        _FavoriteRow(
                          favorite: f,
                          unavailable:
                              known != null && known.byId(f.modelId) == null,
                          first: f == favorites.first,
                          last: f == favorites.last,
                          onMove: (d) => repo.moveFavorite(f.modelId, d),
                          onRemove: () => repo.removeFavorite(f.modelId),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: AppSpacing.s6),
          Text('Каталог', style: t.overline.copyWith(color: c.textTertiary)),
          const SizedBox(height: AppSpacing.s2),
          FormTextField(
            key: const Key('catalog-search'),
            controller: _query,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Поиск моделей',
              prefixIcon: Icon(
                LucideIcons.search,
                size: 18,
                color: c.textTertiary,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          if (catalog.isLoading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.s6),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (catalog.hasError && known == null)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s4),
              child: Text(
                'Каталог недоступен: нет связи с сервером. Избранные модели '
                'продолжают работать.',
                key: const Key('catalog-error'),
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
            ),
          if (known != null && known.stale)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s2),
              child: Text(
                'Показан сохранённый каталог: обновить не удалось.',
                style: t.caption.copyWith(color: c.textTertiary),
              ),
            ),
          Container(
            decoration: BoxDecoration(
              color: c.surface1,
              borderRadius: AppRadii.borderL,
            ),
            child: Column(
              children: [
                for (final m in found)
                  ListTile(
                    key: Key('catalog-${m.id}'),
                    title: Text(m.name, style: t.body),
                    subtitle: Text(
                      '${m.id}\n${priceLabel(m)}'
                      '${m.supportsTools ? ' · инструменты' : ''}',
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                    isThreeLine: true,
                    trailing: IconButton(
                      key: Key('catalog-star-${m.id}'),
                      tooltip: favoriteIds.contains(m.id)
                          ? 'Убрать из быстрого выбора'
                          : 'В быстрый выбор',
                      icon: Icon(
                        favoriteIds.contains(m.id)
                            ? LucideIcons.star
                            : LucideIcons.starOff,
                        size: 20,
                        color: favoriteIds.contains(m.id)
                            ? c.textPrimary
                            : c.textTertiary,
                      ),
                      onPressed: () => favoriteIds.contains(m.id)
                          ? repo.removeFavorite(m.id)
                          : repo.addFavorite(m),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FavoriteRow extends StatelessWidget {
  const _FavoriteRow({
    required this.favorite,
    required this.unavailable,
    required this.first,
    required this.last,
    required this.onMove,
    required this.onRemove,
  });

  final ModelFavorite favorite;
  final bool unavailable;
  final bool first;
  final bool last;
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Padding(
      key: Key('favorite-${favorite.modelId}'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s2,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(favorite.displayName, style: t.body),
                Text(
                  unavailable ? 'Недоступна в каталоге' : favorite.modelId,
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            key: Key('favorite-up-${favorite.modelId}'),
            tooltip: 'Выше',
            onPressed: first ? null : () => onMove(-1),
            icon: const Icon(LucideIcons.arrowUp, size: 18),
          ),
          IconButton(
            key: Key('favorite-down-${favorite.modelId}'),
            tooltip: 'Ниже',
            onPressed: last ? null : () => onMove(1),
            icon: const Icon(LucideIcons.arrowDown, size: 18),
          ),
          IconButton(
            key: Key('favorite-remove-${favorite.modelId}'),
            tooltip: 'Убрать',
            onPressed: onRemove,
            icon: const Icon(LucideIcons.x, size: 18),
          ),
        ],
      ),
    );
  }
}
