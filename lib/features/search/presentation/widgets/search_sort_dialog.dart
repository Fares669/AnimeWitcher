import 'package:flutter/material.dart';

import '../../../../shared/widgets/apple_liquid_glass.dart';

import '../../../../core/utils/localized_text.dart';

enum SearchSortOption {
  mostFavorited('favorites'),
  productionDateAscending('year_asc'),
  productionDateDescending('year_desc'),
  nameAscending('name_asc'),
  nameDescending('name_desc');

  const SearchSortOption(this.value);

  final String value;

  static SearchSortOption fromValue(String value) {
    return SearchSortOption.values.firstWhere(
      (option) => option.value == value.trim().toLowerCase(),
      orElse: () => SearchSortOption.mostFavorited,
    );
  }

  String label(BuildContext context) {
    switch (this) {
      case SearchSortOption.mostFavorited:
        return appText(
          context,
          english: 'Most favorited',
          arabic: 'الأكثر تفضيلًا',
        );
      case SearchSortOption.productionDateAscending:
        return appText(
          context,
          english: 'Production date (ascending)',
          arabic: 'تاريخ الإنتاج (تصاعدي)',
        );
      case SearchSortOption.productionDateDescending:
        return appText(
          context,
          english: 'Production date (descending)',
          arabic: 'تاريخ الإنتاج (تنازلي)',
        );
      case SearchSortOption.nameAscending:
        return appText(
          context,
          english: 'Name (A → Z)',
          arabic: 'الاسم من أ إلى ي',
        );
      case SearchSortOption.nameDescending:
        return appText(
          context,
          english: 'Name (Z → A)',
          arabic: 'الاسم من ي إلى أ',
        );
    }
  }
}

class SearchSortDialog extends StatefulWidget {
  const SearchSortDialog({super.key, required this.initialValue});

  final String initialValue;

  @override
  State<SearchSortDialog> createState() => _SearchSortDialogState();
}

class _SearchSortDialogState extends State<SearchSortDialog> {
  late SearchSortOption _selected;

  @override
  void initState() {
    super.initState();
    _selected = SearchSortOption.fromValue(widget.initialValue);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    final radius = BorderRadius.circular(30);

    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 56),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
        child: AppleLiquidGlassSurface(
          borderRadius: radius,
          style: 'regular',
          interactive: true,
          fallbackColor: colors.surfaceContainerHigh.withValues(alpha: 0.96),
          fallbackBorder: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.34),
          ),
          child: Material(
            color: Colors.transparent,
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
                    child: Row(
                      children: [
                        Icon(
                          Icons.sort_rounded,
                          color: colors.primary,
                          size: 28,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            appText(
                              context,
                              english: 'Sort by',
                              arabic: 'الترتيب حسب',
                            ),
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: appText(
                            context,
                            english: 'Close',
                            arabic: 'إغلاق',
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: colors.outlineVariant.withValues(alpha: 0.42),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: RadioGroup<SearchSortOption>(
                        groupValue: _selected,
                        onChanged: (value) {
                          if (value != null) setState(() => _selected = value);
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final option in SearchSortOption.values)
                              RadioListTile<SearchSortOption>(
                                value: option,
                                title: Text(
                                  option.label(context),
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                activeColor: colors.primary,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: colors.outlineVariant.withValues(alpha: 0.42),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(
                            appText(
                              context,
                              english: 'Cancel',
                              arabic: 'إلغاء',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton(
                          onPressed: () =>
                              Navigator.of(context).pop(_selected.value),
                          child: Text(
                            appText(context, english: 'Apply', arabic: 'تطبيق'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
