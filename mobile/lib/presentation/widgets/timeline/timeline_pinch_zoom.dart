import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_drag_region.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';

/// Asset kept under the fingers while the column count changes, with its tile's top edge before and after the change
typedef TimelineZoomAnchor = ({int assetIndex, double currentTop, double targetTop});

const int _kMinColumnCount = 2;
const int _kMaxColumnCount = 6;

/// Extra scale required past the midpoint between two column counts before switching, prevents flip-flopping
const double _kSwitchHysteresis = 1.05;

/// How far the grid can be stretched past the smallest/largest column count
const double _kOverscrollLimit = 0.12;

const Duration _kSettleDuration = Duration(milliseconds: 250);
const Duration _kCrossFadeDuration = Duration(milliseconds: 180);
const Duration _kRelayoutTimeout = Duration(milliseconds: 800);

/// Pinch to zoom on the timeline grid. The grid follows the fingers continuously and switches the number of columns
/// (the `timelineTilesPerRow` setting) mid-gesture, cross-fading from a snapshot while the asset under the fingers
/// stays at the same height. On release the grid settles into the new layout. The left edge stays aligned throughout.
class TimelinePinchZoom extends ConsumerStatefulWidget {
  const TimelinePinchZoom({
    super.key,
    required this.transform,
    required this.onColumnCountWillChange,
    required this.onZoomingChanged,
    required this.child,
  });

  /// Receives the zoom transform of the asset grid, in the coordinates of [child]
  final ValueNotifier<Matrix4> transform;

  /// Called immediately before the new column count is written to the setting. The returned future completes once
  /// the timeline has been laid out with the new column count and scrolled to the anchor
  final Future<void> Function(TimelineZoomAnchor? anchor) onColumnCountWillChange;

  /// Called when a two finger zoom gesture starts or ends
  final ValueChanged<bool> onZoomingChanged;

  final Widget child;

  /// Whether more than one pointer went down since all pointers were last lifted, gestures such as long press
  /// selection should be ignored then as they are part of a pinch
  static bool isMultiTouch(BuildContext context) =>
      context.findAncestorStateOfType<_TimelinePinchZoomState>()?._isMultiTouch ?? false;

  @override
  ConsumerState createState() => _TimelinePinchZoomState();
}

class _TimelinePinchZoomState extends ConsumerState<TimelinePinchZoom> with TickerProviderStateMixin {
  final _boundaryKey = GlobalKey();
  final _contentKey = GlobalKey();

  late final AnimationController _settleController = AnimationController(vsync: this, duration: _kSettleDuration)
    ..addListener(_onSettleTick);
  late final AnimationController _fadeController = AnimationController(vsync: this, duration: _kCrossFadeDuration)
    ..addListener(() => setState(() {}))
    ..addStatusListener(_onFadeStatus);

  int _pointerCount = 0;
  bool _isMultiTouch = false;

  // The grid is drawn at `(_scale * x, _translation + _scale * y)`, keeping the left edge in place
  double _translation = 0;
  double _scale = 1.0;

  // Gesture state
  bool _isZooming = false;
  int _columnCount = 4;
  double _focalY = 0;
  double _anchorY = 0;
  double _baseScale = 1.0;
  double _gestureScaleOrigin = 1.0;

  // Column switch state
  bool _isSwitching = false;
  bool _settleAfterSwitch = false;
  ui.Image? _snapshot;

  // Settle animation state
  double _settleFromTranslation = 0;
  double _settleFromScale = 1.0;

  @override
  void dispose() {
    _settleController.dispose();
    _fadeController.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent _) {
    _pointerCount++;
    if (_pointerCount > 1) {
      _isMultiTouch = true;
    }
  }

  void _onPointerUp(PointerEvent _) {
    _pointerCount = math.max(0, _pointerCount - 1);
    if (_pointerCount == 0) {
      _isMultiTouch = false;
    }
  }

