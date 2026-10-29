import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';

/// Height of the top bar below the status bar
const double kTabTopBarHeight = kToolbarHeight;

/// Extra height below the top bar over which its blur fades out
const double _kTabTopBarFadeExtent = 32;

/// Blur strength at the top of the top bar, fading out towards its bottom
const double _kMaxBlurSigma = 8;

/// Provided by the tab shell, used to fix the top bars of its pages in place and cross-fade them while switching pages
class TabTopBarScope extends InheritedWidget {
  const TabTopBarScope({
    super.key,
    required this.pageController,
    required this.activeIndex,
    required this.leftInset,
    required super.child,
  });

  final PageController pageController;

  /// Used while the page controller is not attached yet
  final int activeIndex;

  /// Horizontal space taken by navigation next to the pages, such as the navigation rail in landscape
  final double leftInset;

  static TabTopBarScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TabTopBarScope>();

  @override
  bool updateShouldNotify(TabTopBarScope oldWidget) =>
      pageController != oldWidget.pageController ||
      activeIndex != oldWidget.activeIndex ||
      leftInset != oldWidget.leftInset;
}

/// A tab page with a top bar that overlays its content, which scrolls underneath it. Use [SliverTabTopBarSpacer] to
/// start the content below the bar.
///
/// The bar is rendered in the overlay, so it stays in place while swiping between pages and fades into the next
/// page's bar. The blurred background is part of the page, unless [withBackground] is false and the page places a
/// [TabTopBarBackground] itself, such as below its own floating controls.
class TabTopBar extends StatefulWidget {
  const TabTopBar({
    super.key,
    required this.tabIndex,
    required this.bar,
    this.withBackground = true,
    this.extent = kTabTopBarHeight,
    required this.child,
  });

  final int tabIndex;

  /// Contents of the bar, such as an [AppBar] with a transparent background
  final Widget bar;

  final bool withBackground;

  /// Height of the bar below the status bar
  final double extent;

  final Widget child;

  @override
  State<TabTopBar> createState() => _TabTopBarState();
}

class _TabTopBarState extends State<TabTopBar> {
  final _portalController = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    _portalController.show();
  }

  Widget _buildBar(BuildContext context) {
    final scope = TabTopBarScope.maybeOf(context);
    final bar = SizedBox(height: context.padding.top + widget.extent, child: widget.bar);

    return Positioned(
      top: 0,
      left: scope?.leftInset ?? 0,
      right: 0,
      child: scope == null
          ? bar
          : ListenableBuilder(
              listenable: scope.pageController,
              builder: (context, child) {
                final controller = scope.pageController;
                final page = controller.hasClients && controller.position.haveDimensions
                    ? controller.page ?? scope.activeIndex.toDouble()
                    : scope.activeIndex.toDouble();
                // Fade the current bar out over the first half of the swipe and the next one in over the second
                final opacity = (1 - 2 * (page - widget.tabIndex).abs()).clamp(0.0, 1.0);
                return IgnorePointer(
                  ignoring: opacity < 1,
                  child: Opacity(opacity: opacity, child: child),
                );
              },
              child: bar,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portalController,
      overlayChildBuilder: _buildBar,
      child: widget.withBackground
          ? Stack(
              children: [
                widget.child,
                Positioned(top: 0, left: 0, right: 0, child: TabTopBarBackground(extent: widget.extent)),
              ],
            )
          : widget.child,
    );
  }
}

/// Progressive blur behind the top bar, strongest at the top and fading out below the bar
class TabTopBarBackground extends StatefulWidget {
  const TabTopBarBackground({super.key, this.intensity = 1.0, this.fillParent = false, this.extent = kTabTopBarHeight});

  /// Scales the blur and its tint, to fade the background in
  final double intensity;

  /// Fade the blur out over the height of the parent, such as an app bar, instead of below the top bar
  final bool fillParent;

  /// Height of the bar below the status bar, the blur fades out below it
  final double extent;

  @override
  State<TabTopBarBackground> createState() => _TabTopBarBackgroundState();
}

class _TabTopBarBackgroundState extends State<TabTopBarBackground> {
  static ui.FragmentProgram? _program;
  static final Future<ui.FragmentProgram?> _programLoader = ui.ImageFilter.isShaderFilterSupported
      ? ui.FragmentProgram.fromAsset(
          'shaders/progressive_blur.frag',
        ).then<ui.FragmentProgram?>((program) => _program = program, onError: (_) => null)
      : Future.value(null);

