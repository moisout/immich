import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_drag_region.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';

/// Asset kept in place while the column count changes, with its tile's top edge before and after the change
typedef TimelineZoomAnchor = ({int assetIndex, double currentTop, double targetTop});

/// Layout with a neighbouring column count that is cross-faded in while zooming.
/// It is scrolled so the tile of [assetIndex] has its top edge at [anchorTop], aligned with the grid
typedef TimelineZoomPreview = ({int columnCount, int assetIndex, double anchorTop});

/// State shared between the pinch to zoom gesture and the timeline rendering the grid and the previews
class TimelineZoomController {
  final gridTransform = ValueNotifier(Matrix4.identity());
  final gridOpacity = ValueNotifier(1.0);
  final previews = ValueNotifier<List<TimelineZoomPreview>>(const []);
  final _previewTransforms = <int, ValueNotifier<Matrix4>>{};
  final _previewOpacities = <int, ValueNotifier<double>>{};

  /// Whether scrolling should be ignored, as the pointers are zooming
  bool isScrollLocked = false;

  ValueNotifier<Matrix4> previewTransform(int columnCount) =>
      _previewTransforms.putIfAbsent(columnCount, () => ValueNotifier(Matrix4.identity()));

  ValueNotifier<double> previewOpacity(int columnCount) =>
      _previewOpacities.putIfAbsent(columnCount, () => ValueNotifier(0.0));

  void dispose() {
    gridTransform.dispose();
    gridOpacity.dispose();
    previews.dispose();
    for (final notifier in [..._previewTransforms.values, ..._previewOpacities.values]) {
      notifier.dispose();
    }
  }
}

/// Wraps a rendered [TimelineZoomPreview], so its tiles are not mistaken for the grid's
class TimelineZoomPreviewScope extends StatelessWidget {
  const TimelineZoomPreviewScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

const int _kMinColumnCount = 2;
const int _kMaxColumnCount = 6;

/// Scale change before a zoom direction is picked, avoids flipping between previews while hovering around 1
const double _kPreviewThreshold = 0.02;

/// Exponent applied to the pinch scale, below 1 the grid zooms slower than the fingers move
const double _kPinchSensitivity = 0.6;

/// How far the grid can be stretched past the smallest/largest column count
const double _kOverscrollLimit = 0.12;

const Duration _kSettleDuration = Duration(milliseconds: 250);
const Duration _kRelayoutTimeout = Duration(milliseconds: 800);

/// Pinch to zoom on the timeline grid. The grid follows the fingers continuously, while the layout with the next
/// column count is cross-faded in with the zoom progress. Once fully zoomed to it, the `timelineTilesPerRow` setting
/// is switched over underneath the preview. On release the zoom settles to the nearest column count.
/// The left edge stays aligned and the asset under the fingers stays at the same height.
///
/// The previews are built as soon as a second pointer goes down, before the fingers start moving, so building them
/// doesn't cause a visible hitch.
class TimelinePinchZoom extends ConsumerStatefulWidget {
  const TimelinePinchZoom({
    super.key,
    required this.controller,
    required this.onColumnCountWillChange,
    required this.child,
  });

  final TimelineZoomController controller;

  /// Called immediately before the new column count is written to the setting. The returned future completes once
  /// the timeline has been laid out with the new column count and scrolled to the anchor
  final Future<void> Function(TimelineZoomAnchor anchor) onColumnCountWillChange;

  final Widget child;

  /// Whether more than one pointer went down since all pointers were last lifted, gestures such as long press
  /// selection should be ignored then as they are part of a pinch
  static bool isMultiTouch(BuildContext context) =>
      context.findAncestorStateOfType<_TimelinePinchZoomState>()?._isMultiTouch ?? false;

  @override
  ConsumerState createState() => _TimelinePinchZoomState();
}

class _TimelinePinchZoomState extends ConsumerState<TimelinePinchZoom> with SingleTickerProviderStateMixin {
  final _contentKey = GlobalKey();

  late final AnimationController _settleController = AnimationController(vsync: this, duration: _kSettleDuration)
    ..addListener(_onSettleTick);

  final _pointerPositions = <int, Offset>{};
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

  // Prepared previews by column count, the one in the zoom direction is [_preview]. Its tile extent relative to the
  // grid's is [_previewRatio]
  final _previews = <int, TimelineZoomPreview>{};
  TimelineZoomPreview? _preview;
  double _previewRatio = 1.0;

  // Column switch state, while switching the preview stands in for the grid
  bool _isSwitching = false;
  bool _settleAfterSwitch = false;
  double _previewAnchorY = 0;

