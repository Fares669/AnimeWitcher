import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reaches the kept-alive Home page from any of the app's navigation layouts.
final homeTabReselectionProvider = NotifierProvider<HomeTabReselection, int>(
  HomeTabReselection.new,
);

class HomeTabReselection extends Notifier<int> {
  @override
  int build() => 0;

  void reselect() => state++;
}
