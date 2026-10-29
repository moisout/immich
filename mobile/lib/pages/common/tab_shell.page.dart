import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/search/paginated_search.provider.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/search/search_input_focus.provider.dart';
import 'package:immich_mobile/providers/tab.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/tab_top_bar.dart';

@RoutePage()
class TabShellPage extends ConsumerStatefulWidget {
  const TabShellPage({super.key});

  @override
  ConsumerState<TabShellPage> createState() => _TabShellPageState();
}

class _TabShellPageState extends ConsumerState<TabShellPage> {
  StreamSubscription? _multiSelectSubscription;
  bool _isMultiSelectEnabled = false;
  int _pointerCount = 0;
  int? _swipeStartIndex;

  @override
  void initState() {
    super.initState();
    _multiSelectSubscription = EventStream.shared.listen<MultiSelectToggleEvent>(
      (event) => setState(() => _isMultiSelectEnabled = event.isEnabled),
    );
  }

  @override
  void dispose() {
    unawaited(_multiSelectSubscription?.cancel());
    super.dispose();
  }

  // Swiping is disabled while multiple pointers are down so pinch-to-zoom on the timeline doesn't change tabs
  void _onPointerCountChanged(int delta) {
    final wasMultiTouch = _pointerCount > 1;
    _pointerCount = (_pointerCount + delta).clamp(0, 10);
    if (wasMultiTouch != _pointerCount > 1) {
      setState(() {});
    }
  }

  bool _onPageScrollNotification(ScrollNotification notification, TabsRouter tabsRouter) {
    // Ignore scrolling inside the tab pages themselves
    if (notification.depth != 0) {
      return false;
    }

    if (notification is ScrollStartNotification && notification.dragDetails != null) {
      _swipeStartIndex = tabsRouter.activeIndex;
    } else if (notification is ScrollEndNotification && _swipeStartIndex != null) {
      final previousIndex = _swipeStartIndex!;
      _swipeStartIndex = null;
      if (tabsRouter.activeIndex != previousIndex) {
        _onTabSelected(previousIndex, tabsRouter.activeIndex, ref);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final isScreenLandscape = context.orientation == Orientation.landscape;
    final isReadonlyModeEnabled = ref.watch(readonlyModeProvider);

    final navigationDestinations = <NavigationDestination>[
      NavigationDestination(
        label: context.t.photos,
        icon: const Icon(Icons.photo_library_outlined),
        selectedIcon: Icon(Icons.photo_library, color: context.primaryColor),
      ),
      NavigationDestination(
        label: context.t.search,
        icon: const Icon(Icons.search_rounded),
        selectedIcon: Icon(Icons.search, color: context.primaryColor),
        enabled: !isReadonlyModeEnabled,
      ),
      NavigationDestination(
        label: context.t.albums,
        icon: const Icon(Icons.photo_album_outlined),
        selectedIcon: Icon(Icons.photo_album_rounded, color: context.primaryColor),
        enabled: !isReadonlyModeEnabled,
      ),
      NavigationDestination(
        label: context.t.library$,
        icon: const Icon(Icons.space_dashboard_outlined),
        selectedIcon: Icon(Icons.space_dashboard_rounded, color: context.primaryColor),
        enabled: !isReadonlyModeEnabled,
      ),
    ];

    Widget navigationRail(TabsRouter tabsRouter) {
      return NavigationRail(
        destinations: navigationDestinations
            .map(
              (e) => NavigationRailDestination(
                icon: e.icon,
                label: Text(e.label),
                selectedIcon: e.selectedIcon,
                disabled: !e.enabled,
              ),
            )
            .toList(),
        onDestinationSelected: (index) => _onNavigationSelected(tabsRouter, index, ref),
        selectedIndex: tabsRouter.activeIndex,
        labelType: NavigationRailLabelType.all,
        groupAlignment: 0.0,
      );
    }

    final canSwipe = !isReadonlyModeEnabled && !_isMultiSelectEnabled && _pointerCount < 2;

    return AutoTabsRouter.pageView(
      routes: const [MainTimelineRoute(), SearchRoute(), AlbumsRoute(), LibraryRoute()],
      physics: canSwipe ? null : const NeverScrollableScrollPhysics(),
      builder: (context, pageView, pageController) {
        final tabsRouter = AutoTabsRouter.of(context);
        final child = LayoutBuilder(
          builder: (context, constraints) => TabTopBarScope(
            pageController: pageController,
            activeIndex: tabsRouter.activeIndex,
            // The pages are aligned to the right, next to the navigation rail in landscape
            leftInset: MediaQuery.sizeOf(context).width - constraints.maxWidth,
            child: Listener(
              onPointerDown: (_) => _onPointerCountChanged(1),
              onPointerUp: (_) => _onPointerCountChanged(-1),
              onPointerCancel: (_) => _onPointerCountChanged(-1),
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) => _onPageScrollNotification(notification, tabsRouter),
                child: pageView,
              ),
            ),
          ),
        );
        return PopScope(
          canPop: tabsRouter.activeIndex == 0,
          onPopInvokedWithResult: (didPop, _) => !didPop ? tabsRouter.setActiveIndex(0) : null,
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            // The navigation bar floats over the pages
            extendBody: true,
            body: isScreenLandscape
                ? Row(
                    children: [
                      navigationRail(tabsRouter),
                      const VerticalDivider(),
                      Expanded(child: child),
                    ],
                  )
                : child,
            bottomNavigationBar: _BottomNavigationBar(tabsRouter: tabsRouter, destinations: navigationDestinations),
          ),
        );
      },
    );
  }
}

