import 'package:flutter/material.dart';

class MangaReaderImageActionsSheet extends StatelessWidget {
  const MangaReaderImageActionsSheet({
    super.key,
    required this.isArabic,
    required this.onSetCover,
    required this.onShare,
    required this.onSave,
  });

  final bool isArabic;
  final VoidCallback onSetCover;
  final VoidCallback onShare;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Row(
        children: <Widget>[
          Expanded(
            child: _ReaderImageActionButton(
              icon: Icons.image_outlined,
              label: isArabic ? 'تعيين كغلاف' : 'Set as cover',
              onPressed: onSetCover,
            ),
          ),
          Expanded(
            child: _ReaderImageActionButton(
              icon: Icons.share_outlined,
              label: isArabic ? 'مشاركة' : 'Share',
              onPressed: onShare,
            ),
          ),
          Expanded(
            child: _ReaderImageActionButton(
              icon: Icons.save_outlined,
              label: isArabic ? 'حفظ' : 'Save',
              onPressed: onSave,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReaderImageActionButton extends StatelessWidget {
  const _ReaderImageActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TextButton(
        onPressed: onPressed,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon),
            const SizedBox(height: 6),
            Text(label, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
