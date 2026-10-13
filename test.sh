#!/bin/zsh
set -eu
cd "${0:A:h}"
test_binary=$(mktemp -t fortibar-tests)
trap 'rm -f "$test_binary"' EXIT
swiftc Source/ConnectionInfo.swift Tests/main.swift -o "$test_binary"
"$test_binary"
zsh -n build.sh install.sh package-dmg.sh
plutil -lint Source/Info.plist