  double _tileExtent(int columnCount) {
    final width = (_contentKey.currentContext?.findRenderObject() as RenderBox?)?.size.width ?? 0;
    return math.max(1.0, width - kTimelineSpacing * (columnCount - 1)) / columnCount;
  }

  void _applyTransform() {
    widget.transform.value = Matrix4.diagonal3Values(_scale, _scale, 1)..setTranslationRaw(0, _translation, 0);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount < 2) {
      _endZoom();
      return;
    }

    if (!_isZooming) {
      _startZoom(details);
    }

    final rawScale = _baseScale * (details.scale / _gestureScaleOrigin);
    _scale = _applyOverscroll(rawScale);

    if (!_isSwitching && _snapshot == null) {
      final n = _columnCount;
      if (n > _kMinColumnCount && rawScale > math.sqrt(n / (n - 1)) * _kSwitchHysteresis) {
        _switchColumnCount(n - 1);
      } else if (n < _kMaxColumnCount && rawScale < math.sqrt(n / (n + 1)) / _kSwitchHysteresis) {
        _switchColumnCount(n + 1);
      }
    }

    _translation = _focalY - _anchorY * _scale;
    _applyTransform();
  }

  void _startZoom(ScaleUpdateDetails details) {
    _settleController.stop();
    _isZooming = true;
    _columnCount = ref.read(appConfigProvider.select((config) => config.timeline.tilesPerRow));
    _focalY = details.localFocalPoint.dy;
    _anchorY = (_focalY - _translation) / _scale;
    _baseScale = _scale;
    _gestureScaleOrigin = details.scale;
    widget.onZoomingChanged(true);
  }

  void _endZoom() {
    if (!_isZooming) {
      return;
    }

    _isZooming = false;
    widget.onZoomingChanged(false);
    if (_isSwitching) {
      _settleAfterSwitch = true;
    } else {
      _settle();
    }
  }

  /// Resist stretching beyond the smallest/largest column count
  double _applyOverscroll(double scale) {
    double resist(double overshoot) => _kOverscrollLimit * (1 - 1 / (1 + overshoot / _kOverscrollLimit));

    if (scale > 1 && _columnCount <= _kMinColumnCount) {
      return 1 + resist(scale - 1);
    }
    if (scale < 1 && _columnCount >= _kMaxColumnCount) {
      return 1 - resist(1 - scale);
    }
    return scale;
  }

  void _switchColumnCount(int columnCount) {
    final previousExtent = _tileExtent(_columnCount);
    final nextExtent = _tileExtent(columnCount);

    // Snapshot the current frame to cross-fade from while the timeline is laid out again
    try {
      final boundary = _boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      _snapshot = boundary?.toImageSync(pixelRatio: MediaQuery.devicePixelRatioOf(context));
    } catch (_) {
      _snapshot = null;
    }

    // The grid is only scaled horizontally, so any tile in the row under the fingers works as the anchor
    final width = (_contentKey.currentContext?.findRenderObject() as RenderBox?)?.size.width ?? 0;
    final tile = _findTileNearest(Offset(width / 2, _anchorY));
    final anchorFraction = tile == null ? null : (_anchorY - tile.rect.top) / tile.rect.height;

    // Rebase the scale so the tiles keep their on-screen size in the new layout
    _baseScale *= previousExtent / nextExtent;
    _scale *= previousExtent / nextExtent;
    _columnCount = columnCount;
    setState(() => _isSwitching = true);

    final anchor = tile == null
        ? null
        : (assetIndex: tile.assetIndex, currentTop: tile.rect.top, targetTop: _anchorY - anchorFraction! * nextExtent);
    final relayout = widget.onColumnCountWillChange(anchor);
    unawaited(ref.read(settingsProvider).write(.timelineTilesPerRow, columnCount));
    unawaited(_completeSwitch(relayout, tile?.assetIndex, anchorFraction));
  }

  Future<void> _completeSwitch(Future<void> relayout, int? assetIndex, double? anchorFraction) async {
    await relayout.timeout(_kRelayoutTimeout, onTimeout: () {});
    // Wait for the frame that lays out the restored scroll position
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      return;
    }

    final tile = assetIndex == null ? null : _findTile(assetIndex);
    if (tile != null && anchorFraction != null) {
      _anchorY = tile.top + anchorFraction * tile.height;
    }

    _translation = _focalY - _anchorY * _scale;
    _applyTransform();
    setState(() => _isSwitching = false);
    unawaited(_fadeController.forward(from: 0));

    if (_settleAfterSwitch) {
      _settleAfterSwitch = false;
      _settle();
    }
  }

  void _onFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      setState(() {
        _snapshot?.dispose();
        _snapshot = null;
      });
    }
  }

  void _settle() {
    _settleFromTranslation = _translation;
    _settleFromScale = _scale;
    unawaited(_settleController.forward(from: 0));
  }

  void _onSettleTick() {
    final t = Curves.easeOutCubic.transform(_settleController.value);
    _translation = ui.lerpDouble(_settleFromTranslation, 0, t)!;
    _scale = ui.lerpDouble(_settleFromScale, 1.0, t)!;
    _applyTransform();
  }

  /// Visits the laid out timeline tiles, with their rects in the unzoomed coordinates of the child
  void _visitTiles(bool Function(int assetIndex, Rect rect) visitor) {
    final contentContext = _contentKey.currentContext;
    final content = contentContext?.findRenderObject();
    if (contentContext == null || content == null) {
      return;
    }

    bool done = false;
    void visit(Element element) {
      if (done) {
        return;
      }
      final widget = element.widget;
      if (widget is TimelineAssetIndexWrapper) {
        final box = element.renderObject;
        if (box is RenderBox && box.attached && box.hasSize) {
          final rect = MatrixUtils.transformRect(box.getTransformTo(content), Offset.zero & box.size);
          done = !visitor(widget.assetIndex, rect);
        }
        return;
      }
      element.visitChildElements(visit);
    }

    contentContext.visitChildElements(visit);
  }

  ({int assetIndex, Rect rect})? _findTileNearest(Offset position) {
    ({int assetIndex, Rect rect})? nearest;
    double nearestDistance = double.infinity;
    _visitTiles((assetIndex, rect) {
      final dx = math.max(0.0, math.max(rect.left - position.dx, position.dx - rect.right));
      final dy = math.max(0.0, math.max(rect.top - position.dy, position.dy - rect.bottom));
      final distance = dx * dx + dy * dy;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = (assetIndex: assetIndex, rect: rect);
      }
      return distance > 0;
    });
    return nearest;
  }

  Rect? _findTile(int assetIndex) {
    Rect? result;
    _visitTiles((index, rect) {
      if (index == assetIndex) {
        result = rect;
        return false;
      }
      return true;
    });
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerUp,
      child: RawGestureDetector(
        gestures: {
          _CustomScaleGestureRecognizer: GestureRecognizerFactoryWithHandlers<_CustomScaleGestureRecognizer>(
            () => _CustomScaleGestureRecognizer(),
            (_CustomScaleGestureRecognizer scale) {
              scale.onUpdate = _onScaleUpdate;
              scale.onEnd = (_) => _endZoom();
            },
          ),
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              key: _boundaryKey,
              child: KeyedSubtree(key: _contentKey, child: widget.child),
            ),
            if (snapshot != null)
              IgnorePointer(
                child: Opacity(
                  opacity: _isSwitching ? 1 : 1 - _fadeController.value,
                  // Opaque, so the timeline being laid out again doesn't shine through the gaps
                  child: ColoredBox(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: RawImage(image: snapshot, fit: BoxFit.fill),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// accepts a gesture even though it should reject it (because child won)
class _CustomScaleGestureRecognizer extends ScaleGestureRecognizer {
  @override
  void rejectGesture(int pointer) {
    acceptGesture(pointer);
  }
}
