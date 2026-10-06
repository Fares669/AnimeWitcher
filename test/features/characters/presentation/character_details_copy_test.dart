import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('character details comments action uses التعليقات', () {
    final source = File(
      'lib/features/characters/presentation/character_details_screen.dart',
    ).readAsStringSync();
    expect(source, contains("isArabic ? 'التعليقات'"));
    expect(source.contains("isArabic ? 'تعليقات'"), isFalse);
  });

  test('character details uses the shared centered progressive header', () {
    final source = File(
      'lib/features/characters/presentation/character_details_screen.dart',
    ).readAsStringSync();

    expect(source, contains('AppPageAppBar('));
    expect(source, contains('extendBodyBehindAppBar: true'));
    expect(source, contains('appPageHeaderContentTopInset(context)'));
    expect(source, contains('AppleLiquidGlassActionGroup('));
    expect(source, contains('icon: Icons.chat_bubble_outline_rounded'));
    expect(source, contains('icon: Icons.more_horiz_rounded'));
    expect(source.contains('class _CharacterActionButton'), isFalse);
  });

  test('character actions remain available outside the persistent header', () {
    final source = File(
      'lib/features/characters/presentation/character_details_screen.dart',
    ).readAsStringSync();

    expect(source, contains('final isLarge = context.isTabletOrLarger'));
    expect(
      source,
      contains('appleUsesPersistentLiquidGlassHeader || isLarge'),
    );
    expect(
      source,
      contains('!appleUsesPersistentLiquidGlassHeader && isLarge'),
    );
  });

  test('comments preserve the persistent-header morph behavior', () {
    final commentsSource = File(
      'lib/features/comments/presentation/animewitcher_comments_screen.dart',
    ).readAsStringSync();
    final glassSource = File(
      'lib/shared/widgets/apple_liquid_glass.dart',
    ).readAsStringSync();

    expect(commentsSource, contains('allowInstantBoundaryMorph: true'));
    expect(glassSource, contains('hardCutInstantBoundary'));
    expect(glassSource, contains('!allowInstantBoundaryMorph'));
  });

  test('details screen hides the empty characters copy', () {
    final source = File(
      'lib/features/details/presentation/details_screen.dart',
    ).readAsStringSync();
    expect(source.contains('لم يتم اضافة الشخصيات حتي الان'), isFalse);
    expect(source.contains('No characters have been added yet'), isFalse);
  });
}
