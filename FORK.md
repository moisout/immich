# Immich mobile fork

Personal fork of the Immich Android app with UI refinements. It installs alongside the Play Store app.

- `main` mirrors upstream `immich-app/immich` and is never committed to.
- `fork` holds all fork changes, on top of `main`. One commit per change, conventional commit messages.

This document lists every fork change, which upstream files it touches, and how to carry it across upstream changes.
Keep it up to date when adding a change.

## Merging upstream

```sh
git remote add upstream https://github.com/immich-app/immich.git   # once
git fetch upstream
git switch main && git merge --ff-only upstream/main && git push origin main
git switch fork && git merge main
```

Merge rather than rebase: the fork commits touch the same files repeatedly (the timeline zoom took six commits), so a
rebase replays the same conflict several times.

When a conflict hits one of the files below, **don't resolve it line by line**. Most fork edits are structural (moved
widgets, wrapped slivers, reindented blocks), so a textual merge easily produces code that compiles but behaves
wrongly. Instead:

1. Take upstream's version of the file (`git checkout --theirs <file>` during the merge).
2. Read what upstream changed and why (the PR linked from the commit).
3. Re-apply the fork change on top, following the notes for that change below.

After merging, regenerate code and rebuild:

```sh
cd mobile
mise run codegen        # if codegen:native fails on stdarg.h, see Build below
mise exec -- flutter build apk --release --target-platform android-arm64
adb devices             # the phone's wireless adb address changes
adb -s <ip:port> install -r build/app/outputs/flutter-apk/app-release.apk
```

