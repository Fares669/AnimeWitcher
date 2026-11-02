import 'package:flutter/material.dart';

import '../../../shared/widgets/app_page_header.dart';
import 'more_sidebar_shell.dart';

class ProviderUnsupportedPage extends StatelessWidget {
  const ProviderUnsupportedPage({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final canPop = !MorePaneScope.of(context) && Navigator.of(context).canPop();
    return Scaffold(
      appBar: AppPageAppBar(
        title: title,
        canPop: canPop,
        onBack: canPop ? () => Navigator.of(context).pop() : null,
      ),
      body: const Center(child: Text('هذه الميزة غير متاحة للمزود المختار')),
    );
  }
}
