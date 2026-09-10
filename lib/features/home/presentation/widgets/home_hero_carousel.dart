import 'home_hero_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import '../../../../core/router/app_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../../../../core/utils/artwork_quality.dart';
import '../../../../core/utils/storyblok_image.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../shared/widgets/fallback_poster_image.dart';
import '../../../../shared/widgets/cards_wrapper.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/device_info_provider.dart';

import '../../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../details/presentation/details_ratings.dart';
import '../../../../l10n/generated/app_localizations.dart';

/// Lightweight controller for the hero carousel.
/// API-compatible with the old CarouselSliderController (nextPage/previousPage).
class HeroCarouselController {
  VoidCallback? onNextPage;
  VoidCallback? onPreviousPage;

  void nextPage({Duration? duration, Curve? curve}) => onNextPage?.call();
  void previousPage({Duration? duration, Curve? curve}) =>
      onPreviousPage?.call();
}

class HomeHeroCarousel extends ConsumerStatefulWidget {
  final List<MultimediaItem> movies;
  final ScrollController? scrollController;
  final void Function(MultimediaItem)? onTap;
  final VoidCallback? onNavigateUp;

  /// Called once after initState with the internal [HeroCarouselController]
  /// so the parent can drive prev/next from an external UI (e.g. header arrows).
  final void Function(HeroCarouselController controller)? onControllerReady;

  const HomeHeroCarousel({
    super.key,
    required this.movies,
    this.scrollController,
    this.onTap,
    this.onNavigateUp,
    this.onControllerReady,
  });

  @override
  ConsumerState<HomeHeroCarousel> createState() => _HomeHeroCarouselState();
}

// Intents used by the carousel's keyboard shortcuts. Defined at file scope so
// they're const-constructible and stable across rebuilds.
class _CarouselUpIntent extends Intent {
  const _CarouselUpIntent();
}

class _CarouselPrevIntent extends Intent {
  const _CarouselPrevIntent();
}

class _CarouselNextIntent extends Intent {
  const _CarouselNextIntent();
}