  // Settle animation state
  double _settleFromTranslation = 0;
  double _settleFromScale = 1.0;
  double _settleToTranslation = 0;
  double _settleToScale = 1.0;

  @override
  void dispose() {
    _settleController.dispose();
    super.dispose();
  }

  bool get _isIdle => !_isZooming && !_isSwitching && !_settleController.isAnimating;

  void _onPointerDown(PointerDownEvent event) {
    _pointerPositions[event.pointer] = event.localPosition;
    if (_pointerPositions.length < 2) {
      return;
    }

    _isMultiTouch = true;
    widget.controller.isScrollLocked = true;
    if (_isIdle && _previews.isEmpty) {
      final focal = _pointerPositions.values.reduce((a, b) => a + b) / _pointerPositions.length.toDouble();
      _columnCount = ref.read(appConfigProvider.select((config) => config.timeline.tilesPerRow));
      _preparePreviews((focal.dy - _translation) / _scale);
    }
  }

  void _onPointerUp(PointerEvent event) {
    _pointerPositions.remove(event.pointer);
    if (_pointerPositions.isNotEmpty) {
      return;
    }

    _isMultiTouch = false;
    // The scroll view handles the pointer up after this listener, keep it locked so it doesn't fling
    scheduleMicrotask(() => widget.controller.isScrollLocked = false);
    if (_isIdle) {
      _clearPreviews();
    }
  }

  double get _width => (_contentKey.currentContext?.findRenderObject() as RenderBox?)?.size.width ?? 0;

  double _tileExtent(int columnCount) => math.max(1.0, _width - kTimelineSpacing * (columnCount - 1)) / columnCount;

  /// How far the zoom has progressed from the grid's column count to the preview's, between 0 and 1
  double get _previewProgress {
    if (_preview == null) {
      return 0;
    }
    return (math.log(_scale) / math.log(_previewRatio)).clamp(0.0, 1.0);
  }

  double get _previewScale => _scale / _previewRatio;

  /// Aligns the preview's anchor tile with the grid's
  double get _previewTranslation => _translation + (_scale - _previewScale) * (_preview?.anchorTop ?? 0);

  static Matrix4 _matrix(double scale, double translation) =>
      Matrix4.diagonal3Values(scale, scale, 1)..setTranslationRaw(0, translation, 0);

  void _apply() {
    final controller = widget.controller;
    for (final columnCount in _previews.keys) {
      if (columnCount != _preview?.columnCount) {
        controller.previewOpacity(columnCount).value = 0;
      }
    }

    final preview = _preview;
    if (_isSwitching && preview != null) {
      controller.previewTransform(preview.columnCount).value = _matrix(_scale, _focalY - _previewAnchorY * _scale);
      controller.previewOpacity(preview.columnCount).value = 1;
      controller.gridOpacity.value = 0;
      return;
    }

    controller.gridTransform.value = _matrix(_scale, _translation);
    if (preview == null) {
      controller.gridOpacity.value = 1;
      return;
    }

    final progress = _previewProgress;
    controller.previewTransform(preview.columnCount).value = _matrix(_previewScale, _previewTranslation);
    controller.previewOpacity(preview.columnCount).value = (2 * progress).clamp(0.0, 1.0);
    controller.gridOpacity.value = (2 * (1 - progress)).clamp(0.0, 1.0);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount < 2) {
      _endZoom();
      return;
    }

    if (!_isZooming) {
      _startZoom(details);
    }

    _scale = _applyOverscroll(_baseScale * math.pow(details.scale / _gestureScaleOrigin, _kPinchSensitivity));
    if (!_isSwitching) {
      _translation = _focalY - _anchorY * _scale;
      _updatePreview();
      if (_preview != null && _previewProgress >= 1) {
        _switchColumnCount();
      }
    }
    _apply();
  }

  void _startZoom(ScaleUpdateDetails details) {
    if (_previews.isEmpty && !_isSwitching) {
      _columnCount = ref.read(appConfigProvider.select((config) => config.timeline.tilesPerRow));
    }
    _settleController.stop();
    _isZooming = true;
    final previousFocalY = _focalY;
    _focalY = details.localFocalPoint.dy;
    _anchorY = (_focalY - _translation) / _scale;
    _previewAnchorY += (_focalY - previousFocalY) / _scale;
    _baseScale = _scale;
    _gestureScaleOrigin = details.scale;
  }

