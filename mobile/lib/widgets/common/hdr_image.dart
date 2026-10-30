import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';

/// Local Ultra HDR images (JPEGs with a gain map), which [HdrImage] shows natively on Android
abstract final class HdrImages {
  static const _channel = MethodChannel('immich/fork/hdr_image');
  static final _isHdr = <String, bool>{};
  static final _supported = CurrentPlatform.isAndroid
      ? HybridAndroidViewController.checkIfSupported()
      : Future.value(false);

  /// Whether the image is known to be HDR, null until [prepare] finished for it
  static bool? isHdr(String localId) => _isHdr[localId];

  /// Finds out whether the image is HDR, and if so starts decoding it for [HdrImage]
  static Future<bool> prepare(String localId) async {
    final known = _isHdr[localId];
    if (known != null) {
      return known;
    }
    final hdr = await _supported && (await _channel.invokeMethod<bool>('prepare', {'localId': localId}) ?? false);
    return _isHdr[localId] = hdr;
  }
}

/// Shows a local image in a native Android view, which displays its HDR gain map, or nothing if it isn't HDR.
/// Needs Hybrid Composition++
class HdrImage extends StatefulWidget {
  const HdrImage({super.key, required this.localId});

  final String localId;

  @override
  State<HdrImage> createState() => _HdrImageState();
}

class _HdrImageState extends State<HdrImage> {
  static const _viewType = 'immich/fork/hdr_image';

  bool _isHdr = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(HdrImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.localId != widget.localId) {
      _prepare();
    }
  }

  void _prepare() {
    final localId = widget.localId;
    _isHdr = HdrImages.isHdr(localId) ?? false;
    if (HdrImages.isHdr(localId) == null) {
      unawaited(
        HdrImages.prepare(localId).then((hdr) {
          if (mounted && widget.localId == localId && hdr != _isHdr) {
            setState(() => _isHdr = hdr);
          }
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isHdr) {
      return const SizedBox.shrink();
    }
    return PlatformViewLink(
      key: ValueKey(widget.localId),
      viewType: _viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      ),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initHybridAndroidView(
          id: params.id,
          viewType: _viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: {'localId': widget.localId},
          creationParamsCodec: const StandardMessageCodec(),
        )..addOnPlatformViewCreatedListener(params.onPlatformViewCreated);
        unawaited(controller.create());
        return controller;
      },
    );
  }
}