Then go through the [test checklist](#test-checklist).

## Build

Toolchain comes from `mise` (`mobile/mise.toml`): Flutter, Java 21. Gotchas:

- `mise install` / `mise run` rewrite `mise.lock` and `mobile/mise.lock`. Revert them, they are not fork changes.
- An upstream change to the root `mise.toml` makes mise refuse it until `mise trust` is run again.
- A full `mise install` fails resolving lock entries for other platforms. Install only what the build needs:
  `mise install` in `mobile`, plus `mise install node npm:@openapitools/openapi-generator-cli` for the API client.
- Flutter must use Java 21 (`flutter config --jdk-dir "$(mise where java)"`), Gradle 8.14 fails on Java 25.
- `codegen:native` (ffigen) can't find clang's headers, and its failure skips the other codegen tasks. Run it
  manually from `mobile` (so mise provides `dart`):
  `mise exec -- sh -c 'cd ../native/native_core && dart run ffigen --config ffigen.yaml --compiler-opts "-I/usr/lib/clang/<version>/include"'`,
  then the remaining tasks one by one: `//:open-api-dart`, `codegen:pigeon`, `codegen:translation`, `codegen:dart`,
  `codegen:drift:migration`, `codegen:drift:schema` (`mise run <task>` each).
- Release builds are signed with the local debug key (no `key.jks`). Keep `~/.android/debug.keystore`, Android only
  accepts updates signed with the same key. The installed app's key has the SHA-256 fingerprint ending in `98:1D:77`
  (`keytool -list -keystore ~/.android/debug.keystore -storepass android`).

## Changes

Files marked **fork** only exist in the fork and never conflict. All other files are upstream files with fork edits.

### 1. Separate app id and name

Installs as `dev.moisout.immich` / "Immich Fork" next to the upstream app.

| File | Edit |
| --- | --- |
| `mobile/android/app/fork.gradle` | **fork**. Overrides `applicationId` and the `app_name` string, configurable with `-Pfork.applicationId` / `-Pfork.appName` |
| `mobile/android/app/build.gradle` | One line at the end: `apply from: "fork.gradle"` |

Conflict risk: very low. If lost, re-add the `apply from` line at the end of the file.

### 2. Swipe between tabs

The four bottom tabs are a swipeable `PageView`.

| File | Edit |
| --- | --- |
| `mobile/lib/pages/common/tab_shell.page.dart` | `AutoTabsRouter` → `AutoTabsRouter.pageView`. Swiping runs the same side effects as tapping a tab (`_onTabSelected`), detected from the page view's drag scroll notifications. Swiping is disabled in multi-select, readonly mode and while two or more pointers are down (pinch to zoom) |
| `mobile/lib/routing/router.dart` | `SearchRoute` lost `maintainState: false`. Otherwise the search page is unloaded halfway through a swipe and blinks |

Re-applying: if upstream changes the tab shell, keep their navigation logic and swap the router constructor again;
the builder signature of `pageView` is `(context, child, pageController)`. The search page must stay alive
(`maintainState` true), the swipe and the overlaid top bar (change 5) both depend on it.

### 3. Smooth pinch to zoom on the timeline

Pinching the photo grid follows the fingers continuously. The layout with the next column count is cross-faded in with
the pinch progress, the column count switches underneath once fully zoomed, and it settles on release.

How it works:

- The zoom transform and opacity are applied while painting the grid sliver (no rebuilds while pinching).
- A second, non-interactive grid with the neighbouring column count (the "preview") is rendered underneath, aligned on
  the asset under the fingers. Both neighbouring previews are built when the second finger touches down, before any
  movement, so building them doesn't cause a visible hitch.
- When fully zoomed, the `timelineTilesPerRow` setting is written. The timeline keeps the previous layout on screen
  while the segments are regenerated and restores the scroll position to the anchor asset, then the preview is
  removed. The preview already shows the identical layout, so the swap is invisible.
- Scrolling is ignored while two pointers are down, through scroll physics (no rebuild).
- Long press selection is ignored while two pointers are down.
- `_kPinchSensitivity` (0.6) slows the zoom down relative to the fingers.

| File | Edit |
| --- | --- |
| `.../widgets/timeline/timeline_pinch_zoom.dart` | Rewritten. Gesture state machine, `TimelineZoomController`, previews, column switching. Fork-owned in practice |
| `.../widgets/timeline/sliver_segmented_list.dart` | `zoomTransform` / `zoomOpacity` listenables. The render object paints its children through them, and paints the cache extent too while zoomed |
| `.../widgets/timeline/timeline.widget.dart` | See below |
| `.../widgets/timeline/timeline_drag_selection.dart` | Ignore drag selection start and auto-scroll while multi-touch |
| `.../widgets/timeline/fixed/segment.model.dart` | Ignore tile long press while multi-touch |

`timeline.widget.dart` is the highest risk file of the fork. Its edits:

1. `TimelinePinchZoom` wraps the whole `asyncSegments.widgetWhen(...)` body (upstream wraps only the data branch).
   It must stay outside, so the gesture survives the timeline rebuilding.
2. **Keeps the previous segments while reloading** (`watchedSegments.isReloading && hasValue` → `AsyncData`).
   Upstream shows a loading indicator and rebuilds the scroll view whenever the column count or width changes.
3. **Restores the scroll position when new segments arrive**, from a `ref.listenManual(timelineSegmentProvider)` in
   `initState`, as the scroll view no longer re-attaches. `_restoreAssetPosition` also takes a
   `_restoreScrollAdjustment` (to keep the anchor under the fingers instead of at the top) and completes
   `_restoreCompleter`, which the zoom waits for.
4. `_onColumnCountWillChange(anchor)` computes the restore target from the anchor tile.
5. `_ZoomLockScrollPhysics` wraps the grid physics.
6. `SliverSegmentedList` gets the grid's zoom notifiers. The preview grids (`_ZoomPreviewGrid`, built from
   `_buildPreviewSegments`) are the first children of the timeline's `Stack`, below the grid.
7. `topBarBackground` parameter, see change 5.

Re-applying: `timeline_pinch_zoom.dart` originally came from upstream (a simple discrete zoom), the fork replaced it
entirely. If upstream reworks the timeline, take theirs and re-add points 1 to 7. The preview reuses
`FixedSegmentBuilder` and `segment.builder`, so if upstream changes how segments are built, `_buildPreviewSegments`
must follow (it mirrors `timelineSegmentProvider`). If upstream improves its own zoom, compare before re-applying, it
might make parts of this unnecessary.

### 4. Fixed, blurred top bar on the tabs

The top bars of the four tabs overlay the content instead of scrolling away, on a progressive blur (strongest at the
top). They stay in place while swiping between tabs and cross-fade into each other.

