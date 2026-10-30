# HDR photos (parked)

Investigation into showing Ultra HDR / ColorOS "ProXDR" photos with their brighter highlights in the mobile app's
photo viewer, from October 2026. Parked: every working setup has a drawback, because Flutter can't render HDR itself.
The prototypes are kept on branches, see [Prototypes](#prototypes).

Device used throughout: OPPO, ColorOS, Android 16, MediaTek mt6991, 1264×2780 at 120 Hz.

## The format

ProXDR photos are standard **Ultra HDR** JPEGs (Android 14+, also called JPEG_R):

| Part | Content |
| --- | --- |
| Primary image | Normal SDR JPEG, 3072×4096. What any viewer, and the gallery's "SDR" button, shows |
| Gain map | Grayscale JPEG, 1536×2048 (~400 KB), appended after the primary image and listed in its MPF (APP2) |
| Primary XMP (APP1) | `hdrgm:Version="1.0"`, Google container directory with a `GainMap` item and its length |
| Gain map XMP | `hdrgm:GainMapMin="0"`, `GainMapMax="2.30409"` (log2, so up to 4.9× SDR white), `Gamma="1"`, offsets 0, `HDRCapacityMin/Max`, `BaseRenditionIsHDR="False"`, plus ColorOS' own `hdrgm:OplusScale="4.93855"` (= 2^GainMapMax) |
| APP5–APP10 | ~390 KB of OPPO binary data, unknown, not needed |

The gallery's ProXDR button (`com.coloros.gallery3d:id/iv_proxdr`) shows the SDR primary image while held: the gallery
switches surfaces and the backlight ramps down from ~1130 to ~510 nits over a second, then back up within ~0.3 s.

## Immich today

- The server stores the uploaded original unchanged, and `/assets/{id}/original` returns it byte for byte
  (`downloadOriginal` in `server/src/services/asset-media.service.ts`). Checked by downloading a server-only photo
  through the app: gain map and `hdrgm` metadata are there. The app requests `edited=true`, so an edited asset returns
  the edited file, which most likely has no gain map.
- Server thumbnails and previews are re-encoded without the gain map (upstream: sharp/libvips; libvips 8.18 can keep
  it, see [upstream](#upstream)).
- The app decodes images natively (`RemoteImagesImpl.kt`, `LocalImagesImpl.kt`) with `ImageDecoder` into 8-bit sRGB,
  then copies only the base image's pixels to Flutter (`toNativeBuffer` / `copyPixelsToBuffer`). Android 14+ attaches
  the gain map to the decoded bitmap, and it is dropped there. Local photos decode from the file, so they have the gain
  map even at preview size; remote ones only with "load original".
- Detecting HDR without decoding: read the JPEG headers up to the start of scan and look for the
  `http://ns.adobe.com/hdr-gain-map/1.0/` XMP namespace or the `urn:iso:std:iso:ts:21496:-1` APP2 marker (all
  prototypes have `hasGainMap`). The server doesn't record it, so remote assets can't be detected before downloading
  the original.

## Why Flutter can't do it

Flutter's Android embedding renders 8-bit sRGB only: no HDR color mode, no extended-range dataspace, no 10-bit or FP16
swapchain (checked in `flutter.jar` of Flutter 3.47). Anything brighter than SDR white is clipped. `dart:ui` has
`ColorSpace.extendedSRGB`, which iOS uses for wide gamut, but nothing on Android.

As of October 2026 ([sources](#sources)):

- [flutter#127852](https://github.com/flutter/flutter/issues/127852) "Implement Wide Gamut colors for Vulkan" is open,
  lowered to P3, "We are not currently working on this" (Mar 2025). Wide gamut alone wouldn't give HDR either, a
  Flutter engineer said Ultra HDR would need separate support.
- [flutter#192526](https://github.com/flutter/flutter/pull/192526) (Sep 2026) only fixes HDR (PQ/HLG) image decoding on
  iOS. Nothing comparable for Android, and no HDR output on either platform.
- Extended-range pixel formats are Apple-only in Impeller
  ([flutter#194156](https://github.com/flutter/flutter/issues/194156)).
- Upstream Immich ([discussion #7262](https://github.com/immich-app/immich/discussions/7262)): HDR is planned but not a
  priority. Maintainers consider native viewers more feasible than contributing HDR to Flutter. A native iOS viewer
  test had less smooth swipes and transitions, and platform views stutter when created (PR #26294 adds a Flutter
  placeholder). A user got Ultra HDR showing in a native Android view (Glide), with memory and transition issues.

A Flutter engine fork wouldn't help on ColorOS either: Flutter's SurfaceView is an app-created layer, which ColorOS
composes like our own layers (see below), so the whole UI would come out too bright.

## Android HDR mechanics

- **HWUI (Views, Compose)** applies a bitmap's gain map itself when the window is in HDR color mode
  (`window.colorMode = ActivityInfo.COLOR_MODE_HDR`). It renders gain maps for `min(display headroom, desired
  headroom)` and tags each buffer with its HDR/SDR ratio (`setExtendedRangeBrightness`, visible in logcat as
  `SurfaceControl: setExtendedRangeBrightness sc=… currentBufferRatio=…, desiredRatio=…`).
- **Ramp**: by default the headroom jumps. `Window.setDesiredHdrHeadroom` (Android 15+) animated from 1 to the gain
  map's `displayRatioForFullHdr` on a log scale over ~0.8 s gives a gallery-like brightening. Resetting it to 0 and
  leaving HDR mode returns to SDR.
- **Own layers**: `SurfaceControl` child layers can show an FP16 `HardwareBuffer` with an extended-range dataspace and
  `setExtendedRangeBrightness(current, desired)`. `SurfaceView.applyTransactionToFrame` (Android 14) applies a
  transaction together with the SurfaceView's next frame, which keeps a layer aligned with Flutter.
- **Gain map math** (Ultra HDR spec, linear light): `hdr = (sdr + epsilonSdr) * 2^(mix(log2 ratioMin, log2 ratioMax,
  gain^(1/gamma)) * weight) - epsilonHdr`, with `weight` from the display's ratio between the gain map's
  `minDisplayRatioForHdrTransition` and `displayRatioForFullHdr` on a log scale. In AGSL, sample the gain map with
  `setInputBuffer` (not color managed) and the base with `setInputShader`, then `toLinearSrgb` / `fromLinearSrgb`. ProXDR
  gain maps decode as `ALPHA_8` (value in `.a`). Decode mutable and set `bitmap.gainmap = null`, so HWUI doesn't apply
  it a second time.
- `SurfaceSyncGroup` can only sync windows and `SurfaceControlViewHost`s for apps, `add(SurfaceView, …)` is hidden.

## ColorOS specifics

What the compositor does, read from `adb shell dumpsys SurfaceFlinger` (layer `clientType`, `whitePointNits`, `dimmingRatio`,
`composition`, `current/desired hdr/sdr ratio`, `createFrom`):

| Layer | Composition | Result |
| --- | --- | --- |
| OPPO gallery window (opaque, top layer, created by system_server) | `DEVICE`, `clientType=0x0` | Correct, the reference |
| SDR layers while HDR is on | dimmed (`dimmingRatio` ≈ sdrWhite / displayPeak) | Correct |
| Our `SurfaceControl` layer, any dataspace (linear/sRGB/P3 extended), above or below Flutter | `CLIENT`, `clientType=ULTRA_HDR`, `whitePointNits` = display peak, `dimmingRatio=1` | Buffer value 1.0 is shown at the display's peak, the buffer's HDR/SDR ratio is ignored |
| Our window, translucent (Flutter's SurfaceView makes it `fmt=TRANSLUCENT`, can't be undone) | `CLIENT`, `ULTRA_HDR` | Shadows too bright |
| Our window, opaque (Flutter in texture mode) | `CLIENT`, `ULTRA_HDR`, but with the HWUI ratio applied | Correct as long as the rendered ratio matches the display's, see the texture-view notes |

The exact rule for `ULTRA_HDR` is unknown: OPPO's SurfaceFlinger isn't readable without root. Covering, opacity and
creator each contradict some observation; the gallery's window is the only one that got `DEVICE`.

**Private API** (`oplus-framework.jar`, `com.oplus.view.OplusEdrUtils`, reachable through reflection): `setEdrFlags`,
`setEdrImageSize`, `setEdrViewTransform(OplusEdrParameters)`, `setEdrGainmapInfo(OplusSkGainmapInfo)`,
`setEdrAuxiliaryImage(bitmap)`, `setEdrImageMetadata(bytes)`, `setEdrAnimDuration`, `setEdrSdrRatio`,
`getBlastSurfaceControl(SurfaceView)`, flags like `LOCALHDR_ON_WITH_ANIMATION = 65793`. "Local HDR": the compositor
applies an auxiliary image (gain map) inside a region of a layer, with its own animation. The gallery wraps it
(`EdrUtilsWrapper`, `BrightenSession`, `MaskAnimationManager`) for other features, but its photo viewer uses plain
window HDR via HWUI (logcat shows `setExtendedRangeBrightness` on `ViewGallery` and
`OplusFeatureEdrEnhanceBrightness: infoScale = 4.926 --> rearealEnhanceFactor = 4.0`). Not tried, it would be
ColorOS-only and undocumented. Decompiled with jadx from `framework.jar` (`classes4.dex`), `oplus-framework.jar`
(`classes2.dex`) and the gallery APK.

## Prototypes

All local photos only, all on Android 14+, `HdrImagePlugin.kt` and `lib/widgets/common/hdr_image.dart` on each branch.

| Branch | How | Brightness | Alignment | Ramp | Performance |
| --- | --- | --- | --- | --- | --- |
| `hdr/hcpp-platform-view` | Native `ImageView` embedded with Hybrid Composition++ (`io.flutter.embedding.android.EnableHcpp`), HWUI applies the gain map | Correct | Synced by HCPP | System default (instant) | **83%** of frames on time while swiping (98% without HCPP, 95% with HCPP but no view, 88% with an empty view) |
| `hdr/surface-control-layer` | AGSL shader renders into an FP16 buffer on a `SurfaceControl` layer below the transparent Flutter surface, hole in Flutter | Correct only with the ColorOS workaround: values scaled by 1/display ratio | Synced via `applyTransactionToFrame` | Own 0.8 s ramp | Flutter unaffected; re-renders take 3–10 ms. Flickers while the backlight changes, and is instantly bright when reopened soon after |
| `hdr/texture-view` | HWUI view in the window below Flutter rendering in **texture mode** (one opaque window), hole as a `photo_view` overlay | Correct when the ratios match | Same HWUI frame; follows zoom, pan and dismiss | `setDesiredHdrHeadroom` ramp | Not measured; texture mode copies Flutter's frame every frame |

The texture-view branch is the most complete. Its known issues and next steps:

- The window isn't redrawn when the display's headroom changes after the ramp (ambient light, backlight), so the
  rendered ratio falls behind the display's and shadows show too bright. Fix: register
  `Display.registerHdrSdrRatioChangedListener` in the view and `invalidate()` while images are shown.
- Zoomed in, the screen-size bitmap gets blurry: load full resolution (or the visible region) past 1×.
- Remote assets: reuse the bitmap `RemoteImagesImpl` decodes for "load original", which already carries the gain map.
- Measure texture mode's frame cost (see below), and check the rest of the app.
- Flutter's transparent mode switches to a texture view by itself (`FlutterFragmentActivity.getRenderMode`), which is
  why prototype B overrides `getRenderMode()` to `surface`.

Other things learned on the way:

- Decoding at screen size (1264×1685, 80–100 ms) instead of full size (3072×4096) and preloading the neighbours in
  `AssetPreloader` removed most per-swipe jank in the HCPP prototype. Keeping HDR mode between consecutive HDR photos
  halves the frame count (no repeated backlight ramp).
- The HDR photo must disappear when the viewer route starts animating (heroes fly in Flutter), and the window must
  leave HDR mode right away once no HDR photo shows, or ColorOS shows the SDR UI too bright.
- `HardwareBufferRenderer.draw` needs its own callback executor if the callback waits on the fence.
- A native viewer (Kotlin/Compose) would mean rebuilding ~3,700 lines of viewer and ~3,300 lines of `photo_view`, hero
  transitions across render surfaces, and all actions and details, and porting every upstream viewer change.

## Measuring

- Open a photo directly: `adb shell am start -a android.intent.action.VIEW -t image/jpeg -d
  content://media/external/images/media/<id> dev.moisout.immich` (or `com.coloros.gallery3d` for the reference).
- Swipe in the viewer: `adb shell 'input swipe 1000 1400 200 1400 150; sleep 1; input swipe 200 1400 1000 1400 150'`.
- HWUI frames: `dumpsys gfxinfo dev.moisout.immich reset`, then `… dev.moisout.immich` or `… framestats`. Doesn't see
  Flutter's own surface.
- Presented frames of all layers: `dumpsys SurfaceFlinger --timestats -clear -enable`, swipe, `--timestats -dump`
  (`presentToPresent` histogram; 8 ms = on time at 120 Hz), `--timestats -disable`.
- Composition: `dumpsys SurfaceFlinger`, search for `Output Layer` of the app's layers.
- The HCPP branch has a measuring switch: `adb shell am broadcast -a dev.moisout.immich.HDR_MODE --es mode
  full|sdr|empty`.
- ColorOS logs `setExtendedRangeBrightness` every frame and `SurfaceView dispatchDraw` lines; they push other lines out
  of the log buffer quickly.

## Upstream

[Discussion #7262](https://github.com/immich-app/immich/discussions/7262) tracks it. Server side, gain maps would
survive thumbnail generation with libvips 8.18 and sharp's `keepGainMap()` (suggested in the discussion), which would
need all previews regenerated. Worth checking before picking this up again: upstream may have shipped a native
viewer or server-side gain maps by then.

## Sources

- [flutter/flutter#127852: Implement Wide Gamut colors for Vulkan](https://github.com/flutter/flutter/issues/127852)
- [flutter/flutter#192526: Fix HDR image packing for iOS](https://github.com/flutter/flutter/pull/192526)
- [flutter/flutter#194156: Flutter GPU defaultColorFormat with wide gamut on Metal](https://github.com/flutter/flutter/issues/194156)
- [Flutter: Migration guide for wide gamut Color](https://docs.flutter.dev/release/breaking-changes/wide-gamut-framework)
- [Flutter & Dart's 2026 roadmap](https://flutter.dev/blog/flutter-darts-2026-roadmap)
- [immich-app/immich discussion #7262: Support for "Ultra HDR" pictures on Android](https://github.com/immich-app/immich/discussions/7262)
- [Android Developers: Enhance graphics with wide color content](https://developer.android.com/training/wide-color-gamut)
