import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/utils/localized_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_widgets.dart';

/// Only registered providers that support anime can appear in this picker.
class AnimeProviderSettingsTile extends ConsumerWidget {
  const AnimeProviderSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final animeProviders = ref
        .watch(extensionManagerProvider)
        .where(
          (provider) => provider.supportedTypes.contains(ProviderType.anime),
        )
        .toList(growable: false);
    final active = ref.watch(activeProviderProvider);
    final selected = animeProviders.where(
      (provider) => provider.packageName == active?.packageName,
    );
    final title = appText(
      context,
      english: 'Anime provider',
      arabic: 'مزود الأنمي',
    );

    return SettingsTile(
      key: const ValueKey('settings-anime-provider'),
      icon: Icons.live_tv_rounded,
      title: title,
      subtitle: selected.isNotEmpty
          ? selected.first.name
          : appText(
              context,
              english: 'No anime provider available',
              arabic: 'لا يوجد مزود أنمي متاح',
            ),
      onTap: animeProviders.isEmpty
          ? null
          : () => showDialog<void>(
              context: context,
              builder: (dialogContext) => Consumer(
                builder: (context, ref, _) {
                  final currentId = ref
                      .watch(activeProviderProvider)
                      ?.packageName;
                  return AlertDialog(
                    title: Text(title),
                    content: SizedBox(
                      width: 360,
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final provider in animeProviders)
                            ListTile(
                              key: ValueKey(
                                'anime-provider-option-${provider.packageName}',
                              ),
                              title: Text(provider.name),
                              trailing: currentId == provider.packageName
                                  ? Icon(
                                      Icons.check_rounded,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                    )
                                  : null,
                              onTap: () async {
                                if (currentId != provider.packageName) {
                                  await ref
                                      .read(activeProviderProvider.notifier)
                                      .set(provider);
                                }
                                if (dialogContext.mounted) {
                                  Navigator.of(dialogContext).pop();
                                }
                              },
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

/// Optional Rift account access for protected streams and downloads. This is
/// deliberately separate from the AnimeWitcher account and provider choice.
class AnimeRiftAccountSettingsTile extends ConsumerWidget {
  const AnimeRiftAccountSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AnimeRiftProvider? rift;
    for (final provider in ref.watch(extensionManagerProvider)) {
      if (provider is AnimeRiftProvider) {
        rift = provider;
        break;
      }
    }
    return rift == null
        ? const SizedBox.shrink()
        : _AnimeRiftAccountTile(provider: rift);
  }
}

class _AnimeRiftAccountTile extends StatefulWidget {
  const _AnimeRiftAccountTile({required this.provider});

  final AnimeRiftProvider provider;

  @override
  State<_AnimeRiftAccountTile> createState() => _AnimeRiftAccountTileState();
}

class _AnimeRiftAccountTileState extends State<_AnimeRiftAccountTile> {
  late Future<bool> _status = widget.provider.restoreAccountSession();

  @override
  void didUpdateWidget(covariant _AnimeRiftAccountTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.provider, widget.provider)) {
      _status = widget.provider.restoreAccountSession();
    }
  }

  void _reload() {
    setState(() {
      _status = widget.provider.restoreAccountSession();
    });
  }

  Future<void> _showSignIn() async {
    var code = '';
    var busy = false;
    String? error;
    final linked = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('ربط حساب Anime Rift'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'أنشئ رمز تسجيل دخول من تطبيق Anime Rift الرسمي على جهاز '
                  'مسجل، ثم أدخله هنا. مكتبتك في AnimeWitcher تبقى مستقلة.',
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('animerift-code-field'),
                  autofocus: true,
                  maxLength: 256,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  onChanged: (value) => code = value,
                  decoration: const InputDecoration(
                    labelText: 'رمز تسجيل الدخول',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy
                  ? null
                  : () => Navigator.of(dialogContext).pop(false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              key: const ValueKey('animerift-account-submit'),
              onPressed: busy
                  ? null
                  : () async {
                      final value = code.trim();
                      if (value.isEmpty) {
                        setDialogState(
                          () =>
                              error = 'أدخل رمزًا صادرًا من تطبيق Anime Rift.',
                        );
                        return;
                      }
                      setDialogState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await widget.provider.signInWithCode(value);
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop(true);
                        }
                      } catch (_) {
                        if (dialogContext.mounted) {
                          setDialogState(() {
                            busy = false;
                            error =
                                'تعذر ربط الحساب. تحقق من الرمز واتصال الشبكة '
                                'ثم أعد المحاولة.';
                          });
                        }
                      }
                    },
              child: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('ربط الحساب'),
            ),
          ],
        ),
      ),
    );
    if (linked == true && mounted) {
      setState(() {
        _status = Future<bool>.value(true);
      });
    }
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إلغاء ربط حساب Anime Rift؟'),
        content: const Text(
          'سيعود الوصول المحمي والتنزيل إلى وضع الضيف. لن تُحذف مكتبة '
          'Anime Rift المحلية أو تنزيلاتك أو حساب AnimeWitcher.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('رجوع'),
          ),
          FilledButton(
            key: const ValueKey('animerift-account-signout-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('إلغاء الربط'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() {
        _status = widget.provider.signOut().then((_) => false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _status,
      builder: (context, snapshot) {
        final waiting = snapshot.connectionState == ConnectionState.waiting;
        final failed = snapshot.hasError;
        final linked = snapshot.data == true;
        return SettingsTile(
          key: const ValueKey('settings-animerift-account'),
          icon: linked ? Icons.link_rounded : Icons.link_off_rounded,
          title: appText(
            context,
            english: 'Anime Rift account access',
            arabic: 'وصول حساب Anime Rift',
          ),
          subtitle: waiting
              ? appText(
                  context,
                  english: 'Checking secure session…',
                  arabic: 'جارٍ التحقق من الجلسة الآمنة…',
                )
              : failed
              ? appText(
                  context,
                  english: 'Secure session unavailable — tap to retry',
                  arabic: 'تعذر قراءة الجلسة الآمنة — اضغط لإعادة المحاولة',
                )
              : linked
              ? appText(
                  context,
                  english: 'Linked for protected Rift playback and downloads',
                  arabic: 'مربوط للتشغيل والتنزيل المحمي من Rift',
                )
              : appText(
                  context,
                  english: 'Not linked — public browsing remains available',
                  arabic: 'غير مربوط — التصفح العام يبقى متاحًا',
                ),
          onTap: waiting
              ? null
              : failed
              ? _reload
              : linked
              ? _confirmSignOut
              : _showSignIn,
        );
      },
    );
  }
}
