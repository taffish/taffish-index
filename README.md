# taffish-index

`taffish-index` is the generated package index for TAFFISH.

The repository is intentionally static. Its GitHub Actions workflow scans `taffish`, finds repositories that look like TAFFISH apps, and updates:

```text
index/index.json
index/packages/<package>.json
index/commands/<command>.json
```

Local users will eventually run:

```sh
taf update
```

and download:

```text
https://raw.githubusercontent.com/taffish/taffish-index/main/index/index.json
```

Then `taf install <name>` can resolve package metadata from the cached index.

## Package Discovery

A repository is considered a TAFFISH app when:

- root `taffish.toml` exists,
- required `taffish.toml` sections and fields are present,
- `[package].main` points to an existing `.taf` file,
- `docs/help.md` exists,
- `[repository].url` points to the scanned GitHub repository,
- release tags use `v<version>-r<release>`.

The builder prefers release tags. Default branch indexing can be enabled for development snapshots.

## Optional Metadata

`taffish.toml` can include dependency and platform constraints:

```toml
[dependencies]
blast = ">=2.0.0-r1"
seqtk = "^1.0.0-r3"

[platform]
os = "linux,darwin"
arch = "amd64,arm64"
container = "required"       # optional|required|forbidden
min_cpus = 2
min_memory_mb = 4096
```

These fields are exported into each version record under:

- `dependencies.packages[]`
- `platform.os[]`
- `platform.arch[]`
- `platform.container`
- `platform.min_cpus`
- `platform.min_memory_mb`

## Local Test

From this repository root:

```sh
sbcl --script scripts/build-index.lisp -- --local-repo ../../taffish/test/my-test-tool --output index
```

From the `taffish-hub` workspace root:

```sh
cd repos/taffish-index
sbcl --script scripts/build-index.lisp -- --local-repo ../../../taffish/test/my-test-tool --output index
```

## GitHub Automation

`.github/workflows/build-index.yml` runs on:

- manual dispatch,
- hourly schedule.

It installs SBCL, runs:

```sh
sbcl --script scripts/build-index.lisp -- --org "$TAFFISH_ORG" --output index
```

and commits changed `index/` files back to this repository.

Configure repository variable `TAFFISH_ORG` if the organization is not `taffish`. Configure secret `TAFFISH_BOT_TOKEN` if the workflow must read private repositories; otherwise the default `GITHUB_TOKEN` is enough for public repository scans.
