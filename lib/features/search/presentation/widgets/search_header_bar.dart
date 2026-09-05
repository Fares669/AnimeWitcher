import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import '../search_provider.dart';
import '../search_text_direction.dart';
import '../../../../shared/widgets/loading_indicator.dart';
import '../../../../shared/widgets/apple_liquid_glass.dart';
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
    this.isCompact = false,
  });

  @override
  ConsumerState<SearchHeaderBar> createState() => _SearchHeaderBarState();
}

class _SearchHeaderBarState extends ConsumerState<SearchHeaderBar> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final searchResultsAsync = ref.watch(searchResultsProvider);
    final isCompact = widget.isCompact;
    final isDark = theme.brightness == Brightness.dark;
    // The same wording the home bar uses, so the two read as one control.
    final searchHint = l10n.searchHint;

    final actionWidth = SearchActionButtons.groupWidthForHeight(
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
              maxWidth: isCompact ? 360 : 460 + 12 + actionWidth,
            ),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => widget.searchFocusNode.requestFocus(),
                      child: SearchGlassSurface(
                        child: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: widget.textController,
                          builder: (context, value, child) {
                            final isSearching = searchResultsAsync.maybeWhen(
                              data: (state) => state.isLoading,
                              loading: () => true,
                              orElse: () => false,
                            );

                            // Empty and idle, the field carries the same keyboard
                            // hint the home bar shows, so the two read as one control.
                            Widget? suffix = Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Center(
                                widthFactor: 1,
                                child: Container(
                                  width: 22,
                                  height: 22,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surfaceContainerHighest
                                        .withValues(alpha: 0.7),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: theme.colorScheme.onSurfaceVariant
                                          .withValues(alpha: 0.18),
                                    ),
                                  ),
                                  child: Text(
                                    '/',
                                    style: TextStyle(
                                      fontSize: 12,
                                      height: 1,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            );
                            if (isSearching) {
                              suffix = Padding(
                                padding: const EdgeInsets.all(14),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: AppLoadingIndicator(
                                    color: theme.colorScheme.primary,
                                    constraints: BoxConstraints.tight(
                                      const Size(20, 20),
                                    ),
                                  ),
                                ),
                              );
                            } else if (value.text.isNotEmpty) {
                              suffix = AnimatedBuilder(
                                animation: widget.clearButtonFocusNode,
                                builder: (context, child) {
                                  final isFocused =
                                      widget.clearButtonFocusNode.hasFocus;
                                  return IconButton(
                                    focusNode: widget.clearButtonFocusNode,
                                    icon: Icon(
                                      Icons.clear_rounded,
                                      size: 18,
                                      color: isFocused
                                          ? theme.colorScheme.primary
                                          : (isDark
                                                ? Colors.white70
                                                : theme.colorScheme.onSurfaceVariant),
                                    ),
                                    style: IconButton.styleFrom(
                                      backgroundColor: isFocused
                                          ? theme.colorScheme.primary.withValues(
                                              alpha: 0.15,
                                            )
                                          : Colors.transparent,
                                      minimumSize: const Size(32, 32),
                                      padding: EdgeInsets.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () {
                                      widget.textController.clear();
                                      ref
                                          .read(
                                            searchSuggestionControllerProvider
                                                .notifier,
                                          )
                                          .clear();
                                      ref.read(searchQueryProvider.notifier).set('');
                                      widget.searchFocusNode.requestFocus();
                                    },
                                  );
                                },
                              );
                            }

                            // The field reads left-to-right in every locale: magnifier
                            // on the left, hint and caret starting there.
                            return Directionality(
                              textDirection: TextDirection.ltr,
                              child: TextField(
                                controller: widget.textController,
                                focusNode: widget.searchFocusNode,
                                autofocus: false,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: theme.colorScheme.onSurface,
                                ),
                                textDirection: searchTextDirection(
                                  value.text,
                                  fallback: TextDirection.ltr,
                                ),
                                textAlign: TextAlign.start,
                                textAlignVertical: TextAlignVertical.center,
                                textInputAction: TextInputAction.search,
                                enableInteractiveSelection: true,
                                contextMenuBuilder: (context, editableTextState) {
                                  return AdaptiveTextSelectionToolbar.buttonItems(
                                    anchors: editableTextState.contextMenuAnchors,
                                    buttonItems:
                                        editableTextState.contextMenuButtonItems,
                                  );
                                },
                                onChanged: widget.onChanged,
                                onSubmitted: widget.onSubmitted,
                                decoration: InputDecoration(
                                  hintText: searchHint,
                                  border: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  filled: false,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 0,
                                  ),
                                  hintStyle: TextStyle(
                                    fontSize: 13,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  prefixIcon: Icon(
                                    Icons.search_rounded,
                                    size: 18,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  prefixIconConstraints: const BoxConstraints(
                                    minWidth: 42,
                                    minHeight: SearchGlassSurface.height,
                                  ),
                                  suffixIcon: suffix,
                                  suffixIconConstraints: const BoxConstraints(
                                    minWidth: 46,
                                    minHeight: SearchGlassSurface.height,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  if (!isCompact) ...[
                    const SizedBox(width: 4),
                    SearchActionButtons(
                      filterCount: widget.activeFilterCount,
                      isFilterLoading: widget.isFilterLoading,
                      sortValue: widget.sortValue,
                      sortItems: widget.sortItems,
                      onSortSelected: widget.onSortSelected,
                      sortIcon: widget.sortIcon,
                      sortSystemImage: widget.sortSystemImage,
                      sortTooltip: widget.sortTooltip,
                      filterTooltip: appText(context, english: 'Filters', arabic: 'الفلاتر'),
                      onFilterPressed: widget.onShowFilters,
                      tintColor: theme.colorScheme.primary,
                      height: SearchGlassSurface.height,
                    ),
                    const SizedBox(width: 8),
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
