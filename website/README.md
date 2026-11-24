# Looper website

The marketing homepage is in `index.html`. Edit the getting-started and architecture pages in `website/guides/`. The deployment page pulls the configuration, policy and verification sections from `Deployment/README.md`. The menu bar preview uses the app’s 16 download frames at 24 fps. The Swift and GitHub marks come from [Simple Icons](https://github.com/simple-icons/simple-icons).

## Preview locally

From the repository root, use a Python 3 virtual environment.

```sh
python3 -m venv .build/pages-venv
.build/pages-venv/bin/python -m pip install -r website/requirements.txt
preview_dir="$(mktemp -d)"
.build/pages-venv/bin/python website/build.py "$preview_dir/site"
.build/pages-venv/bin/python -m http.server 8765 --bind 127.0.0.1 --directory "$preview_dir/site"
```

Open <http://127.0.0.1:8765/>.

## Publish on GitHub Pages

Choose **Deploy from a branch** under **Settings → Pages**, then select **gh-pages** and **/(root)**. The branch contains the generated site. For updates, rebuild with `website/build.py` and commit the generated files to that branch.

Use relative paths for site assets and navigation so the site works under the `/Looper/` project path.
