import 'dart:async';

import 'package:flutter/material.dart';
import 'package:skystream/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../details/presentation/details_screen.dart';

class BroadcastScheduleScreen extends ConsumerStatefulWidget {
  const BroadcastScheduleScreen({super.key});

  @override
  ConsumerState<BroadcastScheduleScreen> createState() =>
      _BroadcastScheduleScreenState();
}

class _BroadcastScheduleScreenState
    extends ConsumerState<BroadcastScheduleScreen> {
  late Future<Map<String, List<MultimediaItem>>> _scheduleFuture;
  late final PageController _pageController;
  late int _selectedDay;

  @override
  void initState() {
    super.initState();
    _selectedDay = _todayIndex();
    _pageController = PageController(initialPage: _selectedDay);
    _scheduleFuture = _loadSchedule();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _selectDay(int value) {
    if (value < 0 ||
        value >= animeWitcherBroadcastDays.length ||
        value == _selectedDay) {
      return;
    }
    setState(() => _selectedDay = value);
    _pageController.animateToPage(
      value,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
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

  Future<Map<String, List<MultimediaItem>>> _loadSchedule() async {
    final provider = _provider();
    if (provider == null) {
      throw StateError('AnimeWitcher Native provider is unavailable');
    }
    return provider.getBroadcastSchedule();
  }

  Future<void> _refreshSchedule() async {
    final future = _loadSchedule();
    setState(() => _scheduleFuture = future);
    await future;
  }

  bool _isArabic(BuildContext context) =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

  @override
  Widget build(BuildContext context) {
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
                alignment:
                    isArabic ? Alignment.centerRight : Alignment.centerLeft,
                child: Directionality(
                  textDirection:
                      isArabic ? TextDirection.rtl : TextDirection.ltr,
                  child: Text(
                    isArabic ? 'جدول البث' : 'Broadcast schedule',
                  ),
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
      body: FutureBuilder<Map<String, List<MultimediaItem>>>(
        future: _scheduleFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const AnimeCatalogShimmer();
          }
          if (snapshot.hasError || !snapshot.hasData) {
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
                      onPressed: () {
                        setState(() => _scheduleFuture = _loadSchedule());
                      },
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(isArabic ? 'إعادة المحاولة' : 'Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          final schedule = snapshot.data!;
          return Column(
            children: [
              _DayTabs(
                selectedIndex: _selectedDay,
                isArabic: isArabic,
                onSelected: _selectDay,
              ),
              Divider(height: 1, color: Theme.of(context).dividerColor),
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: animeWitcherBroadcastDays.length,
                  onPageChanged: (value) {
                    if (value != _selectedDay) {
                      setState(() => _selectedDay = value);
                    }
                  },
                  itemBuilder: (context, index) {
                    final day = animeWitcherBroadcastDays[index];
                    final items =
                        schedule[day] ?? const <MultimediaItem>[];
                    return RefreshIndicator(
                      onRefresh: _refreshSchedule,
                      child: items.isEmpty
                          ? ListView(
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
                            )
                          : _ScheduleGrid(items: items, day: day),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DayTabs extends StatefulWidget {
  final int selectedIndex;
  final bool isArabic;
  final ValueChanged<int> onSelected;

  const _DayTabs({
    required this.selectedIndex,
    required this.isArabic,
    required this.onSelected,
  });

  @override
  State<_DayTabs> createState() => _DayTabsState();
}

class _DayTabsState extends State<_DayTabs> {
  final GlobalKey _viewportKey = GlobalKey();
  late final List<GlobalKey> _dayKeys = List<GlobalKey>.generate(
    animeWitcherBroadcastDays.length,
    (_) => GlobalKey(),
  );
  bool _visibilityCheckScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleSelectedDayVisibility();
  }

  @override
  void didUpdateWidget(covariant _DayTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex ||
        oldWidget.isArabic != widget.isArabic) {
      _scheduleSelectedDayVisibility();
    }
  }

  void _scheduleSelectedDayVisibility() {
    if (_visibilityCheckScheduled) return;
    _visibilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckScheduled = false;
      if (!mounted) return;
      _revealSelectedDayIfNeeded();
    });
  }

  void _revealSelectedDayIfNeeded() {
    final index = widget.selectedIndex;
    if (index < 0 || index >= _dayKeys.length) return;

    final viewportContext = _viewportKey.currentContext;
    final dayContext = _dayKeys[index].currentContext;
    final viewportBox = viewportContext?.findRenderObject();
    final dayBox = dayContext?.findRenderObject();
    if (viewportBox is! RenderBox ||
        dayBox is! RenderBox ||
        !viewportBox.hasSize ||
        !dayBox.hasSize ||
        dayContext == null) {
      return;
    }

    final viewportOrigin = viewportBox.localToGlobal(Offset.zero);
    final dayOrigin = dayBox.localToGlobal(Offset.zero);
    final viewportLeft = viewportOrigin.dx + 4;
    final viewportRight = viewportOrigin.dx + viewportBox.size.width - 4;
    final dayLeft = dayOrigin.dx;
    final dayRight = dayOrigin.dx + dayBox.size.width;
    if (dayLeft >= viewportLeft && dayRight <= viewportRight) return;

    unawaited(
      Scrollable.ensureVisible(
        dayContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      ),
    );
  }

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
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      key: _viewportKey,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          for (var i = 0; i < animeWitcherBroadcastDays.length; i++) ...[
            Material(
              key: _dayKeys[i],
              color: widget.selectedIndex == i
                  ? colors.primary
                  : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(24),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => widget.onSelected(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 11,
                  ),
                  child: Text(
                    widget.isArabic
                        ? animeWitcherBroadcastDays[i]
                        : english[i],
                    style: TextStyle(
                      color: widget.selectedIndex == i
                          ? colors.onPrimary
                          : colors.onSurface,
                      fontWeight: widget.selectedIndex == i
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
            if (i != animeWitcherBroadcastDays.length - 1)
              const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _ScheduleGrid extends StatelessWidget {
  final List<MultimediaItem> items;
  final String day;

  const _ScheduleGrid({required this.items, required this.day});

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    return GridView.builder(
      key: PageStorageKey<String>('broadcast-$day'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
      gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
        context,
        maxCrossAxisExtent: isDesktop ? 240 : 150,
        childAspectRatio: isDesktop ? 0.58 : 0.55,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return MultimediaCard(
          key: ValueKey('broadcast-$day-${item.url}'),
          imageUrl: item.posterImageUrl,
          title: item.title,
          heroTag: 'broadcast-$day-${item.id}-$index',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DetailsScreen(item: item),
            ),
          ),
        );
      },
    );
  }
}
