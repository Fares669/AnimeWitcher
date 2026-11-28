/// Dialogs that sit on a blurred page rather than on a flat black scrim.
///
/// The app's surfaces are glass — the taskbar, the menus, the settings panels.
/// Its dialogs were the last plain boxes left: an opaque card over a dimmed
/// screenshot of whatever you were reading. Blurring the page behind them, and
/// letting the card itself be translucent, puts them in the same material as
/// everything they open from.
library;

import 'dart:ui';

import 'package:flutter/material.dart';

/// Shows [builder]'s dialog over a blurred page.
///
/// A drop-in replacement for [showDialog]: same return, same barrier
/// behaviour, so a call site only changes its name.
Future<T?> showGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    // Lighter than the default scrim: the blur is doing the work of
    // separating the dialog from the page, so the dim can stay gentle.
    barrierColor: Colors.black.withValues(alpha: 0.3),
    builder: (context) => BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      child: GlassDialogTheme(child: Builder(builder: builder)),
    ),
  );
}

/// A staged choice: only Apply commits, and first run requires a choice.
Future<void> showGlassPreferencePicker({
  required BuildContext context,
  required bool firstRun,
  required double maxWidth,
  bool scrollable = false,
  required String title,
  required String description,
  required Widget Function(StateSetter setState, double width) buildChoices,
  required VoidCallback onConfirm,
}) {
  return showGlassDialog<void>(
    context: context,
    barrierDismissible: !firstRun,
    builder: (dialogContext) => PopScope(
      canPop: !firstRun,
      child: StatefulBuilder(
        builder: (context, setState) {
          final width = (MediaQuery.sizeOf(context).width - 64)
              .clamp(280.0, maxWidth)
              .toDouble();
          return AlertDialog(
            surfaceTintColor: Colors.transparent,
            scrollable: scrollable,
            title: Text(title),
            content: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  buildChoices(setState, width),
                ],
              ),
            ),
            actions: [
              if (!firstRun)
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('إلغاء'),
                ),
              FilledButton(
                onPressed: () {
                  onConfirm();
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('تطبيق'),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// Makes the dialogs below it translucent, so the blur behind shows through.
///
/// Applied by [showGlassDialog] to whatever it is given, which is why the
/// dialogs themselves need no changes.
class GlassDialogTheme extends StatelessWidget {
  const GlassDialogTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: colors.onSurfaceVariant.withValues(alpha: 0.18)),
    );
    final background = colors.surface.withValues(alpha: 0.72);

    return Theme(
      data: theme.copyWith(
        dialogTheme: theme.dialogTheme.copyWith(
          backgroundColor: background,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shape: shape,
        ),
      ),
      child: child,
    );
  }
}

/// The same material for modal bottom sheets.
///
/// A sheet slides up over the page you were reading; blurring what is behind
/// it keeps that page present without letting it compete with the choice on
/// top of it.
class GlassSheetSurface extends StatelessWidget {
  const GlassSheetSurface({
    super.key,
    required this.child,
    this.showHandle = false,
  });

  final Widget child;

  /// Draws the drag handle inside the glass instead of above it.
  ///
  /// The sheet's own handle sits outside whatever it is given, so the panel
  /// began below it and its top edge drew a line across the sheet — one rule
  /// under the handle and the sheet's own edge above it. Drawing the handle
  /// in here makes the whole thing one surface.
  final bool showHandle;

  static const BorderRadius _radius = BorderRadius.vertical(
    top: Radius.circular(24),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: _radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: 0.72),
            borderRadius: _radius,
          ),
          // The rows inside paint their ink on the nearest Material ancestor.
          // Without one below this box, taps and hovers would splash behind
          // the glass and never be seen.
          child: Material(
            type: MaterialType.transparency,
            child: showHandle
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 6),
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: colors.onSurfaceVariant.withValues(
                              alpha: 0.4,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Flexible(child: child),
                    ],
                  )
                : child,
          ),
        ),
      ),
    );
  }
}
