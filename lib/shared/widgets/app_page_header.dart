import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';

import '../../core/utils/window_controls_inset.dart';
import 'app_back_button.dart';
import 'apple_liquid_glass.dart';

/// A compact translucent header backdrop.
///
/// On Impeller this uses one captured backdrop with a two-pass separable
/// Gaussian shader. The sigma falls continuously from [maxSigma] at the top
/// edge to zero at the content edge, so there is no hard blur boundary.
///
/// Backends that cannot run shader image filters keep a single fixed
/// BackdropFilter as a cheap fallback.
class AppProgressiveHeaderBackdrop extends StatefulWidget {
  const AppProgressiveHeaderBackdrop({
    super.key,
    this.maxSigma = 12,
    this.falloff = 1.2,
  });

  final double maxSigma;
  final double falloff;

  static ui.FragmentProgram? _program;
  static Future<ui.FragmentProgram>? _loading;

  /// Loads the runtime effect once so the first visible header can use it.
  static Future<void> preload() async {
    if (_program != null || !ui.ImageFilter.isShaderFilterSupported) return;

    try {
      _program = await (_loading ??= ui.FragmentProgram.fromAsset(
        'shaders/progressive_header_blur.frag',
      ));
    } catch (error) {
      _loading = null;
      debugPrint(
        'progressive_header_blur.frag unavailable; using fixed blur: $error',
      );
    }
  }

  @override
  State<AppProgressiveHeaderBackdrop> createState() =>
      _AppProgressiveHeaderBackdropState();
}

class _AppProgressiveHeaderBackdropState
    extends State<AppProgressiveHeaderBackdrop> {
  ui.FragmentShader? _horizontalShader;
  ui.FragmentShader? _verticalShader;

  @override
  void initState() {
    super.initState();
    _makeShaders();
    if (_horizontalShader == null && ui.ImageFilter.isShaderFilterSupported) {
      AppProgressiveHeaderBackdrop.preload().then((_) {
        if (!mounted) return;
        setState(_makeShaders);
      });
    }
  }

  void _makeShaders() {
    final program = AppProgressiveHeaderBackdrop._program;
    if (program == null || _horizontalShader != null) return;
    _horizontalShader = program.fragmentShader();
    _verticalShader = program.fragmentShader();
  }

  @override
  void dispose() {
    _horizontalShader?.dispose();
    _verticalShader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.maxSigma <= 0) return const SizedBox.expand();

    final surface = Theme.of(context).colorScheme.surface;
    final horizontal = _horizontalShader;
    final vertical = _verticalShader;
    final canUseShader =
        horizontal != null &&
        vertical != null &&
        ui.ImageFilter.isShaderFilterSupported;

    final blur = canUseShader
        ? _ProgressiveHeaderBlurLayer(
            horizontalShader: horizontal,
            verticalShader: vertical,
            maxSigma: widget.maxSigma,
            falloff: widget.falloff,
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            child: const SizedBox.expand(),
          )
        : BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX: widget.maxSigma,
              sigmaY: widget.maxSigma,
            ),
            child: const SizedBox.expand(),
          );

    return IgnorePointer(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            blur,
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    surface.withValues(alpha: 0.16),
                    surface.withValues(alpha: 0.08),
                    surface.withValues(alpha: 0.02),
                    surface.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.50, 0.82, 1],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressiveHeaderBlurLayer extends SingleChildRenderObjectWidget {
  const _ProgressiveHeaderBlurLayer({
    required this.horizontalShader,
    required this.verticalShader,
    required this.maxSigma,
    required this.falloff,
    required this.devicePixelRatio,
    required super.child,
  });

  final ui.FragmentShader horizontalShader;
  final ui.FragmentShader verticalShader;
  final double maxSigma;
  final double falloff;
  final double devicePixelRatio;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderProgressiveHeaderBlur(
        horizontalShader: horizontalShader,
        verticalShader: verticalShader,
        maxSigma: maxSigma,
        falloff: falloff,
        devicePixelRatio: devicePixelRatio,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderProgressiveHeaderBlur renderObject,
  ) {
    renderObject.update(
      horizontalShader: horizontalShader,
      verticalShader: verticalShader,
      maxSigma: maxSigma,
      falloff: falloff,
      devicePixelRatio: devicePixelRatio,
    );
  }
}

