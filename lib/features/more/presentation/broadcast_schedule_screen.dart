/// V1.4.8 schedule integration: each broadcast day loads independently with
/// bounded pages, pull-to-refresh, request cancellation, and safe tab cleanup.
import 'dart:async';

import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:animewitcher/shared/widgets/underline_segment_tabs.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/catalog_ltr.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../details/presentation/details_screen.dart';

class BroadcastScheduleScreen extends ConsumerStatefulWidget {
  const BroadcastScheduleScreen({super.key});

  @override
  ConsumerState<BroadcastScheduleScreen> createState() =>
      _BroadcastScheduleScreenState();
}

class _BroadcastScheduleDayState {
  const _BroadcastScheduleDayState({
    this.items = const <MultimediaItem>[],
    this.nextOffset = 0,
    this.hasMore = true,
    this.loading = false,
    this.loaded = false,
    this.error,
  });

  final List<MultimediaItem> items;
  final int nextOffset;
  final bool hasMore;
  final bool loading;
  final bool loaded;
  final Object? error;
}

class _BroadcastScheduleScreenState
    extends ConsumerState<BroadcastScheduleScreen>
    with SingleTickerProviderStateMixin {
  static const int _pageSize = 30;

  late final TabController _tabController;
  late int _selectedDay;
  final Map<String, _BroadcastScheduleDayState> _dayStates =
      <String, _BroadcastScheduleDayState>{};
  final Map<String, CancelToken> _requestTokens = <String, CancelToken>{};

  @override
  void initState() {
    super.initState();
    _selectedDay = _todayIndex();
    for (final day in animeWitcherBroadcastDays) {
      _dayStates[day] = const _BroadcastScheduleDayState();
    }
    _tabController = TabController(
      length: animeWitcherBroadcastDays.length,
      vsync: this,
      initialIndex: _selectedDay,
    )..addListener(_handleTabTick);
    unawaited(_loadDay(animeWitcherBroadcastDays[_selectedDay], refresh: true));
  }

  @override
  void dispose() {
    for (final token in _requestTokens.values) {
      token.cancel('Broadcast schedule screen disposed');
    }
    _requestTokens.clear();
    _tabController
      ..removeListener(_handleTabTick)
      ..dispose();
    super.dispose();
  }

  void _handleTabTick() {
    if (_tabController.indexIsChanging) return;
    final value = _tabController.index;
    if (value == _selectedDay) return;
    setState(() => _selectedDay = value);
    final day = animeWitcherBroadcastDays[value];
    final state = _dayStates[day] ?? const _BroadcastScheduleDayState();
    if (state.items.isEmpty && !state.loading && state.error == null) {
      unawaited(_loadDay(day, refresh: true));
    }
  }

  int _todayIndex() {
    return switch (DateTime.now().weekday) {
      DateTime.saturday => 0,
      DateTime.sunday => 1,
      DateTime.monday => 2,
      DateTime.tuesday => 3,
      DateTime.wednesday => 4,
      DateTime.thursday => 5,
      DateTime.friday => 6,
      _ => 0,
    };
  }

  AnimeWitcherNativeProvider? _provider() {
    final active = ref.read(activeProviderProvider);
    if (active is AnimeWitcherNativeProvider) return active;
    for (final provider in ref.read(extensionManagerProvider)) {
      if (provider is AnimeWitcherNativeProvider) return provider;
    }
    return null;
  }

  Future<void> _loadDay(String day, {required bool refresh}) async {
    final previous = _dayStates[day] ?? const _BroadcastScheduleDayState();
    if (!refresh && (previous.loading || !previous.hasMore)) return;
    final provider = _provider();
    if (provider == null) {
      if (!mounted) return;
      setState(() {
        _dayStates[day] = _BroadcastScheduleDayState(
          items: previous.items,
          nextOffset: previous.nextOffset,
          hasMore: previous.hasMore,
          error: StateError('AnimeWitcher Native provider is unavailable'),
        );
      });
      return;
    }

    _requestTokens.remove(day)?.cancel('Superseded schedule request');
    final token = CancelToken();
    _requestTokens[day] = token;
    final offset = refresh ? 0 : previous.nextOffset;
    if (mounted) {
      setState(() {
        _dayStates[day] = _BroadcastScheduleDayState(
          items: previous.items,
          nextOffset: offset,
          hasMore: refresh ? true : previous.hasMore,
          loading: true,
          loaded: previous.loaded,
        );
      });
    }

    try {
      final page = await provider.getBroadcastSchedulePage(
        day,
        offset: offset,
        limit: _pageSize,
        refresh: refresh,
        cancelToken: token,
      );
      if (!mounted || !identical(_requestTokens[day], token)) return;
      final merged = refresh
          ? page.items
          : <MultimediaItem>[...previous.items, ...page.items];
      final deduped = <String, MultimediaItem>{
        for (final item in merged) item.url: item,
      }.values.toList(growable: false);
      setState(() {
        _dayStates[day] = _BroadcastScheduleDayState(
          items: deduped,
          nextOffset: page.nextOffset,
          hasMore: page.hasMore,
          loaded: true,
        );
      });
    } on DioException catch (error) {
      if (CancelToken.isCancel(error) || !mounted) return;
      setState(() {
        _dayStates[day] = _BroadcastScheduleDayState(
          items: previous.items,
          nextOffset: previous.nextOffset,
          hasMore: previous.hasMore,
          loaded: previous.loaded,
          error: error,
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _dayStates[day] = _BroadcastScheduleDayState(
          items: previous.items,
          nextOffset: previous.nextOffset,
          hasMore: previous.hasMore,
          loaded: previous.loaded,
          error: error,
        );
      });
    } finally {
      if (identical(_requestTokens[day], token)) {
        _requestTokens.remove(day);
      }
    }
  }

  bool _isArabic(BuildContext context) =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(accountDataRevisionProvider, (previous, next) {
      if (previous == next) return;
      for (final token in List<CancelToken>.from(_requestTokens.values)) {
        token.cancel('Account content preference changed');
      }
      _requestTokens.clear();
      setState(() {
        for (final day in animeWitcherBroadcastDays) {
          _dayStates[day] = const _BroadcastScheduleDayState();
        }
      });
      unawaited(
        _loadDay(animeWitcherBroadcastDays[_selectedDay], refresh: true),
      );
    });
    final isArabic = _isArabic(context);
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppBar(
            automaticallyImplyLeading: false,
            centerTitle: false,
            titleSpacing: 16,
            title: ApplePersistentGlassHeaderScope(
              enabled: Navigator.of(context).canPop(),
              onBack: () => Navigator.of(context).pop(),
              child: Align(
                alignment: isArabic
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Directionality(
                  textDirection: isArabic
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  child: Text(isArabic ? 'جدول البث' : 'Broadcast schedule'),
                ),
              ),
            ),
            leading: appleUsesPersistentLiquidGlassHeader
                ? null
                : AppleLiquidGlassBackButton(
                    onPressed: () => Navigator.of(context).pop(),
                  ),
            elevation: 0,
          ),
        ),
      ),
      body: Column(
        children: [
          _DayTabs(controller: _tabController, isArabic: isArabic),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                for (final day in animeWitcherBroadcastDays)
                  _ScheduleDayBody(
                    day: day,
                    state:
                        _dayStates[day] ?? const _BroadcastScheduleDayState(),
                    isArabic: isArabic,
                    onRefresh: () => _loadDay(day, refresh: true),
                    onLoadMore: () => _loadDay(day, refresh: false),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DayTabs extends StatelessWidget {
  const _DayTabs({required this.controller, required this.isArabic});

  final TabController controller;
  final bool isArabic;

  @override
  Widget build(BuildContext context) {
    const english = <String>[
      'Saturday',
      'Sunday',
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
    ];
    return FilterStyleTabBar(
      controller: controller,
      tabs: [
        for (var i = 0; i < animeWitcherBroadcastDays.length; i++)
          FilterStyleTab(
            label: isArabic ? animeWitcherBroadcastDays[i] : english[i],
          ),
      ],
    );
  }
}

class _ScheduleDayBody extends StatelessWidget {
  const _ScheduleDayBody({
    required this.day,
    required this.state,
    required this.isArabic,
    required this.onRefresh,
    required this.onLoadMore,
  });

  final String day;
  final _BroadcastScheduleDayState state;
  final bool isArabic;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onLoadMore;

  @override
  Widget build(BuildContext context) {
    if ((state.loading || !state.loaded) &&
        state.items.isEmpty &&
        state.error == null) {
      return const AnimeCatalogShimmer();
    }
    if (state.error != null && state.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 42),
              const SizedBox(height: 12),
              Text(
                isArabic
                    ? 'تعذر تحميل جدول البث'
                    : 'Could not load the broadcast schedule',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => unawaited(onRefresh()),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(isArabic ? 'إعادة المحاولة' : 'Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (state.items.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 120, 24, 110),
          children: [
            Text(
              isArabic
                  ? 'لا يوجد بث مجدول لهذا اليوم'
                  : 'No broadcasts scheduled for this day',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: _ScheduleGrid(
        items: state.items,
        day: day,
        isLoadingMore: state.loading,
        hasMore: state.hasMore,
        onLoadMore: onLoadMore,
      ),
    );
  }
}

class _ScheduleGrid extends StatelessWidget {
  const _ScheduleGrid({
    required this.items,
    required this.day,
    required this.isLoadingMore,
    required this.hasMore,
    required this.onLoadMore,
  });

  final List<MultimediaItem> items;
  final String day;
  final bool isLoadingMore;
  final bool hasMore;
  final Future<void> Function() onLoadMore;

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            hasMore &&
            !isLoadingMore &&
            notification.metrics.extentAfter < 360) {
          unawaited(onLoadMore());
        }
        return false;
      },
      child: CatalogLtr(
        child: GridView.builder(
          key: PageStorageKey<String>('broadcast-$day'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
          gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
            context,
            maxCrossAxisExtent: isDesktop ? 240 : 150,
            childAspectRatio: MultimediaCardLayout.gridAspectRatio(
              isPortrait: true,
              isDesktop: isDesktop,
            ),
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
          ),
          itemCount: items.length + (isLoadingMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= items.length) {
              return const Center(child: CircularProgressIndicator.adaptive());
            }
            final item = items[index];
            return MultimediaCard.fromItem(
              key: ValueKey('broadcast-$day-${item.url}'),
              item: item,
              heroTag: 'broadcast-$day-${item.id}-$index',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DetailsScreen(item: item),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
