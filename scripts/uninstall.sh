#!/bin/zsh
set -euo pipefail

agent_target="$HOME/Library/LaunchAgents/com.sacrosaunt.atlas.plist"
/bin/launchctl bootout "gui/$(id -u)" "$agent_target" 2>/dev/null || true
/bin/rm -f "$agent_target"
echo "Atlas background service removed. Project, app, and local state were left intact."
