import 'package:flutter/material.dart';

import '../../../core/domain/entity/multimedia_item.dart';

Future<StreamResult?> showStreamSourcePicker(
  BuildContext context,
  List<StreamResult> sources, {
  required bool forDownload,
  String? episodeLabel,
}) {
  final isArabic =
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
  final rows = _buildSourcePickerRows(sources);

  return showModalBottomSheet<StreamResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
              child: Text(
                sourcePickerHeader(episodeLabel, isArabic: isArabic),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  if (row.heading != null) {
                    return _SourceQualityHeader(label: row.heading!);
                  }

                  final source = row.source!;
                  return ListTile(
                    contentPadding: const EdgeInsetsDirectional.only(
                      start: 36,
                      end: 20,
                    ),
                    leading: Icon(
                      forDownload
                          ? Icons.file_download_outlined
                          : Icons.play_circle_outline,
                    ),
                    title: Text(
                      source.source,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(source),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Uses the server-provided episode label as the picker title when available.
/// The generic title remains the safe fallback for non-episode content.
String sourcePickerHeader(String? episodeLabel, {required bool isArabic}) {
  final label = episodeLabel?.trim() ?? '';
  if (label.isNotEmpty) return label;
  return isArabic ? 'اختر المصدر' : 'Choose source';
}

List<_SourcePickerRow> _buildSourcePickerRows(List<StreamResult> sources) {
  final entries = <_SourcePickerEntry>[
    for (var i = 0; i < sources.length; i++)
      _SourcePickerEntry(
        source: sources[i],
        originalIndex: i,
        qualityScore: _qualityScore(sources[i].quality),
        qualityLabel: _qualityLabel(sources[i].quality),
      ),
  ];

  entries.sort((a, b) {
    final qualityCompare = b.qualityScore.compareTo(a.qualityScore);
    if (qualityCompare != 0) return qualityCompare;

    final serverCompare = _serverPriority(a.source.source)
        .compareTo(_serverPriority(b.source.source));
    if (serverCompare != 0) return serverCompare;

    final nameCompare = a.source.source
        .toLowerCase()
        .compareTo(b.source.source.toLowerCase());
    if (nameCompare != 0) return nameCompare;

    return a.originalIndex.compareTo(b.originalIndex);
  });

  final rows = <_SourcePickerRow>[];
  String? currentQuality;
  for (final entry in entries) {
    if (entry.qualityLabel != currentQuality) {
      currentQuality = entry.qualityLabel;
      rows.add(_SourcePickerRow.heading(currentQuality));
    }
    rows.add(_SourcePickerRow.source(entry.source));
  }
  return rows;
}

int _serverPriority(String source) {
  final normalized = source.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (normalized.startsWith('PD') || normalized.contains('PIXELDRAIN')) {
    return 0;
  }
  if (normalized.startsWith('MF') || normalized.contains('MEDIAFIRE')) {
    return 1;
  }
  if (normalized.startsWith('ST') || normalized.contains('STREAMTAPE')) {
    return 2;
  }
  return 10;
}

int _qualityScore(String? quality) {
  final raw = quality?.trim();
  if (raw == null || raw.isEmpty) return -1;

  final lower = raw.toLowerCase();
  final numericMatch = RegExp(r'(\d{3,4})').firstMatch(lower);
  if (numericMatch != null) {
    return int.tryParse(numericMatch.group(1)!) ?? -1;
  }

  if (lower.contains('4k') || lower.contains('uhd')) return 2160;
  if (lower.contains('fhd') || lower.contains('fullhd')) return 1080;
  if (lower == 'hd' || lower.contains('hd')) return 720;
  if (lower.contains('sd')) return 480;
  return -1;
}

String _qualityLabel(String? quality) {
  final score = _qualityScore(quality);
  if (score > 0) return '${score}p';

  final raw = quality?.trim();
  if (raw != null && raw.isNotEmpty) return raw;
  return 'غير معروف';
}

class _SourcePickerEntry {
  final StreamResult source;
  final int originalIndex;
  final int qualityScore;
  final String qualityLabel;

  const _SourcePickerEntry({
    required this.source,
    required this.originalIndex,
    required this.qualityScore,
    required this.qualityLabel,
  });
}

class _SourcePickerRow {
  final String? heading;
  final StreamResult? source;

  const _SourcePickerRow.heading(this.heading) : source = null;
  const _SourcePickerRow.source(this.source) : heading = null;
}

class _SourceQualityHeader extends StatelessWidget {
  final String label;

  const _SourceQualityHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 18, 20, 6),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Text(
          label,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
      ),
    );
  }
}
