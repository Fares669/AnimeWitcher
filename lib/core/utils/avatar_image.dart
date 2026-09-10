import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

/// A profile photo, decoded for the circle it is actually painted in.
///
/// Avatars arrive at whatever size the account service stored them — a phone
/// camera's portrait is not unusual — and a [CircleAvatar] paints them forty
/// logical pixels across. Handing the raw provider to the widget decodes
/// every one of those source pixels into memory and then throws away all but
/// a fraction of a percent, once per avatar, down a list built to scroll.
///
/// Unlike poster artwork there is nothing to trade off here, so the bound is
/// unconditional rather than tied to the high-quality artwork switch: no
/// detail above the circle's own resolution can reach the screen.
ImageProvider<Object>? avatarImage(
  BuildContext context,
  String? url, {
  required double radius,
}) {
  final source = url?.trim() ?? '';
  if (source.isEmpty) return null;
  final pixels = radius * 2 * MediaQuery.devicePixelRatioOf(context);
  return ResizeImage(
    CachedNetworkImageProvider(source),
    width: pixels.ceil(),
    // A small avatar is left at its own size rather than blown up to fill the
    // request: upscaling would spend memory to arrive at a blurrier picture.
    allowUpscaling: false,
  );
}