How it works: each tab page wraps itself in `TabTopBar`, which renders the bar contents through an `OverlayPortal`, so
they are not moved by the page view and the page keeps owning their state (such as the search field). The tab shell
provides the page position through `TabTopBarScope` for the cross-fade. The blur is a single shader backdrop filter
(`progressive_blur.frag`), which needs Impeller (falls back to a uniform blur otherwise). Pages start their content
below the bar with `SliverTabTopBarSpacer`.

| File | Edit |
| --- | --- |
| `mobile/lib/widgets/common/tab_top_bar.dart` | **fork**. `TabTopBar`, `TabTopBarScope`, `TabTopBarBackground`, `SliverTabTopBarSpacer`, `SliverTabBottomSpacer`, `FlexibleSpaceTopBarBlur`, `SliverScrollUnder` |
| `mobile/shaders/progressive_blur.frag` | **fork**. Separable blur pass whose strength fades out from the top |
| `mobile/pubspec.yaml` | `shaders:` entry under `flutter:` |
| `mobile/lib/pages/common/tab_shell.page.dart` | Provides `TabTopBarScope` around the page view |
| `mobile/lib/widgets/common/immich_sliver_app_bar.dart` | Actions extracted to `_buildActions`; new `ImmichTabTopBar` (transparent `AppBar` with the same title and actions) |
| `.../pages/dev/main_timeline.page.dart` | Wrapped in `TabTopBar`; timeline `appBar: SliverTabTopBarSpacer()`, `topBarBackground` |
| `.../widgets/timeline/timeline.widget.dart` | `topBarBackground` placed in the timeline `Stack` between the grid and the multi-select controls |
| `mobile/lib/presentation/pages/album.page.dart` | `ImmichSliverAppBar` → spacer, wrapped in `TabTopBar` |
| `mobile/lib/presentation/pages/library.page.dart` | Same |
| `.../pages/search/search.page.dart` | See below |

`search.page.dart`: the `AppBar` (search field and menu) and the filter chips moved out of the `Scaffold` into the
`TabTopBar` bar, so results scroll underneath both. The bar fades out in multi-select. The search field background is
opaque (`alphaBlend` of the original tint onto `surfaceContainerLow`). `_SearchResultGrid` takes `headerExtent` and
pads its timeline / no results view with it. The diff is mostly moved code; when upstream changes this page, take
theirs and move the app bar and chips again rather than merging text. New search filters or menu items from upstream
come along automatically that way.

If upstream adds a new tab, it needs a `TabTopBar` with its index and a spacer, or it will scroll under nothing.

### 5. Blurred top bars on secondary pages

Pages opened from the tabs get the same blur, with content scrolling under the collapsed bar.

`SliverScrollUnder` wraps a pinned `SliverAppBar` and reports a smaller layout extent, so the following slivers
scroll underneath its pinned part. The app bars use `forceMaterialTransparency` and draw the blur in their flexible
space (`FlexibleSpaceTopBarBlur` for collapsing image headers, fading in as they collapse; `TabTopBarBackground` with
`fillParent` for plain bars).

| File | Edit |
| --- | --- |
| `mobile/lib/widgets/common/mesmerizing_sliver_app_bar.dart` | `SliverScrollUnder`, transparent, `FlexibleSpaceTopBarBlur`. Used by favorites, archive, locked folder, recently added/taken, videos, partner, place detail, local timeline |
| `mobile/lib/widgets/common/remote_album_sliver_app_bar.dart` | Same, album page |
| `mobile/lib/widgets/common/person_sliver_app_bar.dart` | Same, person page |
| `mobile/lib/presentation/pages/trash.page.dart` | Plain bar treatment |
| `mobile/lib/presentation/pages/place.page.dart` | Plain bar treatment |
| `mobile/lib/widgets/common/local_album_sliver_app_bar.dart` | Plain bar treatment |
| `mobile/lib/presentation/pages/people_collection.page.dart` | `extendBodyBehindAppBar`, transparent bar with blur, grid padded by the top inset instead of `SafeArea` |

