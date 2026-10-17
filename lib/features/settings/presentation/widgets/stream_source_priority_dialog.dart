import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/stream_source_preferences.dart';
import '../../../../core/utils/localized_text.dart';
import '../../../../shared/widgets/glass_dialog.dart';
import '../general_settings_provider.dart';

Future<void> showStreamServerPriorityDialog(
  BuildContext context,
  WidgetRef ref,
  List<String> current,
) {
  return _showStreamPriorityDialog(
    context,
    title: appText(
      context,
      english: 'Server priority',
      arabic: 'أولوية السيرفرات',
    ),
    current: normalizeStreamPriority(current, defaultStreamServerPriority),
    onSave: (order) => ref
        .read(generalSettingsProvider.notifier)
        .setStreamServerPriority(order),
  );
}

Future<void> showStreamQualityPriorityDialog(
  BuildContext context,
  WidgetRef ref,
  List<String> current,
) {
  return _showStreamPriorityDialog(
    context,
    title: appText(
      context,
      english: 'Quality priority',
      arabic: 'أولوية الجودة',
    ),
    current: normalizeStreamPriority(current, defaultStreamQualityPriority),
    onSave: (order) => ref
        .read(generalSettingsProvider.notifier)
        .setStreamQualityPriority(order),
  );
}

Future<void> _showStreamPriorityDialog(
  BuildContext context, {
  required String title,
  required List<String> current,
  required Future<void> Function(List<String>) onSave,
}) async {
  final order = List<String>.of(current);

  await showGlassDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        final viewport = MediaQuery.sizeOf(context);
        return AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(title),
          content: SizedBox(
            width: (viewport.width - 64).clamp(240.0, 480.0).toDouble(),
            height: (viewport.height - 180).clamp(180.0, 460.0).toDouble(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'اسحب لترتيب الأولوية من الأعلى إلى الأسفل.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: order.length,
                    onReorder: (oldIndex, newIndex) {
                      setState(() {
                        if (newIndex > oldIndex) newIndex -= 1;
                        final value = order.removeAt(oldIndex);
                        order.insert(newIndex, value);
                      });
                    },
                    itemBuilder: (context, index) => Card(
                      key: ValueKey<String>('stream-priority-${order[index]}'),
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        title: Text(order[index]),
                        trailing: ReorderableDragStartListener(
                          index: index,
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.drag_handle_rounded),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () async {
                await onSave(order);
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              },
              child: Text('حفظ'),
            ),
          ],
        );
      },
    ),
  );
}
