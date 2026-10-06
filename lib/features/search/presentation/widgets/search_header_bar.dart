import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../search_domain.dart';
import '../search_provider.dart';
import '../search_text_direction.dart';
import '../../../../shared/widgets/loading_indicator.dart';
import '../../../../shared/widgets/apple_liquid_glass.dart';
import '../../../../shared/widgets/app_search_field.dart';
import 'search_action_buttons.dart';
import 'search_glass_surface.dart';

import 'package:animewitcher/core/utils/window_controls_inset.dart';
import 'package:animewitcher/core/utils/localized_text.dart';

/// Redesigned static widescreen/desktop search control bar.
class SearchHeaderBar extends ConsumerStatefulWidget {
  final TextEditingController textController;
  final FocusNode searchFocusNode;
  final FocusNode clearButtonFocusNode;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<String> onChanged;
  final VoidCallback onShowFilters;
  final ValueChanged<String> onSortSelected;
  final String sortValue;
  final List<AppleNativeMenuItem> sortItems;
  final IconData sortIcon;
  final String sortSystemImage;
  final String sortTooltip;
  final int activeFilterCount;
  final bool isFilterLoading;
  final bool showSort;
  final bool showFilter;
  final bool isCompact;

  const SearchHeaderBar({
    super.key,
    required this.textController,
    required this.searchFocusNode,
    required this.clearButtonFocusNode,
    required this.onSubmitted,
    required this.onChanged,
    required this.onShowFilters,
    required this.onSortSelected,
    required this.sortValue,
    required this.sortItems,
    required this.sortIcon,
    required this.sortSystemImage,
    required this.sortTooltip,
    required this.activeFilterCount,
    required this.isFilterLoading,
    required this.showSort,
    required this.showFilter,
    this.isCompact = false,
  });

  @override
  ConsumerState<SearchHeaderBar> createState() => _SearchHeaderBarState();
}

class _SearchHeaderBarState extends ConsumerState<SearchHeaderBar> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Only whether a search is running: watching the whole results state
    // rebuilt the bar with every page of results that came in.
    final searching = ref.watch(
      searchPagedResultsProvider.select((state) => state.isLoading),
    );
    final isCompact = widget.isCompact;
    final fieldDirection = Directionality.of(context);
    // The same wording the home bar uses, so the two read as one control.
    // Names what is being searched, so a manga search does not read as an
    // anime one.
    final searchHint = searchDomainHint(
      context,
      ref.watch(searchDomainProvider),
    );

    // Keep the row's full two-action width even when one action is hidden.
    // Expanded search then consumes that freed slot (characters have no sort).
    final fullActionWidth = SearchActionButtons.groupWidthForHeight(
      SearchGlassSurface.height,
    );
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 24 + windowControlsSymmetricInset,
      ),
      child: SizedBox(
        height: 56,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isCompact ? 360 : 460 + 12 + fullActionWidth,
            ),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Row(
                children: [
                  Expanded(
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: widget.textController,
                      builder: (context, value, child) {
                        Widget? suffix;
                        if (searching) {
                          suffix = Padding(
                            padding: const EdgeInsets.all(12),
                            child: AppLoadingIndicator(
                              color: theme.colorScheme.primary,
                              constraints: BoxConstraints.tight(
                                const Size(18, 18),
                              ),
                            ),
                          );
                        } else if (value.text.isNotEmpty) {
                          suffix = IconButton(
                            focusNode: widget.clearButtonFocusNode,
                            tooltip: appText(
                              context,
                              english: 'Clear',
                              arabic: 'مسح',
                            ),
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () {
                              widget.textController.clear();
                              ref
                                  .read(
                                    searchSuggestionControllerProvider.notifier,
                                  )
                                  .clear();
                              ref.read(searchQueryProvider.notifier).set('');
                              widget.searchFocusNode.requestFocus();
                            },
                          );
                        }

                        return AppSearchField(
                          controller: widget.textController,
                          focusNode: widget.searchFocusNode,
                          hintText: searchHint,
                          textDirection: searchTextDirection(
                            value.text,
                            fallback: fieldDirection,
                          ),
                          onChanged: widget.onChanged,
                          onSubmitted: widget.onSubmitted,
                          suffixIcon: suffix,
                        );
                      },
                    ),
                  ),
                  if (!isCompact) ...[
                    const SizedBox(width: 4),
                    SearchActionButtons(
                      showSort: widget.showSort,
                      showFilter: widget.showFilter,
                      filterCount: widget.showFilter
                          ? widget.activeFilterCount
                          : 0,
                      isFilterLoading: widget.isFilterLoading,
                      sortValue: widget.sortValue,
                      sortItems: widget.sortItems,
                      onSortSelected: widget.onSortSelected,
                      sortIcon: widget.sortIcon,
                      sortSystemImage: widget.sortSystemImage,
                      sortTooltip: widget.sortTooltip,
                      filterTooltip: appText(
                        context,
                        english: 'Filters',
                        arabic: 'الفلاتر',
                      ),
                      onFilterPressed: widget.onShowFilters,
                      // Match the library filter's theme accent.
                      tintColor: theme.colorScheme.primary,
                      height: SearchGlassSurface.height,
                    ),
                    SizedBox(
                      // Details pins its native toolbar 34pt inside the iOS
                      // safe-area trailing edge. Search is an inline platform
                      // view, so include that same safe-area inset explicitly.
                      width: appleUsesPersistentLiquidGlassHeader
                          ? 10 + MediaQuery.paddingOf(context).right
                          : 8,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
