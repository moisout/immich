import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Overshoots vertical scrollables past their edges instead of stretching them, with a light haptic tick when they
/// reach the edge. Horizontal ones stop at their edges without any effect
class OverscrollScrollBehavior extends MaterialScrollBehavior {
  const OverscrollScrollBehavior();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) =>
      axisDirectionToAxis(details.direction) == Axis.vertical ? _ScrollLimitHaptics(child: child) : child;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    // Called by each Scrollable with its own context
    final scrollable = context.widget;
    if (scrollable is Scrollable && axisDirectionToAxis(scrollable.axisDirection) == Axis.vertical) {
      return const BouncingScrollPhysics(parent: RangeMaintainingScrollPhysics());
    }
    return const ClampingScrollPhysics(parent: RangeMaintainingScrollPhysics());
  }
}

class _ScrollLimitHaptics extends StatelessWidget {
  const _ScrollLimitHaptics({required this.child});

  static const _channel = MethodChannel('immich/fork/scroll_limit_haptics');

  final Widget child;

  bool _onScrollUpdate(ScrollUpdateNotification notification) {
    final metrics = notification.metrics;
    final delta = notification.scrollDelta;
    if (notification.depth != 0 || delta == null || !metrics.outOfRange) {
      return false;
    }

    final previous = metrics.pixels - delta;
    if (previous >= metrics.minScrollExtent && previous <= metrics.maxScrollExtent) {
      unawaited(_play());
    }
    return false;
  }

  static Future<void> _play() async {
    try {
      if (await _channel.invokeMethod<bool>('play') ?? false) {
        return;
      }
    } on MissingPluginException {
      // Only implemented on Android
    }
    await HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollUpdateNotification>(onNotification: _onScrollUpdate, child: child);
}
