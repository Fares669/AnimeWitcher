import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'downloads_provider.dart';

Future<void> confirmAndRemoveDownload(
  BuildContext context,
  WidgetRef ref,
  DownloadItem item,
) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.deleteDownload),
      content: Text(l10n.confirmDeleteDownload),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(
            l10n.delete,
            style: const TextStyle(color: Colors.red),
          ),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await ref.read(downloadsProvider.notifier).removeDownload(item);
  }
}