class _RenderProgressiveHeaderBlur extends RenderProxyBox {
  _RenderProgressiveHeaderBlur({
    required ui.FragmentShader horizontalShader,
    required ui.FragmentShader verticalShader,
    required double maxSigma,
    required double falloff,
    required double devicePixelRatio,
  }) : _horizontalShader = horizontalShader,
       _verticalShader = verticalShader,
       _maxSigma = maxSigma,
       _falloff = falloff,
       _devicePixelRatio = devicePixelRatio;

  ui.FragmentShader _horizontalShader;
  ui.FragmentShader _verticalShader;
  double _maxSigma;
  double _falloff;
  double _devicePixelRatio;

  void update({
    required ui.FragmentShader horizontalShader,
    required ui.FragmentShader verticalShader,
    required double maxSigma,
    required double falloff,
    required double devicePixelRatio,
  }) {
    if (identical(_horizontalShader, horizontalShader) &&
        identical(_verticalShader, verticalShader) &&
        _maxSigma == maxSigma &&
        _falloff == falloff &&
        _devicePixelRatio == devicePixelRatio) {
      return;
    }

    _horizontalShader = horizontalShader;
    _verticalShader = verticalShader;
    _maxSigma = maxSigma;
    _falloff = falloff;
    _devicePixelRatio = devicePixelRatio;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  BackdropFilterLayer? get layer => super.layer as BackdropFilterLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      layer = null;
      return;
    }

    final origin = localToGlobal(Offset.zero);
    _configureShader(_horizontalShader, axis: 0, origin: origin);
    _configureShader(_verticalShader, axis: 1, origin: origin);

    (layer ??= BackdropFilterLayer()).filter = ui.ImageFilter.compose(
      outer: ui.ImageFilter.shader(_verticalShader),
      inner: ui.ImageFilter.shader(_horizontalShader),
    );
    context.pushLayer(layer!, super.paint, offset);
  }

  void _configureShader(
    ui.FragmentShader shader, {
    required double axis,
    required Offset origin,
  }) {
    final dpr = _devicePixelRatio;
    final values = <double>[
      _maxSigma * dpr,
      _falloff,
      axis,
      origin.dx * dpr,
      origin.dy * dpr,
      size.width * dpr,
      size.height * dpr,
    ];

    // Float slots 0 and 1 are uSize; Flutter supplies those for image-filter
    // shaders. Our uniforms start at slot 2.
    for (var i = 0; i < values.length; i++) {
      shader.setFloat(i + 2, values[i]);
    }
  }
}

/// Top padding that keeps initial scroll content below [AppPageAppBar]
/// while still allowing it to move underneath the translucent header.
double appPageHeaderContentTopInset(BuildContext context) =>
    MediaQuery.paddingOf(context).top + kToolbarHeight;

/// Standard conventional page chrome.
///
/// The title is physically centred in the viewport rather than centred in the
/// space left over by navigation/actions. Back is always on the physical left.
class AppPageAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AppPageAppBar({
    super.key,
    required this.title,
    this.canPop = true,
    this.onBack,
    this.actions = const <Widget>[],
    this.titleKey,
  });

  final String title;
  final bool canPop;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final Key? titleKey;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final theme = Theme.of(context);
    final appBarTitleStyle =
        (theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge)
            ?.copyWith(
              color:
                  theme.appBarTheme.foregroundColor ??
                  theme.colorScheme.onSurface,
              fontWeight: FontWeight.bold,
            );
    final pop = onBack ?? () => Navigator.of(context).maybePop();
    final leadingInset = windowControlsLeadingInset;
    final titleClearance =
        windowControlsSymmetricInset + (actions.isEmpty ? 72.0 : 120.0);
    final hasWindowControlsGap = actions.any((action) => action is WindowControlsGap);

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          AppBar(
            automaticallyImplyLeading: false,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            flexibleSpace: const AppProgressiveHeaderBackdrop(),
            leadingWidth:
                canPop && !appleUsesPersistentLiquidGlassHeader
                    ? 56 + leadingInset
                    : null,
            leading: canPop && !appleUsesPersistentLiquidGlassHeader
                ? Padding(
                    padding: EdgeInsets.only(left: leadingInset),
                    child: AppBackButton(onPressed: pop),
                  )
                : null,
            actions: <Widget>[
              ...actions,
              if (!hasWindowControlsGap) const WindowControlsGap(),
            ],
          ),
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: IgnorePointer(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: titleClearance),
                  child: Center(
                    child: ApplePersistentGlassHeaderScope(
                      enabled: canPop,
                      onBack: pop,
                      child: Directionality(
                        textDirection:
                            isArabic ? TextDirection.rtl : TextDirection.ltr,
                        child: Text(
                          title,
                          key: titleKey,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: appBarTitleStyle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
