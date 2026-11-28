import 'dart:collection';

import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/widgets/provider_search_filter_dialog.dart';
import 'package:animewitcher/features/search/presentation/search_domain.dart';
import 'package:animewitcher/features/search/presentation/search_provider.dart';
import 'package:animewitcher/features/search/presentation/search_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/memory_storage_service.dart';

class _Extensions extends ExtensionManager {
  _Extensions(this.provider);
  final WitanimeProvider provider;

  @override
  List<AnimeWitcherProvider> build() => [provider];
}

bool _isChip(Widget widget) {
  final key = widget.key;
  return widget is Material &&
      key is ValueKey<String> &&
      key.value.startsWith('filterChip-');
}

void main() {
  testWidgets('phone Search studio foldout keeps choices ordered and usable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final provider = WitanimeProvider((uri, {cancelToken}) async {
      return '<main></main>';
    });
    final studios = (await provider.getSearchFilterOptions()).studios;
    expect(studios.length, greaterThan(250));
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(MemoryStorageService()),
        extensionManagerProvider.overrideWith(() => _Extensions(provider)),
        activeProviderProvider.overrideWithValue(provider),
        deviceProfileProvider.overrideWith((_) async => const DeviceProfile()),
      ],
    );
    addTearDown(container.dispose);
    container.read(searchDomainProvider.notifier).set(SearchDomain.anime);
    container
        .read(searchProviderFiltersProvider.notifier)
        .set(ProviderSearchFilters(studios: {studios.last}, sort: 'name_asc'));
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const SearchScreen())],
    );
    addTearDown(router.dispose);
    // The production Search screen can continue animating behind the sheet.
    // Advance beyond the modal, chip, and foldout durations, not to idle.
    Future<void> settleModalAnimations() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump();
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await settleModalAnimations();
    await tester.tap(find.byTooltip('الفلاتر'));
    await settleModalAnimations();
    final dialog = find.byType(ProviderSearchFilterDialog);
    expect(tester.widget<ProviderSearchFilterDialog>(dialog).asSheet, isTrue);
    final more = find.byKey(const ValueKey('filter-studio-more'));
    final card = find.byKey(const ValueKey('filterCard-studio'));
    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('filterCards')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(more, 160, scrollable: scrollable);
    await Scrollable.ensureVisible(tester.element(more), alignment: 0.35);
    await settleModalAnimations();
    expect(more.hitTestable(), findsOneWidget);

    Finder chip(String label) => find.descendant(
      of: card,
      matching: find.byKey(ValueKey('filterChip-$label')),
    );
    Iterable<Element> chips() => find
        .descendant(of: card, matching: find.byWidgetPredicate(_isChip))
        .evaluate();
    Iterable<Key?> orderedKeys() => chips().map((e) => e.widget.key);
    (int, int, int) appearanceObjects() {
      final styles = HashSet<TextStyle>.identity();
      final shapes = HashSet<ShapeBorder>.identity();
      final sides = HashSet<BorderSide>.identity();
      for (final element in chips()) {
        final chip = element.widget as Material;
        final shape = chip.shape! as StadiumBorder;
        final ink = chip.child! as InkWell;
        final padding = ink.child! as Padding;
        final label = padding.child! as Text;
        styles.add(label.style!);
        shapes.add(shape);
        sides.add(shape.side);
      }
      return (styles.length, shapes.length, sides.length);
    }

    FocusNode chipFocus(String label) => Focus.of(
      tester.element(
        find
            .descendant(of: chip(label), matching: find.byType(MouseRegion))
            .first,
      ),
    );
    Future<void> reveal(Finder target, {double alignment = 0.25}) async {
      await Scrollable.ensureVisible(
        tester.element(target),
        alignment: alignment,
      );
      await settleModalAnimations();
      expect(target.hitTestable(), findsOneWidget);
    }

    expect(orderedKeys(), [
      for (final studio in [...studios.take(8), studios.last])
        ValueKey('filterChip-$studio'),
    ]);
    await tester.tap(more.hitTestable());
    await settleModalAnimations();
    final expandedKeys = studios.map((s) => ValueKey('filterChip-$s'));
    expect(orderedKeys(), expandedKeys);
    expect(
      Directionality.of(tester.element(chip(studios.first))),
      TextDirection.rtl,
    );
    expect(
      tester.getCenter(chip(studios.first)).dx,
      greaterThan(tester.getCenter(chip(studios[1])).dx),
    );

    final colors = Theme.of(tester.element(chip(studios.first))).colorScheme;
    final selectedColor = colors.primary.withValues(alpha: 0.18);
    Color? chipColor(String value) =>
        tester.widget<Material>(chip(value)).color;
    expect(chipColor(studios.last), selectedColor);
    expect(appearanceObjects(), (2, 2, 2));

    final position = tester.state<ScrollableState>(scrollable).position;
    for (final (value, previous, activeCount, keyboard) in [
      (studios[1], studios.last, 1, true),
      (studios[3], studios[1], 1, false),
      (studios[3], studios[3], 0, true),
      (studios[6], null, 1, false),
    ]) {
      await reveal(chip(value));
      final focus = chipFocus(value);
      if (keyboard) {
        focus.requestFocus();
        await settleModalAnimations();
        expect(focus.hasPrimaryFocus, isTrue);
      }
      final offset = position.pixels;
      if (keyboard) {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        await tester.tap(chip(value).hitTestable());
      }
      await settleModalAnimations();
      if (keyboard) {
        expect(chipFocus(value), same(focus));
        expect(focus.hasPrimaryFocus, isTrue);
      }
      expect(
        find.text(activeCount == 0 ? 'تطبيق' : 'تطبيق ($activeCount)'),
        findsOneWidget,
      );
      expect(orderedKeys(), expandedKeys);
      expect(position.pixels, closeTo(offset, 0.01));
      expect(
        chipColor(value),
        activeCount == 0 ? isNot(selectedColor) : selectedColor,
      );
      if (previous != null && previous != value) {
        expect(chipColor(previous), isNot(selectedColor));
      }
      final appearances = activeCount == 0 ? 1 : 2;
      expect(appearanceObjects(), (appearances, appearances, appearances));
    }
    await reveal(chip(studios.last));
    final endChoice = studios[studios.length - 2];
    await reveal(chip(endChoice));
    await tester.tap(chip(endChoice).hitTestable());
    await settleModalAnimations();
    expect(chipColor(endChoice), selectedColor);
    await reveal(more);
    await tester.tap(more.hitTestable());
    await settleModalAnimations();
    // Collapsing this tall card can put it out of the ListView's cache.
    // Return to the card using the actual scroll position.
    position.jumpTo(0);
    await settleModalAnimations();
    await tester.scrollUntilVisible(more, 160, scrollable: scrollable);
    await reveal(chip(endChoice));
    expect(orderedKeys(), [
      for (final studio in [...studios.take(8), endChoice])
        ValueKey('filterChip-$studio'),
    ]);
    await tester.tap(find.byKey(const ValueKey('filterApply')));
    await settleModalAnimations();
    expect(dialog, findsNothing);
    final result = container.read(searchProviderFiltersProvider);
    expect(result.studios, {endChoice});
    expect(result.sort, 'name_asc');
  });
}
