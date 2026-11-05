import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';

import 'dart:async';

import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart'
    show AnimeRiftSecureStorageUnavailable;
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/storage/anime_rift_auto_sync.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
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
                                  if (provider is AnimeRiftProvider) {
                                    unawaited(
                                      ref
                                          .read(riftAutoSyncProvider)
                                          .refresh()
                                          .catchError((Object _) {
                                            // The local lists remain usable
                                            // while Rift is offline.
                                          }),
                                    );
                                  }
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

class _AnimeRiftAccountTile extends ConsumerStatefulWidget {
  const _AnimeRiftAccountTile({required this.provider});

  final AnimeRiftProvider provider;

  @override
  ConsumerState<_AnimeRiftAccountTile> createState() =>
      _AnimeRiftAccountTileState();
}

class _AnimeRiftAccountTileState extends ConsumerState<_AnimeRiftAccountTile> {
  late Future<bool> _status;

  @override
  void initState() {
    super.initState();
    _status = _restoreAndRefresh();
  }

  Future<bool> _restoreAndRefresh() async {
    final previousScope = AnimeRiftLocalAccountScope.accountHash;
    final linked = await widget.provider.restoreAccountSession();
    if (mounted && previousScope != AnimeRiftLocalAccountScope.accountHash) {
      ref.read(accountDataRevisionProvider.notifier).bump();
    }
    if (linked && mounted) _refreshCloudAutomatically();
    return linked;
  }

  @override
  void didUpdateWidget(covariant _AnimeRiftAccountTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.provider, widget.provider)) {
      _status = _restoreAndRefresh();
    }
  }

  void _reload() {
    setState(() {
      _status = _restoreAndRefresh();
    });
  }

  void _refreshCloudAutomatically() {
    unawaited(
      ref.read(riftAutoSyncProvider).refresh().catchError((Object _) {
        // Offline accounts keep their local data; the coordinator retries on
        // the next startup, local change, or foreground activation.
      }),
    );
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
                      } on AnimeRiftSecureStorageUnavailable {
                        if (dialogContext.mounted) {
                          setDialogState(() {
                            busy = false;
                            error =
                                'تعذر حفظ جلسة Rift في التخزين الآمن. '
                                'تحقق من إعدادات حماية الجهاز ثم أعد المحاولة.';
                          });
                        }
                      } on AnimeRiftAccessUnavailable catch (e) {
                        if (dialogContext.mounted) {
                          setDialogState(() {
                            busy = false;
                            // Only a sanitized stage/HTTP code, never credentials.
                            error = e.toString();
                          });
                        }
                      } catch (_) {
                        if (dialogContext.mounted) {
                          setDialogState(() {
                            busy = false;
                            error =
                                'تعذر ربط الحساب بسبب خطأ غير متوقع. '
                                'تحقق من سجل AnimeRift ثم أعد المحاولة.';
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
      ref.read(accountDataRevisionProvider.notifier).bump();
      setState(() {
        _status = Future<bool>.value(true);
      });
      _refreshCloudAutomatically();
    }
  }

  Future<void> _confirmSignOut() async {
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إلغاء ربط حساب Anime Rift؟'),
        content: const Text(
          'يمكنك تبديل حساب Rift برمز من حساب آخر أو إلغاء الربط. '
          'ستظهر مكتبة Rift المحلية الخاصة بالحساب المختار، '
          'وتبقى بيانات AnimeWitcher مستقلة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('رجوع'),
          ),
          TextButton(
            key: const ValueKey('animerift-account-switch'),
            onPressed: () => Navigator.of(dialogContext).pop('switch'),
            child: const Text('تبديل الحساب'),
          ),
          FilledButton(
            key: const ValueKey('animerift-account-signout-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop('unlink'),
            child: const Text('إلغاء الربط'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'switch') {
      await _showSignIn();
    } else if (action == 'unlink') {
      setState(() {
        _status = widget.provider.signOut().then((_) {
          if (mounted) ref.read(accountDataRevisionProvider.notifier).bump();
          return false;
        });
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
        final identity = linked ? widget.provider.accountIdentity : null;
        final accountTile = SettingsTile(
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
              : linked && identity?.displayName != null
              ? appText(
                  context,
                  english:
                      'Connected as ${identity!.displayName} · automatic cloud import',
                  arabic:
                      'متصل باسم ${identity.displayName} · استيراد سحابي تلقائي',
                )
              : linked && identity?.isVerified == true
              ? appText(
                  context,
                  english:
                      'Connected: ${identity!.id} · automatic cloud import',
                  arabic: 'الحساب: ${identity.id} · استيراد سحابي تلقائي',
                )
              : linked
              ? appText(
                  context,
                  english:
                      'Linked for protected Rift access · automatic import',
                  arabic: 'مربوط للوصول المحمي إلى Rift · استيراد تلقائي',
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
        return accountTile;
      },
    );
  }
}
