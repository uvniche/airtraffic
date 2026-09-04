#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$repo_root/.build/arm64-release"
staging_dir="$build_root/package"
output_dir="$repo_root/dist"
output_file="$output_dir/airtraffic-macos-arm64.tar.gz"

rm -rf "$build_root"
mkdir -p "$staging_dir" "$output_dir"

swift build \
  --package-path "$repo_root" \
  --configuration release \
  --arch arm64 \
  --build-path "$build_root"

cp "$build_root/arm64-apple-macosx/release/airtraffic" "$staging_dir/airtraffic"
test "$(file -b "$staging_dir/airtraffic")" = "Mach-O 64-bit executable arm64"

tar -C "$staging_dir" -czf "$output_file" airtraffic
shasum -a 256 "$output_file"