void _onNavigationSelected(TabsRouter router, int index, WidgetRef ref) {
  _onTabSelected(router.activeIndex, index, ref);
  ref.read(hapticFeedbackProvider.notifier).selectionClick();
  router.setActiveIndex(index);
}

/// Shared by tapping a navigation destination and swiping between tabs
void _onTabSelected(int previousIndex, int index, WidgetRef ref) {
  // On Photos page menu tapped
  if (previousIndex == kPhotoTabIndex && index == kPhotoTabIndex) {
    EventStream.shared.emit(const ScrollToTopEvent());
  }

  if (index == kPhotoTabIndex) {
    ref.invalidate(memoryLaneProvider);
  }

  if (previousIndex != kSearchTabIndex && index == kSearchTabIndex) {
    ref.read(searchPreFilterProvider.notifier).clear();
  }

  // On Search page tapped
  if (previousIndex == kSearchTabIndex && index == kSearchTabIndex) {
    ref.read(searchInputFocusProvider).requestFocus();
  }

  // Album page
  if (index == kAlbumTabIndex) {
    unawaited(ref.read(remoteAlbumProvider.notifier).refresh());
  }

  ref.read(tabProvider.notifier).state = TabEnum.values[index];
}

class _BottomNavigationBar extends ConsumerStatefulWidget {
  const _BottomNavigationBar({required this.tabsRouter, required this.destinations});

  final List<NavigationDestination> destinations;
  final TabsRouter tabsRouter;

  @override
  ConsumerState createState() => _BottomNavigationBarState();
}

class _BottomNavigationBarState extends ConsumerState<_BottomNavigationBar> {
  bool hideNavigationBar = false;
  StreamSubscription? _eventSubscription;

  @override
  void initState() {
    super.initState();
    _eventSubscription = EventStream.shared.listen<MultiSelectToggleEvent>(_onEvent);
  }

  void _onEvent(MultiSelectToggleEvent event) {
    setState(() {
      hideNavigationBar = event.isEnabled;
    });
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isScreenLandscape = context.orientation == Orientation.landscape;

    if (isScreenLandscape || hideNavigationBar) {
      return const SizedBox.shrink();
    }

    final background = context.themeData.navigationBarTheme.backgroundColor ?? context.colorScheme.surfaceContainer;
    const borderRadius = BorderRadius.all(Radius.circular(_kFloatingNavigationBarHeight / 2));

    // Floats over the pages, which extend underneath it
    return Padding(
      padding: EdgeInsets.only(bottom: context.padding.bottom + 12),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: math.min(_kFloatingNavigationBarMaxWidth, context.width - 32)),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 16, offset: const Offset(0, 4)),
              ],
            ),
            child: ClipRRect(
              borderRadius: borderRadius,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: background.withValues(alpha: 0.75),
                    borderRadius: borderRadius,
                    border: Border.all(color: context.colorScheme.outlineVariant.withValues(alpha: 0.3)),
                  ),
                  child: SizedBox(
                    height: _kFloatingNavigationBarHeight,
                    child: Padding(
                      padding: const EdgeInsets.all(_kFloatingNavigationBarPadding),
                      child: Row(
                        children: [
                          for (final (index, destination) in widget.destinations.indexed)
                            Expanded(
                              child: _FloatingNavigationItem(
                                destination: destination,
                                isSelected: widget.tabsRouter.activeIndex == index,
                                onTap: () => _onNavigationSelected(widget.tabsRouter, index, ref),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const double _kFloatingNavigationBarHeight = 68;
const double _kFloatingNavigationBarPadding = 6;
const double _kFloatingNavigationBarMaxWidth = 340;

/// A destination of the floating navigation bar, highlighted as a whole (icon and label) when selected
class _FloatingNavigationItem extends StatelessWidget {
  const _FloatingNavigationItem({required this.destination, required this.isSelected, required this.onTap});

  final NavigationDestination destination;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final foreground = isSelected ? colorScheme.onSecondaryContainer : colorScheme.onSurfaceVariant;
    const shape = StadiumBorder();

    return Semantics(
      button: true,
      selected: isSelected,
      enabled: destination.enabled,
      label: destination.label,
      excludeSemantics: true,
      child: Opacity(
        opacity: destination.enabled ? 1 : 0.38,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: shape,
            onTap: destination.enabled ? onTap : null,
            child: AnimatedContainer(
              duration: Durations.short4,
              curve: Curves.easeOut,
              decoration: ShapeDecoration(
                shape: shape,
                color: isSelected
                    ? colorScheme.secondaryContainer
                    : colorScheme.secondaryContainer.withValues(alpha: 0),
              ),
              child: IconTheme.merge(
                data: IconThemeData(color: foreground, size: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    isSelected ? destination.selectedIcon ?? destination.icon : destination.icon,
                    const SizedBox(height: 2),
                    Text(
                      destination.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.labelMedium?.copyWith(
                        color: foreground,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
