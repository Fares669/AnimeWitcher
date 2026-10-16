import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/device_info_provider.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/window_controls_inset.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'widgets/downloads_tab.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final isTv = profile?.isTv == true || context.isTv;
    final isWidescreen = isTv || context.isTabletOrLarger;
    final title = AppLocalizations.of(context)!.downloads;

    final titleDirection = TextDirection.rtl;
    final titleAlignment = Alignment.centerRight;

    if (isWidescreen) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                height: LayoutConstants.dashboardHeaderHeight,
                // Clear of the window's caption buttons, which are painted
                // over the same corner the title sits in.
                padding: EdgeInsets.only(
                  left: LayoutConstants.dashboardContentPadding,
                  right:
                      LayoutConstants.dashboardContentPadding +
                      windowControlsTrailingInset,
                ),
                alignment: titleAlignment,
                child: Directionality(
                  textDirection: titleDirection,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
            const Expanded(child: DownloadsTab()),
          ],
        ),
      );
    }

    // On handsets the tab strip is the page header. Avoid repeating
    // "Downloads" in a separate AppBar and keep the two tabs immediately
    // below the system safe area.
    return Scaffold(body: SafeArea(bottom: false, child: const DownloadsTab()));
  }
}
