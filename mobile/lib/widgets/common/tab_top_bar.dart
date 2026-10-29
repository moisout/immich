import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';

/// Height of the top bar below the status bar
const double kTabTopBarHeight = kToolbarHeight;

/// Extra height below the top bar over which its blur fades out
const double _kTabTopBarFadeExtent = 32;

/// Blur strengths of the stacked layers making up the progressive blur, from the full height to the topmost layer.
/// The layers blur on top of each other, so the blur is strongest at the top
const List<double> _kBlurSigmas = [0.5, 1, 1.5, 2, 3, 4];

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
    required this.child,
  });

  final int tabIndex;

  /// Contents of the bar, such as an [AppBar] with a transparent background
  final Widget bar;

  final bool withBackground;

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
    final bar = SizedBox(height: context.padding.top + kTabTopBarHeight, child: widget.bar);

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
                const Positioned(top: 0, left: 0, right: 0, child: TabTopBarBackground()),
              ],
            )
          : widget.child,
    );
  }
}

/// Progressive blur behind the top bar, strongest at the top and fading out below the bar
class TabTopBarBackground extends StatelessWidget {
  const TabTopBarBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final height = context.padding.top + kTabTopBarHeight + _kTabTopBarFadeExtent;
    final surface = context.colorScheme.surface;

    return IgnorePointer(
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            for (final (index, sigma) in _kBlurSigmas.indexed)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: height * (1 - index / _kBlurSigmas.length),
                child: ClipRect(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            // Tints the blur for the legibility of the bar, fading out with it
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      surface.withValues(alpha: 0.7),
                      surface.withValues(alpha: 0.45),
                      surface.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.55, 1],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Space at the top of a tab page's scroll view, for its [TabTopBar] overlaying the content
class SliverTabTopBarSpacer extends StatelessWidget {
  const SliverTabTopBarSpacer({super.key});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(child: SizedBox(height: context.padding.top + kTabTopBarHeight));
  }
}

/// Status bar icons matching the theme, as the top bar is transparent
SystemUiOverlayStyle tabTopBarOverlayStyle(BuildContext context) =>
    context.isDarkTheme ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;
