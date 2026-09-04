#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$repo_root/.build/arm64-release"
staging_dir="$build_root/package"
output_dir="$repo_root/dist"
output_file="$output_dir/airtraffic-macos-arm64.tar.gz"
cache_dir="$build_root/cache"
module_cache_dir="$cache_dir/modules"
config_dir="$cache_dir/configuration"
security_dir="$cache_dir/security"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swift_bin="$(xcrun --sdk macosx --find swift)"

rm -rf "$build_root"
mkdir -p \
  "$staging_dir" \
  "$output_dir" \
  "$module_cache_dir" \
  "$config_dir" \
  "$security_dir"

export CLANG_MODULE_CACHE_PATH="$module_cache_dir"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_dir"
export SDKROOT="$sdk_path"

"$swift_bin" build \
  --package-path "$repo_root" \
  --configuration release \
  --arch arm64 \
  --build-path "$build_root" \
  --cache-path "$cache_dir" \
  --config-path "$config_dir" \
  --security-path "$security_dir" \
  --sdk "$sdk_path" \
  --disable-sandbox

cp "$build_root/arm64-apple-macosx/release/airtraffic" "$staging_dir/airtraffic"
test "$(file -b "$staging_dir/airtraffic")" = "Mach-O 64-bit executable arm64"

tar -C "$staging_dir" -czf "$output_file" airtraffic
shasum -a 256 "$output_file"
