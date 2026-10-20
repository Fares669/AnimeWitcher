import '../../../../shared/widgets/glass_dialog.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/navigation/taskbar_destination.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../general_settings_provider.dart';

Future<void> showTaskbarCustomizationDialog(
  BuildContext context,
  WidgetRef ref,
  List<String> currentOrder,
  Set<String> currentHidden,
) async {
  final l10n = AppLocalizations.of(context)!;

  final order = normalizeTaskbarOrder(currentOrder).toList(growable: true);
  final hidden = normalizeHiddenTaskbarItems(currentHidden).toSet();

  await showGlassDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        final viewport = MediaQuery.sizeOf(context);
        final maxHeight = (viewport.height - 120)
            .clamp(160.0, 560.0)
            .toDouble();
        final contentWidth = (viewport.width - 64)
            .clamp(240.0, 520.0)
            .toDouble();

        return AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text('تخصيص شريط المهام'),
          content: SizedBox(
            width: contentWidth,
            height: maxHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'اسحب العناصر لتغيير ترتيبها، وأخفِ ما لا تحتاجه. الإعدادات متاحة من القائمة الجانبية.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: order.length,
                    onReorder: (oldIndex, newIndex) {
                      setState(() {
                        if (newIndex > oldIndex) newIndex -= 1;
                        final item = order.removeAt(oldIndex);
                        order.insert(newIndex, item);
                      });
                    },
                    itemBuilder: (context, index) {
                      final destination = order[index];
                      final visible = !hidden.contains(destination.id);

                      return Card(
                        key: ValueKey(destination.id),
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Icon(destination.icon),
                          title: Text(destination.label(l10n)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: visible,
                                onChanged: (value) {
                                  setState(() {
                                    if (value) {
                                      hidden.remove(destination.id);
                                    } else {
                                      hidden.add(destination.id);
                                    }
                                  });
                                },
                              ),
                              ReorderableDragStartListener(
                                index: index,
                                child: const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Icon(Icons.drag_handle_rounded),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () async {
                await ref
                    .read(generalSettingsProvider.notifier)
                    .setTaskbarPreferences(
                      order.map((destination) => destination.id).toList(),
                      hidden,
                    );
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: Text(l10n.save),
            ),
          ],
        );
      },
    ),
  );
}
