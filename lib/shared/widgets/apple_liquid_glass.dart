import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

const _appleLiquidGlassViewType = 'com.animewitcher.app/liquid_glass';
const _appleNativeGlassButtonViewType =
    'com.animewitcher.app/native_glass_button';
const _appleNativeToolbarViewType = 'com.animewitcher.app/native_toolbar';
const _appleNativeSearchFieldViewType =
    'com.animewitcher.app/native_search_field';
const _appleNativeMenuButtonViewType =
    'com.animewitcher.app/native_menu_button';

bool get _usesNativeAppleLiquidGlass =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;


/// True on iOS where AnimeWitcher hosts the native Liquid Glass controls.
/// Screens use this to hand their header actions to the persistent overlay
/// instead of creating route-local platform views that slide with transitions.
bool get appleUsesPersistentLiquidGlassHeader => _usesNativeAppleLiquidGlass;

class ApplePersistentGlassHeaderConfig {
  ApplePersistentGlassHeaderConfig({
    required this.owner,
    this.route,
    this.onBack,
    this.backTooltip,
    this.backForegroundColor,
    this.backFallbackColor,
    this.trailing,
    this.trailingButtons,
    this.branchIndex,
    this.deferTrailingMorphUntilRouteSettles = false,
    this.instantRouteBoundary = false,
  });

  final Object owner;
  ModalRoute<dynamic>? route;
  VoidCallback? onBack;
  String? backTooltip;
  Color? backForegroundColor;
  Color? backFallbackColor;
  Widget? trailing;
  List<AppleLiquidGlassToolbarButton>? trailingButtons;
  int? branchIndex;
  bool deferTrailingMorphUntilRouteSettles;
  bool instantRouteBoundary;

  bool visuallyMatches(ApplePersistentGlassHeaderConfig other) {
    final sameCustomTrailing = trailing == null && other.trailing == null ||
        identical(trailing, other.trailing);
    return (onBack != null) == (other.onBack != null) &&
        backTooltip == other.backTooltip &&
        backForegroundColor == other.backForegroundColor &&
        backFallbackColor == other.backFallbackColor &&
        branchIndex == other.branchIndex &&
        deferTrailingMorphUntilRouteSettles ==
            other.deferTrailingMorphUntilRouteSettles &&
        instantRouteBoundary == other.instantRouteBoundary &&
        sameCustomTrailing &&
        _sameToolbarButtons(trailingButtons, other.trailingButtons);
  }

  void updateFrom(ApplePersistentGlassHeaderConfig other) {
    route = other.route;
    onBack = other.onBack;
    backTooltip = other.backTooltip;
    backForegroundColor = other.backForegroundColor;
    backFallbackColor = other.backFallbackColor;
    trailing = other.trailing;
    trailingButtons = other.trailingButtons;
    branchIndex = other.branchIndex;
    deferTrailingMorphUntilRouteSettles =
        other.deferTrailingMorphUntilRouteSettles;
    instantRouteBoundary = other.instantRouteBoundary;
  }
}