class _HomeHeroCarouselState extends ConsumerState<HomeHeroCarousel>
    with TickerProviderStateMixin {
  final ValueNotifier<int> _currentIndexNotifier = ValueNotifier<int>(0);
  final HeroCarouselController _heroCarouselController =
      HeroCarouselController();
  final ValueNotifier<double> _scrollOffset = ValueNotifier(0.0);
  // Single anchor focus node so the carousel acts as ONE focus target on TV/
  // keyboard. Otherwise each slide is independently focusable and pages cause
  // focus to drop into the next row when slides unmount.
  final FocusNode _carouselFocusNode = FocusNode(debugLabel: 'carousel_anchor');
  bool _isFocusHighlighted = false;
  // True while the carousel occupies any visible viewport. Drives autoPlay
  // so the 5s slide loop pauses when the user scrolls past it — eliminates
  // off-screen frame work and the resulting battery / raster drain.
  bool _isVisibleOnScreen = true;

  // Crossfade + scale transition
  late final AnimationController _transitionController;
  late final Animation<double> _transitionAnimation;
  int _currentSlide = 0;
  int? _previousSlide;
  bool _isTransitioning = false;

  // Progress bar fill — also serves as the auto-advance timer (5s).
  late final AnimationController _fillController;

  @override
  void initState() {
    super.initState();

    _transitionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _transitionAnimation = CurvedAnimation(
      parent: _transitionController,
      curve: Curves.fastOutSlowIn,
    );
    _transitionController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() {
          _isTransitioning = false;
          _previousSlide = null;
        });
      }
    });

    _fillController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
    _fillController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        _goToNextSlide();
      }
    });

    _heroCarouselController.onNextPage = _goToNextSlide;
    _heroCarouselController.onPreviousPage = _goToPreviousSlide;

    widget.scrollController?.addListener(_onParentScroll);
    // Expose the internal controller to the parent so header arrows can
    // drive carousel navigation. Deferred to post-frame to avoid calling
    // setState on an ancestor while the widget tree is still building.
    if (widget.onControllerReady != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onControllerReady!(_heroCarouselController);
      });
    }

    _fillController.forward();
  }

  void _goToNextSlide() {
    if (widget.movies.length <= 1) return;
    final next = (_currentSlide + 1) % widget.movies.length;
    _startTransitionTo(next);
  }

  void _goToPreviousSlide() {
    if (widget.movies.length <= 1) return;
    final prev =
        (_currentSlide - 1 + widget.movies.length) % widget.movies.length;
    _startTransitionTo(prev);
  }

  void _startTransitionTo(int nextIndex) {
    if (_isTransitioning || nextIndex == _currentSlide || !mounted) return;
    setState(() {
      _previousSlide = _currentSlide;
      _currentSlide = nextIndex;
      _isTransitioning = true;
    });
    _currentIndexNotifier.value = nextIndex;
    _transitionController.forward(from: 0.0);
    _restartFill();
  }

  void _restartFill() {
    _fillController.reset();
    if (_isVisibleOnScreen) {
      _fillController.forward();
    }
  }

  void _onParentScroll() {
    // Always update — do NOT gate on _isVisibleOnScreen. Earlier we tried
    // to skip rebuilds while the carousel was off-screen, but that left
    // _scrollOffset frozen at a stale value; when the user scrolled back
    // up, syncing the offset on visibility-change caused a visible snap
    // (VisibilityDetector throttles, so the catch-up frame lands after
    // the user has already scrolled past it). The rebuild cost here is
    // negligible — Transform/RenderTransform reuses its RenderObject, the
    // CachedNetworkImage is cache-hit, and the whole carousel page is
    // wrapped in a RepaintBoundary so off-screen rebuilds don't ripple.
    if (widget.scrollController!.hasClients) {
      _scrollOffset.value = widget.scrollController!.offset;
    }
  }

  void _activateCurrent() {
    final movie = widget.movies[_currentSlide];
    if (widget.onTap != null) {
      widget.onTap!(movie);
    } else {
      _navigateToDetails(context, movie);
    }
  }

  @override
  void dispose() {
    _transitionController.dispose();
    _fillController.dispose();
    widget.scrollController?.removeListener(_onParentScroll);
    _scrollOffset.dispose();
    _currentIndexNotifier.dispose();
    _carouselFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.movies.isEmpty) return const SizedBox.shrink();

    final isDesktop = context.isDesktop;
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final isTv = profile?.isTv ?? context.isTv;

    return HomeHeroFrame(
      builder: (context, heroHeight) => VisibilityDetector(
        key: const Key('explore-carousel-visibility'),
        // Visibility is still tracked — but only to gate the 5s auto-advance
        // timer (so we don't fire page transitions for an audience that
        // isn't watching). Parallax offset updates ignore this flag; see
        // [_onParentScroll] for the rationale.
        onVisibilityChanged: (info) {
          final visible = info.visibleFraction > 0.1;
          if (visible != _isVisibleOnScreen && mounted) {
            setState(() => _isVisibleOnScreen = visible);
            if (visible) {
              _fillController.forward();
            } else {
              _fillController.stop();
            }
          }
        },
        child: FocusableActionDetector(
          focusNode: _carouselFocusNode,
          // Only auto-focus on TV where D-pad is the primary input. On desktop
          // we skip autofocus so the focus ring doesn't appear on app launch
          // (Flutter defaults to 'traditional' highlight mode until a mouse
          // event arrives, which would show the ring immediately).
          autofocus: false,
          mouseCursor: SystemMouseCursors.click,
          // Arrow keys are wired as explicit Shortcuts/Actions at this level so
          // they fire when _carouselFocusNode has focus. Using a nested
          // Focus(onKeyEvent:) for arrows is unreliable here — that child Focus
          // is a descendant of _carouselFocusNode, and key events only propagate
          // UP from the focused node, so the child's handler never runs. Worse,
          // unhandled arrow keys fall through to Flutter's default ScrollAction
          // which then scrolls the outer vertical CustomScrollView — exactly the
          // "Right pages carousel AND scrolls page vertically" bug we saw.
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.arrowUp): _CarouselUpIntent(),
            SingleActivator(LogicalKeyboardKey.arrowLeft):
                _CarouselPrevIntent(),
            SingleActivator(LogicalKeyboardKey.arrowRight):
                _CarouselNextIntent(),
          },
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                _activateCurrent();
                return null;
              },
            ),
            _CarouselUpIntent: CallbackAction<_CarouselUpIntent>(
              onInvoke: (_) {
                widget.onNavigateUp?.call();
                return null;
              },
            ),
            _CarouselPrevIntent: CallbackAction<_CarouselPrevIntent>(
              onInvoke: (_) {
                _goToPreviousSlide();
                return null;
              },
            ),
            _CarouselNextIntent: CallbackAction<_CarouselNextIntent>(
              onInvoke: (_) {
                _goToNextSlide();
                return null;
              },
            ),
          },
          onShowFocusHighlight: (show) =>
              setState(() => _isFocusHighlighted = show),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (details) {
              if (details.primaryVelocity == null) return;
              if (details.primaryVelocity! < -300) {
                _goToNextSlide();
              } else if (details.primaryVelocity! > 300) {
                _goToPreviousSlide();
              }
            },
            child: isDesktop
                ? RepaintBoundary(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        border: _isFocusHighlighted
                            ? Border.all(
                                color: Theme.of(context).colorScheme.primary,
                                width: 2.5,
                              )
                            : null,
                      ),
                      child: _buildFramedHero(
                        heroHeight,
                        isDesktop: isDesktop || isTv,
                      ),
                    ),
                  )
                : Padding(
                    padding: EdgeInsets.zero,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        border: _isFocusHighlighted
                            ? Border.all(
                                color: Theme.of(context).colorScheme.primary,
                                width: 2.5,
                              )
                            : null,
                      ),
                      child: SizedBox(
                        height: heroHeight,
                        child: _buildCarouselStack(
                          heroHeight,
                          isDesktop: isDesktop || isTv,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Custom carousel with crossfade + scale transition
  // Entry: scale 0.8→1, opacity 0→1  |  Exit: scale 1→1.2, opacity 1→0  |  400ms
  // ---------------------------------------------------------------------------

  /// The hero, run to the window's edges, with a way through it at each side.
  ///
  /// The arrows keep their physical sides whatever the language: one on the
  /// left, one on the right, each pointing the way it moves the row.
  Widget _buildFramedHero(double height, {required bool isDesktop}) {
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          _buildCarouselStack(height, isDesktop: isDesktop),
          if (widget.movies.length > 1) ...[
            Positioned(
              left: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: _HeroEdgeArrow(
                  icon: Icons.chevron_left_rounded,
                  onTap: _goToPreviousSlide,
                ),
              ),
            ),
            Positioned(
              right: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: _HeroEdgeArrow(
                  icon: Icons.chevron_right_rounded,
                  onTap: _goToNextSlide,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCarouselStack(double height, {required bool isDesktop}) {
    return Stack(
      children: [
        // Previous slide (exiting) — only during transition
        if (_isTransitioning && _previousSlide != null)
          AnimatedBuilder(
            animation: _transitionAnimation,
            builder: (context, _) {
              final t = _transitionAnimation.value;
              return Opacity(
                opacity: 1.0 - t,
                child: Transform.scale(
                  scale: 1.0 + 0.2 * t,
                  child: _buildSlideForIndex(
                    height,
                    _previousSlide!,
                    isDesktop: isDesktop,
                  ),
                ),
              );
            },
          ),

        // Current slide (entering or static)
        _isTransitioning
            ? AnimatedBuilder(
                animation: _transitionAnimation,
                builder: (context, _) {
                  final t = _transitionAnimation.value;
                  return Opacity(
                    opacity: t,
                    child: Transform.scale(
                      scale: 0.8 + 0.2 * t,
                      child: _buildSlideForIndex(
                        height,
                        _currentSlide,
                        isDesktop: isDesktop,
                      ),
                    ),
                  );
                },
              )
            : _buildSlideForIndex(height, _currentSlide, isDesktop: isDesktop),

        // Progress bar indicators
        if (widget.movies.length > 1)
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: RepaintBoundary(child: _buildProgressIndicators()),
          ),
      ],
    );
  }

  Widget _buildProgressIndicators() {
    return ValueListenableBuilder<int>(
      valueListenable: _currentIndexNotifier,
      builder: (context, currentIndex, _) {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final entry in widget.movies.asMap().entries)
                _ProgressDot(
                  key: ValueKey('hcd_${entry.key}'),
                  isActive: currentIndex == entry.key,
                  fillController: _fillController,
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSlideForIndex(
    double height,
    int index, {
    required bool isDesktop,
  }) {
    final movie = widget.movies[index];
    if (widget.scrollController == null) {
      return _buildStaticItem(context, movie, height, isDesktop: isDesktop);
    }
    return _buildCarouselItem(context, movie, height, isDesktop: isDesktop);
  }

  void _navigateToDetails(BuildContext context, MultimediaItem item) {
    DetailsRoute($extra: DetailsRouteExtra(item: item)).push<void>(context);
  }

  Widget _buildCarouselItem(
    BuildContext context,
    MultimediaItem movie,
    double height, {
    bool isDesktop = false,
  }) {
    final theme = Theme.of(context);
    final scaffoldColor = theme.scaffoldBackgroundColor;

    return CardsWrapper(
      scaleFactor: 1.0,
      onTap: () {
        if (widget.onTap != null) {
          widget.onTap!(movie);
        } else {
          _navigateToDetails(context, movie);
        }
      },
      borderRadius: BorderRadius.zero,
      child: RepaintBoundary(
        child: ValueListenableBuilder<double>(
          valueListenable: _scrollOffset,
          builder: (context, scrollOffset, child) {
            final parallaxOffset = scrollOffset * 0.1;
            final contentOffset = -scrollOffset * 0.2;
            final opacity = (1.0 - (scrollOffset / (height * 0.5))).clamp(
              0.0,
              1.0,
            );

            return _buildSlideBase(
              context: context,
              movie: movie,
              height: height,
              isDesktop: isDesktop,
              parallaxOffset: parallaxOffset,
              contentOffset: contentOffset,
              opacity: opacity,
              scaffoldColor: scaffoldColor,
              theme: theme,
            );
          },
        ),
      ),
    );
  }

  Widget _buildStaticItem(
    BuildContext context,
    MultimediaItem movie,
    double height, {
    bool isDesktop = false,
  }) {
    final theme = Theme.of(context);
    return CardsWrapper(
      scaleFactor: 1.0,
      onTap: () {
        if (widget.onTap != null) {
          widget.onTap!(movie);
        } else {
          _navigateToDetails(context, movie);
        }
      },
      borderRadius: BorderRadius.zero,
      child: _buildSlideBase(
        context: context,
        movie: movie,
        height: height,
        isDesktop: isDesktop,
        parallaxOffset: 0,
        contentOffset: 0,
        opacity: 1.0,
        scaffoldColor: theme.scaffoldBackgroundColor,
        theme: theme,
      ),
    );
  }

  Widget _buildSlideBase({
    required BuildContext context,
    required MultimediaItem movie,
    required double height,
    required bool isDesktop,
    required double parallaxOffset,
    required double contentOffset,
    required double opacity,
    required Color scaffoldColor,
    required ThemeData theme,
  }) {
    // Prefer the anime banner explicitly for hero cards. Fall back to the
    // poster only when a provider does not expose a banner.
    final banner = movie.bannerUrl?.trim();
    // Asked for at the size it was uploaded at. The catalog's URLs carry a
    // rendition directive — often 576px wide — which is invisible on a card
    // and plain on a banner drawn the width of the window.
    final imageUrl = banner == null || banner.isEmpty
        ? movie.posterImageUrl
        : storyblokAtStoredWidth(banner, maxWidth: storyblokBannerWidth);
    final title = movie.title;

    // The details-page banner is painted directly into its frame with no
    // vertical overdraw. Keep the portrait-phone hero identical so the same
    // banner has the same crop/scale on Home and Details. Retain the existing
    // bleed elsewhere for the desktop/landscape parallax treatment.
    final size = MediaQuery.sizeOf(context);
    final isPortraitPhone =
        !isDesktop &&
        ResponsiveBreakpoints.isHandset(context) &&
        size.height > size.width;
    final bleed = isPortraitPhone ? 0.0 : 60.0;

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Background Image
          Positioned(
            top: -bleed + parallaxOffset,
            bottom: -bleed - parallaxOffset,
            left: 0,
            right: 0,
            child: ArtworkDecode(
              paintedWidth: MediaQuery.sizeOf(context).width,
              builder: (BuildContext context, int? decodeWidth) =>
                  FallbackPosterImage(
                    imageUrl: imageUrl,
                    // This frame is a banner; a poster looked up for it would
                    // be the wrong shape.
                    preferBanner: true,
                    malId: movie.artworkLookupMalId,
                    title: movie.artworkLookupTitle,
                    fit: BoxFit.cover,
                    memCacheWidth: decodeWidth,
                    filterQuality: FilterQuality.medium,
                    placeholder: (context) => Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                    ),
                    errorWidget: (context) => ThumbnailErrorPlaceholder(
                      label: title,
                      isBackdrop: true,
                    ),
                  ),
            ),
          ),

          // 2. Parallax Gradients
          Positioned(
            top: -bleed + parallaxOffset,
            bottom: -bleed - parallaxOffset,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDesktop
                      ? [
                          Colors.black.withValues(alpha: 0.2),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.45),
                          Colors.black.withValues(alpha: 0.75),
                        ]
                      : [
                          Colors.black.withValues(alpha: 0.3),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.4),
                          Colors.black.withValues(alpha: 0.8),
                        ],
                  stops: isDesktop
                      ? const [0.0, 0.35, 0.75, 1.0]
                      : const [0.0, 0.4, 0.6, 1.0],
                ),
              ),
            ),
          ),

          // 2.5. Fixed Bottom Feather (eased page transition scrim)
          Positioned(
            bottom: -1,
            left: 0,
            right: 0,
            height: 120,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      scaffoldColor.withValues(alpha: 0.0),
                      scaffoldColor.withValues(alpha: 0.15),
                      scaffoldColor.withValues(alpha: 0.45),
                      scaffoldColor.withValues(alpha: 0.8),
                      scaffoldColor,
                    ],
                    stops: const [0.0, 0.5, 0.75, 0.9, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // 3. Content
          Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: Transform.translate(
              offset: Offset(0, contentOffset),
              child: opacity >= 0.999
                  ? _buildCarouselContent(
                      isDesktop: isDesktop,
                      movie: movie,
                      theme: theme,
                      context: context,
                    )
                  : Opacity(
                      opacity: opacity,
                      child: _buildCarouselContent(
                        isDesktop: isDesktop,
                        movie: movie,
                        theme: theme,
                        context: context,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCarouselContent({
    required bool isDesktop,
    required MultimediaItem movie,
    required ThemeData theme,
    required BuildContext context,
  }) {
    final logoUrl = movie.logoUrl;
    final title = movie.title;
    final genres = movie.tags?.join(' • ') ?? '';
    final size = MediaQuery.sizeOf(context);
    final compactLandscape =
        context.isHandsetLandscape ||
        (context.isDesktopLandscape && size.height < 560);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: isDesktop
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        if (logoUrl != null)
          Padding(
            padding: EdgeInsets.only(
              bottom: compactLandscape
                  ? LayoutConstants.spacingSm
                  : LayoutConstants.spacingLg,
            ),
            child: _buildLogo(
              logoUrl,
              title,
              isDesktop: isDesktop,
              compactLandscape: compactLandscape,
            ),
          )
        else
          _buildTitleFallback(
            title,
            isDesktop: isDesktop,
            compactLandscape: compactLandscape,
          ),
        if (genres.isNotEmpty)
          // Under the name and on the same edge as it. Pinned left to right
          // in a box the width of the window, the line ran to the far side
          // of the screen from the title it belongs to.
          SizedBox(
            width: double.infinity,
            child: Directionality(
              textDirection: Directionality.of(context),
              child: Text(
                genres,
                textAlign: isDesktop ? TextAlign.start : TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
        if (isDesktop) ...[
          if ((movie.description ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            // Enough of the story to decide by, held to a readable measure.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Text(
                movie.description!.trim(),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.82),
                  height: 1.5,
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          _buildHeroActions(context, movie, theme),
        ],
      ],
    );
  }

  /// Start watching, keep for later, and what it scores.
  Widget _buildHeroActions(
    BuildContext context,
    MultimediaItem movie,
    ThemeData theme,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final malMean = AnimeDetailsRatings.fromItem(movie).malMean;
    return Wrap(
      spacing: 14,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // White, and the only filled thing on the artwork: it is what the
        // banner is advertising.
        Material(
          color: const Color(0xFFF2F3F5),
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _startWatching(context, movie),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.play_arrow_rounded,
                    size: 22,
                    color: Color(0xFF101114),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.play,
                    style: const TextStyle(
                      color: Color(0xFF101114),
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (malMean != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'MAL',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                malMean.toStringAsFixed(malMean >= 10 ? 0 : 1),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
      ],
    );
  }

  void _startWatching(BuildContext context, MultimediaItem movie) {
    if (widget.onTap != null) {
      widget.onTap!(movie);
      return;
    }
    // Straight into the episode, rather than the page about it: the button
    // says watching, so it should not stop at a description.
    DetailsRoute(
      $extra: DetailsRouteExtra(item: movie, autoPlay: true),
    ).push<void>(context);
  }

  Widget _buildLogo(
    String logoUrl,
    String title, {
    bool isDesktop = false,
    bool compactLandscape = false,
  }) {
    final logoHeight = compactLandscape ? 88.0 : 140.0;
    final logoWidth = compactLandscape ? 220.0 : 300.0;
    if (logoUrl.toLowerCase().endsWith('.svg')) {
      return SvgPicture.network(
        logoUrl,
        height: logoHeight,
        width: logoWidth,
        fit: BoxFit.contain,
        placeholderBuilder: (context) =>
            SizedBox(height: logoHeight, width: logoWidth),
        errorBuilder: (context, error, stackTrace) => _buildTitleFallback(
          title,
          isDesktop: isDesktop,
          compactLandscape: compactLandscape,
        ),
      );
    }
    return ArtworkDecode(
      paintedWidth: logoWidth,
      builder: (BuildContext context, int? decodeWidth) => CachedNetworkImage(
        imageUrl: logoUrl,
        height: logoHeight,
        width: logoWidth,
        memCacheWidth: decodeWidth,
        fit: BoxFit.contain,
        alignment: Alignment.bottomCenter,
        placeholder: (context, url) =>
            SizedBox(height: logoHeight, width: logoWidth),
        errorWidget: (context, url, error) => _buildTitleFallback(
          title,
          isDesktop: isDesktop,
          compactLandscape: compactLandscape,
        ),
      ),
    );
  }

  Widget _buildTitleFallback(
    String title, {
    bool isDesktop = false,
    bool compactLandscape = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: LayoutConstants.spacingXs),
      child: Text(
        title,
        textDirection: TextDirection.ltr,
        textAlign: isDesktop ? TextAlign.left : TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Colors.white,
          fontSize: compactLandscape ? 18 : (isDesktop ? 26 : 19),
          // Match MultimediaCard title typography: use the app's default
          // font face with the same semibold weight and line height.
          fontWeight: FontWeight.w600,
          height: 1.2,
          shadows: [Shadow(color: Colors.black, blurRadius: 10)],
        ),
      ),
    );
  }

}

/// A single progress dot whose width animates with spring physics.
///
/// When [isActive] toggles the dot springs between inactive (11 px) and active
/// (35 px) width. The active dot also renders a fill bar driven by
/// [fillController] that grows from 0 % → 100 % over the auto-advance interval.
///
/// Each dot manages its own [AnimationController] for the spring width
/// transition — only two dots tick per toggle. The fill bar is a separate
/// [AnimatedBuilder] that exists only on the active dot, so per-frame fill
/// rebuilds are limited to exactly one dot.
class _ProgressDot extends StatefulWidget {
  final bool isActive;
  final AnimationController fillController;

  const _ProgressDot({
    super.key,
    required this.isActive,
    required this.fillController,
  });

  @override
  State<_ProgressDot> createState() => _ProgressDotState();
}

class _ProgressDotState extends State<_ProgressDot>
    with SingleTickerProviderStateMixin {
  static const double _activeWidth = 35.0;
  static const double _inactiveWidth = 11.0;
  static const double _height = 4.0;

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _controller.value = widget.isActive ? 1.0 : 0.0;
  }

  @override
  void didUpdateWidget(_ProgressDot old) {
    super.didUpdateWidget(old);
    if (widget.isActive != old.isActive) {
      _animateToTarget();
    }
  }

  void _animateToTarget() {
    _controller.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 300, damping: 30),
        _controller.value,
        widget.isActive ? 1.0 : 0.0,
        0,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final width = _inactiveWidth + (_activeWidth - _inactiveWidth) * t;

        return Container(
          width: width,
          height: _height,
          margin: const EdgeInsets.symmetric(horizontal: 3.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            color: Colors.white.withValues(alpha: widget.isActive ? 0.3 : 0.2),
          ),
          child: widget.isActive
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: AnimatedBuilder(
                    animation: widget.fillController,
                    builder: (context, _) {
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: _activeWidth * widget.fillController.value,
                          height: _height,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      );
                    },
                  ),
                )
              : null,
        );
      },
    );
  }
}

/// One of the two ways through the hero, at the edge of the artwork.
class _HeroEdgeArrow extends StatelessWidget {
  const _HeroEdgeArrow({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox.square(
          dimension: 46,
          child: Icon(
            icon,
            size: 30,
            // Held left to right: these point at the edges they sit on, and
            // a mirrored chevron on an Arabic page pointed back into the
            // banner it was meant to lead out of.
            textDirection: TextDirection.ltr,
            color: Colors.white.withValues(alpha: 0.85),
          ),
        ),
      ),
    );
  }
}
