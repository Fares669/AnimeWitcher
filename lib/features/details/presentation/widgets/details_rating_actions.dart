/// Rating an anime and reading its reviews, as two actions any part of the
/// details page can offer.
///
/// The panel further down the page has carried both since it was the only
/// place that offered them. The hero row offers them too now, and a second
/// copy of "check the account, ask, save, and say what went wrong" is exactly
/// the kind of thing that drifts apart, so both call these.
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../core/account/account_providers.dart';
import '../../../../core/account/animewitcher_account_models.dart';
import '../../../../core/account/animewitcher_comment_models.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/services/notification_service.dart';
import '../../../comments/presentation/animewitcher_comments_screen.dart';
import '../details_ratings.dart';
import 'scale_rating_bar.dart';

const String kRateLoginRequiredToast = 'يجب تسجيل الدخول';
const String kReviewsClosedToast = 'تم ايقاف المراجعات علي هذا الأنمي';

/// What came back from the rating dialog.
///
/// [changed] separates "left it as it was" from "cleared it", which a bare
/// nullable rating cannot say.
typedef AnimeRatingOutcome = ({bool changed, int? rating});

const AnimeRatingOutcome _unchanged = (changed: false, rating: null);

void _toast(WidgetRef ref, String message, {bool info = true}) {
  final notifications = ref.read(notificationServiceProvider);
  if (info) {
    notifications.showInfo(message);
  } else {
    notifications.showError(message);
  }
}

/// Asks for a rating and records it.
///
/// Returns what is on record afterwards, so a caller showing the score can
/// keep its own copy in step.
Future<AnimeRatingOutcome> openAnimeRatingDialog(
  BuildContext context,
  WidgetRef ref, {
  required AnimeDetailsRatings ratings,
  int initialRating = 0,
}) async {
  if (!ratings.canRate) return _unchanged;
  final service = ref.read(animeWitcherAccountServiceProvider);
  if (!service.isSignedIn) {
    _toast(ref, kRateLoginRequiredToast);
    return _unchanged;
  }
  final selected = await showAnimeRatingDialog(
    context,
    initialRating: initialRating,
  );
  if (selected == null) return _unchanged;

  try {
    if (selected == 0) {
      await service.clearAnimeUserRating(ratings.animeId);
      return (changed: true, rating: null);
    }
    final saved = await service.saveAnimeUserRating(ratings.animeId, selected);
    return (changed: true, rating: saved);
  } catch (error) {
    if (error is AnimeWitcherAccountException &&
        error.code == 'not-signed-in') {
      _toast(ref, kRateLoginRequiredToast);
    } else {
      _toast(ref, 'تعذر حفظ التقييم', info: false);
    }
    return _unchanged;
  }
}

/// Opens the reviews for [item], unless they are closed.
///
/// The details payload says whether they are, and the account service is
/// asked again in case that has changed since the page loaded; if it cannot
/// be reached, the flag that came with the page stands.
Future<void> openAnimeReviews(
  BuildContext context,
  WidgetRef ref, {
  required MultimediaItem item,
  required AnimeDetailsRatings ratings,
}) async {
  final target = animeWitcherAnimeReviewTarget(item);
  if (target == null) return;
  if (ratings.reviewsClosed) {
    _toast(ref, kReviewsClosedToast);
    return;
  }

  final service = ref.read(animeWitcherAccountServiceProvider);
  if (service.isSignedIn && target.animeId?.isNotEmpty == true) {
    try {
      final closed = await service.isAnimeReviewsClosed(target.animeId!);
      if (!context.mounted) return;
      if (closed) {
        _toast(ref, kReviewsClosedToast);
        return;
      }
    } catch (_) {
      // Keep the local details flag as the fallback.
    }
  }

  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AnimeWitcherCommentsScreen(target: target),
    ),
  );
}

/// The dialog itself: ten stars, and clearing by choosing none.
Future<int?> showAnimeRatingDialog(
  BuildContext context, {
  required int initialRating,
}) {
  var rating = initialRating.clamp(0, 10);
  return showDialog<int>(
    context: context,
    // Nothing behind it is worth hiding, and a solid panel over the artwork
    // read as a plain grey box dropped on the page. The blur is what every
    // other surface in the app is made of.
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final colors = Theme.of(context).colorScheme;
          return AlertDialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            contentPadding: EdgeInsets.zero,
            titlePadding: EdgeInsets.zero,
            actionsPadding: EdgeInsets.zero,
            content: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest.withValues(
                      alpha: 0.55,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: colors.onSurfaceVariant.withValues(alpha: 0.14),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                    child: _ratingDialogBody(
                      context,
                      rating: rating,
                      initialRating: initialRating,
                      dialogContext: dialogContext,
                      onChanged: (value) =>
                          setDialogState(() => rating = value),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

Widget _ratingDialogBody(
  BuildContext context, {
  required int rating,
  required int initialRating,
  required BuildContext dialogContext,
  required ValueChanged<int> onChanged,
}) {
  // A width to aim for, not one to insist on: a narrow window would
  // otherwise be handed a 420px row of buttons and overflow it.
  return ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 420),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'قيّم',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Text(
          '$rating /10',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: ScaleRatingBar(
            rating: rating,
            starSize: 30,
            onChanged: onChanged,
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 4,
          runSpacing: 4,
          children: [
            if (initialRating > 0)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, 0),
                child: const Text('مسح التقييم'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: rating <= 0
                  ? null
                  : () => Navigator.pop(dialogContext, rating),
              child: const Text('تأكيد'),
            ),
          ],
        ),
      ],
    ),
  );
}
