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
- Flutter must use Java 21 (`flutter config --jdk-dir "$(mise where java)"`), Gradle 8.14 fails on Java 25.
- `codegen:native` (ffigen) can't find clang's headers. Run it manually:
  `cd native/native_core && dart run ffigen --config ffigen.yaml --compiler-opts "-I/usr/lib/clang/<version>/include"`,
  then rerun `mise run codegen:dart codegen:drift:migration` which were skipped.
- Release builds are signed with the local debug key (no `key.jks`). Keep `~/.android/debug.keystore`, Android only
  accepts updates signed with the same key.

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

The bottom navigation bar is a floating, rounded, blurred pill; the pages extend underneath it (`extendBody`).

| File | Edit |
| --- | --- |
| `mobile/lib/pages/common/tab_shell.page.dart` | `_BottomNavigationBarState.build` wraps the `NavigationBar` (transparent, height 68, bottom padding removed) in padding, shadow, clip, blur and a translucent background. `Scaffold(extendBody: true)` |
| `album.page.dart`, `library.page.dart`, `search.page.dart` | `SliverTabBottomSpacer` at the end of their scroll views. Timelines already pad by the bottom inset |

A new scrolling tab page from upstream needs a `SliverTabBottomSpacer` (or bottom inset padding), or its last items
end up behind the bar.

## Conflict hotspots

| File | Changes | Risk | Strategy |
| --- | --- | --- | --- |
| `.../widgets/timeline/timeline.widget.dart` | 3, 4 | High | Take theirs, re-apply the 7 points of change 3 |
| `.../widgets/timeline/timeline_pinch_zoom.dart` | 3 | High if upstream touches zoom | Keep ours, port upstream fixes by hand |
| `.../pages/search/search.page.dart` | 4 | High | Take theirs, move app bar and chips into `TabTopBar` |
| `mobile/lib/pages/common/tab_shell.page.dart` | 2, 4, 6 | Medium | Merge by hand, the edits are in separate places |
| `.../widgets/timeline/sliver_segmented_list.dart` | 3 | Medium | Keep the paint override, merge layout changes |
| `mesmerizing` / `remote_album` / `person_sliver_app_bar.dart` | 5 | Medium | Take theirs, re-apply the three edits |
| `immich_sliver_app_bar.dart` | 4 | Low | New actions go into `_buildActions` |
| Other pages listed above | 4, 5, 6 | Low | Small edits, merge by hand |

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
