# Getting started

Use Looper to see which Apple sound packs are already on your Mac and install the ones you need for your next session.

## Open the library

Install your audio app first. Download the Looper installer from [GitHub Releases](https://github.com/maxhewett/Looper/releases/latest), run the package, then open Looper from Applications. After setup, click its menu bar icon to get back to the Library.

The counters at the top summarise the catalogue. Each row shows the package name, audio app, download size and installation status. Use **Search** to find a pack by name or **Filter** to narrow the list.

## Choose your content

Open **Run Scope** from the Library. Choose **Essential** for the smaller starter collection, **All** for the full catalogue or **None** to skip that app. Open **Advanced** to include or skip particular package IDs. Save your settings before starting the run.

## Follow an install

Start the run using the play button in the window toolbar. Watch the menu bar for progress and open **Logging** for individual package results. On a shared Mac, an administrator can supply the scope and schedule through a configuration profile.

## Use the CLI

Check the last run with `looper status`. To preview a custom manifest, list its packages before installing them.

```sh
looper list --manifest /path/to/loops.json
looper install --manifest /path/to/loops.json
```

Start with the [sample manifest](../../Manifests/sample-loops.json). Replace its example package URL with an Apple content URL before running an install.