  @override
  void initState() {
    super.initState();
    if (_program == null) {
      unawaited(
        _programLoader.then((_) {
          if (mounted) {
            setState(() {});
          }
        }),
      );
    }
  }

  /// A single filter blurring with a strength fading out from the top, in a horizontal and a vertical pass
  ui.ImageFilter _progressiveBlur(ui.FragmentProgram program, double height, double maxSigma) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    ui.ImageFilter pass(double dx, double dy) {
      final shader = program.fragmentShader()
        // The first two floats are the input size, set by the engine
        ..setFloat(2, dx)
        ..setFloat(3, dy)
        ..setFloat(4, maxSigma * pixelRatio)
        ..setFloat(5, height * pixelRatio);
      return ui.ImageFilter.shader(shader);
    }

    return ui.ImageFilter.compose(outer: pass(0, 1), inner: pass(1, 0));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fillParent) {
      return LayoutBuilder(builder: (context, constraints) => _buildBackground(context, constraints.maxHeight));
    }
    return _buildBackground(context, context.padding.top + widget.extent + _kTabTopBarFadeExtent);
  }

  Widget _buildBackground(BuildContext context, double height) {
    final intensity = widget.intensity.clamp(0.0, 1.0);
    if (intensity <= 0 || !height.isFinite) {
      return const SizedBox.shrink();
    }

    final surface = context.colorScheme.surface;
    final program = _program;
    final maxSigma = _kMaxBlurSigma * intensity;

    return IgnorePointer(
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRect(
              child: BackdropFilter(
                // Without shader filters, fall back to a uniform blur
                filter: program != null
                    ? _progressiveBlur(program, height, maxSigma)
                    : ui.ImageFilter.blur(sigmaX: maxSigma / 2, sigmaY: maxSigma / 2),
                child: const SizedBox.expand(),
              ),
            ),
            // Tints the blur for the legibility of the bar, fading out with it
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    surface.withValues(alpha: 0.7 * intensity),
                    surface.withValues(alpha: 0.45 * intensity),
                    surface.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.55, 1],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Blurs the collapsed part of a [SliverAppBar]'s flexible space, fading in as it collapses.
/// Wrap the app bar in [SliverScrollUnder] and make it transparent for the content to scroll underneath it
class FlexibleSpaceTopBarBlur extends StatelessWidget {
  const FlexibleSpaceTopBarBlur({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final settings = context.dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
    if (settings == null) {
      return child;
    }

    final deltaExtent = settings.maxExtent - settings.minExtent;
    final collapseProgress = deltaExtent <= 0
        ? 1.0
        : (1.0 - (settings.currentExtent - settings.minExtent) / deltaExtent).clamp(0.0, 1.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: settings.minExtent,
          child: TabTopBarBackground(intensity: collapseProgress, fillParent: true),
        ),
        child,
      ],
    );
  }
}

/// Lets the following slivers scroll underneath the pinned part of [sliver], such as a pinned [SliverAppBar],
/// instead of stopping at its bottom edge
class SliverScrollUnder extends SingleChildRenderObjectWidget {
  const SliverScrollUnder({super.key, required Widget sliver}) : super(child: sliver);

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSliverScrollUnder();
}

class _RenderSliverScrollUnder extends RenderProxySliver {
  @override
  void performLayout() {
    final child = this.child!;
    child.layout(constraints, parentUsesSize: true);
    final geometry = child.geometry!;
    // Lay out the following slivers as if this one scrolled away, while it keeps painting its pinned part over them
    final unpinnedExtent = calculatePaintOffset(constraints, from: 0, to: geometry.scrollExtent);
    this.geometry = geometry.copyWith(layoutExtent: math.min(geometry.layoutExtent, unpinnedExtent));
  }
}

/// Space at the top of a tab page's scroll view, for its [TabTopBar] overlaying the content
class SliverTabTopBarSpacer extends StatelessWidget {
  const SliverTabTopBarSpacer({super.key, this.extent = kTabTopBarHeight});

  /// Height of the bar below the status bar
  final double extent;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(child: SizedBox(height: context.padding.top + extent));
  }
}

/// Status bar icons matching the theme, as the top bar is transparent
SystemUiOverlayStyle tabTopBarOverlayStyle(BuildContext context) =>
    context.isDarkTheme ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;
