# Looper

[![Platform: macOS 15+](https://img.shields.io/badge/macOS-15%2B-333333?logo=apple&logoColor=white)](Looper.xcodeproj/project.pbxproj)
[![Language: Swift](https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white)](Sources/)
[![Deployment: Jamf Pro](https://img.shields.io/badge/Deployment-Jamf%20Pro-28539B)](Deployment/README.md)

Looper is an companion app for Apple's GarageBand, Logic Pro, and
MainStage.

It downloads Apple loop packages automatically, based on a configurable catalogue via either the app itself, or via configuration profile pushed from MDM.

It is manifest-driven, so changes to the Apple content catalogue don't (usually) mean you need to download an update.
repaired without rewriting the installer.

## A Note on the Current State of Loops

Apple has been changing how they do things with Logic Pro (non-X). Apple documents the shared loop install location as:

```text
/Library/Audio/Apple Loops/Apple
```

Current Logic Pro 12+ content delivery appears to be changing in ways that don't always expose normal `.pkg` files. Because of this, Looper treats package discovery as data, and isn't hard-coded.

## CLI Usage

Run a manifest:

```sh
looper install --manifest /path/to/loops.json
```

Useful commands:

```sh
looper status
looper list --manifest /path/to/loops.json
looper uninstall --forget-state
```

## Manifest Format

See `Manifests/sample-loops.json`. Each item has a stable `id`, display name, download URL, optional SHA-256, optional expected package identifier, and target applications whose users should be prompted after new content is installed.

## Notes for Lab Deployment

- Downloads resume from `.part` files using HTTP range requests where the server
  supports them.
- Package install state is checked with `pkgutil --pkg-info` when a package id is
  provided, then recorded in local state after successful installs.
- Prompts are intentionally best-effort: the CLI can notify logged-in users, and
  the menu bar app can present richer interactive actions later.
- Use the provided uninstall script or `looper uninstall` to remove Looper state,
  caches, and LaunchAgent entries. It does not remove Apple loop content by
  default.

## Managed Preferences

Looper overlays configuration profiles in the `com.maxhewett.Looper` domain on its local settings in `/Library/Application Support/Looper/settings.json`. See [Jamf deployment](Deployment/README.md) for the schema, helper approval
profile, package signing, and scheduled install policy.

The helper wakes to service explicit requests. Enable unattended installs through a Jamf policy and the managed `ScheduledInstallEnabled` setting.
