import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
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
