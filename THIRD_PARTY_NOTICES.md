# Third-party notices

Portlane does not redistribute the runtime components listed below in this repository. When users or release manifests install them, their own licenses apply.

| Component | Purpose | License / terms |
|---|---|---|
| Wine | Win32/Win64 compatibility layer | LGPL-2.1-or-later |
| DXMT | Direct3D 10/11 to Metal | LGPL-2.1-or-later |
| DXVK | Direct3D 8/9/10/11 to Vulkan | zlib |
| VKD3D / VKD3D-Proton | Direct3D 12 to Vulkan | LGPL-2.1-or-later |
| MoltenVK | Vulkan portability implementation over Metal | Apache-2.0 |
| Apple D3DMetal / GPTK | Direct3D 11/12 to Metal | Apple license supplied with GPTK; user-provided only |
| Steam | Store client and game delivery | Valve/Steam terms; user-installed only |
| Steam WebHelper wrapper | Forces Wine-compatible CEF process mode | MIT, copyright 2026 notpop |
| Indie Wine 11 runtime | Wine 11 macOS host, new WoW64, MSync and Indie patches | Wine LGPL-2.1-or-later; corresponding CodeWeavers FOSS source and patch set are published with the runtime |
| Switchyard Wine spatial audio patches | Windows object audio to CoreAudio Spatial Mixer; author jungwuk-ryu, exact source commits in docs/SPATIAL_AUDIO.md | LGPL-2.1-or-later |
| FreeType | Wine font rendering | FreeType License or GPL-2.0-only |
| GnuTLS, GMP, Nettle | Wine TLS and cryptography support | LGPL-2.1-or-later / LGPL-3.0-or-later and component-specific notices |
| libinotify-kqueue | kqueue-backed filesystem notifications for wineserver | MIT |

The interface includes a Steam logo retrieved from Valve's official Steam static
asset host (`store.fastly.steamstatic.com`). The Portlane icon also composites the
original circular icon extracted from a locally installed Steam.app into a MacBook
illustration. Steam and the Steam logo are trademarks of Valve Corporation; this
artwork is not covered by the project's Apache source-code license. Portlane is
not affiliated with Valve or Apple.

Runtime releases must include exact notices and corresponding-source links for their pinned versions.

Portlane retains the Apache-2.0 Mac Gaming Uncle source history and attribution.
The 2026-10-11 lifecycle, runtime preparation and frame-presentation port adapts
upstream author tabshi's commits `bf1ada9b6c2e857c639534595772a20cb2ff19b4`,
`2db077053c8646ca19124339fc0ad91c8c36a672` and
`2cd8d61e65ccb04ffcec0f85d5156b1c5ddcab12` from
https://github.com/enginefuture/mac-gaming-uncle. Portlane-specific adaptations
and validation are recorded in `docs/UPSTREAM_PORT_PLAN.md`.
