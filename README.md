[中文版](README_zh.md) | **English**

# AirPods Fix

A native macOS app for diagnosing and repairing common AirPods audio problems on macOS.

It helps when AirPods are connected but have no sound, degraded audio quality, wrong output routing, mute/volume issues, or microphone problems.

## End Users

For most people, the right path is the packaged app from GitHub Releases.

1. Download the latest `.dmg`
2. Open the disk image
3. Drag `AirPods Fix.app` into `Applications`
4. Launch the app normally

You do not need Xcode, Xcode Command Line Tools, or a local Swift toolchain just to run the app.

Current releases may be unsigned. If macOS blocks the first launch, Control-click the app and choose `Open`, or allow it in `System Settings -> Privacy & Security` and launch it again.

## Developers

Build from source only if you want to work on the project itself.

- macOS 13 or later
- Xcode Command Line Tools

Useful commands:

```bash
./build.sh
./package-release.sh
```

- `./build.sh` builds `AirPods Fix.app`
- `./package-release.sh` builds the app and creates a release `.dmg`
- Pushing a `v*` tag triggers GitHub Actions to build and publish a release artifact

More packaging and release notes are in [RUNTIME.md](RUNTIME.md).

## Runtime Dependencies

Runtime behavior depends on how the app was packaged.

- GitHub Release builds are expected to bundle `blueutil` inside the app
- Local builds use a system-installed `blueutil` if one is available
- If `blueutil` is missing, the app still works for scanning, diagnostics, speaker test, microphone test, soft repair, and medium repair
- If `blueutil` is missing, only Bluetooth reconnect is unavailable

The app also requests microphone permission for the microphone test. Everything else works without microphone access.

## Features

- Detects connected AirPods and shows battery levels
- Supports choosing the target device when multiple AirPods pairs are connected
- Diagnoses output routing, stereo/mono mode, sample rate, mute state, and low volume
- Includes speaker and microphone test tools
- Provides staged repair:
  - soft fix: refresh audio routing
  - medium fix: restart `coreaudiod`
  - hard fix: Bluetooth reconnect
- Temporarily mutes system output during route refresh, then restores the original mute state, so fallback speaker switching does not blast audio through the MacBook speakers
- Shows a timestamped diagnostic log

## Basic Usage

1. Connect AirPods to your Mac
2. Open the app and let it scan
3. Choose the target pair if more than one is connected
4. Check the diagnostic section
5. Run speaker or microphone tests if needed
6. Use **One-Click Repair** if the audio path is still broken

## Requirements

- macOS 13 (Ventura) or later
- AirPods or AirPods Pro

## License

MIT
