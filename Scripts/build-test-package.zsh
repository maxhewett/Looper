#!/bin/zsh
set -euo pipefail
export COPYFILE_DISABLE=1

# Build a local installer package that follows the same shape we expect from
# MDM deployment: Looper.app in /Applications and the reusable CLI exposed at
# /usr/local/bin/looper. The app should register its bundled ServiceManagement
# daemon after install so macOS attributes Background App Activity correctly.

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${LOOPER_DERIVED_DATA:-$repo_root/.build/PackageDerivedData}"
configuration="${LOOPER_CONFIGURATION:-Release}"
products_dir="$derived_data/Build/Products/$configuration"
stage_root="$repo_root/.build/pkg-root"
scripts_dir="$repo_root/.build/pkg-scripts"
package_dir="${LOOPER_PACKAGE_OUTPUT_DIR:-$repo_root/.build/packages}"
package_path="$package_dir/Looper.pkg"

mkdir -p "$package_dir"

build_args=(
  -project "$repo_root/Looper.xcodeproj"
  -scheme Looper
  -configuration "$configuration"
  -derivedDataPath "$derived_data"
)

if [[ "${LOOPER_UNSIGNED_PACKAGE:-0}" == "1" ]]; then
  # Unsigned packages are useful for validating payload layout on development
  # machines without access to the signing identity. ServiceManagement daemon
  # registration should be tested with a signed build.
  build_args+=(CODE_SIGNING_ALLOWED=NO)
elif [[ -n "${LOOPER_APP_SIGN_IDENTITY:-}" ]]; then
  build_args+=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$LOOPER_APP_SIGN_IDENTITY" ENABLE_HARDENED_RUNTIME=YES)
fi

/usr/bin/xcodebuild "${build_args[@]}" build

/bin/rm -rf "$stage_root" "$scripts_dir"
/bin/mkdir -p "$stage_root/Applications" "$scripts_dir"
/usr/bin/ditto --norsrc "$products_dir/Looper.app" "$stage_root/Applications/Looper.app"
/usr/bin/find "$stage_root" -name "._*" -delete
/usr/bin/xattr -cr "$stage_root"
while IFS= read -r staged_item; do
  /usr/bin/xattr -d com.apple.provenance "$staged_item" 2>/dev/null || true
done < <(/usr/bin/find "$stage_root" -print)

