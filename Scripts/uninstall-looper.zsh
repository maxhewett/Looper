#!/bin/zsh
set -euo pipefail

installed_app="/Applications/Looper.app"
launch_agent="$HOME/Library/LaunchAgents/com.maxhewett.Looper.agent.plist"

for session_uid in $(/bin/ps -axo uid= | /usr/bin/sort -un); do
  (( session_uid >= 500 )) || continue
  /usr/bin/sudo /bin/launchctl bootout "gui/$session_uid/com.maxhewett.Looper.menu-bar" 2>/dev/null || true
done
/usr/bin/sudo /bin/rm -f /Library/LaunchAgents/com.maxhewett.Looper.menu-bar.plist /Library/LaunchAgents/com.maxhewett.Looper.shared-library.plist

if [[ -f /Library/LaunchDaemons/com.maxhewett.Looper.preload.plist ]]; then
  /usr/bin/sudo /bin/launchctl bootout system/com.maxhewett.Looper.preload || true
  /usr/bin/sudo /bin/rm -f /Library/LaunchDaemons/com.maxhewett.Looper.preload.plist
fi

device_label=com.maxhewett.Looper.device-helper
if [[ -f "/Library/LaunchDaemons/$device_label.plist" ]]; then
  /usr/bin/sudo /bin/launchctl bootout "system/$device_label" || true
  /usr/bin/sudo /bin/rm -f "/Library/LaunchDaemons/$device_label.plist" "/Library/PrivilegedHelperTools/$device_label"
fi

if [[ -f "$launch_agent" ]]; then
  /bin/rm -f "$launch_agent"
fi

if [[ -x "$installed_app/Contents/MacOS/Looper" ]]; then
  "$installed_app/Contents/MacOS/Looper" --unregister-helper || true
fi

if [[ -L "/usr/local/bin/looper" ]]; then
  /usr/bin/sudo /bin/rm -f "/usr/local/bin/looper"
fi

if [[ "${1:-}" != "--keep-app" ]]; then
  /usr/bin/sudo /bin/rm -rf "$installed_app"
fi

/usr/bin/sudo /bin/rm -rf "/Library/Caches/Looper"

if [[ "${1:-}" == "--forget-state" ]]; then
  /usr/bin/sudo /bin/rm -rf "/Library/Application Support/Looper" "/Library/Logs/Looper" "/var/log/Looper"
fi

echo "Looper removed. Apple loop content was left untouched."
