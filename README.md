<div align="center">
  <img src="Assets/PortlaneIcon.png" width="144" alt="Portlane icon">
  <h1>Portlane · 引航</h1>
  <p><strong>Windows Steam on your Mac, with compatibility settings for each game.</strong></p>
  <p>Object-based spatial audio · Validated 7.1.4 output · Apple Silicon · Wine · D3DMetal</p>
  <p>English · <a href="README.zh-CN.md">简体中文</a></p>
</div>

Portlane manages the Mac environment that runs Windows Steam games. Browse the store, install games, manage downloads, and press **Play** in the official Windows Steam client. Use Portlane to choose the graphics backend, adjust compatibility rules, configure controllers, and diagnose launch problems.

**Spatial audio is a core Portlane feature.** Our runtime connects Windows game audio objects to native macOS rendering, preserving position and height information. The local 7.1.4 output path has been validated, and the user has confirmed working in-game Atmos rendering in **Black Myth: Wukong**.

Keep Portlane open while playing. When **Steam Play relay connected** appears, supported Play requests from Steam's desktop interface apply the selected game's saved Mac configuration before launch.

![Portlane game configuration](docs/screenshots/portlane/game-configuration.jpg)

## Core feature: Windows game spatial audio

Portlane's spatial audio runtime supports static beds and dynamic audio objects submitted through **Windows Spatial Audio**, rendered by the **macOS CoreAudio Spatial Mixer**. Object positions stay synchronized with audio data, while native channel order and height-speaker labels are preserved. Games that supply object audio can use this spatial rendering path on a Mac.

- **Multichannel output with height:** the local 7.1.4 endpoint path (12 channels at 48 kHz) has been validated, alongside 5.1.2 layout tests and stereo fallback.
- **Real game checks:** the user confirmed working in-game Atmos rendering in **Black Myth: Wukong**. **Split Fiction** passed a short gameplay check with the spatial audio services runtime and 7.1.4 output, with normal graphics, controls, and sound.
- **Runtime validation:** `11.0.9-services.1` completed 3,090 spatial audio checks on the 7.1.4 endpoint with zero failures or skips, retaining two existing todo results.
- **Per-game diagnostics:** optional spatial audio logs expose endpoint, object-capacity, and rendering information.

To use it, import and select a runtime containing the spatial audio patches under **Runtime components** (the currently validated build is `11.0.9-services.1`), configure the macOS output device, and enable spatial/Atmos audio in a supported game. The app's default older `11.0.2` runtime download does not yet include this support.

Support covers Windows object audio rendered through CoreAudio. Games must submit spatial objects, and multichannel devices must expose the correct speaker layout. Dolby Atmos encoded bitstream passthrough and head tracking are not implemented; physical speaker direction, device changes, and long sessions still need further acceptance testing.

The implementation originates from Switchyard Wine's spatial audio patches, adapted and validated for this project's runtime. See [implementation and provenance](docs/SPATIAL_AUDIO.md) and [validation results](docs/SPATIAL_AUDIO_VALIDATION.md).

## What each app handles

| Official Windows Steam | Portlane |
| --- | --- |
| Store, purchases and account sign-in | Mac runtime setup and component management |
| Game library, installation, updates and downloads | Per-game graphics, synchronization and display settings |
| Play, achievements and Steam Input | DLL overrides, environment variables and controller bridging |
| Steam launch arguments in game properties | Applying Mac configuration before managed Steam launches |

Portlane's workspace has three main pages: **Game configuration**, **Runtime components**, and **Diagnostics**. **Mac controllers** and **Global preferences** are accessible from the sidebar. Local Windows EXEs can also be imported and configured.

## Getting started

### Requirements

- An Apple Silicon Mac running macOS 15 or later.
- Network access and space for runtime components and games.
- Your own Steam account and licensed games.
- Xcode 26 with a compatible Swift 6 toolchain to build the app. Features using macOS 26 APIs need SDK 26 or later to compile.

