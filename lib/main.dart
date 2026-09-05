import 'dart:async';
import 'dart:io';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter/services.dart'; // LogicalKeyboardKey, KeyDownEvent
import 'package:flutter/foundation.dart'; // For kReleaseMode
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'package:window_manager/window_manager.dart';
import 'core/theme/theme_provider.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/storage/storage_service.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'core/utils/app_utils.dart';
import 'core/utils/artwork_host_fallback.dart';
import 'core/utils/window_controls_visibility.dart';
import 'core/utils/artwork_quality.dart';
import 'core/utils/immersive_mode.dart';
import 'core/utils/factory_reset.dart';
import 'core/utils/localized_text.dart';
import 'core/providers/update_provider.dart';
import 'core/widgets/update_dialog.dart';
import 'core/services/download_service.dart';
import 'core/services/notification_service.dart';
import 'core/widgets/m3_toast_overlay.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'core/providers/locale_provider.dart';
import 'core/providers/device_info_provider.dart';
import 'shared/widgets/loading_indicator.dart';
import 'features/settings/presentation/general_settings_provider.dart';
import 'core/account/account_providers.dart';
import 'core/widgets/welcome_dialog.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Silence logs in release mode
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  // Native window init (Desktop) - Run once
  if (Platform.isMacOS || Platform.isWindows) {
    await windowManager.ensureInitialized();

    final windowOptions = WindowOptions(
      size: const Size(1280, 720),
      minimumSize: const Size(360, 640),
      center: true,
      backgroundColor: Colors
          .black, // Solid black prevents transparency during fullscreen transition
      skipTaskbar: false,
      titleBarStyle: Platform.isMacOS
          ? TitleBarStyle.normal
          : TitleBarStyle.hidden,
    );

    unawaited(
      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      }),
    );
  }

  AppUtils.setRestartFunction(() => runApp(const AppRoot()));
  runApp(const AppRoot());
}

/// iOS does not expose touches that begin inside the system keyboard window to
/// Flutter. This lightweight edge gesture mirrors the native "pull keyboard
/// down" feel from the closest public touch surface: a narrow strip directly
/// above the visible keyboard. It never participates in the gesture arena, so
/// normal taps and scrolling continue to work unchanged.
class _IosKeyboardEdgeSwipeDismiss extends StatefulWidget {
  const _IosKeyboardEdgeSwipeDismiss({required this.child});

  final Widget child;

  @override
  State<_IosKeyboardEdgeSwipeDismiss> createState() =>
      _IosKeyboardEdgeSwipeDismissState();
}

