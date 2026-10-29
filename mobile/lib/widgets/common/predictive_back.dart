import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Part of the exit animation of dialogs, sheets and menus a back gesture plays before it is released, the rest plays
/// on release. Pages follow the gesture all the way
const double kPredictiveBackPreviewExtent = 0.4;

/// Plays the exit animation of the top route along with the back gesture, unless a [PredictiveBackScope] in it
/// handles the gesture. Heroes follow when they allow user gestures
class PredictiveBackRouteObserver extends NavigatorObserver with WidgetsBindingObserver {
  Route<dynamic>? _top;
  TransitionRoute<dynamic>? _route;
  bool _registered = false;

  // auto_route also builds observers for tab routers, which never attach to a navigator
  void _setTop(Route<dynamic>? route) {
    _top = route;
    if (!_registered) {
      _registered = true;
      WidgetsBinding.instance.addObserver(this);
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _setTop(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _setTop(previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route == _top) {
      _setTop(previousRoute);
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute == _top) {
      _setTop(newRoute);
    }
  }

  static double _routeValue(TransitionRoute<dynamic> route, PredictiveBackEvent backEvent) =>
      1 - backEvent.progress * (route is PageRoute ? 1 : kPredictiveBackPreviewExtent);

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final route = _top;
    if (backEvent.isButtonEvent ||
        route is! TransitionRoute ||
        !route.isCurrent ||
        !route.popGestureEnabled ||
        _PredictiveBackScopeState.handlesGesture(route)) {
      return false;
    }
    _route = route;
    // Starts the gesture before moving the animation, so transitions see it as a pop from the start
    route.handleStartBackGesture(progress: 1);
    route.handleUpdateBackGestureProgress(progress: _routeValue(route, backEvent));
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    final route = _route;
    route?.handleUpdateBackGestureProgress(progress: _routeValue(route, backEvent));
  }

  @override
  void handleCancelBackGesture() {
    _route?.handleCancelBackGesture();
    _route = null;
  }

  // TransitionRoute.handleCommitBackGesture restarts the exit animation from the start, pop from where the gesture
  // left it instead
  @override
  void handleCommitBackGesture() {
    final route = _route;
    _route = null;
    final navigator = route?.navigator;
    if (route == null || navigator == null) {
      return;
    }
    if (!route.isCurrent) {
      navigator.didStopUserGesture();
      return;
    }

    final animation = route.animation!;
    void onStatusChanged(AnimationStatus status) {
      if (status.isDismissed) {
        animation.removeStatusListener(onStatusChanged);
        navigator.didStopUserGesture();
      }
    }

    animation.addStatusListener(onStatusChanged);
    navigator.pop();
  }
}

/// Handles back gestures inside a page while [enabled], instead of [PredictiveBackRouteObserver] playing its route's
/// exit animation. [onStart] and [onProgress] follow the gesture, [onCancel] ends it without going back, and [onBack]
/// goes back.
///
/// With [interceptsPop] the page stays open: the back button calls [onBack] too. Without it, the back button pops the
/// route as usual and [onBack] is expected to pop it at the end of the gesture
class PredictiveBackScope extends StatefulWidget {
  const PredictiveBackScope({
    super.key,
    required this.enabled,
    this.interceptsPop = true,
    required this.onBack,
    this.onStart,
    this.onProgress,
    this.onCancel,
    required this.child,
  });

  final bool enabled;
  final bool interceptsPop;
  final VoidCallback onBack;
  final ValueChanged<PredictiveBackEvent>? onStart;
  final ValueChanged<PredictiveBackEvent>? onProgress;
  final VoidCallback? onCancel;
  final Widget child;

  @override
  State<PredictiveBackScope> createState() => _PredictiveBackScopeState();
}

class _PredictiveBackScopeState extends State<PredictiveBackScope> with WidgetsBindingObserver {
  static final _mounted = <_PredictiveBackScopeState>{};

  static bool handlesGesture(Route<dynamic> route) =>
      _mounted.any((scope) => scope.widget.enabled && ModalRoute.of(scope.context) == route);

  bool _inGesture = false;

  @override
  void initState() {
    super.initState();
    _mounted.add(this);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mounted.remove(this);
    super.dispose();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (!widget.enabled || backEvent.isButtonEvent || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return false;
    }
    _inGesture = true;
    widget.onStart?.call(backEvent);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (_inGesture) {
      widget.onProgress?.call(backEvent);
    }
  }

  @override
  void handleCancelBackGesture() {
    if (_inGesture) {
      _inGesture = false;
      widget.onCancel?.call();
    }
  }

  @override
  void handleCommitBackGesture() {
    if (_inGesture) {
      _inGesture = false;
      widget.onBack();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !(widget.enabled && widget.interceptsPop),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && widget.enabled && widget.interceptsPop) {
        widget.onBack();
      }
    },
    child: widget.child,
  );
}

/// Android's fade forwards page transition, which plays its pop animation along with a back gesture instead of its
/// push animation in reverse
class BackGestureFadeForwardsPageTransitionsBuilder extends PageTransitionsBuilder {
  const BackGestureFadeForwardsPageTransitionsBuilder();

  static const _transition = FadeForwardsPageTransitionsBuilder();

  @override
  Duration get transitionDuration => _transition.transitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      (context, animation, secondaryAnimation, allowSnapshotting, child) => _transition.delegatedTransition!(
        context,
        animation,
        _BackGestureAnimation.of(secondaryAnimation, Navigator.maybeOf(context)),
        allowSnapshotting,
        child,
      );

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _transition.buildTransitions(
    route,
    context,
    _BackGestureAnimation.of(animation, route.navigator),
    _BackGestureAnimation.of(secondaryAnimation, route.navigator),
    child,
  );
}

/// Reports a route animation as reversing while a back gesture drives it, which makes transitions built on
/// [DualTransitionBuilder] show their pop animation. At the start and end of the gesture both look the same
class _BackGestureAnimation extends Animation<double>
    with AnimationLazyListenerMixin, AnimationLocalListenersMixin, AnimationLocalStatusListenersMixin {
  _BackGestureAnimation(this._parent, this._gesture);

  static final _cache = Expando<_BackGestureAnimation>();

  static Animation<double> of(Animation<double> parent, NavigatorState? navigator) {
    if (navigator == null) {
      return parent;
    }
    return _cache[parent] ??= _BackGestureAnimation(parent, navigator.userGestureInProgressNotifier);
  }

  final Animation<double> _parent;
  final ValueListenable<bool> _gesture;
  late AnimationStatus _lastStatus = status;

  @override
  double get value => _parent.value;

  @override
  AnimationStatus get status {
    final parentStatus = _parent.status;
    return _gesture.value && parentStatus.isAnimating ? AnimationStatus.reverse : parentStatus;
  }

  void _onStatusChanged() {
    final current = status;
    if (current != _lastStatus) {
      _lastStatus = current;
      notifyStatusListeners(current);
    }
  }

  void _onParentStatusChanged(AnimationStatus _) => _onStatusChanged();

  @override
  void didStartListening() {
    _lastStatus = status;
    _parent.addListener(notifyListeners);
    _parent.addStatusListener(_onParentStatusChanged);
    _gesture.addListener(_onStatusChanged);
  }

  @override
  void didStopListening() {
    _parent.removeListener(notifyListeners);
    _parent.removeStatusListener(_onParentStatusChanged);
    _gesture.removeListener(_onStatusChanged);
  }
}