  void _endZoom() {
    if (!_isZooming) {
      return;
    }

    _isZooming = false;
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

  bool _isValidColumnCount(int columnCount) => columnCount >= _kMinColumnCount && columnCount <= _kMaxColumnCount;

  /// Prepares the layouts with the neighbouring column counts, aligned on the tile closest to [anchorY]
  void _preparePreviews(double anchorY) {
    final tile = _findTileNearest(Offset(_width / 2, anchorY));
    if (tile == null) {
      return;
    }

    for (final columnCount in [_columnCount - 1, _columnCount + 1]) {
      if (_isValidColumnCount(columnCount) && !_previews.containsKey(columnCount)) {
        _previews[columnCount] = (columnCount: columnCount, assetIndex: tile.assetIndex, anchorTop: tile.rect.top);
      }
    }
    widget.controller.previews.value = _previews.values.toList();
  }

  void _clearPreviews() {
    for (final columnCount in _previews.keys) {
      widget.controller.previewOpacity(columnCount).value = 0;
    }
    _previews.clear();
    _preview = null;
    widget.controller.previews.value = const [];
  }

  /// Picks the preview in the direction of the zoom
  void _updatePreview() {
    if (math.log(_scale).abs() < _kPreviewThreshold) {
      return;
    }

    final columnCount = _scale > 1 ? _columnCount - 1 : _columnCount + 1;
    if (!_isValidColumnCount(columnCount)) {
      _preview = null;
      return;
    }
    if (_preview?.columnCount == columnCount) {
      return;
    }

    // Not prepared when a pointer went down, such as right after switching the column count mid-gesture
    if (!_previews.containsKey(columnCount)) {
      _preparePreviews(_anchorY);
    }
    _preview = _previews[columnCount];
    _previewRatio = _tileExtent(columnCount) / _tileExtent(_columnCount);
  }

  /// Switches the grid to the preview's column count, the preview is shown in its place until it is laid out
  void _switchColumnCount() {
    final preview = _preview!;
    _isSwitching = true;
    _previewAnchorY = (_focalY - _previewTranslation) / _previewScale;
    _baseScale /= _previewRatio;
    _scale = _previewScale;
    _columnCount = preview.columnCount;

    final relayout = widget.onColumnCountWillChange((
      assetIndex: preview.assetIndex,
      currentTop: preview.anchorTop,
      targetTop: preview.anchorTop,
    ));
    unawaited(ref.read(settingsProvider).write(.timelineTilesPerRow, preview.columnCount));
    unawaited(_completeSwitch(relayout, preview));
  }

  Future<void> _completeSwitch(Future<void> relayout, TimelineZoomPreview preview) async {
    await relayout.timeout(_kRelayoutTimeout, onTimeout: () {});
    // Wait for the frame that lays out the restored scroll position
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      return;
    }

    // Translate from the preview's coordinates to the grid's, they are aligned on the anchor tile
    final tileTop = _findTile(preview.assetIndex)?.top ?? preview.anchorTop;
    _anchorY = _previewAnchorY + tileTop - preview.anchorTop;
    _translation = _focalY - _anchorY * _scale;
    _isSwitching = false;
    _clearPreviews();
    _apply();

    if (_settleAfterSwitch) {
      _settleAfterSwitch = false;
      _settle();
    }
  }

  /// Animates to the nearest column count once the fingers are lifted
  void _settle() {
    if (_preview != null && _previewProgress >= 0.5) {
      unawaited(
        _animateTo(_previewRatio, _focalY - _anchorY * _previewRatio).then((_) {
          if (_preview == null) {
            return;
          }
          _switchColumnCount();
          _settleAfterSwitch = true;
        }),
      );
    } else {
      unawaited(
        _animateTo(1.0, 0).then((_) {
          _clearPreviews();
          _apply();
        }),
      );
    }
  }

  /// Completes only when the animation finishes, not when it is interrupted by another gesture
  TickerFuture _animateTo(double scale, double translation) {
    _settleFromScale = _scale;
    _settleFromTranslation = _translation;
    _settleToScale = scale;
    _settleToTranslation = translation;
    return _settleController.forward(from: 0);
  }

  void _onSettleTick() {
    final t = Curves.easeOutCubic.transform(_settleController.value);
    _scale = ui.lerpDouble(_settleFromScale, _settleToScale, t)!;
    _translation = ui.lerpDouble(_settleFromTranslation, _settleToTranslation, t)!;
    _apply();
  }

  /// Visits the laid out grid tiles, with their rects in the unzoomed coordinates of the child
  void _visitTiles(bool Function(int assetIndex, Rect rect) visitor) {
    final contentContext = _contentKey.currentContext;
    final content = contentContext?.findRenderObject();
    if (contentContext == null || content == null) {
      return;
    }

    bool done = false;
    void visit(Element element) {
      final widget = element.widget;
      if (done || widget is TimelineZoomPreviewScope) {
        return;
      }
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
        child: KeyedSubtree(key: _contentKey, child: widget.child),
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
