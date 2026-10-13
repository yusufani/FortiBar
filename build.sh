#!/bin/zsh
set -eu
cd "${0:A:h}"
bundle="$PWD/FortiBar.app"
mkdir -p "$bundle/Contents/MacOS"
arch_dir=$(mktemp -d -t fortibar-build)
trap 'rm -rf "$arch_dir"' EXIT
for architecture in arm64 x86_64; do
  swiftc Source/*.swift -O -target "$architecture-apple-macosx13.0" -o "$arch_dir/FortiBar-$architecture" -framework AppKit -framework Security -framework ApplicationServices -framework ServiceManagement
done
lipo -create "$arch_dir/FortiBar-arm64" "$arch_dir/FortiBar-x86_64" -output "$bundle/Contents/MacOS/FortiBar"
cp Source/Info.plist "$bundle/Contents/Info.plist"
codesign --force --sign - --identifier com.fortibar.app "$bundle"
codesign --verify --strict "$bundle"
