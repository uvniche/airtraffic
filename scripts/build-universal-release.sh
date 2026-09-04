#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$repo_root/.build/universal-release"
staging_dir="$build_root/package"
output_dir="$repo_root/dist"
output_file="$output_dir/airtraffic-macos-universal.tar.gz"

rm -rf "$build_root"
mkdir -p "$staging_dir" "$output_dir"

swift build \
  --package-path "$repo_root" \
  --configuration release \
  --arch arm64 \
  --build-path "$build_root/arm64"

swift build \
  --package-path "$repo_root" \
  --configuration release \
  --arch x86_64 \
  --build-path "$build_root/x86_64"

xcrun lipo -create \
  "$build_root/arm64/arm64-apple-macosx/release/airtraffic" \
  "$build_root/x86_64/x86_64-apple-macosx/release/airtraffic" \
  -output "$staging_dir/airtraffic"

codesign --force --sign - "$staging_dir/airtraffic"
test "$(xcrun lipo -archs "$staging_dir/airtraffic")" = "x86_64 arm64"

tar -C "$staging_dir" -czf "$output_file" airtraffic
shasum -a 256 "$output_file"
