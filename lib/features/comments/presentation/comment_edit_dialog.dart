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
}) => showDialog<CommentEditDraft>(
  context: context,
  builder: (_) => _CommentEditDialog(
    title: title,
    hint: hint,
    initialText: initialText,
    initialSpoiler: initialSpoiler,
    isReview: isReview,
  ),
);

class _CommentEditDialog extends StatefulWidget {
  const _CommentEditDialog({
    required this.title,
    required this.hint,
    required this.initialText,
    required this.initialSpoiler,
    required this.isReview,
  });

  final String title;
  final String hint;
  final String initialText;
  final bool initialSpoiler;
  final bool isReview;

  @override
  State<_CommentEditDialog> createState() => _CommentEditDialogState();
}

class _CommentEditDialogState extends State<_CommentEditDialog> {
  late final _controller = TextEditingController(text: widget.initialText);
  late bool _spoiler = !widget.isReview && widget.initialSpoiler;

  @override
  void dispose() {
    // The route result can resolve before the reverse transition finishes.
    // Keep the controller alive for as long as the dialog's field is mounted.
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.pop(
      context,
      CommentEditDraft(text: text, spoiler: !widget.isReview && _spoiler),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 3,
            maxLines: 7,
            maxLength: 500,
            textDirection: TextDirection.rtl,
            decoration: InputDecoration(
              hintText: widget.hint,
              border: const OutlineInputBorder(),
            ),
          ),
          if (!widget.isReview)
            CheckboxListTile(
              value: _spoiler,
              contentPadding: EdgeInsets.zero,
              title: const Text('يحتوي على حرق'),
              onChanged: (value) => setState(() => _spoiler = value == true),
            ),
        ],
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
      FilledButton(onPressed: _save, child: const Text('حفظ')),
    ],
  );
}
