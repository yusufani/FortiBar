#!/bin/zsh
set -eu
cd "${0:A:h}"
stage_dir=$(mktemp -d -t fortibar-dmg)
trap 'rm -rf "$stage_dir"' EXIT
./build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' FortiBar.app/Contents/Info.plist)
ditto FortiBar.app "$stage_dir/FortiBar.app"
ln -s /Applications "$stage_dir/Applications"
cat > "$stage_dir/Install.txt" <<TEXT
FortiBar $version — macOS 13+ / Apple Silicon and Intel

1. Drag FortiBar.app into Applications, then eject this disk image.
2. Open FortiBar from Applications.
3. Save your exact FortiClient VPN profile name and username.
4. Choose Update Password to save your password in macOS Keychain.
5. Allow FortiBar in System Settings > Privacy & Security > Accessibility.
6. Click Connect VPN when disconnected. Complete MFA in FortiClient if required.

FortiBar requests startup at login after being installed. If macOS asks for
approval, use System Settings > General > Login Items.

This preview is ad-hoc signed and is NOT Apple notarized. macOS may block it
as an unidentified developer. Review the source and release checksums before
deciding whether to allow it. No passwords or personal VPN settings are
included in this disk image.

https://github.com/yusufani/FortiBar
TEXT
dmg_path="$PWD/FortiBar-$version-universal.dmg"
hdiutil create -volname "FortiBar $version" -srcfolder "$stage_dir" -format UDZO -ov "$dmg_path"
hdiutil verify "$dmg_path"
shasum -a 256 "${dmg_path:t}" > SHA256SUMS.txt
