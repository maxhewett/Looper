# Inside Looper

The menu bar app, command-line tool and device helper share the same installation logic. On a shared Mac, the helper can prepare sound content before anyone signs in.

## From catalogue to library

1. **Discover.** Looper builds a catalogue from available Apple content metadata. A manifest describes each pack, its target apps and its download location.
2. **Select.** The run scope selects eligible packs. Managed preferences take priority over local choices, and package exclusions narrow the selection.
3. **Compare.** Looper checks installer receipts and local content state to find packages that need attention.
4. **Install.** The device helper downloads the selected content. Interrupted package downloads can resume when the server supports range requests.
5. **Review.** Open Logging to inspect package-level results, or run `looper status` to check the most recent run.

## Shared Logic sound content

Modern Logic packs use a shared library bundle. The login agent connects a new account or an empty default library to that bundle. An account with an existing personal library can select the shared bundle in Logic’s Sound Library settings.

## Deployment components

| Component | Role |
| --- | --- |
| Looper.app | Presents the Library, settings, menu bar controls and logs. |
| Device helper | Services installation requests with the privileges needed to write shared content. |
| Preload service | Checks managed content at installation, at boot and hourly when enabled. |
| Login agents | Start the menu bar app and connect users to the shared Logic library. |
| Command-line tool | Lists manifest packages, reports status and starts managed or manual runs. |

See the [Jamf deployment guide](../../Deployment/README.md) for the installation order and pilot checks.
