import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/notification_service.dart';

/// Shares toast routing across comments, personal comments, and replies.
mixin CommentScreenMessages<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  void showCommentMessage(
    String message, {
    bool isError = false,
    bool isInfo = false,
  }) {
    if (!mounted) return;
    final notifications = ref.read(notificationServiceProvider);
    if (isError) {
      notifications.showError(message);
    } else if (isInfo) {
      notifications.showInfo(message);
    } else {
      notifications.showSuccess(message);
    }
  }
}
