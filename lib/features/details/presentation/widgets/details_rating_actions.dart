/// Opens the shared rating dialog and saves the user's rating.
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../core/account/account_providers.dart';
import '../../../../core/account/anime3rb_account_service.dart';
import '../../../../core/account/animewitcher_account_models.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/extensions/providers/anime3rb_provider.dart';
import '../../../../core/services/notification_service.dart';
import '../../../../core/storage/anime3rb_library_service.dart';
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
  MultimediaItem? item,
  int initialRating = 0,
}) async {
  if ((ratings.isAnime3rb || item?.provider == Anime3rbProvider.id) &&
      item != null) {
    final a3Account = ref.read(anime3rbAccountServiceProvider);
    if (!a3Account.isSignedIn) {
      _toast(ref, 'سجّل الدخول إلى حساب Anime3rb أولًا للتقييم.');
      return _unchanged;
    }
    if (!ratings.canRate) return _unchanged;
    final selected = await showAnimeRatingDialog(
      context,
      initialRating: initialRating,
    );
    if (selected == null) return _unchanged;
    try {
      final saved = await ref
          .read(anime3rbLibraryServiceProvider)
          .setUserRating(item, selected == 0 ? null : selected);
      return (changed: true, rating: saved);
    } catch (error) {
      _toast(ref, error.toString(), info: false);
      return _unchanged;
    }
  }

  final service = ref.read(animeWitcherAccountServiceProvider);
  if (!service.isSignedIn) {
    _toast(ref, kRateLoginRequiredToast);
    return _unchanged;
  }
  if (!ratings.canRate) return _unchanged;

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
