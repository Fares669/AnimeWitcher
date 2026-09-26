import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_config.dart';
import 'package:animewitcher/core/navigation/app_layout_style.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/theme/theme_provider.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_seasons_bar.dart';
import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/data/anime4k_download.dart';
import 'package:animewitcher/features/player/presentation/widgets/anime4k_player_sheet.dart';
import 'package:animewitcher/features/settings/presentation/account_screen.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:animewitcher/shared/widgets/live_previews.dart';

/// Whether the first-launch setup has been completed on this install.
///
/// One flag for the whole screen rather than one per question: the screen
/// is shown once, and each answer is also stored by its own setting, which
/// settings can change later.
class FirstRunSetup {
  // v8: the manga choice and an account step in every build.
  static const String storageKey = 'first_run_setup_v8';

  static bool isDone(StorageService storage) {
    try {
      return storage.getString(storageKey) == 'done';
    } catch (_) {
      // Unreadable storage should not put the setup in front of someone on
      // every launch.
      return true;
    }
  }

  static void markDone(StorageService storage) {
    try {
      storage.setString(storageKey, 'done');
    } catch (_) {
      // At worst the setup is offered once more.
    }
  }
}

/// Opens the setup over everything, and waits until it is finished.
Future<void> showFirstRunSetup(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (_, _, _) => const FirstRunSetupScreen(),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

enum _Step { appearance, details, player, account }

/// The first-launch setup, one part of the app at a time: how it looks,
/// how an anime's page shows its seasons, the player, then the account.
/// Each step has its choices on one side and a picture of that part of the
/// app on the other, redrawn as the choices change.
///
/// Everything here is also in settings; the screen exists so a new viewer
/// meets the choices once, with a preview, instead of finding them later.
/// It takes the place of the earlier welcome dialog, which asked for the
/// theme, the skip options and a sign-in in a smaller box of its own.
class FirstRunSetupScreen extends ConsumerStatefulWidget {
  const FirstRunSetupScreen({super.key});

  @override
  ConsumerState<FirstRunSetupScreen> createState() =>
      _FirstRunSetupScreenState();
}

class _FirstRunSetupScreenState extends ConsumerState<FirstRunSetupScreen> {
  late AppLayoutStyle _layout;
  late SeasonsBarStyle _seasons;
  late bool _anime4k;
  late Anime4kMode _mode;
  late bool _skipSegments;
  late bool _skipIntro;
  late bool _skipCredits;
  late FillerBehaviour _filler;
  late bool _mangaTab;
  int _index = 0;

  /// Desktops and tablets choose among three layouts; phones have one.
  bool get _isDesktop => appLayoutsAvailable(context);

  /// [_layout] as this screen can draw it: a choice another kind of screen
  /// made reads as the dock here.
  AppLayoutStyle get _effectiveLayout =>
      effectiveAppLayout(stored: _layout, isDesktopPlatform: _isDesktop);

  List<_Step> get _steps => [
    _Step.appearance,
    // The seasons bar belongs to the wide anime page; phones never show it.
    if (_isDesktop) _Step.details,
    _Step.player,
    // Always: a build without the account service says so here, rather
    // than the step silently not being there.
    _Step.account,
  ];

  @override
  void initState() {
    super.initState();
    _layout = ref.read(appLayoutStyleProvider) ?? AppLayoutStyle.dock;
    _seasons = ref.read(seasonsBarStyleProvider);
    final player =
        ref.read(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    _anime4k = player.anime4kEnabled;
    _mode = player.anime4kMode == Anime4kMode.off
        ? Anime4kMode.a
        : player.anime4kMode;
    _skipSegments = player.skipSegmentsEnabled;
    _skipIntro = player.autoSkipIntro;
    _skipCredits = player.autoSkipCredits;
    _filler = player.fillerBehaviour;
    _mangaTab = ref.read(mangaHasOwnTabProvider);
  }

  Future<void> _finish() async {
    // Held before the awaits below: the download outlives this screen, so it
    // is started on the app's container rather than on this widget.
    final container = ProviderScope.containerOf(context, listen: false);
    if (_isDesktop) {
      ref.read(appLayoutStyleProvider.notifier).select(_effectiveLayout);
    }
    ref.read(seasonsBarStyleProvider.notifier).select(_seasons);
    if (_mangaTab != ref.read(mangaHasOwnTabProvider)) {
      await ref.read(generalSettingsProvider.notifier).setMangaTab(_mangaTab);
    }

    final settings = ref.read(playerSettingsProvider.notifier);
    final player =
        ref.read(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    if (_skipSegments != player.skipSegmentsEnabled) {
      await settings.setSkipSegmentsEnabled(_skipSegments);
    }
    // Automatic skipping is under skipping: with that off, so are these.
    final autoIntro = _skipSegments && _skipIntro;
    final autoCredits = _skipSegments && _skipCredits;
    if (autoIntro != player.autoSkipIntro) {
      await settings.setAutoSkipIntro(autoIntro);
    }
    if (autoCredits != player.autoSkipCredits) {
      await settings.setAutoSkipCredits(autoCredits);
    }
    if (_filler != player.fillerBehaviour) {
      await settings.setFillerBehaviour(_filler);
    }
    if (_anime4k != player.anime4kEnabled) {
      await settings.setAnime4kEnabled(_anime4k);
    }
    if (_anime4k && _mode != player.anime4kMode) {
      await settings.setAnime4kMode(_mode);
    }
    if (_anime4k && player.anime4kShaderDirectory.trim().isEmpty) {
      // The shaders are a separate download. It runs behind the app rather
      // than in front of the first screen; the player applies them once
      // they are there.
      unawaited(
        container
            .read(anime4kDownloaderProvider)
            .download()
            .then(
              (result) => container
                  .read(playerSettingsProvider.notifier)
                  .setAnime4kShaderDirectory(result.directory),
            )
            .catchError((Object _) {
              // Settings → Anime4K offers the download again.
            }),
      );
    }

    FirstRunSetup.markDone(ref.read(storageServiceProvider));
    if (mounted) Navigator.of(context).pop();
  }

  void _openSignIn() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => const AnimeWitcherAccountScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final arabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final steps = _steps;
    final step = steps[_index.clamp(0, steps.length - 1)];
    final isLast = _index >= steps.length - 1;
    final wide = MediaQuery.sizeOf(context).width >= 820;
    final themeStyle = ref.watch(appThemeStyleProvider);
    final account = ref.watch(animeWitcherAccountControllerProvider);
    final profile = account.asData?.value.profile;

    final options = _StepPanel(
      arabic: arabic,
      stepNumber: _index + 1,
      stepCount: steps.length,
      title: switch (step) {
        _Step.appearance => arabic ? 'المظهر' : 'Appearance',
        _Step.details => arabic ? 'صفحة الأنمي' : 'Anime page',
        _Step.player => arabic ? 'المشغل' : 'Player',
        _Step.account => arabic ? 'الحساب' : 'Account',
      },
      description: switch (step) {
        _Step.appearance =>
          arabic
              ? 'ألوان التطبيق ومكان قائمة التنقل.'
              : 'The app\'s colours and where the navigation sits.',
        _Step.details =>
          arabic
              ? 'كيف تظهر المواسم والأفلام فوق الحلقات.'
              : 'How seasons and movies show above the episodes.',
        _Step.player =>
          arabic
              ? 'تحسين الصورة وتخطي المقدمة والخاتمة.'
              : 'Picture upscaling and skipping openings and endings.',
        _Step.account =>
          arabic
              ? 'اختياري: سجّل الدخول لحفظ مكتبتك وسجل مشاهدتك.'
              : 'Optional: sign in to keep your library and history.',
      },
      onBack: _index == 0 ? null : () => setState(() => _index--),
      onNext: isLast ? _finish : () => setState(() => _index++),
      nextLabel: isLast
          ? (arabic ? 'ابدأ المشاهدة' : 'Start watching')
          : (arabic ? 'التالي' : 'Next'),
      children: switch (step) {
        _Step.appearance => [
          _Heading(arabic ? 'الألوان' : 'Colours'),
          _Choices<AppThemeStyle>(
            values: AppThemeStyle.values,
            selected: themeStyle,
            label: (style) => style.label(arabic: arabic),
            swatch: (style) => style.swatch,
            // Applied at once, so the app around the setup changes too.
            onSelected: (style) =>
                ref.read(appThemeStyleProvider.notifier).select(style),
          ),
          // Phones have no layout to choose: the bar and the side menu.
          if (_isDesktop) ...[
            _Heading(arabic ? 'شكل التطبيق' : 'App layout'),
            for (final style in appLayoutChoices(wide: true))
              _OptionTile(
                selected: style == _effectiveLayout,
                icon: switch (style) {
                  AppLayoutStyle.dock => Icons.call_to_action_rounded,
                  AppLayoutStyle.sideRail => Icons.view_sidebar_rounded,
                  AppLayoutStyle.topBar => Icons.web_asset_rounded,
                },
                title: style.label(arabic: arabic),
                subtitle: style.description(arabic: arabic),
                onTap: () => setState(() => _layout = style),
              ),
          ],
          // One compact row rather than two tiles: the step already holds
          // the colours and the layouts, and must still fit with its Next.
          // Its own Material, so the row's ink shows over the panel.
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              key: const ValueKey<String>('setup-manga-own-tab'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              secondary: const Icon(Icons.menu_book_rounded),
              title: Text(
                arabic ? 'قسم خاص للمانجا في الشريط' : 'Manga as its own tab',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                arabic
                    ? 'وإلا تبقى فصولها الجديدة في الرئيسية مع الأنمي.'
                    : 'Otherwise its new chapters stay on home with anime.',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
              ),
              value: _mangaTab,
              onChanged: (value) => setState(() => _mangaTab = value),
            ),
          ),
        ],
        _Step.details => [
          for (final style in SeasonsBarStyle.values)
            _OptionTile(
              selected: style == _seasons,
              icon: switch (style) {
                SeasonsBarStyle.cards => Icons.photo_library_rounded,
                SeasonsBarStyle.pills => Icons.smart_button_rounded,
              },
              title: style.label(arabic: arabic),
              subtitle: switch (style) {
                SeasonsBarStyle.cards =>
                  arabic
                      ? 'بطاقة بصورة لكل موسم وفيلم.'
                      : 'A picture card for each season and movie.',
                SeasonsBarStyle.pills =>
                  arabic
                      ? 'أزرار صغيرة بالأسماء، تأخذ مساحة أقل.'
                      : 'Small named buttons that take less room.',
              },
              onTap: () => setState(() => _seasons = style),
            ),
        ],
        _Step.player => [
          _SwitchTile(
            value: _anime4k,
            title: arabic
                ? 'Anime4K · تحسين الصورة'
                : 'Anime4K · sharper picture',
            subtitle: arabic
                ? 'يرفع جودة الأنمي أثناء التشغيل. يحتاج كرت شاشة جيد، ويُنزَّل مرة واحدة.'
                : 'Upscales anime as it plays. Needs a capable GPU; downloaded once.',
            onChanged: (value) => setState(() => _anime4k = value),
          ),
          if (_anime4k)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Choices<Anime4kMode>(
                    values: [
                      for (final mode in Anime4kMode.values)
                        if (mode != Anime4kMode.off) mode,
                    ],
                    selected: _mode,
                    label: (mode) => mode.label,
                    onSelected: (mode) => setState(() => _mode = mode),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    anime4kModeHint(context, _mode),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          _SwitchTile(
            value: _skipSegments,
            title: arabic
                ? 'تخطي المقدمة والخاتمة'
                : 'Skip openings and endings',
            subtitle: arabic
                ? 'يظهر زر للتخطي عند بدء المقدمة أو الخاتمة.'
                : 'A skip button appears when an opening or ending starts.',
            onChanged: (value) => setState(() => _skipSegments = value),
          ),
          // The automatic versions only mean something once skipping is on.
          if (_skipSegments) ...[
            _SwitchTile(
              nested: true,
              value: _skipIntro,
              title: arabic
                  ? 'تخطي المقدمة تلقائيًا'
                  : 'Skip openings automatically',
              subtitle: arabic
                  ? 'بدون الضغط على الزر.'
                  : 'Without pressing the button.',
              onChanged: (value) => setState(() => _skipIntro = value),
            ),
            _SwitchTile(
              nested: true,
              value: _skipCredits,
              title: arabic
                  ? 'تخطي الخاتمة تلقائيًا'
                  : 'Skip endings automatically',
              subtitle: arabic
                  ? 'ينتقل مباشرة عند بدء الخاتمة.'
                  : 'Jumps ahead when the ending starts.',
              onChanged: (value) => setState(() => _skipCredits = value),
            ),
          ],
          _Heading(arabic ? 'حلقات الفلر' : 'Filler episodes'),
          _Choices<FillerBehaviour>(
            values: FillerBehaviour.values,
            selected: _filler,
            label: (option) => switch (option) {
              FillerBehaviour.off => arabic ? 'تشغيلها' : 'Play them',
              FillerBehaviour.note =>
                arabic ? 'تنبيه مع زر تخطي' : 'Tell me, with a skip button',
              FillerBehaviour.skip => arabic ? 'تخطيها' : 'Skip them',
            },
            onSelected: (option) => setState(() => _filler = option),
          ),
          Text(
            switch (_filler) {
              FillerBehaviour.off =>
                arabic
                    ? 'تُشغّل حلقات الفلر كغيرها.'
                    : 'Filler is played like any other episode.',
              FillerBehaviour.note =>
                arabic
                    ? 'تظهر ملاحظة على بطاقة الحلقة التالية مع الانتقال إلى ما بعدها.'
                    : 'The next-episode card says so and offers the one after it.',
              FillerBehaviour.skip =>
                arabic
                    ? 'يستمر التشغيل من حلقة القصة التالية.'
                    : 'Playback carries on at the next story episode.',
            },
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12,
            ),
          ),
        ],
        _Step.account => [
          if (!AnimeWitcherAccountConfig.firebaseConfigured)
            Text(
              key: const ValueKey<String>('setup-account-unavailable'),
              arabic
                  ? 'تسجيل الدخول غير متاح في هذه النسخة من التطبيق: بُنيت بدون مفتاح خدمة الحساب. النسخ من GitHub فيها تسجيل الدخول.'
                  : 'Sign-in is not available in this copy of the app: it was built without the account service key. Builds from GitHub have it.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                height: 1.5,
              ),
            )
          else if (profile != null)
            _OptionTile(
              selected: true,
              icon: Icons.account_circle_rounded,
              title: profile.userName?.trim().isNotEmpty == true
                  ? profile.userName!.trim()
                  : (arabic ? 'تم تسجيل الدخول' : 'Signed in'),
              subtitle: profile.email ?? '',
              onTap: _openSignIn,
            )
          else ...[
            FilledButton.tonalIcon(
              onPressed: _openSignIn,
              icon: const Icon(Icons.login_rounded),
              label: Text(arabic ? 'تسجيل الدخول' : 'Sign in'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            Text(
              arabic
                  ? 'يمكنك التخطي والتسجيل لاحقًا من الإعدادات.'
                  : 'You can skip this and sign in later from settings.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 12,
              ),
            ),
          ],
        ],
      },
    );

    // A phone sees its own home: upright, in the layout it picked.
    final phoneHome = !_isDesktop && step == _Step.appearance;
    final preview = LivePreviewFrame(
      caption: arabic ? 'معاينة مباشرة' : 'Live preview',
      designSize: phoneHome ? LivePreviewFrame.phoneSize : null,
      note: step == _Step.player && _skipSegments && _skipIntro
          ? (arabic
                ? 'مع التخطي التلقائي لا يظهر زر: تبدأ الحلقة بعد المقدمة مباشرة.'
                : 'With automatic skipping there is no button: the episode carries on past the opening.')
          : null,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: KeyedSubtree(
          key: ValueKey(step),
          child: switch (step) {
            _Step.appearance => HomeLayoutPreview(
              layout: _effectiveLayout,
              theme: themeStyle,
              phone: phoneHome,
            ),
            _Step.details => SeasonsBarPagePreview(
              style: _seasons,
              theme: themeStyle,
            ),
            _Step.player => PlayerSettingsPreview(
              anime4k: _anime4k,
              mode: _mode,
              skipSegments: _skipSegments,
              skipIntro: _skipIntro,
              skipCredits: _skipCredits,
            ),
            _Step.account => _AccountPreview(
              arabic: arabic,
              signedIn: profile != null,
            ),
          },
        ),
      ),
    );

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0E0E0D),
        // On a narrow screen the page scrolls; Back and Next stay at its foot.
        bottomNavigationBar: wide
            ? null
            : SafeArea(
                child: Container(
                  color: const Color(0xFF161615),
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
                  child: options.buttons(),
                ),
              ),
        body: SafeArea(
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 400,
                      child: ColoredBox(
                        color: const Color(0xFF161615),
                        child: Column(
                          children: [
                            Expanded(
                              child: SingleChildScrollView(child: options),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
                              child: options.buttons(),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 72, 32, 32),
                        child: preview,
                      ),
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    options,
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: AspectRatio(
                        aspectRatio: phoneHome ? 0.8 : 1.2,
                        child: preview,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

// ── The choices side ─────────────────────────────────────────────────────

class _StepPanel extends StatelessWidget {
  const _StepPanel({
    required this.arabic,
    required this.stepNumber,
    required this.stepCount,
    required this.title,
    required this.description,
    required this.children,
    required this.onBack,
    required this.onNext,
    required this.nextLabel,
  });

  final bool arabic;
  final int stepNumber;
  final int stepCount;
  final String title;
  final String description;
  final List<Widget> children;
  final VoidCallback? onBack;
  final VoidCallback onNext;
  final String nextLabel;

  /// Back and Next, kept apart from the choices so the screen can pin them
  /// to its foot: a long step must never push Next out of sight.
  Widget buttons() {
    return Row(
      children: [
        if (onBack != null) ...[
          OutlinedButton(
            onPressed: onBack,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            child: Text(arabic ? 'رجوع' : 'Back'),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: FilledButton(
            onPressed: onNext,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            child: Text(
              nextLabel,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final muted = Colors.white.withValues(alpha: 0.6);
    return Container(
      color: const Color(0xFF161615),
      padding: const EdgeInsets.fromLTRB(28, 64, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                'AnimeWitcher',
                style: TextStyle(
                  color: accent,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              for (var i = 1; i <= stepCount; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsetsDirectional.only(start: 5),
                  width: i == stepNumber ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i <= stepNumber
                        ? accent
                        : Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 26),
          Text(
            arabic
                ? 'الخطوة $stepNumber من $stepCount'
                : 'Step $stepNumber of $stepCount',
            style: TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: TextStyle(color: muted, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 16),
          for (final child in children) ...[child, const SizedBox(height: 10)],
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A row of pill buttons, one of them chosen.
class _Choices<T> extends StatelessWidget {
  const _Choices({
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.swatch,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) label;
  final ValueChanged<T> onSelected;
  final Color Function(T value)? swatch;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in values)
          ChoiceChip(
            avatar: swatch == null
                ? null
                : Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: swatch!(value),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white38),
                    ),
                  ),
            label: Text(label(value)),
            selected: value == selected,
            onSelected: (_) => onSelected(value),
            showCheckmark: false,
            backgroundColor: const Color(0xFF232322),
            selectedColor: accent,
            labelStyle: TextStyle(
              color: value == selected ? Colors.black : Colors.white,
              fontWeight: FontWeight.w700,
            ),
            side: BorderSide.none,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(99),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          ),
      ],
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    super.key,
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: const Color(0xFF232322),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? accent : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: selected ? accent : Colors.white70),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_circle_rounded, color: accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.value,
    required this.title,
    required this.subtitle,
    required this.onChanged,
    this.nested = false,
  });

  final bool value;
  final String title;
  final String subtitle;
  final ValueChanged<bool> onChanged;

  /// Drawn indented under the switch it depends on.
  final bool nested;

  @override
  Widget build(BuildContext context) {
    final tile = Material(
      color: nested ? const Color(0xFF1C1C1B) : const Color(0xFF232322),
      borderRadius: BorderRadius.circular(14),
      child: SwitchListTile(
        value: value,
        onChanged: onChanged,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 12,
            height: 1.4,
          ),
        ),
      ),
    );
    if (!nested) return tile;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 22),
      child: tile,
    );
  }
}

/// What an account keeps, for the sign-in step.
class _AccountPreview extends StatelessWidget {
  const _AccountPreview({required this.arabic, required this.signedIn});

  final bool arabic;
  final bool signedIn;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final rows = <(IconData, String, String)>[
      (
        Icons.video_library_rounded,
        arabic ? 'مكتبتك وقوائمك' : 'Your library and lists',
        arabic ? 'نفسها على كل أجهزتك.' : 'The same on every device.',
      ),
      (
        Icons.history_rounded,
        arabic ? 'سجل المشاهدة' : 'Watch history',
        arabic
            ? 'تكمل من حيث توقفت، حتى على جهاز آخر.'
            : 'Carry on where you stopped, even on another device.',
      ),
      (
        Icons.forum_rounded,
        arabic ? 'التعليقات والتقييمات' : 'Comments and ratings',
        arabic
            ? 'شارك رأيك في الحلقات والأنميات.'
            : 'Share what you think of episodes and shows.',
      ),
    ];

    return Directionality(
      textDirection: arabic ? TextDirection.rtl : TextDirection.ltr,
      child: Container(
        color: const Color(0xFF141413),
        padding: const EdgeInsets.symmetric(horizontal: 90, vertical: 60),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: 0.15),
              ),
              child: Icon(
                signedIn ? Icons.verified_user_rounded : Icons.person_rounded,
                color: accent,
                size: 52,
              ),
            ),
            const SizedBox(height: 30),
            for (final (icon, title, subtitle) in rows)
              Container(
                margin: const EdgeInsets.only(bottom: 14),
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFF232322),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Icon(icon, color: accent, size: 30),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (signedIn)
                      Icon(Icons.check_circle_rounded, color: accent),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
