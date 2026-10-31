/// V1.4.8 schedule integration: each broadcast day loads independently with
/// bounded pages, pull-to-refresh, request cancellation, and safe tab cleanup.
import 'more_sidebar_shell.dart';

import 'dart:async';

import 'package:animewitcher/shared/widgets/app_page_header.dart';
import 'package:animewitcher/shared/widgets/underline_segment_tabs.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/extensions/native_provider_resolution.dart';
import '../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/catalog_direction.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../../core/router/app_router.dart';

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
  static const int _pageSize = 12;

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

  Future<void> _loadDay(String day, {required bool refresh}) async {
    final previous = _dayStates[day] ?? const _BroadcastScheduleDayState();
    if (!refresh && (previous.loading || !previous.hasMore)) return;
    final provider = ref.nativeProvider;
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

    final embedded = MorePaneScope.of(context);
    final headerTop = appPageHeaderContentTopInset(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: 'جدول البث',
        canPop: !embedded && Navigator.of(context).canPop(),
        onBack: () => Navigator.of(context).pop(),
      ),
      body: Padding(
        padding: EdgeInsets.only(top: headerTop),
        child: Column(
          children: [
            _DayTabs(controller: _tabController),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  for (final day in animeWitcherBroadcastDays)
                    _ScheduleDayBody(
                      day: day,
                      state:
                          _dayStates[day] ?? const _BroadcastScheduleDayState(),
                      onRefresh: () => _loadDay(day, refresh: true),
                      onLoadMore: () => _loadDay(day, refresh: false),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DayTabs extends StatelessWidget {
  const _DayTabs({required this.controller});

  final TabController controller;

  @override
  Widget build(BuildContext context) {
    return FilterStyleTabBar(
      controller: controller,
      tabs: [
        for (var i = 0; i < animeWitcherBroadcastDays.length; i++)
          FilterStyleTab(label: animeWitcherBroadcastDays[i]),
      ],
    );
  }
}

class _ScheduleDayBody extends StatelessWidget {
  const _ScheduleDayBody({
    required this.day,
    required this.state,
    required this.onRefresh,
    required this.onLoadMore,
  });

  final String day;
  final _BroadcastScheduleDayState state;

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
              Text('تعذر تحميل جدول البث', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => unawaited(onRefresh()),
                icon: const Icon(Icons.refresh_rounded),
                label: Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      );
    }
    if (state.items.isEmpty) {
      return MouseDragRefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 120, 24, 110),
          children: [
            Text('لا يوجد بث مجدول لهذا اليوم', textAlign: TextAlign.center),
          ],
        ),
      );
    }
    return MouseDragRefreshIndicator(
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
      child: CatalogDirection(
        child: GridView.builder(
          key: PageStorageKey<String>('broadcast-$day'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            MultimediaCardLayout.catalogGridHorizontalPadding(context),
            16,
            MultimediaCardLayout.catalogGridHorizontalPadding(context),
            110,
          ),
          gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
            context,
            maxCrossAxisExtent: isDesktop ? 240 : 150,
            childAspectRatio: MultimediaCardLayout.gridAspectRatio(
              isPortrait: true,
              isDesktop: isDesktop,
            ),
            crossAxisSpacing: MultimediaCardLayout.catalogGridCrossAxisSpacing(
              context,
            ),
            mainAxisSpacing: MultimediaCardLayout.catalogGridMainAxisSpacing(
              context,
            ),
            handsetPortraitCrossAxisCount:
                MultimediaCardLayout.handsetPortraitGridColumns,
            horizontalPadding:
                MultimediaCardLayout.catalogGridHorizontalPadding(context),
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
              heroTag: heroTagWithId(
                'broadcast-$day',
                item,
                index,
                dashed: true,
              ),
              onTap: () => item.openDetails(context),
            );
          },
        ),
      ),
    );
  }
}
