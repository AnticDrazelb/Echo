# Echo

**Steal the vibe. Keep your story.**

Echo clones the *look* of any image or video (its color grade, light, texture and optics) and applies it live to your own photos and videos. Everything runs on device: references are analysed into a few hundred bytes of **Style DNA**, and the original pixels are never stored or uploaded.

## Features

| | |
|---|---|
| **Capture a reference** | Live camera ("hold to lock the look") or anything in Photos: images, videos, Live Photos and screenshots. Text and UI are detected and ignored. |
| **Style DNA** | Oklab tone distribution (17 quantiles), shadow/mid/highlight tints, per-hue saturation roll-off, film grain amount & size, halation, vignette and chromatic aberration. |
| **Apply + refine** | Metal-backed live preview with a before/after split, a 0–100 intensity slider, toggles for Color / Light / Grain / Optics, and smart regions (Sky, Skin, Subject) built with Vision. |
| **Video** | Live styled playback; export keeps audio and orientation. |
| **Blend** | Mix up to three looks (for example 50/30/20) into a new style. |
| **Export** | Save to Photos (HEIF), bake a `.cube` LUT for Final Cut, Resolve or Premiere, AirDrop a `.echostyle` file, or copy an `echo://` link. |
| **Attribution** | An optional "Style inspired by @creator" credit is burned into exports. |

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

Requires Xcode 15+ and iOS 17+.

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
| `BUILD_PROVISION_PROFILE_BASE64` | `base64 -i Echo.mobileprovision`: a profile for `com.anticdrazelb.echo` |
| `KEYCHAIN_PASSWORD` | Any random string (optional) |

When these secrets are set, the workflow also archives and exports `Echo.ipa`. It uses ad-hoc by default; choose `development` or `app-store` with *Run workflow*.

## Project layout

```
Echo/
  App/        entry point, navigation, deep links
  Core/       Oklab, Style DNA, analyzer, transfer, renderer, masks, media, export
  Library/    style model, persistence, built-in looks
  UI/         Home, Editor, Camera, New Style / Blend sheets, Metal view
EchoTests/    engine unit tests
tools/        script that generates the app icon and sample scene
```
