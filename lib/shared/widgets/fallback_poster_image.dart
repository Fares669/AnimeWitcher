import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/artwork_fallback_service.dart';
import '../../core/utils/artwork_host_fallback.dart';

/// A poster that looks elsewhere when its artwork will not load.
///
/// Catalog artwork mostly lives on MyAnimeList's CDN, which some networks
/// block. The failure is what triggers the search, so this covers any
/// unreachable host rather than a hardcoded list of them: when the image
/// errors and the anime has a MyAnimeList id, AniZip and Kitsu are asked for
/// a copy and the result is reused for every other card showing that title.
class FallbackPosterImage extends ConsumerStatefulWidget {
  const FallbackPosterImage({
    super.key,
    required this.imageUrl,
    required this.malId,
    this.title,
    this.preferBanner = false,
    this.manga = false,
    required this.placeholder,
    required this.errorWidget,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.width,
    this.height,
    this.memCacheWidth,
    this.filterQuality = FilterQuality.medium,
    this.fadeInDuration = const Duration(milliseconds: 120),
  });

  final String imageUrl;

  /// Identifies the anime for the lookup. Not every catalog entry carries
  /// one, which is what [title] is for.
  final int? malId;

  /// Searched for when there is no [malId]. Less certain than an id, so it is
  /// only used when there is no id to use.
  final String? title;

  /// Looks for wide artwork rather than a poster.
  ///
  /// A hero shows a banner, and the poster the lookup would otherwise return
  /// is the wrong shape for it — cropped to a sliver and blown up past its
  /// own resolution. Only the id path can answer this; a title search knows
  /// no banner.
  final bool preferBanner;

  /// Looks the artwork up as a manga. MyAnimeList numbers manga and anime
  /// separately, so a manga's id asked about as an anime finds the wrong
  /// picture or none. A manga can also look its banner up by title.
  final bool manga;

  final WidgetBuilder placeholder;
  final WidgetBuilder errorWidget;
  final BoxFit fit;

  /// Which part of a picture survives the crop. A banner is anchored to its
  /// top so faces are not cut off by the frame's own proportions.
  final Alignment alignment;
  final double? width;
  final double? height;
  final int? memCacheWidth;
  final FilterQuality filterQuality;
  final Duration fadeInDuration;

  @override
  ConsumerState<FallbackPosterImage> createState() =>
      _FallbackPosterImageState();
}

class _FallbackPosterImageState extends ConsumerState<FallbackPosterImage> {
  String? _fallbackUrl;

  /// Anime look elsewhere only when the viewer turned that on. A manga
  /// always may: much of its artwork sits on MyAnimeList's CDN, which some
  /// networks cannot reach, and the switch lives in the anime settings where
  /// a manga reader would not think to look. It still only looks once the
  /// catalog's picture has failed, or when there is none to show.
  /// The lookup, where there is one. A card drawn outside the app's own
  /// provider scope (a test, a preview) has none, and simply keeps the
  /// catalog's picture rather than failing to build.
  ArtworkFallbackService? _service() {
    try {
      return ref.read(artworkFallbackServiceProvider);
    } catch (_) {
      return null;
    }
  }

  bool get _lookupAllowed => artworkFallbackEnabled.value || widget.manga;
  bool _primaryFailed = false;
  bool _lookedUp = false;

  @override
  void initState() {
    super.initState();
    artworkFallbackEnabled.addListener(_onSwitchChanged);
    malArtworkUnreachable.addListener(_onSwitchChanged);
    _adoptCachedFallback();
    _resolveWhenNothingToShow();
  }

  @override
  void dispose() {
    artworkFallbackEnabled.removeListener(_onSwitchChanged);
    malArtworkUnreachable.removeListener(_onSwitchChanged);
    super.dispose();
  }

  /// Turning the lookup on is how someone reacts to posters that are already
  /// on screen and blank, so the cards they are looking at have to answer for
  /// themselves rather than wait to be scrolled away and back.
  void _onSwitchChanged() {
    if (!mounted || widget.manga) return;
    if (!artworkFallbackEnabled.value) {
      // Back to the catalog's own artwork, and anything found while the
      // lookup was on is dropped so the two states cannot be told apart.
      if (_fallbackUrl == null && !_lookedUp) return;
      setState(() {
        _fallbackUrl = null;
        _primaryFailed = false;
        _lookedUp = false;
      });
      return;
    }
    if (_fallbackUrl != null) return;
    _lookedUp = false;
    _adoptCachedFallback();
    if (_fallbackUrl != null) {
      setState(() {});
      return;
    }
    // A poster that already failed has nothing to wait for; one that has not
    // is only worth replacing if it cannot load from here.
    if (_primaryFailed) {
      unawaited(_resolveFallback());
    } else {
      _resolveWhenNothingToShow();
    }
  }

