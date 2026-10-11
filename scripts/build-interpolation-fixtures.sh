#!/bin/zsh
set -euo pipefail
project_root=${0:A:h:h}
cd "$project_root"
fixture_configuration=${MAC_GAMING_UNCLE_CONFIGURATION:-release}
swift build -c "$fixture_configuration" --product MacGamingUncleApp
bin_dir=$(swift build -c "$fixture_configuration" --show-bin-path)
fixture_destination="$project_root/dist/interpolation-fixtures"
mkdir -p "$fixture_destination"
if [[ -f "$bin_dir/IndieCore.o" ]]; then
  module_dir="$bin_dir"
  core_objects=("$bin_dir/IndieCore.o")
  runtime_objects=("$bin_dir/IndieRuntime.o")
else
  module_dir="$bin_dir/Modules"
  core_objects=("$bin_dir"/IndieCore.build/*.o(N))
  runtime_objects=("$bin_dir"/IndieRuntime.build/*.o(N))
fi
swiftc -O -parse-as-library -target arm64-apple-macos26.0 -I "$module_dir" -I Sources/CSQLite \
  Fixtures/macOS/InterpolationCaptureProbe.swift \
  Sources/MacGamingUncleApp/GameFrameInterpolation.swift \
  Sources/MacGamingUncleApp/InterpolationMetalPresenter.swift \
  "${core_objects[@]}" "${runtime_objects[@]}" -lsqlite3 \
  -o "$fixture_destination/InterpolationCaptureProbe"
swiftc -O -parse-as-library Fixtures/macOS/InterpolationPattern.swift \
  -o "$fixture_destination/InterpolationPattern"
swiftc -O -parse-as-library -target arm64-apple-macos26.0 -I "$module_dir" -I Sources/CSQLite \
  Fixtures/macOS/InterpolationBaselineProbe.swift "${core_objects[@]}" -lsqlite3 \
  -o "$fixture_destination/InterpolationBaselineProbe"
ditto "$bin_dir/MacGamingUncle_IndieCore.bundle" "$fixture_destination/MacGamingUncle_IndieCore.bundle"
print "$fixture_destination"
