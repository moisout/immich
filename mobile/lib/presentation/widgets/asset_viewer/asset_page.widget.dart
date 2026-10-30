import 'dart:async';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/gestures.dart' show Drag, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent, SwipeEdge;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/extensions/scroll_extensions.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_stack.provider.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_stack.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/ocr_overlay.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/progressive_image.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/is_motion_video_playing.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/view_intent/view_intent_file_path.provider.dart';
import 'package:immich_mobile/widgets/common/hdr_image.dart';
import 'package:immich_mobile/widgets/common/immich_loading_indicator.dart';
import 'package:immich_mobile/widgets/common/predictive_back.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';

enum _DragIntent { none, scroll, dismiss }

class AssetPage extends ConsumerStatefulWidget {
  final int index;
  final int heroOffset;
  final void Function(int direction)? onTapNavigate;

  const AssetPage({super.key, required this.index, required this.heroOffset, this.onTapNavigate});

  @override
  ConsumerState createState() => _AssetPageState();
}

class _AssetPageState extends ConsumerState<AssetPage> {
  PhotoViewControllerBase? _viewController;
  StreamSubscription? _scaleBoundarySub;
  StreamSubscription? _eventSubscription;

  AssetViewerStateNotifier get _viewer => ref.read(assetViewerProvider.notifier);

  late PhotoViewControllerValue _initialPhotoViewState;

  bool _showingDetails = false;
  // Keeps the details rendered while they scroll out after being closed
  bool _keepDetails = false;
  double _backStartScrollOffset = 0.0;
  Offset? _backStartTouch;
  Offset? _backLastTouch;
  double _backLastTouchProgress = 0.0;
  bool _isZoomed = false;
  bool _restoreControlsAfterZoom = false;
  // Frozen during dismiss drag + settle to prevent widget tree swap mid-animation.
  bool _wasMotionPlayingAtDismiss = false;
  bool _isDismissAnimating = false;

  final _scrollController = SnapScrollController();
  double _snapOffset = 0.0;
  static const double _maxImagePixelSize = 12.0;

  DragStartDetails? _dragStart;
  _DragIntent _dragIntent = _DragIntent.none;
  Drag? _drag;

  BaseAsset? _asset;