  @override
  void didUpdateWidget(FallbackPosterImage old) {
    super.didUpdateWidget(old);
    if (old.imageUrl != widget.imageUrl ||
        old.malId != widget.malId ||
        old.title != widget.title ||
        old.manga != widget.manga) {
      _fallbackUrl = null;
      _primaryFailed = false;
      _lookedUp = false;
      _adoptCachedFallback();
      _resolveWhenNothingToShow();
    }
  }

  /// A title already resolved for another card is known synchronously, so its
  /// poster is used from the first frame instead of failing once more first.
  void _adoptCachedFallback() {
    if (!_lookupAllowed) return;
    final service = _service();
    if (service == null) return;
    final malId = widget.malId;
    final title = widget.title?.trim() ?? '';

    String? cached;
    if (widget.manga) {
      if (!service.hasResolvedManga(malId, title)) return;
      _lookedUp = true;
      final art = service.cachedManga(malId, title);
      cached = widget.preferBanner ? art?.banner : art?.cover;
      if (cached == null || cached.isEmpty) return;
      _fallbackUrl = cached;
      return;
    }
    if (widget.preferBanner) {
      if (malId != null && malId > 0 && service.hasResolvedBanner(malId)) {
        cached = service.cachedBanner(malId);
        _lookedUp = true;
      }
      if (cached == null || cached.isEmpty) return;
      _fallbackUrl = cached;
      return;
    }
    if (malId != null && malId > 0 && service.hasResolved(malId)) {
      cached = service.cached(malId);
      _lookedUp = true;
    } else if (title.isNotEmpty && service.hasResolvedTitle(title)) {
      cached = service.cachedForTitle(title);
      _lookedUp = true;
    }
    if (cached == null || cached.isEmpty) return;
    _fallbackUrl = cached;
  }

  /// Starts the lookup without waiting for a load to fail, when there is
  /// either nothing to load or the only candidate sits on a host already
  /// known to be unreachable. Waiting for that request to time out is the
  /// difference between a poster appearing at once and appearing late.
  void _resolveWhenNothingToShow() {
    if (!_lookupAllowed || _fallbackUrl != null) return;
    final url = widget.imageUrl.trim();
    final doomed =
        url.isEmpty || (malArtworkUnreachable.value && isMalArtworkUrl(url));
    if (!doomed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resolveFallback();
    });
  }

  Future<void> _resolveFallback() async {
    if (!_lookupAllowed || _lookedUp) return;
    final service = _service();
    if (service == null) return;
    final malId = widget.malId;
    final title = widget.title?.trim() ?? '';

    final String? url;
    if (widget.manga) {
      if ((malId == null || malId <= 0) && title.isEmpty) return;
      _lookedUp = true;
      final art = await service.mangaArtwork(malId: malId, title: title);
      url = widget.preferBanner ? art.banner : art.cover;
    } else if (widget.preferBanner) {
      if (malId == null || malId <= 0) return;
      _lookedUp = true;
      url = await service.bannerFor(malId);
    } else if (malId != null && malId > 0) {
      _lookedUp = true;
      url = await service.posterFor(malId);
    } else if (title.isNotEmpty) {
      _lookedUp = true;
      url = await service.posterForTitle(title);
    } else {
      return;
    }

    if (!mounted || url == null || url.isEmpty) return;
    setState(() => _fallbackUrl = url);
  }

  @override
  Widget build(BuildContext context) {
    final url = _fallbackUrl ?? widget.imageUrl;
    if (url.trim().isEmpty) return widget.errorWidget(context);

    return CachedNetworkImage(
      imageUrl: url,
      fit: widget.fit,
      alignment: widget.alignment,
      width: widget.width,
      height: widget.height,
      memCacheWidth: widget.memCacheWidth,
      filterQuality: widget.filterQuality,
      placeholder: (context, _) => widget.placeholder(context),
      errorWidget: (context, _, _) {
        // Only the catalog's own URL is worth replacing; if the replacement
        // fails too there is nothing further to try.
        if (_fallbackUrl == null && !_primaryFailed) {
          _primaryFailed = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _resolveFallback();
          });
        }
        return widget.errorWidget(context);
      },
      fadeOutDuration: Duration.zero,
      fadeInDuration: widget.fadeInDuration,
      useOldImageOnUrlChange: true,
    );
  }
}
