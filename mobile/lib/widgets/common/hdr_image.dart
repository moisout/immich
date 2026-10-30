import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';

const _channel = MethodChannel('immich/fork/hdr_image');

/// Local Ultra HDR images (JPEGs with a gain map), which [HdrImage] shows on Android
abstract final class HdrImages {
  static final _isHdr = <String, bool>{};

  /// Whether the image is known to be HDR, null until [prepare] finished for it
  static bool? isHdr(String localId) => _isHdr[localId];

  /// Finds out whether the image is HDR, and if so starts rendering it for [HdrImage]
  static Future<bool> prepare(String localId) async {
    if (!CurrentPlatform.isAndroid) {
      return false;
    }
    final known = _isHdr[localId];
    if (known != null) {
      return known;
    }
    final hdr = await _channel.invokeMethod<bool>('prepare', {'localId': localId}) ?? false;
    return _isHdr[localId] = hdr;
  }
}

/// Shows a local image with its HDR gain map, fitted into this widget. Flutter only renders SDR, so the image is in a
/// native view below the Flutter view, and this widget leaves a transparent hole for it. Shows nothing until the view
/// is ready, if the image isn't HDR, or while the route is animating, as heroes fly in Flutter
class HdrImage extends StatefulWidget {
  const HdrImage({super.key, required this.localId});

  final String localId;

  @override
  State<HdrImage> createState() => _HdrImageState();
}

class _HdrImageState extends State<HdrImage> {
  Size? _size;
  Animation<double>? _routeAnimation;

  bool get _routeOpen => _routeAnimation?.status != AnimationStatus.forward && !_routeClosing;

  bool get _routeClosing => _routeAnimation?.status == AnimationStatus.reverse;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (animation != _routeAnimation) {
      _routeAnimation?.removeStatusListener(_onRouteStatus);
      _routeAnimation = animation?..addStatusListener(_onRouteStatus);
      _onRouteStatus(animation?.status ?? AnimationStatus.completed);
    }
  }

  @override
  void didUpdateWidget(HdrImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.localId != widget.localId) {
      unawaited(_hide(oldWidget.localId));
      _size = null;
      if (_routeOpen) {
        unawaited(_show(widget.localId));
      }
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    unawaited(_hide(widget.localId));
    super.dispose();
  }

  void _onRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _size == null) {
      unawaited(_show(widget.localId));
    } else if (status == AnimationStatus.reverse) {
      unawaited(_hide(widget.localId));
      if (_size != null && mounted) {
        setState(() => _size = null);
      }
    }
  }

  Future<void> _show(String localId) async {
    if (!await HdrImages.prepare(localId) || !mounted || widget.localId != localId || !_routeOpen) {
      return;
    }
    final size = await _channel.invokeMapMethod<String, int>('show', {'localId': localId});
    if (size == null) {
      return;
    }
    if (!mounted || widget.localId != localId || !_routeOpen) {
      unawaited(_hide(localId));
      return;
    }
    setState(() => _size = Size(size['width']!.toDouble(), size['height']!.toDouble()));
  }

  Future<void> _hide(String localId) => _channel.invokeMethod('hide', {'localId': localId});

  @override
  Widget build(BuildContext context) {
    final size = _size;
    if (size == null) {
      return const SizedBox.shrink();
    }
    return Center(
      child: AspectRatio(
        aspectRatio: size.width / size.height,
        child: _HdrHole(localId: widget.localId, devicePixelRatio: MediaQuery.devicePixelRatioOf(context)),
      ),
    );
  }
}

class _HdrHole extends LeafRenderObjectWidget {
  const _HdrHole({required this.localId, required this.devicePixelRatio});

  final String localId;
  final double devicePixelRatio;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHdrHole(localId, devicePixelRatio);

  @override
  void updateRenderObject(BuildContext context, _RenderHdrHole renderObject) => renderObject
    ..localId = localId
    ..devicePixelRatio = devicePixelRatio;
}

/// Clears its area to transparent, and after every frame places the HDR layer at its position on screen. The layer
/// moves with the next frame, so the hole is only cleared from the frame after the first placement: before that the
/// layer is hidden behind the SDR image instead of leaving an empty hole
class _RenderHdrHole extends RenderBox {
  _RenderHdrHole(this.localId, this.devicePixelRatio);

  String localId;
  double devicePixelRatio;
  Rect? _placed;
  bool _clear = false;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    SchedulerBinding.instance.addPostFrameCallback(_place);
  }

  void _place(Duration _) {
    if (!attached) {
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback(_place);

    final rect = MatrixUtils.transformRect(getTransformTo(null), Offset.zero & size);
    final physical = Rect.fromLTRB(
      rect.left * devicePixelRatio,
      rect.top * devicePixelRatio,
      rect.right * devicePixelRatio,
      rect.bottom * devicePixelRatio,
    );
    if (physical == _placed) {
      if (!_clear) {
        _clear = true;
        markNeedsPaint();
      }
      return;
    }
    _placed = physical;
    unawaited(
      _channel.invokeMethod('update', {
        'localId': localId,
        'left': physical.left,
        'top': physical.top,
        'width': physical.width,
        'height': physical.height,
      }),
    );
    // The layer change is applied with the next frame of the Flutter surface
    SchedulerBinding.instance.scheduleFrame();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_clear) {
      context.canvas.drawRect(offset & size, Paint()..blendMode = BlendMode.clear);
    }
  }
}