The three header files are reindented by the `SliverScrollUnder(sliver: ...)` wrapper, so any upstream change in them
conflicts. Take theirs and re-apply three edits per file: wrap the returned `SliverAppBar` in `SliverScrollUnder`, add
`forceMaterialTransparency: true`, wrap the `FlexibleSpaceBar` in `FlexibleSpaceTopBarBlur`. New pages with pinned
app bars from upstream don't get the treatment automatically.

### 6. Floating navigation bar

The bottom navigation bar is a floating, centered, blurred pill (max 340 wide); the pages extend underneath it
(`extendBody`). The selected destination is highlighted as a whole, icon and label, which Material's `NavigationBar`
can't do, so it is a custom row of `_FloatingNavigationItem`s built from the same `NavigationDestination`s as the
landscape rail.

| File | Edit |
| --- | --- |
| `mobile/lib/pages/common/tab_shell.page.dart` | `_BottomNavigationBarState.build` replaces the `NavigationBar` with the floating pill and `_FloatingNavigationItem`. `Scaffold(extendBody: true)` |
| `album.page.dart`, `library.page.dart`, `search.page.dart` | `SliverTabBottomSpacer` at the end of their scroll views. Timelines already pad by the bottom inset |

A new scrolling tab page from upstream needs a `SliverTabBottomSpacer` (or bottom inset padding), or its last items
end up behind the bar.

### 7. Overscroll bounce with an edge haptic

Vertical scrollables overshoot their edges and spring back instead of Android's stretch, with a light haptic tick when
they start to overshoot. Horizontal scrollables stop at their edges without any effect.

`OverscrollScrollBehavior` (set as the app's `scrollBehavior`) picks the physics per scrollable from its axis:
`BouncingScrollPhysics` vertically, `ClampingScrollPhysics` horizontally. It removes the overscroll indicator, and wraps
vertical scrollables in a listener that plays the haptic when a scroll update crosses from in range to out of range.
The haptic is ColorOS' private feedback constant 307 (the one its gallery plays, found with
`adb shell dumpsys vibrator_manager`), played through a method channel; elsewhere it falls back to
`HapticFeedback.selectionClick`.

| File | Edit |
| --- | --- |
| `mobile/lib/widgets/common/overscroll_scroll_behavior.dart` | **fork**. `OverscrollScrollBehavior`, haptic listener |
| `mobile/android/app/src/main/kotlin/app/alextran/immich/fork/ScrollLimitHapticsPlugin.kt` | **fork**. Method channel `immich/fork/scroll_limit_haptics`, plays the ColorOS haptic |
| `mobile/android/app/src/main/kotlin/app/alextran/immich/MainActivity.kt` | Import and `flutterEngine.plugins.add(ScrollLimitHapticsPlugin())` in `registerPlugins` |
| `mobile/lib/main.dart` | Import and `scrollBehavior: const OverscrollScrollBehavior()` on `MaterialApp.router` |
| `.../widgets/timeline/scrubber.widget.dart` | `_currentOffset` clamped to the scrubber height, so the thumb doesn't follow the overshoot |
| `.../widgets/asset_viewer/asset_page.widget.dart` | `SnapScrollPhysics(parent: ClampingScrollPhysics())`, the details sheet keeps clamping |

Upstream scrollables with explicit physics keep them: `ClampingScrollPhysics` clamps, and physics with a parent
inherit the bounce. Code that reads `pixels` against the scroll extent may need clamping like the scrubber.
`main.dart` and `MainActivity.kt` use CRLF line endings.

### 8. Predictive back

Android's predictive back is enabled, and every back gesture animates along with the finger and can be cancelled.
Upstream disabled it in #12221 because back closed the app; their back handling has since moved to `PopScope`, which
predictive back relies on.

| Back gesture on | Animation |
| --- | --- |
| Pages | Their pop transition (fade forwards: slide and fade), following the finger 1:1 |
| Dialogs, bottom sheets, menus | Their exit animation, 40% of the way (`kPredictiveBackPreviewExtent`), the rest on release |
| Photos tab (root) | System back-to-home |
| Other tabs | The pager slides back to Photos |
| Photo viewer | Drag to dismiss: the photo follows the finger, shrinks towards it and the background fades; release closes it like a swipe down (hero back to the thumbnail). Zoomed in, the route fades instead |
| Photo viewer with details open | The details close first, following the finger |

