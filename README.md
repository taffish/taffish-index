# taffish-index

[English](README.md) | [中文](README.cn.md)

`taffish-index` is the static package index repository for TAFFISH Hub.

It scans TAFFISH app repositories in the `taffish` GitHub organization, validates
their `taffish.toml` metadata and release tags, generates JSON index files, and
commits those generated files back to this repository.

Local `taf` commands use this repository as the cloud index source for package
discovery and installation.

## Table of Contents

- [Role in TAFFISH Hub](#role-in-taffish-hub)
- [Generated Files](#generated-files)
- [Index Format](#index-format)
- [Package Discovery](#package-discovery)
- [Optional Metadata](#optional-metadata)
- [GitHub Automation](#github-automation)
- [Local Test](#local-test)
- [Configuration](#configuration)
- [Related Repositories](#related-repositories)
- [Status](#status)

## Role in TAFFISH Hub

TAFFISH Hub is currently GitHub-based. The index repository is the bridge between
GitHub app repositories and the local `taf` package manager:

1. App repositories publish versioned tags such as `v0.1.0-r1`.
2. `taffish-index` scans the organization and validates app metadata.
3. The builder writes static JSON files under `index/`.
4. Users run `taf update` to cache the latest index locally.
5. `taf search`, `taf info`, and `taf install` resolve packages from that cached index.

The official index URL is:

```text
https://raw.githubusercontent.com/taffish/taffish-index/main/index/index.json
```

TAFFISH `0.2.0` can also read a mirrored index through runtime config:

```toml
[index]
url = "https://gitee.com/taffish-org/taffish-index/raw/main/index/index.json"

[[source.rewrite]]
from = "https://github.com/taffish/"
to = "https://gitee.com/taffish-org/"
enabled = true
```

`taf update` reads `[index].url`; `taf install` applies `source.rewrite` when
cloning app repositories. Mirror operators must keep compatible repositories,
release tags, and the same index schema.

This repository does not build container images. Image builds belong to each app
repository.

## Generated Files

The index builder writes:

```text
index/index.json
index/packages/<package>.json
index/commands/<command>.json
```

`index/index.json` is the full index. Split package and command files are written
for consumers that want smaller lookups.

Generated files are committed intentionally. They are the published static index
that `taf` can download without requiring a custom Hub backend server.

## Index Format

Current schema identifier:

```json
"schema_version": "taffish.index/v1"
```

Top-level fields include:

| Field | Purpose |
| --- | --- |
| `schema_version` | Index schema identifier. |
| `generated_at` | UTC generation timestamp. |
| `organization` | Scanned GitHub organization, normally `taffish`. |
| `counts` | Summary counts for packages, versions, commands, repositories, and warnings. |
| `packages` | Package records keyed by package name. |
| `commands` | Command lookup records keyed by base command name. |
| `repositories` | Repository lookup records keyed by `owner/repo`. |
| `warnings` | Non-fatal scan or validation warnings. |

Each package record contains a `versions` object keyed by version id, such as
`0.1.0-r1`.

Each version record contains package metadata, runtime flags, dependency
metadata, platform constraints, source ref information, optional container
metadata, and optional upstream metadata.

## Package Discovery

A repository is considered a TAFFISH app when:

- A root-level `taffish.toml` exists.
- Required `taffish.toml` sections and fields are present.
- `[package].name` is a valid TAFFISH project name.
- `[package].kind` is `tool` or `flow`.
- `[package].main` points to an existing `.taf` file.
- `docs/help.md` exists.
- `[repository].url` is a GitHub repository URL.
- `[repository].url` matches the scanned repository.
- `[command].name` starts with `taf-`.
- Release tags use `v<version>-r<release>`.

The builder prefers release tags. Default branch snapshots are only indexed when
explicitly enabled for development use.

## Optional Metadata

`taffish.toml` can include dependencies, platform constraints, and upstream
source metadata.

Example:

```toml
[dependencies]
taf-dep-tool = "0.1.0-r1"
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
docker_image = "quay.io/biocontainers/cd-hit:4.8.1"
version = "4.8.1"
license = "GPL-2.0"
citation = "Fu et al. 2012"
doi = "10.1093/bioinformatics/bts565"
pmid = "23060610"
```

Dependencies:

- Keys must be base taf command names, such as `taf-fastqc`.
- Values may be a version id string or an array of version id strings.
- Arrays mean every listed version is required. They are not alternatives.

Platform:

- `os` and `arch` are comma-separated token lists.
- `container` defaults to `optional`.
- `min_cpus` and `min_memory_mb` must be positive integers when present.

Upstream:

- Recognized fields are `name`, `type`, `homepage`, `repository`, `release_url`,
  `docker_image`, `version`, `license`, `citation`, `doi`, and `pmid`.
- Empty or unknown upstream fields are ignored.
- Missing upstream metadata is omitted from JSON rather than represented as
  `null`, `none`, or `"not provided"`.

## GitHub Automation

`.github/workflows/build-index.yml` runs on:

- Manual dispatch.
- Daily schedule.

The scheduled run uses:

```text
17 1 * * *  # UTC
```

The workflow:

1. Checks out this repository.
2. Installs SBCL.
3. Runs the Common Lisp index builder.
4. Writes generated files under `index/`.
5. Commits and pushes changes when the generated index changed.

The main build command is:

```sh
sbcl --script scripts/build-index.lisp -- --org "taffish" --output index
```

## Local Test

From this repository root:

```sh
sbcl --script scripts/build-index.lisp -- --no-org --local-repo ../../../taffish/test/my-test-tool --output index
```

You can also scan multiple local repositories:

```sh
sbcl --script scripts/build-index.lisp -- \
  --no-org \
  --local-repo ../../../taffish/test/my-test-tool \
  --local-repo ../../../taffish/test/my-test-flow \
  --output index
```

To scan the GitHub organization locally:

```sh
TAFFISH_BOT_TOKEN=<TOKEN> sbcl --script scripts/build-index.lisp -- --org taffish --output index
```

For public repositories, unauthenticated requests may work, but a token is more
reliable because of GitHub API rate limits.

## Configuration

CLI options:

```text
--org <ORG>                  Scan GitHub organization
--no-org                     Disable GitHub organization scan
--local-repo <PATH>          Add a local TAFFISH app repository
--output <DIR>               Output directory, default index
--include-default-branch     Also index default branch snapshots
--include-archived           Include archived GitHub repositories
--include-forks              Include fork repositories
-h, --help                   Show command help
```

Environment variables:

| Variable | Purpose |
| --- | --- |
| `TAFFISH_ORG` | Default organization if `--org` is not provided. Defaults to `taffish`. |
| `TAFFISH_BOT_TOKEN` | GitHub API token used by the builder. |
| `TAFFISH_INDEX_INCLUDE_DEFAULT_BRANCH` | Enables default branch snapshots when set to `1`, `true`, or `yes`. |

The GitHub Actions workflow uses `TAFFISH_BOT_TOKEN` from repository secrets when
available, and falls back to `GITHUB_TOKEN`.

## Related Repositories

- [taffish/taffish](https://github.com/taffish/taffish): CLI and compiler binary distribution.
- [taffish/taffish-docs](https://github.com/taffish/taffish-docs): developer documentation.
- [taffish/taffish.github.io](https://github.com/taffish/taffish.github.io): web Hub.

## Status

`taffish-index` is part of the current GitHub-based TAFFISH Hub design. It is a
static index repository, not a general package publishing service and not a
custom backend server.

The official Hub is curated by the `taffish` organization. It is not an open
self-service publishing platform yet.