class _IosKeyboardEdgeSwipeDismissState
    extends State<_IosKeyboardEdgeSwipeDismiss> {
  static const double _activationBand = 72;
  static const double _dismissDistance = 8;

  int? _pointer;
  Offset? _start;
  bool _eligible = false;

  void _reset() {
    _pointer = null;
    _start = null;
    _eligible = false;
  }

  void _onPointerDown(PointerDownEvent event) {
    final mediaQuery = MediaQuery.maybeOf(context);
    if (mediaQuery == null || mediaQuery.viewInsets.bottom <= 0) {
      _reset();
      return;
    }

    final keyboardTop = mediaQuery.size.height - mediaQuery.viewInsets.bottom;
    final distanceAboveKeyboard = keyboardTop - event.position.dy;
    final hasEditableFocus = FocusManager.instance.primaryFocus != null;

    _pointer = event.pointer;
    _start = event.position;
    _eligible =
        hasEditableFocus &&
        distanceAboveKeyboard >= 0 &&
        distanceAboveKeyboard <= _activationBand;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_eligible || event.pointer != _pointer || _start == null) return;

    final delta = event.position - _start!;
    final isLightDownwardSwipe =
        delta.dy >= _dismissDistance && delta.dy > delta.dx.abs() * 0.65;
    if (!isLightDownwardSwipe) return;

    _eligible = false;
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (_) => _reset(),
      onPointerCancel: (_) => _reset(),
      child: widget.child,
    );
  }
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  late StorageService _storageService;
  bool _initialized = false;
  Object? _error;
  StackTrace? _stackTrace;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _storageService = StorageService();
    try {
      await Future.wait([
        _storageService.init(),
        if (Platform.isAndroid)
          FlutterDisplayMode.setHighRefreshRate().catchError((Object e) {
            if (kDebugMode) debugPrint("Error setting high refresh rate: $e");
          }),
      ]);

      // Image widgets read the artwork quality switch directly, so publish it
      // (and the matching image cache budget) before the first screen paints.
      applyArtworkQuality(_storageService.isHighQualityPostersEnabled());

      // Artwork mostly lives on MyAnimeList's CDN, which some networks block.
      // Publish last run's answer immediately so the first screen already
      // picks reachable artwork, then re-check in the background. Skipped
      // entirely unless the viewer asked for it, so the default costs nothing.
      final artworkFallback = _storageService.isArtworkFallbackEnabled();
      applyArtworkFallbackEnabled(artworkFallback);
      if (artworkFallback) {
        seedMalArtworkReachability(_storageService.isMalArtworkUnreachable());
        unawaited(_refreshArtworkHostReachability());
      }

      if (Platform.isMacOS || Platform.isWindows) {
        final alwaysOnTop = _storageService.isAlwaysOnTop();
        await windowManager.setAlwaysOnTop(alwaysOnTop);
      }

      if (mounted) {
        setState(() {
          _initialized = true;
        });
      }
    } catch (e, stack) {
      if (mounted) {
        setState(() {
          _error = e;
          _stackTrace = stack;
        });
      }
    }
  }

  /// Re-checks whether the MyAnimeList CDN answers, and remembers it. Runs off
  /// the critical path: the seeded value already drives the first frame, and a
  /// changed answer only needs to apply from the next screen onwards.
  Future<void> _refreshArtworkHostReachability() async {
    final probedAt = _storageService.malArtworkProbedAt();
    if (probedAt != null &&
        DateTime.now().difference(probedAt) < probeTtl &&
        !_storageService.isMalArtworkUnreachable()) {
      // Recently confirmed reachable; nothing to re-check. A previous
      // "unreachable" is always re-probed so the app recovers on its own.
      return;
    }
    final unreachable = await probeMalArtworkUnreachable();
    if (!mounted) return;
    seedMalArtworkReachability(unreachable);
    await _storageService.setMalArtworkUnreachable(unreachable);
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return LaunchErrorApp(
        error: _error!,
        stackTrace: _stackTrace,
        storageService: _storageService,
      );
    }

    if (!_initialized) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: DynamicColorBuilder(
          builder: (lightDynamic, darkDynamic) {
            const color = AppTheme.animeWitcherAccent;
            return ColoredBox(
              color: Colors.black,
              child: Center(child: AppLoadingIndicator(color: color)),
            );
          },
        ),
      );
    }

    return ProviderScope(
      overrides: [storageServiceProvider.overrideWithValue(_storageService)],
      child: const MyApp(),
    );
  }
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp>
    with WindowListener, WidgetsBindingObserver {
  DateTime? _lastForegroundAccountSyncAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addEarlyKeyEventHandler(_handleEarlyKeyEvent);
    if (Platform.isMacOS || Platform.isWindows) {
      windowManager.addListener(this);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(downloadServiceProvider).init();
      _checkAppUpdates();
      _maybeShowWelcomeDialog();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeEarlyKeyEventHandler(_handleEarlyKeyEvent);
    if (Platform.isMacOS || Platform.isWindows) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(downloadServiceProvider).onAppForegrounded());
    }
    if (state != AppLifecycleState.resumed) return;
    final account = ref
        .read(animeWitcherAccountControllerProvider)
        .asData
        ?.value;
    if (account?.isSignedIn != true) return;

    final now = DateTime.now();
    final previous = _lastForegroundAccountSyncAt;
    if (previous != null &&
        now.difference(previous) < const Duration(minutes: 1)) {
      return;
    }
    _lastForegroundAccountSyncAt = now;
    unawaited(
      ref
          .read(animeWitcherAccountControllerProvider.notifier)
          .syncNow()
          .catchError((Object error) {
            if (kDebugMode) {
              debugPrint(
                '[AnimeWitcherAccount] Foreground sync deferred: $error',
              );
            }
          }),
    );
  }

  KeyEventResult _handleEarlyKeyEvent(KeyEvent event) {
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus == null) {
      return KeyEventResult.ignored;
    }

    final context = primaryFocus.context;
    if (context == null || !context.mounted) {
      return KeyEventResult.ignored;
    }

    final renderObject = context.findRenderObject();
    if (renderObject == null) {
      return KeyEventResult.ignored;
    }

    RenderObject? current = renderObject;
    bool isLaidOut = true;
    while (current != null) {
      if (current is RenderBox && !current.hasSize) {
        isLaidOut = false;
        break;
      }
      final parent = current.parent;
      if (parent is RenderObject) {
        current = parent;
      } else {
        break;
      }
    }

    if (!isLaidOut) {
      if (kDebugMode) {
        debugPrint(
          '[FocusGuard] Consumed key event ${event.logicalKey.keyLabel} because primary focus context or its ancestor is not laid out.',
        );
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Future<void> _checkAppUpdates() async {
    if (kDebugMode) {
      debugPrint('[Lifecycle] Starting _checkAppUpdates after 5s delay...');
    }
    await Future<void>.delayed(const Duration(seconds: 5));
    if (!mounted) {
      if (kDebugMode) {
        debugPrint('[Lifecycle] _checkAppUpdates aborted: MyApp unmounted');
      }
      return;
    }

    try {
      final controller = ref.read(updateControllerProvider.notifier);
      await controller.checkForUpdates();
    } catch (e) {
      if (kDebugMode) {
        debugPrint("[Lifecycle] App update trigger failed: $e");
      }
    }
  }

  Future<void> _maybeShowWelcomeDialog() async {
    if (!mounted) return;
    final navContext = ref
        .read(appRouterProvider)
        .routerDelegate
        .navigatorKey
        .currentContext;
    if (navContext == null || !navContext.mounted) return;
    await maybeShowWelcomeDialog(navContext, ref);
  }

  Future<void> _toggleFullscreen() async {
    if (!(Platform.isMacOS || Platform.isWindows)) return;
    try {
      final isFull = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!isFull);
    } catch (e) {
      if (kDebugMode) debugPrint('_toggleFullscreen: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Restore the AnimeWitcher session and reconcile account data without
    // blocking the first frame. Local library/history remain immediately
    // available while the async provider performs its merge in the background.
    ref.watch(animeWitcherAccountControllerProvider);
    final themeMode = ref.watch(appThemeModeProvider);
    final appRouter = ref.watch(appRouterProvider);
    final locale = ref.watch(localeProvider);
    final profileAsync = ref.watch(deviceProfileProvider);

    // Reactive Listener: Keeps UpdateController alive and handles the UI side-effect
    ref.listen<UpdateState>(updateControllerProvider, (previous, next) {
      if (next is UpdateAvailable) {
        final navContext = appRouter.routerDelegate.navigatorKey.currentContext;
        if (navContext != null && navContext.mounted) {
          if (kDebugMode) {
            debugPrint(
              '[Lifecycle] State update detected: UpdateAvailable. Showing dialog.',
            );
          }
          UpdateDialog.show(navContext, next.release);
        } else {
          if (kDebugMode) {
            debugPrint(
              '[Lifecycle] Update available but navContext not ready/mounted.',
            );
          }
        }
      }
    });

    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        ColorScheme? darkScheme;
        if (darkDynamic != null) {
          darkScheme = darkDynamic;
        }

        final materialApp = MaterialApp.router(
          scaffoldMessengerKey: ref
              .read(notificationServiceProvider)
              .messengerKey,
          title: 'AnimeWitcher',
          debugShowCheckedModeBanner: false,
          scrollBehavior: const MaterialScrollBehavior().copyWith(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          ),
          themeMode: themeMode,
          theme: lightDynamic != null
              ? AppTheme.createLightTheme(lightDynamic)
              : AppTheme.createLightTheme(null),
          darkTheme: AppTheme.createDarkTheme(darkScheme),
          routerConfig: appRouter,
          locale: locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            Widget result = child!;

            // Phase 1: Density override for TV devices
            // Android TV often reports inflated pixel density; we clamp to 1.0 for standard scaling.
            final profile = profileAsync.asData?.value;
            if (profile?.isTv == true) {
              result = MediaQuery(
                data: mq.copyWith(
                  devicePixelRatio: 1.0,
                  textScaler: TextScaler.noScaling,
                ),
                child: result,
              );
            }

            if (!kIsWeb && (Platform.isWindows || Platform.isMacOS)) {
              final isMac = Platform.isMacOS;
              if (!isMac) {
                result = Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(child: result),
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: CustomTitleBar(),
                    ),
                  ],
                );
              }
            }

            result = ApplePersistentGlassHeaderOverlay(child: result);
            if (!kIsWeb && Platform.isIOS) {
              result = _IosKeyboardEdgeSwipeDismiss(child: result);
            }
            return M3ToastOverlay(child: result);
          },
        );

        Widget rootWidget = Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.f11) {
              _toggleFullscreen();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: materialApp,
        );

        if (Platform.isMacOS) {
          final alwaysOnTop = ref.watch(
            generalSettingsProvider.select((s) => s.alwaysOnTop),
          );
          rootWidget = PlatformMenuBar(
            menus: <PlatformMenuItem>[
              PlatformMenu(
                label: 'AnimeWitcher',
                menus: <PlatformMenuItem>[
                  if (PlatformProvidedMenuItem.hasMenu(
                    PlatformProvidedMenuItemType.about,
                  ))
                    const PlatformProvidedMenuItem(
                      type: PlatformProvidedMenuItemType.about,
                    ),
                  const PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.quit,
                  ),
                ],
              ),
              PlatformMenu(
                label: 'تحرير',
                menus: <PlatformMenuItem>[
                  PlatformMenuItem(
                    label: 'تراجع',
                    shortcut: const SingleActivator(
                      LogicalKeyboardKey.keyZ,
                      meta: true,
                    ),
                    onSelected: () {},
                  ),
                  PlatformMenuItem(
                    label: 'إعادة',
                    shortcut: const SingleActivator(
                      LogicalKeyboardKey.keyZ,
                      meta: true,
                      shift: true,
                    ),
                    onSelected: () {},
                  ),
                  PlatformMenuItemGroup(
                    members: <PlatformMenuItem>[
                      PlatformMenuItem(
                        label: 'قص',
                        shortcut: SingleActivator(
                          LogicalKeyboardKey.keyX,
                          meta: true,
                        ),
                        onSelected: null,
                      ),
                      PlatformMenuItem(
                        label: 'نسخ',
                        shortcut: SingleActivator(
                          LogicalKeyboardKey.keyC,
                          meta: true,
                        ),
                        onSelected: null,
                      ),
                      PlatformMenuItem(
                        label: 'لصق',
                        shortcut: SingleActivator(
                          LogicalKeyboardKey.keyV,
                          meta: true,
                        ),
                        onSelected: null,
                      ),
                      PlatformMenuItem(
                        label: 'تحديد الكل',
                        shortcut: SingleActivator(
                          LogicalKeyboardKey.keyA,
                          meta: true,
                        ),
                        onSelected: null,
                      ),
                    ],
                  ),
                ],
              ),
              PlatformMenu(
                label: 'نافذة',
                menus: <PlatformMenuItem>[
                  const PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.minimizeWindow,
                  ),
                  const PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.zoomWindow,
                  ),
                  PlatformMenuItem(
                    label: alwaysOnTop
                        ? 'إلغاء البقاء في المقدمة'
                        : 'البقاء في المقدمة',
                    shortcut: const SingleActivator(
                      LogicalKeyboardKey.keyT,
                      meta: true,
                      control: true,
                    ),
                    onSelected: () async {
                      final nextVal = !alwaysOnTop;
                      await ref
                          .read(generalSettingsProvider.notifier)
                          .setAlwaysOnTop(nextVal);
                      await windowManager.setAlwaysOnTop(nextVal);
                    },
                  ),
                ],
              ),
            ],
            child: rootWidget,
          );
        }

        return rootWidget;
      },
    );
  }
}