Download the [Portlane 0.5.1 DMG](https://github.com/Tianyulife/portlane/releases/download/v0.5.1/Portlane-0.5.1-macOS-arm64.dmg) and [spatial audio Wine 11.0.9-services.1](https://github.com/Tianyulife/portlane/releases/download/v0.5.1/portlane-wine-11.0.9-services.1-macos-x86_64.tar.xz). All assets and SHA-256 files are on the [Release page](https://github.com/Tianyulife/portlane/releases/tag/v0.5.1).

1. Open the DMG, drag **Portlane** to **Applications**, then open it from that folder.
2. Extract the Wine `.tar.xz` to obtain the `wine-runtime` folder.
3. Under **Runtime components → Import local Wine**, select that folder, then select `11.0.9-services.1` as the active runtime.

This is an ad-hoc signed research preview and is not notarized. Spatial audio Wine is a separate Release asset; the app's default runtime download remains the older `11.0.2`. Import the supplied runtime to enable spatial audio.

### Build and open

```bash
git clone https://github.com/Tianyulife/portlane.git
cd portlane
scripts/build-app.sh
open "dist/Portlane.app"
```

The build script prepares the Steam WebHelper wrapper, bundles resources, and verifies the app signature. It uses MinGW when available, or the checked-in wrapper after SHA-256 verification. Local builds are ad-hoc signed and are not notarized.

To generate a DMG with signature, resource, and mount checks:

```bash
scripts/build-dmg.sh
```

For a distribution build, supply your own Developer ID using `MAC_GAMING_UNCLE_CODESIGN_IDENTITY`. The historical package, executable, and build-variable names remain for compatibility.

### Set up Steam and play

1. Open Portlane and complete runtime setup. The app installs or imports Wine and graphics components, then opens the official Windows Steam sign-in flow.
2. Sign in to Windows Steam. The native macOS Steam client's login is separate.
3. Install a game in Windows Steam. In Portlane, select it under **Game configuration**; use **More actions → Rescan Steam games** if it has not appeared.
4. Adjust settings as needed and click **Save**. Defaults and built-in game recommendations are a good starting point.
5. Wait for **Steam Play relay connected**, then press **Play** in Windows Steam. Saved changes apply on the next launch.

Save and exit your game before closing Portlane: quitting the manager also closes its managed Steam session.

## Compatibility settings

- **Graphics and performance:** renderer, synchronization, virtual desktop and resolution, Apple Metal HUD, MetalFX/DLSS mapping, and Metal 4 preferences.
- **Compatibility rules:** per-game DLL loading overrides and environment variables. Steam launch arguments remain in Steam's game properties; local EXE arguments are managed in Portlane.
- **Input and audio:** controller options, spatial audio runtime support, and per-game diagnostics, with device management in **Mac controllers**.
- **Runtime components:** install, import, select, and inspect Wine and graphics components, plus advanced Bottle and directory tools.
- **Diagnostics:** system checks, Steam Play relay connection, launch errors, and runtime logs.

Steam games currently share a Steam Bottle, while each game's configuration is saved separately. Global changes to that Bottle can affect every game inside it. Applying conflicting launch environments can require restarting Steam; Portlane prevents this restart while a game is running or a download is active. Imported local programs use separate Bottles.

**Black Myth: Wukong** retains a verified built-in `mscoree=b` compatibility rule. **Restore recommended** clears custom overrides while preserving the game's built-in preset. Local testing has validated Steam launch handoff and gameplay, including spatial audio rendering; this is not a guarantee for every Mac, game version, or audio device.

MetalFX/DLSS mapping and universal frame interpolation are experimental and off by default. DLSS mapping requires game support; the interpolation prototype requires macOS 26 and does not guarantee doubled frame rate. See the [interpolation notes](docs/FRAME_INTERPOLATION.md) and [spatial audio notes](docs/SPATIAL_AUDIO.md).

## How launch handoff works

```text
Windows Steam: Play
        ↓
Portlane: saved game configuration + compatibility recipe
        ↓
Steam: launch through -applaunch
        ↓
Wine + Rosetta 2 + graphics translation → macOS / Metal
```

The relay covers managed AppIDs discovered locally and supported Steam desktop Play calls. Direct EXE execution, external shortcuts, and Steam URI launches outside that interface are not covered. The connection uses Steam's private client APIs, which can change; failures appear in Diagnostics. A short-lived lease restores Steam's original Play behavior if the manager stops responding. See [companion architecture](docs/mac-companion.md).

## Development

```bash
swift test
node scripts/test-steam-launch-relay.mjs
node scripts/test-steam-bridge.mjs
node scripts/test-steam-presentation.mjs
swift build -c release
swift run macgamingunclectl --json doctor
```

The latest local Swift suite completed 117 tests with four optional integration skips and no failures. Relay regression tests cover interception, duplicate requests, unmanaged calls, reconnection, and lease expiry. Release builds and packaged resource/signature checks also passed. These checks do not establish compatibility with every Steam or game update.

More details: [architecture](docs/ARCHITECTURE.md), [runtime supply chain](docs/RUNTIME_SUPPLY_CHAIN.md), [testing](docs/TESTING.md), [GPTK distribution](docs/GPTK_DISTRIBUTION.md).

The application retains its original bundle identifier and storage paths so existing Steam login, runtime installations, and game configurations survive the Portlane rename. This repository also retains upstream history and attribution. Older documents may describe the former interface; this README and the companion architecture describe the current workspace.

## Status and contribution

Portlane is a compatibility research preview. Support varies by game and hardware; kernel anti-cheat, Windows drivers, and some DRM remain incompatible. Wine processes run with the current user's permissions. Steam, games, and Apple graphics components retain their own licenses and are installed or imported separately.

Report reproducible problems in [Issues](https://github.com/Tianyulife/portlane/issues), including the Mac model, macOS version, Steam AppID, renderer/runtime versions, and relevant logs with personal information removed. Contributions to compatibility recipes, tests, and the interface are welcome.

The project's noncommercial commitment continues: no paid edition, subscriptions, advertising, paid compatibility lists, game commissions, or sale of user data. This describes project operation; it does not change the source license.

## License and attribution

Project source is licensed under [Apache License 2.0](LICENSE). Third-party components and artwork retain their own rights and terms; see [third-party notices](THIRD_PARTY_NOTICES.md). Steam and the Steam logo belong to Valve. Portlane is an independent project and is not affiliated with Valve, Apple, or CodeWeavers.
