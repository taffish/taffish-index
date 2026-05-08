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

`taffish.toml` can include dependency, platform, and upstream source metadata:

```toml
[dependencies]
taf-dep-tool = "0.1.0-r1"
taf-next-step = "latest"
taf-x = ["0.1.0-r1", "0.1.0-r2"]

[platform]
os = "linux,darwin"
arch = "amd64,arm64"
container = "required"       # optional|required|forbidden
min_cpus = 2
min_memory_mb = 4096

[upstream]
name = "CD-HIT"
type = "github"              # official|github|gitlab|archive|docker|apt|conda|other
homepage = "https://github.com/weizhongli/cdhit"
repository = "weizhongli/cdhit"
release_url = "https://github.com/weizhongli/cdhit/releases"
version = "4.8.1"
license = "GPL-2.0"
citation = "Fu et al. 2012"
doi = "10.1093/bioinformatics/bts565"
pmid = "23060610"
```

These fields are exported into each version record under:

- `dependencies` (command => version-id or version-id array)
- `platform.os[]`
- `platform.arch[]`
- `platform.container`
- `platform.min_cpus`
- `platform.min_memory_mb`
- `upstream` (only when at least one recognized upstream field is provided)

Recognized upstream fields are `name`, `type`, `homepage`, `repository`,
`release_url`, `docker_image`, `version`, `license`, `citation`, `doi`, and
`pmid`. Unknown or empty upstream fields are ignored, and missing upstream
metadata is omitted instead of being represented as `null` or `none`.

## Local Test

From this repository root:

```sh
sbcl --script scripts/build-index.lisp -- --no-org --local-repo ../../taffish/test/my-test-tool --output index
```

From the `taffish-hub` workspace root:

```sh
cd repos/taffish-index
sbcl --script scripts/build-index.lisp -- --no-org --local-repo ../../../taffish/test/my-test-tool --output index
```

## GitHub Automation

`.github/workflows/build-index.yml` runs on:

- manual dispatch,
- daily schedule.

The scheduled run uses cron `17 1 * * *` (UTC).

It installs SBCL, runs:

```sh
sbcl --script scripts/build-index.lisp -- --org "taffish" --output index
```

and commits changed `index/` files back to this repository.

The automation is fixed to scan the `taffish` organization. Configure secret `TAFFISH_BOT_TOKEN` if the workflow must read private repositories; otherwise the default `GITHUB_TOKEN` is enough for public repository scans.