class LaunchErrorApp extends StatelessWidget {
  final Object error;
  final StackTrace? stackTrace;
  final StorageService storageService;

  const LaunchErrorApp({
    super.key,
    required this.error,
    this.stackTrace,
    required this.storageService,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      ),
      locale: const Locale('ar'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        backgroundColor: Colors.red.shade900,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Builder(
              builder: (context) {
                final l10n = AppLocalizations.of(context);
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 64,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n?.startupError ?? 'خطأ في بدء التشغيل',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      error.toString(),
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n?.retry ?? 'إعادة المحاولة'),
                      onPressed: () => AppUtils.restartApp(context),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white),
                      ),
                      icon: const Icon(Icons.delete_forever),
                      label: Text(l10n?.factoryReset ?? 'إعادة ضبط المصنع'),
                      onPressed: () async {
                        await runFactoryReset(
                          clearAccountSession: () async {},
                          clearLocalData: storageService.deleteAllData,
                        );
                        if (context.mounted) await AppUtils.restartApp(context);
                      },
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.orange),
                      ),
                      icon: const Icon(Icons.restore),
                      label: Text(
                        appText(
                          context,
                          english: 'Reset Preferences',
                          arabic: 'إعادة ضبط التفضيلات',
                        ),
                      ),
                      onPressed: () async {
                        await storageService.clearPreferences();
                        if (context.mounted) await AppUtils.restartApp(context);
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class CustomTitleBar extends StatefulWidget {
  const CustomTitleBar({super.key});

  @override
  State<CustomTitleBar> createState() => _CustomTitleBarState();
}

class _CustomTitleBarState extends State<CustomTitleBar> with WindowListener {
  bool _isMaximized = false;
  bool _isFullScreen = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _updateStates();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    _updateStates();
  }

  @override
  void onWindowUnmaximize() {
    _updateStates();
  }

  @override
  void onWindowEnterFullScreen() {
    _updateStates();
  }

  @override
  void onWindowLeaveFullScreen() {
    _updateStates();
  }

  Future<void> _updateStates() async {
    // A short delay gives the OS window manager time to finalize transitions (fullscreen/maximize/etc.)
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (!mounted) return;
    final isMax = await windowManager.isMaximized();
    final isFull = await windowManager.isFullScreen();
    if (mounted) {
      setState(() {
        _isMaximized = isMax;
        _isFullScreen = isFull;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // The controls sit directly on artwork now, so they carry their own
    // contrast rather than relying on a bar behind them.
    final iconColor = isDark
        ? Colors.white.withValues(alpha: 0.95)
        : const Color(0xFF5C5C5C); // High contrast text/icon color

    // The window controls sit on the artwork rather than in a bar of their
    // own. The bar used to stay hidden until the pointer reached the top
    // edge, so the only way to close the window was to go looking for the
    // button. Nothing is painted behind them now, which also lets the hero
    // artwork run to the very top of the window.
    return SizedBox(
      // Matches the dashboard header's height so the caption buttons sit on
      // the same line as the search bar rather than above it.
      height: 56,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: Platform.isMacOS ? 80 : 0,
            right: 0,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) {
                windowManager.startDragging();
              },
              onDoubleTap: () async {
                final isMax = await windowManager.isMaximized();
                if (isMax) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
            ),
          ),
          // Right-side window controls (minimize, maximize/restore, close).
          // Fullscreen has no caption button: F11 toggles it.
          if (!Platform.isMacOS)
            Positioned(
              right: 12,
              top: 0,
              bottom: 0,
              // Over a playing video the buttons follow the player's own
              // controls out of view, so they stop sitting on the picture.
              child: ValueListenableBuilder<bool>(
                valueListenable: windowControlsHidden,
                builder: (context, hidden, child) => AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: hidden ? 0.0 : 1.0,
                  child: IgnorePointer(ignoring: hidden, child: child),
                ),
                child: Center(
                  // The app runs RTL, which would mirror the caption
                  // buttons and put close on the left. Window controls
                  // follow the OS, not the content language.
                  child: Directionality(
                    textDirection: TextDirection.ltr,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!_isFullScreen) ...[
                          // 2. Minimize
                          _TitleBarButton(
                            onPressed: () => windowManager.minimize(),
                            child: Center(
                              // A one-pixel rule lands between device pixels
                              // and renders half-lit, which made this the
                              // faintest of the three. The maximise box and
                              // the close cross are drawn a full pixel wide.
                              child: Container(
                                width: 10,
                                height: 1.5,
                                color: iconColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // 3. Maximize / Restore
                          _TitleBarButton(
                            onPressed: () async {
                              if (_isMaximized) {
                                await windowManager.unmaximize();
                              } else {
                                await windowManager.maximize();
                              }
                              await _updateStates();
                            },
                            child: Center(
                              child: _isMaximized
                                  ? SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: Stack(
                                        children: [
                                          Positioned(
                                            right: 0,
                                            top: 0,
                                            child: Container(
                                              width: 8,
                                              height: 8,
                                              decoration: BoxDecoration(
                                                border: Border.all(
                                                  color: iconColor,
                                                  width: 1,
                                                ),
                                              ),
                                            ),
                                          ),
                                          Positioned(
                                            left: 0,
                                            bottom: 0,
                                            child: Container(
                                              width: 8,
                                              height: 8,
                                              decoration: BoxDecoration(
                                                color: isDark
                                                    ? const Color(0xFF050505)
                                                    : const Color(
                                                        0xFFFAF8F5,
                                                      ), // overlap box bg matches titlebar
                                                border: Border.all(
                                                  color: iconColor,
                                                  width: 1,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: iconColor,
                                          width: 1,
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // 4. Close
                          _CloseButton(onPressed: () => windowManager.close()),
                        ],
                      ],
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

class _TitleBarButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onPressed;

  const _TitleBarButton({required this.child, required this.onPressed});

  @override
  State<_TitleBarButton> createState() => _TitleBarButtonState();
}

class _TitleBarButtonState extends State<_TitleBarButton> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hoverColor = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : const Color(
            0xFFE4D9C8,
          ); // Darker warm neutral tan hover background (#E4D9C8)

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onPressed,
        borderRadius: BorderRadius.circular(6),
        hoverColor: hoverColor,
        splashColor: hoverColor.withValues(alpha: 0.2),
        child: SizedBox(width: 32, height: 32, child: widget.child),
      ),
    );
  }
}

class _CloseButton extends StatefulWidget {
  final VoidCallback onPressed;

  const _CloseButton({required this.onPressed});

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: InkWell(
          onTap: widget.onPressed,
          borderRadius: BorderRadius.circular(6),
          hoverColor: Colors.red.withValues(alpha: 0.8),
          splashColor: Colors.red,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(
              // Square-cut rather than rounded, to sit at the same visual
              // weight as the minimize line and the maximize outline.
              Icons.close,
              color: _isHovered
                  ? Colors.white
                  : (isDark
                        ? Colors.white.withValues(alpha: 0.85)
                        : const Color(0xFF5C5C5C)),
              size: 15,
            ),
          ),
        ),
      ),
    );
  }
}