How it works:

- `PredictiveBackRouteObserver` (a navigator observer that is also a binding observer) drives the top route's
  animation through the route's own `handleStartBackGesture` / `handleUpdateBackGestureProgress`, and pops it itself on
  release, because Flutter's `handleCommitBackGesture` restarts the exit animation from the start. It starts the gesture
  at the fully open value before moving the animation, so transitions see a pop from the first frame.
- Pages use `BackGestureFadeForwardsPageTransitionsBuilder`, Flutter's `FadeForwardsPageTransitionsBuilder` with its
  animations reported as reversing while a back gesture runs (`_BackGestureAnimation`). Otherwise it would show its push
  animation in reverse, which has a different curve and fade.
- `PredictiveBackScope` lets a page handle the gesture itself (tab shell, photo viewer): it gets the progress, and the
  route observer leaves its route alone while it's enabled. With `interceptsPop` it also blocks the pop (a `PopScope`)
  and handles the back button.
- The photo viewer's heroes (`thumbnail_tile.widget.dart` and the photo view in `asset_page.widget.dart`) have
  `transitionOnUserGestures`, so they fly along with a gesture-driven route animation.
- When a gesture is cancelled, Android animates the progress back to 0 before reporting the cancel, keeping the last
  touch position. The photo viewer scales its touch offset with the progress for that reason.

The photo viewer also got changes that apply without the gesture:

- Drag to dismiss shrinks the photo more slowly (half size over the screen height, at most down to 40%) and around the
  finger, fades the background over half the screen height, and brings it back gradually when cancelled.
- The route's close fade uses `Curves.easeOutCubic`, the black background stays longer.
- The details panel slides in from the bottom of the screen (`_detailsShift`) instead of appearing under the photo,
  and stays rendered until it has scrolled out (`_keepDetails`). Upstream removed it as soon as it was released.

| File | Edit |
| --- | --- |
| `mobile/lib/widgets/common/predictive_back.dart` | **fork**. Route observer, `PredictiveBackScope`, page transition builder |
| `mobile/android/app/src/main/AndroidManifest.xml` | `android:enableOnBackInvokedCallback="true"` |
| `mobile/lib/main.dart` | `PredictiveBackRouteObserver()` in `navigatorObservers` |
| `mobile/lib/theme/theme_data.dart` | `pageTransitionsTheme`: the fork builder on Android, Cupertino on iOS |
| `mobile/lib/pages/common/tab_shell.page.dart` | `PopScope` replaced by `PredictiveBackScope`, `_onBack*` methods driving the page controller |
| `.../widgets/asset_viewer/asset_page.widget.dart` | `PredictiveBackScope` around the page, `_onBack*` methods, `_updateDismiss` / `_cancelDismiss` extracted from the drag handlers, details shift and keep |
| `.../widgets/images/thumbnail_tile.widget.dart` | `transitionOnUserGestures: true` on the `Hero` |
| `mobile/lib/routing/router.dart` | Asset viewer route fades with `Curves.easeOutCubic` |

Re-applying: pages from upstream get the gesture automatically. A new in-page back state (something closed by back
without leaving the page) needs a `PredictiveBackScope` to follow the finger; a plain `PopScope` still works, it just
switches on release. If upstream enables auto_route's `enablePredictiveBackGesture`, turn it off again, auto_route
would wrap pages in Flutter's predictive back transition and both would drive the route.

### 9. Agent instructions

Upstream's `AGENTS.md` files are trimmed to what applies to the fork: the root one keeps the repo overview (mobile and
native only), mise tasks, generated files and translations, and drops upstream's contribution rules (PRs, issues, "no
code comments", feature freezes) and server-side skills. `mobile/AGENTS.md` and `native/AGENTS.md` are kept as they
are; the ones for `server/`, `web/`, `e2e/` and `machine-learning/` are deleted.

Re-applying: an upstream change to a deleted file shows as a modify/delete conflict, keep it deleted (`git rm`). For the
root `AGENTS.md`, take theirs and trim it again.

## Parked investigations

