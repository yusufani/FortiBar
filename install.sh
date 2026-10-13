#!/bin/zsh
set -eu
cd "${0:A:h}"
app_path="$HOME/Applications/FortiBar.app"
agent_path="$HOME/Library/LaunchAgents/com.fortibar.app.plist"
if [[ -e "$app_path" ]]; then
  print -u2 "FortiBar already exists. Review before replacing it."
  exit 1
fi
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
ditto FortiBar.app "$app_path"
python3 - "$app_path" "$agent_path" <<'PY'
import plistlib,sys
with open(sys.argv[2], 'wb') as f:
    plistlib.dump({'Label':'com.fortibar.app',
        'ProgramArguments':[sys.argv[1]+'/Contents/MacOS/FortiBar'],
        'RunAtLoad':True, 'KeepAlive':True, 'ThrottleInterval':15,
        'ProcessType':'Interactive'}, f)
PY
chmod 600 "$agent_path"
launchctl bootstrap "gui/$(id -u)" "$agent_path"