  @override
  void initState() {
    super.initState();
    _eventSubscription = EventStream.shared.listen(_onEvent);
    _asset = ref.read(timelineServiceProvider).getAssetSafe(widget.index);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      _scrollController.snapPosition.snapOffset = _snapOffset;
      if (_showingDetails && _snapOffset > 0) {
        _scrollController.jumpTo(_snapOffset);
      }
    });
  }

  @override
  void didUpdateWidget(AssetPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _asset = ref.read(timelineServiceProvider).getAssetSafe(widget.index);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    unawaited(_scaleBoundarySub?.cancel());
    unawaited(_eventSubscription?.cancel());
    super.dispose();
  }

  void _onEvent(Event event) {
    switch (event) {
      case ViewerShowDetailsEvent():
        _showDetails();
      case TimelineReloadEvent():
        final asset = ref.read(timelineServiceProvider).getAssetSafe(widget.index);
        if (asset != _asset) {
          _isZoomed = false;
          _viewer.setZoomed(false);
          setState(() => _asset = asset);
        }
      default:
    }
  }

  void _showDetails() {
    if (!_scrollController.hasClients || _snapOffset <= 0) {
      return;
    }
    _viewer.setShowingDetails(true);
    unawaited(_scrollController.animateTo(_snapOffset, duration: Durations.medium2, curve: Curves.easeOutCubic));
  }

  void _hideDetails() {
    if (!_scrollController.hasClients) {
      return;
    }
    _viewer.setShowingDetails(false);
    unawaited(_scrollController.animateTo(0, duration: Durations.medium2, curve: Curves.easeOutCubic));
  }

  // The details slide in from the bottom of the screen while the asset scrolls up, and reach their place below it
  // at the snap offset
  double _detailsShift(double viewportHeight, double detailsOffset) {
    if (!_scrollController.hasClients || _snapOffset <= 0) {
      return 0;
    }
    final progress = (_scrollController.offset / _snapOffset).clamp(0.0, 1.0);
    return (viewportHeight - detailsOffset) * (1 - progress);
  }

  void _onScroll() {
    if (_keepDetails && !_showingDetails && _scrollController.offset <= 0) {
      setState(() => _keepDetails = false);
    }
  }

  // A back gesture closes the details, or else dismisses the asset like dragging it down
  void _onBackStart(PredictiveBackEvent event) {
    if (_showingDetails) {
      _backStartScrollOffset = _scrollController.offset;
    } else {
      _initialPhotoViewState = _viewController!.value;
      _backStartTouch = event.touchOffset;
      _backLastTouch = null;
      _wasMotionPlayingAtDismiss = ref.read(isPlayingMotionVideoProvider);
      setState(() => _dragIntent = _DragIntent.dismiss);
    }
    _onBackProgress(event);
  }

  void _onBackProgress(PredictiveBackEvent event) {
    if (_showingDetails) {
      final offset = _backStartScrollOffset - event.progress * kPredictiveBackPreviewExtent * _snapOffset;
      _scrollController.jumpTo(math.max(offset, 0.0));
      return;
    }

    final start = _backStartTouch;
    final touch = event.touchOffset;
    if (start == null || touch == null) {
      final delta = Offset(event.progress * context.width * (event.swipeEdge == SwipeEdge.left ? 1 : -1), 0);
      _updateDismiss(delta, delta.distance, MediaQuery.sizeOf(context).center(Offset.zero));
      return;
    }
    if (touch != _backLastTouch) {
      _backLastTouch = touch;
      _backLastTouchProgress = event.progress;
    }
    // When the gesture is cancelled, Android animates the progress back to 0 while the touch stays where it was
    final settle = _backLastTouchProgress > 0 ? (event.progress / _backLastTouchProgress).clamp(0.0, 1.0) : 1.0;
    // Touch offsets are in physical pixels
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final delta = (touch - start) / pixelRatio * settle;
    _updateDismiss(delta, delta.distance, start / pixelRatio);
  }

  void _onBackCancel() {
    if (_showingDetails) {
      unawaited(
        _scrollController.animateTo(_backStartScrollOffset, duration: Durations.short4, curve: Curves.easeOutCubic),
      );
      return;
    }
    _dragIntent = _DragIntent.none;
    _cancelDismiss();
  }

  void _onBack() {
    if (_showingDetails) {
      _hideDetails();
      return;
    }
    _dragIntent = _DragIntent.none;
    unawaited(context.maybePop());
  }

  bool _willClose(double scrollVelocity) =>
      _scrollController.hasClients &&
      _snapOffset > 0 &&
      _scrollController.position.pixels < _snapOffset &&
      SnapScrollPhysics.target(_scrollController.position, scrollVelocity, _snapOffset) <
          SnapScrollPhysics.minSnapDistance;

  void _syncShowingDetails() {
    final offset = _scrollController.offset;
    if (offset > SnapScrollPhysics.minSnapDistance) {
      _viewer.setShowingDetails(true);
    } else if (offset < SnapScrollPhysics.minSnapDistance - kTouchSlop) {
      _viewer.setShowingDetails(false);
    }
  }

  void _beginDrag(DragStartDetails details) {
    _dragStart = details;

    if (_viewController != null) {
      _initialPhotoViewState = _viewController!.value;
    }

    if (_showingDetails) {
      _dragIntent = _DragIntent.scroll;
      _startProxyDrag();
    }
  }

  void _startProxyDrag() {
    if (_scrollController.hasClients && _dragStart != null) {
      _drag = _scrollController.position.drag(_dragStart!, () => _drag = null);
    }
  }

  void _updateDrag(DragUpdateDetails details) {
    if (_dragStart == null) {
      return;
    }

    if (_dragIntent == _DragIntent.none) {
      _dragIntent = switch ((details.globalPosition - _dragStart!.globalPosition).dy) {
        < 0 => _DragIntent.scroll,
        > 0 => _DragIntent.dismiss,
        _ => _DragIntent.none,
      };
      if (_dragIntent == _DragIntent.dismiss) {
        _wasMotionPlayingAtDismiss = ref.read(isPlayingMotionVideoProvider);
      }
    }

    switch (_dragIntent) {
      case _DragIntent.none:
      case _DragIntent.scroll:
        if (_drag == null) {
          _startProxyDrag();
        }
        _drag?.update(details);

        _syncShowingDetails();
      case _DragIntent.dismiss:
        final delta = details.localPosition - _dragStart!.localPosition;
        _updateDismiss(delta, delta.dy.abs(), _dragStart!.localPosition);
    }
  }

  void _endDrag(DragEndDetails details) {
    if (_dragStart == null) {
      return;
    }

    final start = _dragStart;
    _dragStart = null;

    final intent = _dragIntent;
    _dragIntent = _DragIntent.none;

    switch (intent) {
      case _DragIntent.none:
      case _DragIntent.scroll:
        final scrollVelocity = -(details.primaryVelocity ?? 0.0);
        _viewer.setShowingDetails(!_willClose(scrollVelocity));

        _drag?.end(details);
        _drag = null;
      case _DragIntent.dismiss:
        const popThreshold = 75.0;
        if (details.localPosition.dy - start!.localPosition.dy > popThreshold) {
          unawaited(context.maybePop());
          return;
        }
        _cancelDismiss();
    }
  }

  void _cancelDismiss() {
    final startOpacity = ref.read(assetViewerProvider).backgroundOpacity;
    final startScale = _viewController?.scale;
    final targetScale = _viewController?.initialScale ?? _initialPhotoViewState.scale;
    // Brings the background back along with the asset scaling back, instead of at once
    final opacitySubscription = _viewController?.outputStateStream.listen((value) {
      final scale = value.scale;
      if (startScale == null || targetScale == null || scale == null || startScale == targetScale) {
        return;
      }
      final progress = ((scale - startScale) / (targetScale - startScale)).clamp(0.0, 1.0);
      _viewer.setOpacity(startOpacity + (1.0 - startOpacity) * progress);
    });

    _isDismissAnimating = true;
    unawaited(
      _viewController
          ?.animateMultiple(
            position: _initialPhotoViewState.position,
            scale: targetScale,
            rotation: _initialPhotoViewState.rotation,
          )
          .whenComplete(() {
            unawaited(opacitySubscription?.cancel());
            if (!mounted) {
              return;
            }
            _viewer.setOpacity(1.0);
            setState(() => _isDismissAnimating = false);
          }),
    );
  }

  void _onDragStart(
    BuildContext context,
    DragStartDetails details,
    PhotoViewControllerBase controller,
    PhotoViewScaleStateController scaleStateController,
  ) {
    if (!_showingDetails && _isZoomed) {
      return;
    }
    _beginDrag(details);
  }

  void _onDragUpdate(BuildContext context, DragUpdateDetails details, PhotoViewControllerValue _) =>
      _updateDrag(details);

  void _onDragEnd(BuildContext context, DragEndDetails details, PhotoViewControllerValue _) => _endDrag(details);

  void _onDragCancel() => _endDrag(DragEndDetails(primaryVelocity: 0.0));

  void _updateDismiss(Offset delta, double distance, Offset focalPoint) {
    // Half the size after dragging the screen height, at most down to 40%
    final scaleReduction = (distance / context.height * 0.5).clamp(0.0, 0.6);
    final initialScale = _viewController?.initialScale ?? _initialPhotoViewState.scale;
    final updatedScale = initialScale != null ? initialScale * (1.0 - scaleReduction) : null;

    // Shrinks towards the point under the finger instead of the center of the asset. Positions are relative to the
    // center of the viewport
    final focalOffset = focalPoint - MediaQuery.sizeOf(context).center(Offset.zero) - _initialPhotoViewState.position;
    final position = _initialPhotoViewState.position + delta + focalOffset * scaleReduction;

    final opacity = (1.0 - distance / (context.height * 0.5)).clamp(0.0, 1.0);

    _viewController?.updateMultiple(position: position, scale: updatedScale);
    _viewer.setOpacity(opacity);
  }

  void _onTapUp(BuildContext context, TapUpDetails details, PhotoViewControllerValue controllerValue) {
    if (_showingDetails || _dragStart != null) {
      return;
    }

    _restoreControlsAfterZoom = false;

    final tapToNavigate = ref.read(appConfigProvider).viewer.tapToNavigate;
    if (!tapToNavigate) {
      _viewer.toggleControls();
      return;
    }

    final tapX = details.globalPosition.dx;
    final screenWidth = context.width;

    // Navigate if the user taps in the leftmost or rightmost quarter of the screen
    final tappedLeftSide = tapX < screenWidth / 4;
    final tappedRightSide = tapX > screenWidth * (3 / 4);

    if (tappedLeftSide) {
      widget.onTapNavigate?.call(-1);
    } else if (tappedRightSide) {
      widget.onTapNavigate?.call(1);
    } else {
      _viewer.toggleControls();
    }
  }

  void _onLongPress(BuildContext context, LongPressStartDetails details, PhotoViewControllerValue controllerValue) =>
      ref.read(isPlayingMotionVideoProvider.notifier).playing = true;

  void _onScaleStateChanged(PhotoViewScaleState scaleState) {
    _isZoomed = scaleState == PhotoViewScaleState.zoomedIn || scaleState == PhotoViewScaleState.covering;
    _viewer.setZoomed(_isZoomed);

    if (scaleState != PhotoViewScaleState.initial) {
      if (_dragStart == null) {
        _restoreControlsAfterZoom |= ref.read(assetViewerProvider).showingControls;
        _viewer.setControls(false);
      }
      return;
    }

    if (!_showingDetails && _restoreControlsAfterZoom) {
      _viewer.setControls(true);
    }

    _restoreControlsAfterZoom = false;
  }

  void _listenForScaleBoundaries(PhotoViewControllerBase? controller) {
    unawaited(_scaleBoundarySub?.cancel());
    _scaleBoundarySub = null;
    if (controller == null || controller.scaleBoundaries != null) {
      return;
    }
    _scaleBoundarySub = controller.outputStateStream.listen((_) {
      if (controller.scaleBoundaries != null) {
        unawaited(_scaleBoundarySub?.cancel());
        _scaleBoundarySub = null;
        if (mounted) {
          setState(() {});
        }
      }
    });
  }

  double _getImageHeight(double maxWidth, double maxHeight, BaseAsset? asset) {
    final sb = _viewController?.scaleBoundaries;
    if (sb != null) {
      return sb.childSize.height * sb.initialScale;
    }

    if (asset == null || asset.width == null || asset.height == null) {
      return maxHeight;
    }

    final r = asset.width! / asset.height!;
    return math.min(maxWidth / r, maxHeight);
  }

  void _onPageBuild(PhotoViewControllerBase controller) {
    _viewController = controller;
    _listenForScaleBoundaries(controller);
  }

  Widget _buildPhotoView({
    required BaseAsset asset,
    required PhotoViewHeroAttributes? heroAttributes,
    required bool isCurrent,
    required bool isPlayingMotionVideo,
    required String? localFilePath,
    required Size? remoteThumbnailSize,
  }) {
    final size = context.sizeData;
    final imageProvider = getFullImageProvider(
      asset,
      size: size,
      localFilePath: localFilePath,
      remoteThumbnailSize: remoteThumbnailSize,
    );

    if (asset.isImage && !isPlayingMotionVideo) {
      return ProgressiveImage(
        provider: imageProvider,
        builder: (context, provider) => PhotoView(
          key: Key(asset.heroTag),
          index: widget.index,
          imageProvider: provider,
          heroAttributes: heroAttributes,
          loadingBuilder: (context, progress, index) => const Center(child: ImmichLoadingIndicator()),
          gaplessPlayback: true,
          filterQuality: FilterQuality.high,
          tightMode: true,
          enablePanAlways: true,
          maxScale: _maxImagePixelSize,
          disableScaleGestures: _showingDetails,
          scaleStateChangedCallback: _onScaleStateChanged,
          onPageBuild: _onPageBuild,
          onDragStart: _onDragStart,
          onDragUpdate: _onDragUpdate,
          onDragEnd: _onDragEnd,
          onDragCancel: _onDragCancel,
          onTapUp: _onTapUp,
          onLongPressStart: asset.isMotionPhoto ? _onLongPress : null,
          // The HDR version of local images, over the SDR image
          overlay: CurrentPlatform.isAndroid && asset.localId != null
              ? IgnorePointer(child: HdrImage(localId: asset.localId!))
              : null,
          errorBuilder: (_, _, _) => SizedBox(
            width: size.width,
            height: size.height,
            child: Thumbnail.fromAsset(asset: asset, fit: BoxFit.contain),
          ),
        ),
      );
    }

    return PhotoView.customChild(
      key: Key(asset.heroTag),
      childSize: asset.width != null && asset.height != null
          ? Size(asset.width!.toDouble(), asset.height!.toDouble())
          : null,
      onDragStart: _onDragStart,
      onDragUpdate: _onDragUpdate,
      onDragEnd: _onDragEnd,
      onDragCancel: _onDragCancel,
      onTapUp: _onTapUp,
      scaleStateChangedCallback: _onScaleStateChanged,
      heroAttributes: heroAttributes,
      filterQuality: FilterQuality.high,
      basePosition: Alignment.center,
      disableScaleGestures: _showingDetails,
      minScale: PhotoViewComputedScale.contained,
      maxScale: _maxImagePixelSize,
      initialScale: PhotoViewComputedScale.contained,
      tightMode: true,
      onPageBuild: _onPageBuild,
      enablePanAlways: true,
      child: NativeVideoViewer(
        key: _NativeVideoViewerKey(asset.heroTag),
        asset: asset,
        localFilePath: localFilePath,
        isCurrent: isCurrent,
        image: Image(image: imageProvider, fit: BoxFit.contain, alignment: Alignment.center),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final (currentAsset, thumbnailSize) = ref.watch(
      assetViewerProvider.select((s) => (s.currentAsset, s.thumbnailSize)),
    );
    _showingDetails = ref.watch(assetViewerProvider.select((s) => s.showingDetails));
    if (_showingDetails) {
      _keepDetails = true;
    }
    final detailsVisible = _showingDetails || _keepDetails;
    final stackIndex = ref.watch(assetViewerProvider.select((s) => s.stackIndex));
    final liveMotionPlaying = ref.watch(isPlayingMotionVideoProvider);
    // Preserve the playback status while dismissing to prevent switching views mid-animation.
    final isPlayingMotionVideo = (_dragIntent == _DragIntent.dismiss || _isDismissAnimating)
        ? _wasMotionPlayingAtDismiss
        : liveMotionPlaying;
    final timelineOrigin = ref.watch(timelineServiceProvider).origin;
    final showingOcr = ref.watch(assetViewerProvider.select((s) => s.showingOcr));

    final asset = _asset;
    if (asset == null) {
      return const Center(child: ImmichLoadingIndicator());
    }

    BaseAsset displayAsset = asset;
    final showAssetStack = ref.watch(timelineServiceProvider.select((s) => s.origin != TimelineOrigin.trash));
    final stackChildren = showAssetStack ? ref.watch(stackChildrenNotifier(asset)).valueOrNull : null;
    if (stackChildren != null && stackChildren.isNotEmpty) {
      final safeStackIndex = stackIndex.clamp(0, stackChildren.length - 1);
      displayAsset = stackChildren.elementAt(safeStackIndex);
    }

    final isCurrent = currentAsset != null && currentAsset.refersToSameAsset(displayAsset);

    final viewportWidth = MediaQuery.widthOf(context);
    final viewportHeight = MediaQuery.heightOf(context);
    final imageHeight = _getImageHeight(viewportWidth, viewportHeight, displayAsset);

    final detailsOffset = (viewportHeight + imageHeight - kMinInteractiveDimension) / 2;
    final snapTarget = viewportHeight / 3;

    _snapOffset = detailsOffset - snapTarget;

    if (_scrollController.hasClients) {
      _scrollController.snapPosition.snapOffset = _snapOffset;
    }

    final viewIntentFilePath = timelineOrigin == TimelineOrigin.deepLink ? ref.watch(viewIntentFilePathProvider) : null;

    final page = Stack(
      children: [
        SingleChildScrollView(
          controller: _scrollController,
          physics: const SnapScrollPhysics(parent: ClampingScrollPhysics()),
          child: ColoredBox(
            color: detailsVisible ? Colors.black : Colors.transparent,
            child: Stack(
              children: [
                SizedBox(
                  width: viewportWidth,
                  height: viewportHeight,
                  child: _buildPhotoView(
                    asset: displayAsset,
                    heroAttributes: isCurrent
                        ? PhotoViewHeroAttributes(
                            tag: '${asset.heroTag}_${widget.heroOffset}',
                            transitionOnUserGestures: true,
                          )
                        : null,
                    isCurrent: isCurrent,
                    isPlayingMotionVideo: isPlayingMotionVideo,
                    localFilePath: viewIntentFilePath,
                    remoteThumbnailSize: thumbnailSize,
                  ),
                ),
                if (showingOcr && displayAsset.width != null && displayAsset.height != null)
                  Positioned.fill(
                    child: OcrOverlay(
                      asset: displayAsset,
                      imageSize: Size(displayAsset.width!.toDouble(), displayAsset.height!.toDouble()),
                      viewportSize: Size(viewportWidth, viewportHeight),
                      controller: _viewController,
                    ),
                  ),
                IgnorePointer(
                  ignoring: !_showingDetails,
                  child: Column(
                    children: [
                      SizedBox(height: detailsOffset),
                      ListenableBuilder(
                        listenable: _scrollController,
                        builder: (context, child) => Transform.translate(
                          offset: Offset(0, _detailsShift(viewportHeight, detailsOffset)),
                          child: child,
                        ),
                        child: GestureDetector(
                          onVerticalDragStart: _beginDrag,
                          onVerticalDragUpdate: _updateDrag,
                          onVerticalDragEnd: _endDrag,
                          onVerticalDragCancel: _onDragCancel,
                          child: AnimatedOpacity(
                            opacity: detailsVisible ? 1.0 : 0.0,
                            duration: Durations.short2,
                            child: detailsVisible
                                ? AssetDetails(asset: displayAsset, minHeight: viewportHeight - snapTarget)
                                : SizedBox(height: viewportHeight - snapTarget),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (stackChildren != null && stackChildren.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: context.padding.bottom,
            child: AssetStackRow(stack: stackChildren),
          ),
      ],
    );

    return PredictiveBackScope(
      // Zoomed assets can't be dragged to dismiss, the route fades out instead
      enabled: isCurrent && (_showingDetails || (!_isZoomed && _viewController != null)),
      interceptsPop: _showingDetails,
      onBack: _onBack,
      onStart: _onBackStart,
      onProgress: _onBackProgress,
      onCancel: _onBackCancel,
      child: page,
    );
  }
}

// A global key is used for video viewers to prevent them from being
// unnecessarily recreated. They're quite expensive, and maintain internal
// state. This can cause videos to restart multiple times during normal usage,
// like a hero animation.
//
// A plain ValueKey is insufficient, as it does not allow widgets to reparent. A
// GlobalObjectKey is fragile, as it checks if the given objects are identical,
// rather than equal. Hero tags are created with string interpolation, which
// prevents Dart from interning them. As such, hero tags are not identical, even
// if they are equal.
class _NativeVideoViewerKey extends GlobalKey {
  final String value;

  const _NativeVideoViewerKey(this.value) : super.constructor();

  @override
  bool operator ==(Object other) => other is _NativeVideoViewerKey && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
