/// APK `RepliesAdapter.holder.reply` → `onReplyClicked` mention tagging.
///
/// Official client rules (v1.4.8):
/// - Own reply: do nothing.
/// - Already tagging (`userTagId != null`): toast and do nothing.
/// - Otherwise append `@` + display name + trailing space, caret at end,
///   and store `userTagId = user_id`.
/// - TextWatcher: if the composer no longer contains `@`, clear `userTagId`.
library;

enum AnimeWitcherReplyMentionStatus { applied, alreadyTagged, ownReply }

class AnimeWitcherReplyMentionOutcome {
  const AnimeWitcherReplyMentionOutcome({
    required this.status,
    required this.text,
    this.userTagId,
  });

  final AnimeWitcherReplyMentionStatus status;
  final String text;
  final String? userTagId;
}

/// Result of tapping the mention/reply icon on a reply card.
AnimeWitcherReplyMentionOutcome applyAnimeWitcherReplyMention({
  required String currentText,
  required String? currentUserTagId,
  required String replyUserId,
  required String replyUserName,
  required bool isOwnReply,
}) {
  if (isOwnReply) {
    return AnimeWitcherReplyMentionOutcome(
      status: AnimeWitcherReplyMentionStatus.ownReply,
      text: currentText,
      userTagId: currentUserTagId,
    );
  }
  if (currentUserTagId != null) {
    return AnimeWitcherReplyMentionOutcome(
      status: AnimeWitcherReplyMentionStatus.alreadyTagged,
      text: currentText,
      userTagId: currentUserTagId,
    );
  }
  return AnimeWitcherReplyMentionOutcome(
    status: AnimeWitcherReplyMentionStatus.applied,
    text: '$currentText@$replyUserName ',
    userTagId: replyUserId,
  );
}

/// APK TextWatcher: drop the stored tag when `@` is no longer in the field.
String? animeWitcherReplyUserTagIdAfterTextChange({
  required String text,
  required String? currentUserTagId,
}) {
  if (!text.contains('@')) return null;
  return currentUserTagId;
}

/// Toast copied from APK `لا يمكن اضافة اكثر من تاج`.
String animeWitcherReplyAlreadyTaggedMessage() {
  return 'لا يمكن اضافة اكثر من تاج';
}
