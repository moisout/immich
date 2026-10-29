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
/// stays in place. On release the grid settles into the new layout.
class TimelinePinchZoom extends ConsumerStatefulWidget {
  const TimelinePinchZoom({
    super.key,
    required this.onColumnCountWillChange,
    required this.onZoomingChanged,
    required this.child,
  });

  /// Called immediately before the new column count is written to the setting. The returned future completes once
  /// the timeline has been laid out with the new column count and scrolled to the anchor
  final Future<void> Function(TimelineZoomAnchor? anchor) onColumnCountWillChange;

  /// Called when a two finger zoom gesture starts or ends
  final ValueChanged<bool> onZoomingChanged;

  final Widget child;

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

  // The grid is drawn at `_translation + _scale * position`
  Offset _translation = Offset.zero;
  double _scale = 1.0;

  // Gesture state
  bool _isZooming = false;
  int _columnCount = 4;
  Offset _focalPoint = Offset.zero;
  Offset _anchorPoint = Offset.zero;
  double _baseScale = 1.0;
  double _gestureScaleOrigin = 1.0;

  // Column switch state
  bool _isSwitching = false;
  bool _settleAfterSwitch = false;
  ui.Image? _snapshot;
  double _snapshotScale = 1.0;

  // Settle animation state
  Offset _settleFromTranslation = Offset.zero;
  double _settleFromScale = 1.0;

  @override
  void dispose() {
    _settleController.dispose();
    _fadeController.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  Size? get _size => (_contentKey.currentContext?.findRenderObject() as RenderBox?)?.size;

  double _tileExtent(int columnCount) {
    final width = _size?.width ?? 0;
    return math.max(1.0, width - kTimelineSpacing * (columnCount - 1)) / columnCount;
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

    setState(() {
      _translation = _focalPoint - _anchorPoint * _scale;
    });
  }

  void _startZoom(ScaleUpdateDetails details) {
    _settleController.stop();
    _isZooming = true;
    _columnCount = ref.read(appConfigProvider.select((config) => config.timeline.tilesPerRow));
    _focalPoint = details.localFocalPoint;
    _anchorPoint = (_focalPoint - _translation) / _scale;
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

    final tile = _findTileNearest(_anchorPoint);
    final anchorFraction = tile == null
        ? null
        : Offset(
            (_anchorPoint.dx - tile.rect.left) / tile.rect.width,
            (_anchorPoint.dy - tile.rect.top) / tile.rect.height,
          );

    // Rebase the scale so the tiles keep their on-screen size in the new layout
    _baseScale *= previousExtent / nextExtent;
    _scale *= previousExtent / nextExtent;
    _snapshotScale = _scale;
    _columnCount = columnCount;
    _isSwitching = true;

    final anchor = tile == null
        ? null
        : (
            assetIndex: tile.assetIndex,
            currentTop: tile.rect.top,
            targetTop: _anchorPoint.dy - anchorFraction!.dy * nextExtent,
          );
    final relayout = widget.onColumnCountWillChange(anchor);
    unawaited(ref.read(settingsProvider).write(.timelineTilesPerRow, columnCount));
    unawaited(_completeSwitch(relayout, tile?.assetIndex, anchorFraction));
  }

  Future<void> _completeSwitch(Future<void> relayout, int? assetIndex, Offset? anchorFraction) async {
    await relayout.timeout(_kRelayoutTimeout, onTimeout: () {});
    // Wait for the frame that lays out the restored scroll position
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      return;
    }

    final tile = assetIndex == null ? null : _findTile(assetIndex);
    if (tile != null && anchorFraction != null) {
      _anchorPoint = Offset(tile.left + anchorFraction.dx * tile.width, tile.top + anchorFraction.dy * tile.height);
    }

    setState(() {
      _isSwitching = false;
      _translation = _focalPoint - _anchorPoint * _scale;
    });
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
    setState(() {
      _translation = Offset.lerp(_settleFromTranslation, Offset.zero, t)!;
      _scale = ui.lerpDouble(_settleFromScale, 1.0, t)!;
    });
  }

  /// Visits the laid out timeline tiles, with their rects in the untransformed grid coordinates
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

  Matrix4 _scaleAbout(Offset origin, double scale) {
    return Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(origin.dx * (1 - scale), origin.dy * (1 - scale), 0);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final double contentOpacity = _isSwitching ? 0 : (snapshot == null ? 1 : _fadeController.value);

    return RawGestureDetector(
      gestures: {
        _CustomScaleGestureRecognizer: GestureRecognizerFactoryWithHandlers<_CustomScaleGestureRecognizer>(
          () => _CustomScaleGestureRecognizer(),
          (_CustomScaleGestureRecognizer scale) {
            scale.onUpdate = _onScaleUpdate;
            scale.onEnd = (_) => _endZoom();
          },
        ),
      },
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              key: _boundaryKey,
              child: Opacity(
                opacity: contentOpacity,
                child: Transform(
                  transform: Matrix4.diagonal3Values(_scale, _scale, 1)
                    ..setTranslationRaw(_translation.dx, _translation.dy, 0),
                  child: KeyedSubtree(key: _contentKey, child: widget.child),
                ),
              ),
            ),
            if (snapshot != null)
              IgnorePointer(
                child: Opacity(
                  opacity: 1 - contentOpacity,
                  child: Transform(
                    transform: _scaleAbout(_focalPoint, _scale / _snapshotScale),
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