device_label="com.maxhewett.Looper.device-helper"
daemon_plist="$stage_root/Library/LaunchDaemons/$device_label.plist"
helper="$stage_root/Library/PrivilegedHelperTools/$device_label"
mkdir -p "${daemon_plist:h}" "${helper:h}"
install -m 644 "$repo_root/Deployment/$device_label.plist" "$daemon_plist"
mkdir -p "$stage_root/Library/LaunchAgents"
install -m 644 "$repo_root/Deployment/com.maxhewett.Looper.shared-library.plist" "$stage_root/Library/LaunchAgents/"
install -m 644 "$repo_root/Deployment/com.maxhewett.Looper.menu-bar.plist" "$stage_root/Library/LaunchAgents/"
install -m 755 "$products_dir/Looper.app/Contents/Helpers/looper" "$helper"
if [[ "${LOOPER_UNSIGNED_PACKAGE:-0}" != 1 ]]; then
  /usr/bin/codesign --verify --strict "$helper"
  team=$(/usr/bin/codesign -dv --verbose=4 "$helper" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')
  [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || { echo "A team-signed helper is required." >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :SpawnConstraint:team-identifier $team" "$daemon_plist"
fi

# Use the same signed executable and launch constraint for device provisioning.
preload_plist="$stage_root/Library/LaunchDaemons/com.maxhewett.Looper.preload.plist"
cp "$daemon_plist" "$preload_plist"
/usr/libexec/PlistBuddy -c 'Set :Label com.maxhewett.Looper.preload' "$preload_plist"
/usr/libexec/PlistBuddy -c 'Set :ProgramArguments:2 --managed-preload' "$preload_plist"
/usr/libexec/PlistBuddy -c 'Delete :WatchPaths' "$preload_plist"
/usr/libexec/PlistBuddy -c 'Add :StartInterval integer 3600' "$preload_plist"

cat > "$scripts_dir/postinstall" <<'SCRIPT'
#!/bin/zsh
set -euo pipefail

/bin/mkdir -p "/Library/Application Support/Looper" "/Library/Application Support/Looper/Requests" "/Library/Application Support/Looper/Results" "/Library/Caches/Looper/tmp" "/var/log/Looper" "/usr/local/bin"
/usr/bin/install -d -o root -g wheel -m 755 "/Library/Application Support/Looper/Logic Pro Library.bundle"
/Library/PrivilegedHelperTools/com.maxhewett.Looper.device-helper bootstrap
/bin/ln -sf "/Library/PrivilegedHelperTools/com.maxhewett.Looper.device-helper" "/usr/local/bin/looper"
if [[ -f "/Library/Application Support/Looper/.unregister-bundled-helper" ]]; then
  /Applications/Looper.app/Contents/MacOS/Looper --unregister-helper
  /bin/rm -f "/Library/Application Support/Looper/.unregister-bundled-helper"
fi
/bin/launchctl bootstrap system /Library/LaunchDaemons/com.maxhewett.Looper.device-helper.plist
/bin/launchctl bootstrap system /Library/LaunchDaemons/com.maxhewett.Looper.preload.plist
# Include desktops already signed in through fast user switching.
for session_uid in $(/bin/ps -axo uid= | /usr/bin/sort -un); do
  (( session_uid >= 500 )) || continue
  domain="gui/$session_uid"
  /bin/launchctl print "$domain" >/dev/null 2>&1 || continue
  if ! /bin/launchctl print "$domain/com.maxhewett.Looper.menu-bar" >/dev/null 2>&1; then
    /bin/launchctl bootstrap "$domain" /Library/LaunchAgents/com.maxhewett.Looper.menu-bar.plist || echo "Menu bar launch deferred until login for UID $session_uid" >&2
  fi
done
# A newly installed LaunchAgent starts at the next login. Connect the active
# desktop account now as that user, including upgrades of the location format.
console_user=$(/usr/bin/stat -f %Su /dev/console)
if [[ "$console_user" != root && "$console_user" != loginwindow && "$console_user" != _mbsetupuser ]]; then
  /usr/bin/sudo -H -u "$console_user" /Library/PrivilegedHelperTools/com.maxhewett.Looper.device-helper connect-shared-library || true
fi
SCRIPT

# Keep installer receipts increasing across the switch from pilot versions to 1.0.
receipt_version=$(/usr/bin/plutil -extract CFBundleVersion raw "$stage_root/Applications/Looper.app/Contents/Info.plist")
cat > "$scripts_dir/preinstall" <<'SCRIPT'
#!/bin/zsh
set -euo pipefail
# The 1.0 release follows pilots with higher marketing versions.
installed_plist="${3:-/}/Applications/Looper.app/Contents/Info.plist"
if [[ -f "$installed_plist" ]]; then
  installed_build=$(/usr/bin/plutil -extract CFBundleVersion raw "$installed_plist")
  if [[ "$installed_build" != <-> ]] || (( installed_build > @LOOPER_BUILD@ )); then
    echo "A newer Looper build is already installed." >&2
    exit 1
  fi
fi
for label in com.maxhewett.Looper.preload com.maxhewett.Looper.helper com.maxhewett.Looper.device-helper; do
  if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
    if [[ "$label" == com.maxhewett.Looper.helper ]]; then
      /bin/mkdir -p "/Library/Application Support/Looper"
      /usr/bin/touch "/Library/Application Support/Looper/.unregister-bundled-helper"
    fi
    /bin/launchctl bootout "system/$label"
  fi
done
SCRIPT

/usr/bin/sed -i '' "s/@LOOPER_BUILD@/$receipt_version/g" "$scripts_dir/preinstall"
/bin/chmod 755 "$scripts_dir/preinstall" "$scripts_dir/postinstall"

pkg_sign_args=()
if [[ -n "${LOOPER_INSTALLER_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --verify --deep --strict "$stage_root/Applications/Looper.app"
  pkg_sign_args=(--sign "$LOOPER_INSTALLER_SIGN_IDENTITY")
fi

components="$repo_root/.build/pkg-components.plist"
/usr/bin/pkgbuild --analyze --root "$stage_root" "$components"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$components" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$components"

# During the one-time 1.3.x pilot to 1.0 transition, the build guard above
# protects newer installs while allowing Installer to replace the pilot app.
if [[ "$receipt_version" == 47 ]]; then
  /usr/libexec/PlistBuddy -c 'Set :0:BundleIsVersionChecked false' "$components"
fi
/usr/bin/pkgbuild --component-plist "$components" --ownership recommended "${pkg_sign_args[@]}" \
  --root "$stage_root" \
  --scripts "$scripts_dir" \
  --identifier "com.maxhewett.Looper.pkg" \
  --version "$receipt_version" \
  --install-location "/" \
  "$package_path"

if [[ -n "${LOOPER_NOTARY_PROFILE:-}" ]]; then
  /usr/bin/xcrun notarytool submit "$package_path" --keychain-profile "$LOOPER_NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$package_path"
fi

echo "$package_path"
