import 'package:flutter/material.dart';

/// The result of the comment edit dialog: the new text and whether it
/// carries a spoiler.
class CommentEditDraft {
  const CommentEditDraft({required this.text, required this.spoiler});

  final String text;
  final bool spoiler;
}

/// The one edit-comment dialog both comment screens open: a text
/// field with the comment's current text and, unless [isReview], a
/// spoiler checkbox. Resolves null when cancelled or left empty.
Future<CommentEditDraft?> showCommentEditDialog(
  BuildContext context, {
  required String title,
  required String hint,
  required String initialText,
  required bool initialSpoiler,
  required bool isReview,
}) async {
  final controller = TextEditingController(text: initialText);
  var spoiler = isReview ? false : initialSpoiler;
  try {
    return await showDialog<CommentEditDraft>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 7,
                  maxLength: 500,
                  textDirection: TextDirection.rtl,
                  decoration: InputDecoration(
                    hintText: hint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                if (!isReview)
                  CheckboxListTile(
                    value: spoiler,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('يحتوي على حرق'),
                    onChanged: (value) {
                      setDialogState(() => spoiler = value == true);
                    },
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                final text = controller.text.trim();
                if (text.isEmpty) return;
                Navigator.pop(
                  dialogContext,
                  CommentEditDraft(
                    text: text,
                    spoiler: isReview ? false : spoiler,
                  ),
                );
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
  } finally {
    controller.dispose();
  }
}
