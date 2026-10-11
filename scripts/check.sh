#!/bin/zsh
set -euo pipefail

indie_root=${0:A:h:h}
cd "$indie_root"
python3 scripts/test-wine11-patches.py
portlane_node=${PORTLANE_NODE:-node}
"$portlane_node" scripts/localize-ui.mjs
"$portlane_node" scripts/test-steam-bridge.mjs
"$portlane_node" scripts/test-steam-launch-relay.mjs
"$portlane_node" scripts/test-steam-presentation.mjs
swift test
swift build -c release --product MacGamingUncleApp
swift build -c release --product macgamingunclectl
"$indie_root/scripts/build-steam-wrapper.sh"
"$indie_root/scripts/build-windows-fixtures.sh"