- HDR photos (Ultra HDR / ProXDR) in the viewer: [FORK-HDR.md](FORK-HDR.md), prototypes on the `hdr/*` branches.

## Conflict hotspots

| File | Changes | Risk | Strategy |
| --- | --- | --- | --- |
| `.../widgets/timeline/timeline.widget.dart` | 3, 4 | High | Take theirs, re-apply the 7 points of change 3 |
| `.../widgets/timeline/timeline_pinch_zoom.dart` | 3 | High if upstream touches zoom | Keep ours, port upstream fixes by hand |
| `.../pages/search/search.page.dart` | 4 | High | Take theirs, move app bar and chips into `TabTopBar` |
| `mobile/lib/pages/common/tab_shell.page.dart` | 2, 4, 6, 8 | Medium | Merge by hand, the edits are in separate places. New destinations or tab side effects from upstream must also reach `_FloatingNavigationItem` (it reads `icon`, `selectedIcon`, `label`, `enabled`) |
| `.../widgets/timeline/sliver_segmented_list.dart` | 3 | Medium | Keep the paint override, merge layout changes |
| `mesmerizing` / `remote_album` / `person_sliver_app_bar.dart` | 5 | Medium | Take theirs, re-apply the three edits |
| `immich_sliver_app_bar.dart` | 4 | Low | New actions go into `_buildActions` |
| Other pages listed above | 4, 5, 6 | Low | Small edits, merge by hand |
| `.../widgets/asset_viewer/asset_page.widget.dart` | 7, 8 | High | Take theirs, re-apply change 8's viewer edits: the scope and `_onBack*` methods, `_updateDismiss` / `_cancelDismiss`, details shift and keep, hero flag. Keep upstream's drag handling and port it into the extracted methods |
| `main.dart`, `MainActivity.kt`, `scrubber.widget.dart` | 7, 8 | Low | One or two lines each, re-add |
| `theme_data.dart`, `router.dart`, `thumbnail_tile.widget.dart`, `AndroidManifest.xml` | 8 | Low | One small edit each, re-add |
| `AGENTS.md` files | 9 | Low | Keep the deleted ones deleted, trim the root one again |

## Test checklist

- Fork and Play Store app both installed, the fork shows as "Immich Fork".
- Swipe between all four tabs, both ways; the top bars cross-fade, nothing blinks (especially Search).
- Tap tabs, including non-adjacent ones; tapping Photos again scrolls to the top, tapping Search again focuses it.
- Pinch the timeline in and out, slowly and quickly, through several column counts in one gesture, near the top
  and the bottom of the timeline. Release halfway. No hitch when starting, the photo under the fingers stays put.
- Pinch doesn't select photos, doesn't scroll, doesn't switch tabs.
- Long press and drag selection still work with one finger; multi-select hides the bars properly.
- Top bar blur over busy photos on all tabs; status bar icons readable in light and dark theme.
- Search: results scroll under the search field and chips, chips and menu work, keyboard opens.
- Album, person, favorites pages: header collapses into a blurred bar, content scrolls underneath.
- Trash, places, people, on device albums: blurred bar, content scrolls underneath.
- Floating navigation bar: content visible underneath, last items of albums/library/search reachable.
- Dialogs (profile) and pushed pages cover the top bar.
- Rotate to landscape: navigation rail, top bar starts right of it.
- Vertical lists bounce at both ends with one light tick each time, horizontal ones (tabs, photo viewer) stop dead.
- Timeline scrubber thumb stays within its track while bouncing; album pull to refresh still works; the photo
  viewer's swipe up for details and swipe down to close behave as before.
- Back gesture, slowly, cancelled and released, on: a page (album, settings), a dialog, a bottom sheet, the Search,
  Albums and Library tabs (pager slides to Photos), the Photos tab (back-to-home).
- Photo viewer: back drags the photo like a swipe down, release lands it on its thumbnail, cancel glides it back with
  the background; zoomed in, the route fades. With details open (also scrolled down), back closes only the details.
- Details panel slides in from the bottom and stays visible while sliding out, after swipe down and after back.
- Multi-select: back clears the selection. Photo editor with changes and backup album selection still ask before
  leaving. Locked folder locks again on back. The back button (3-button navigation) works everywhere.
