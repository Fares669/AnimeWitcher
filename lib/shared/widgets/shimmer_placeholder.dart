import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

class ShimmerPlaceholder extends StatefulWidget {
  final double? width;
  final double? height;
  final ShapeBorder shapeBorder;

  ShimmerPlaceholder({
    super.key,
    this.width,
    this.height,
    double borderRadius = 0,
    ShapeBorder shapeBorder = const RoundedRectangleBorder(),
  }) : shapeBorder = borderRadius > 0
           ? RoundedRectangleBorder(
               borderRadius: BorderRadius.all(Radius.circular(borderRadius)),
             )
           : shapeBorder;

  ShimmerPlaceholder.rectangular({
    super.key,
    this.width,
    this.height,
    double borderRadius = 0,
  }) : shapeBorder = RoundedRectangleBorder(
         borderRadius: BorderRadius.all(Radius.circular(borderRadius)),
       );

  const ShimmerPlaceholder.circular({super.key, this.width, this.height})
    : shapeBorder = const CircleBorder();

  @override
  State<ShimmerPlaceholder> createState() => _ShimmerPlaceholderState();
}

class _ShimmerPlaceholderState extends State<ShimmerPlaceholder> {
  static const _motionBudget = Duration(seconds: 3);
  Timer? _stop;
  bool _motionFinished = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      _stop?.cancel();
      _stop = null;
    } else if (!_motionFinished) {
      _stop ??= Timer(_motionBudget, () {
        setState(() => _motionFinished = true);
      });
    }
  }

  @override
  void dispose() {
    _stop?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final baseColor = colors.surfaceContainerHighest;
    final placeholder = Container(
      width: widget.width,
      height: widget.height,
      decoration: ShapeDecoration(color: baseColor, shape: widget.shapeBorder),
    );

    // Long waits keep the same skeleton geometry but stop asking the engine
    // to repaint every frame. Removing Shimmer also drops its shader layer.
    if (_motionFinished || MediaQuery.disableAnimationsOf(context)) {
      return placeholder;
    }
    return Shimmer.fromColors(
      baseColor: baseColor,
      highlightColor: Color.alphaBlend(
        colors.primary.withValues(alpha: 0.16),
        baseColor,
      ),
      child: placeholder,
    );
  }
}
