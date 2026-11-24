# Deploy Looper with Jamf Pro

For a shared lab, deploy the audio apps, a computer configuration profile, and `Looper.pkg`, in that order. The supplied lab profile selects Essential content for GarageBand and Logic Pro. The Mac can install that content before a student signs in.

## Packaging

Build from the repository root on a Mac with Xcode. For distribution, set `DEVELOPMENT_TEAM` in the Xcode project to match your signing identities and supply your notary keychain profile.

```sh
LOOPER_APP_SIGN_IDENTITY='Developer ID Application: Your Organization (TEAMID)' \
LOOPER_INSTALLER_SIGN_IDENTITY='Developer ID Installer: Your Organization (TEAMID)' \
LOOPER_NOTARY_PROFILE='your-notary-keychain-profile' \
Scripts/build-test-package.zsh
```

The script writes `.build/packages/Looper.pkg`. Use the same package for Jamf and for a manual installation. Its payload includes the following components.

```text
Applications/
└── Looper.app
Library/
├── LaunchAgents/
│   ├── com.maxhewett.Looper.menu-bar.plist
│   └── com.maxhewett.Looper.shared-library.plist
├── LaunchDaemons/
│   ├── com.maxhewett.Looper.device-helper.plist
│   └── com.maxhewett.Looper.preload.plist
└── PrivilegedHelperTools/
    └── com.maxhewett.Looper.device-helper
```

The installer starts the device services, migrates the older bundled helper if present, and creates the `/usr/local/bin/looper` command. The login agents start the menu bar in each graphical session and connect that user to the shared Logic library. Copying the app alone omits these components.

## Jamf/MDM deployment

### Configuration profile

The preference domain is `com.maxhewett.Looper`. Choose one of these ways to configure it.

| Starting point | What to deploy |
| --- | --- |
| Use the lab defaults | Upload the [lab configuration profile](Looper-Lab.mobileconfig) under **Computers → Configuration Profiles**. It includes background-item approvals, enables device preloading, starts the menu bar at login, and skips the setup assistant. |
| Copy a reference Mac | Save the settings in Looper, then open **Settings → Deployment**. Review setup, preload, scheduling and quiet hours. Export **Configuration profile** to include approvals, or export **Preferences plist** for **Application & Custom Settings → Upload** and deploy the [background-item approvals](Looper-Managed-Login-Items.mobileconfig) alongside it. Each full profile export has fresh identifiers. |
| Configure settings in Jamf | In a computer profile, add **Application & Custom Settings → External Applications → Custom Schema**. Enter the preference domain and paste the [Jamf schema](Jamf-Looper.schema.json). Review **Plist Preview**, then scope the [background-item approvals](Looper-Managed-Login-Items.mobileconfig) to the same Macs. |

Managed values take precedence over local choices. These are the settings most relevant to a lab rollout.

| Key | Behaviour |
| --- | --- |
| `RunAppContentSets` | Choose **All**, **Essential**, or **None** for each app. All and Essential pick up new packages in their scope. None disables the app. Existing profiles using arrays are also supported. |
| `AppPackageOverrides` | For an enabled app, **Only** limits installs to the listed IDs, including after the catalogue grows. **Skip** takes precedence. Both fields take comma-separated package or receipt IDs. Modern packs use IDs such as `0018_bassampsounds`. |
| `ExcludedPackageIDs` | Excludes IDs across all apps. Use this for shared packages that another app would otherwise include. |
| `PackagePriorities` | Maps IDs to integer priorities. Higher values install first. If Jamf omits the dictionary editor, upload a preferences plist. |
| `RunAtLogin`, `SkipSetupAssistant` | Control the menu bar and first-launch setup for each user. Administrators can reopen the assistant in **Settings → About**. |
| `ManagedPreloadEnabled`, `ScheduledInstallEnabled`, `ScheduleQuietHours` | Choose who starts unattended runs and when they may start. See the policy examples below. |
| `HelperRunMode`, `LogRetentionDays` | Select sequential or staged installs and retain logs for 1–365 days. |
| `NotifyNewLoopsAvailable`, `NotifyRelaunchPrompts`, `NotifyRunFailures`, `NotifyRunSummaries` | Enable or disable each notification independently. |

### Package policy

Create a computer policy after the profile has reached the pilot Macs.

| Jamf field | Example |
| --- | --- |
| Display name | Install Looper |
| Packages | Upload `Looper.pkg`  |
| Trigger | Recurring Check-in |
| Execution frequency | Once per computer |
| Scope | The same pilot Macs that received the configuration profile |

### Ongoing sound installs

**Device preload** is the mode used by the lab profile. With `ManagedPreloadEnabled` enabled and `RunAppContentSets` configured, Looper checks at package installation, at boot, and hourly. The device service honours scope, overrides and quiet hours even at the login window.

**Jamf-controlled schedule** gives Jamf control of the cadence. Disable `ManagedPreloadEnabled`, enable `ScheduledInstallEnabled`, and create a separate recurring policy that runs:

```sh
/usr/local/bin/looper install --scheduled
```

Choose the trigger and frequency in Jamf. For example, `ScheduleQuietHours` set to `8-16` blocks new scheduled starts from 8 am to 4 pm local time. Remove any previously deployed per-user Looper schedules when switching to this policy. Manual Library requests remain available and respect managed exclusions.

## Verify on a pilot Mac

1. Install GarageBand or Logic Pro, confirm the lab profile has arrived, then let the package policy run.
2. Check the helper and the last run. The helper can exit successfully between requests. Looper’s **Logging** screen and `/var/log/Looper/events.jsonl` show package-level results.

   ```sh
   launchctl print system/com.maxhewett.Looper.device-helper
   /usr/local/bin/looper status
   ```

3. Wait for the preload to finish. GarageBand content from numbered package catalogues uses the device package installer. Modern Logic packs use one shared copy in `/Library/Application Support/Looper/Logic Pro Library.bundle`. Logic’s Essential selection includes **Hip Hop Essentials**, **Electronic Essentials**, and **Studio Instrument Essentials**.
4. Sign in with a fresh standard account. Confirm the menu bar appears if enabled, open Logic, and play a sound from an installed pack. With all three Essential packs verified, check that Logic opens without offering to download them again.

Looper connects a new account or empty default library at login and checks again when shared package definitions change. Accounts with populated or relocated personal libraries keep their existing selection. To move one of those accounts onto the shared library, choose **Logic Pro → Settings → General → Sound Library → Locate**, select the shared bundle, and relaunch Logic. [Apple’s Sound Library settings](https://support.apple.com/guide/logicpro/lgcp725c6d3d/mac)
