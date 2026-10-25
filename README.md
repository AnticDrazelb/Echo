# Echo

**Steal the vibe. Keep your story.**

Echo clones the *look* of any image or video (its color grade, light, texture and optics) and applies it live to your own photos and videos. Everything runs on device: references are analysed into a few hundred bytes of **Style DNA**, and the original pixels are never stored or uploaded.

## Features

| | |
|---|---|
| **Capture a reference** | "+ New Style" opens the live camera ("hold to lock the look") with a Photos picker for images, videos, Live Photos and screenshots. Text and UI are detected and ignored. |
| **Style DNA** | Oklab tone distribution (17 quantiles), shadow/mid/highlight tints, per-hue saturation roll-off, film grain amount & size, halation, vignette and chromatic aberration. |
| **Apply + refine** | Metal-backed live preview with a before/after split, a 0–100 intensity slider, toggles for Color / Light / Grain / Optics, and smart regions (Sky, Skin, Subject) built with Vision. |
| **Video** | Live styled playback; export keeps audio and orientation. |
| **Camera** | Shoot with any look live: tap for a photo, hold to record styled video with sound. |
| **Home** | Style cards preview each look on your own last photo (kept privately on device), with the reference thumbnail. |
| **Blend** | Mix a second look in from the editor, or blend up to three (for example 50/30/20) into a new style. |
| **Export** | One tap saves to Photos (HEIF). The advanced sheet bakes a `.cube` LUT for Final Cut, Resolve or Premiere, AirDrops a `.echostyle` file, or copies an `echo://` link. |
| **Attribution** | An optional "Style inspired by @creator" credit is burned into exports. |
| **Relighting** | Photos with depth (Portrait mode, LiDAR) can be re-lit to match the reference's key-light direction: Editor › Light › Relight. |
| **Museum Mode** | Point the camera at one of the bundled public-domain masterpieces: Echo recognises it on device, applies its look and shows a plaque. Nothing from the camera is saved. |
| **StandBy & widgets** | Rotating Style Cards on the Home Screen and in StandBy; tap to shoot with that look. |
| **Live Activity** | Video exports and batch jobs show progress, a preview thumbnail and a Cancel button on the Lock Screen and Dynamic Island. |
| **Batch** | Apply a look to many photos at once (long-press a style card). |
| **Echo Studio** | A layered compositor: base photo/video, adjustment, text, shape, gradient, solid and image layers; 17 blend modes; masks (shape, gradient, luma key, Vision sky/skin/subject); 33 GPU effects (Echo Look, curves, glow, light leak, blurs, glitch, RGB split, halftone, grain, camera shake…); every parameter keyframeable with easing; timeline, animation presets, undo/redo; render to H.265 video (keeping original audio) or a full-res still. |
| **Apple Watch** | Remote with a live preview from the phone, Digital Crown intensity (0–100), shutter/record, and a haptic when a look locks. |

## How the engine works

1. `StyleAnalyzer` downsamples the reference, converts it to Oklab and measures its statistics. Grain is estimated from the median high-frequency residual, so real detail is ignored.
2. `StyleTransfer` builds a content-adaptive mapping from the *target's* statistics to the *reference's* statistics. It uses histogram-matched tone (slope-limited and smoothed so it never posterizes), zone tints, and hue-aware chroma scaling with gamut-safe chroma reduction. The mapping is baked into a 32³ color cube.
3. `StyleRenderer` builds a Core Image graph with the cube, halation, aberration, vignette, grain, the intensity mix and the region mask. The same graph drives the live preview, camera frames, video export and full-resolution photo export.

## Building

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open Echo.xcodeproj
```

Requires Xcode 15+, iOS 17+ and (for the Watch app) watchOS 10+. Building with Xcode 26 adds iOS 26 Liquid Glass; older SDKs fall back to system materials.

### CI: IPA from GitHub's Mac runners

`.github/workflows/ios.yml` runs on every push:

- **Unit tests** on the newest iPhone simulator.
- **Build IPA**: produces `Echo-unsigned.ipa`, available as a workflow artifact. Pushing a `v*` tag also attaches it to a GitHub Release.

To install the unsigned IPA, sign it on your machine with a sideloading tool such as AltStore, Sideloadly or `zsign`.

To get a **signed** IPA straight from CI, add these repository secrets:

| Secret | Value |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | `base64 -i dist.p12`: your Apple Distribution (or Development) certificate |
| `P12_PASSWORD` | Password for the .p12 |
| `BUILD_PROVISION_PROFILE_BASE64` | Profile for `com.anticdrazelb.echo` (with the `group.com.anticdrazelb.echo` App Group) |
| `WIDGETS_PROVISION_PROFILE_BASE64` | Profile for `com.anticdrazelb.echo.widgets` (same App Group) |
| `WATCH_PROVISION_PROFILE_BASE64` | Profile for `com.anticdrazelb.echo.watchkitapp` |
| `KEYCHAIN_PASSWORD` | Any random string (optional) |

When these secrets are set, the workflow also archives and exports `Echo.ipa`. It uses ad-hoc by default; choose `development` or `app-store` with *Run workflow*.

## Project layout

```
Echo/
  App/        entry point, navigation, deep links
  Core/       Oklab, Style DNA, analyzer, transfer, renderer, masks, media, export
  Library/    style model, persistence, built-in looks
  Studio/     layered compositor: model, effect engine, renderer, exporter, UI
  UI/         Home, Editor, Camera, New Style / Blend sheets, Metal view
EchoWidgets/  StandBy / Home Screen widget and the export Live Activity
EchoWatch/    Apple Watch remote
Shared/       code shared by the app, widgets and watch
EchoTests/    engine unit tests
tools/        scripts that generate the app icon, sample scene and Museum catalog
```

## Museum catalog

The artworks recognised by Museum Mode are public-domain paintings. Their reference images come from Wikimedia Commons and are bundled at 320px. Each work's Style DNA and Vision feature print are computed on device the first time Museum Mode opens. To change the collection, edit `tools/museum-catalog.full.json`, put the images in a folder, and run `tools/build_museum.py`.

## Quality benchmark

`.github/workflows/benchmark.yml` (run it manually) downloads public-domain and CC0 photos (portraits across skin tones, low light, backlit, B&W). It renders every built-in look through the real engine on the simulator, then uploads contact sheets and `metrics.csv`. The metrics are: clipping, shadow-detail retention, skin hue drift and saturation, and tonal levels. `.github/workflows/screenshots.yml` captures the app's screens in the simulator.
