# Packaging a Release

Concise reference for cutting a GitHub release. Not published to the
Factorio mod portal yet - that's planned for 1.0 (see
[`changelog.md`](../changelog.md)).

## 1. Bump the version

Update `version` in [`info.json`](../info.json) (semver, e.g. `0.1.1`).
This is the mod's only source of truth for its version - nothing else
needs editing to match it.

## 2. Build the zip

Factorio expects a zip whose contents sit inside a single top-level
folder named `<name>_<version>` (the `name` from `info.json`, e.g.
`replay-recorder_0.1.0`). Everything the mod needs to run goes inside
that folder:

```
replay-recorder_0.1.0/
├── control.lua
├── data.lua
├── data-updates.lua
├── settings.lua
├── info.json
├── LICENSE
├── locale/
└── script/
```

Leave out anything that isn't part of the running mod: `docs/`, `tools/`,
`README.md`, `changelog.md`, and repo/CI metadata (`.git`, `.gitignore`,
etc.) don't belong in the zip.

From the repo root:

```
VERSION=$(python3 -c "import json; print(json.load(open('info.json'))['version'])")
STAGE="replay-recorder_${VERSION}"
rm -rf "/tmp/${STAGE}" && mkdir -p "/tmp/${STAGE}"
cp -r control.lua data.lua data-updates.lua settings.lua info.json LICENSE locale script "/tmp/${STAGE}/"
(cd /tmp && zip -r "${STAGE}.zip" "${STAGE}")
```

## 3. Tag and release on GitHub

1. Tag the release commit: `git tag v<version>` (e.g. `v0.1.0`), then
   `git push origin v<version>`.
2. Create a GitHub release from that tag.
3. Use the matching point-release section from
   [`changelog.md`](../changelog.md) as the release notes.
4. Attach the zip built in step 2 as a release asset.

That's it - no mod portal upload, no forum post, until 1.0.
