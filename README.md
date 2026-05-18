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
- [Trust Gate](#trust-gate)
- [Optional Metadata](#optional-metadata)
- [GitHub Automation](#github-automation)
- [Local Test](#local-test)
- [Configuration](#configuration)
- [Related Repositories](#related-repositories)
- [License](#license)
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
index/reports/latest.json
index/reports/<timestamp>.json
```

`index/index.json` is the full index. Split package and command files are written
for consumers that want smaller lookups.

Report files record scan warnings and trust-gate failures. Failed new versions
are not added to the main index; maintainers inspect reports and fix the app
repository before the version can become installable.

Known-bad immutable releases can be listed in `rejected-releases.toml`. Rejected
versions are skipped before digest or smoke gates run, are not added to the main
index, and are reported separately from transient trust-gate failures.

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
| `counts` | Summary counts for packages, versions, commands, repositories, warnings, failed trust gates, and known rejected releases. |
| `packages` | Package records keyed by package name. |
| `commands` | Command lookup records keyed by base command name. |
| `repositories` | Repository lookup records keyed by `owner/repo`. |
| `warnings` | Non-fatal scan or validation warnings. |

Each package record contains a `versions` object keyed by version id, such as
`0.1.0-r1`.

Each version record contains package metadata, runtime flags, dependency
metadata, platform constraints, optional human-facing meta fields, source ref
information, optional container metadata, optional smoke metadata, trust status,
and optional upstream metadata.

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

## Trust Gate

For each `repository + version_id`, the builder checks the previous
`index/index.json` first:

- If the version already exists and the release tag still points to the same
  commit, the previous record is reused by default.
- Reused records preserve cached trust-gate results such as container digest,
  platform digests, smoke status, and trust status, while refreshing safe parsed
  metadata such as dependencies, platform constraints, meta, and upstream fields.
- If the version is new, or `--force-recheck` is used, the builder applies the
  trust gate.
- If a release tag changes commit, the version is rejected and reported instead
  of silently replacing the previous record.

For containerized apps, the trust gate currently:

1. validates `[smoke]` metadata;
2. inspects the container image digest and platform list with Docker buildx;
3. runs smoke checks inside the declared backend;
4. adds the version to the main index only when all checks pass.

Docker/Podman smoke runs use `--network none`, do not mount the repository, and
do not pass GitHub tokens or secrets into the container. Apptainer smoke uses a
clean contained environment when that backend is available.

The main index keeps passed or previously accepted versions. Gate failures are
written to `index/reports/latest.json` and timestamped report files. Known-bad
immutable releases listed in `rejected-releases.toml` are skipped and reported
under `rejected` instead of being re-smoked on every run. `taf update` and
`taf install` consume the stable main index, while maintainers use reports to
fix failed app releases.

Previously accepted versions may not have full trust metadata until they are
republished or rechecked with `--force-recheck`. This preserves install
stability while the Hub follows the stricter 0.8.x trust model.

Current container metadata shape:

```json
"container": {
  "image": "ghcr.io/taffish/my-tool:0.1.0-r1",
  "dockerfile": "docker/Dockerfile",
  "image_tag": "0.1.0-r1",
  "image_tag_matches_version": true,
  "digest": "sha256:manifest-list-digest",
  "platforms": ["linux/amd64", "linux/arm64"],
  "platform_digests": {
    "linux/amd64": "sha256:...",
    "linux/arm64": "sha256:..."
  }
}
```

Current smoke result shape:

```json
"smoke": {
  "backend": "docker",
  "timeout": 60,
  "exist": ["samtools"],
  "test": ["samtools --help"],
  "status": "passed",
  "checked_at": "2026-05-12T08:00:00Z",
  "backend_used": "docker"
}
```

## Optional Metadata

`taffish.toml` can include dependencies, platform constraints, human-facing
meta fields, smoke metadata, and upstream source metadata.

TAFFISH `0.8.1` documents `[meta]` and `[upstream]` as optional ecosystem
metadata. New public Hub apps should provide them when useful, while old
immutable releases can have display metadata and existing upstream attribution
metadata supplemented with `metadata-overrides.toml`.

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

[meta]
domain = "bio"
category = "clustering"
keywords = ["sequence", "identity", "cd-hit"]
summary = "Sequence clustering toolkit for reducing redundancy in biological sequence datasets."

[smoke]
backend = "docker"
timeout = 60
exist = ["cd-hit"]
test = ["cd-hit -h"]

[upstream]
name = "CD-HIT"
type = "github"              # official|github|gitlab|archive|docker|apt|conda|other
url = "https://github.com/weizhongli/cdhit"
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

Meta:

- `domain` is a broad domain token such as `bio`, `ml`, `chem`, `devops`, or `general`.
- `category` is the primary category token used for Hub filtering and browsing.
- `keywords` are normalized search tokens used to improve package discovery.
- `category` and `categories` accept simple filter tokens made of letters,
  digits, `.`, `_`, `-`, and `+`.
- `keywords` accept the same characters plus `/` and spaces, so common aliases
  and phrases such as `blast+`, `ka/ks`, `dn/ds`, and
  `multiple sequence alignment` are valid search terms.
- `summary` is a short human-facing description for Hub pages and repository metadata.
- `categories` and `description` are accepted Hub-side aliases. The index
  normalizes `category` into `categories` and `summary` into `description`, then
  emits both forms for compatibility.
- New app releases should prefer native `[meta]` in `taffish.toml`.
- Existing immutable release tags can be supplemented through `metadata-overrides.toml`.

Upstream:

- Recognized fields are `name`, `type`, `url`, `homepage`, `repository`,
  `release_url`, `docker_image`, `version`, `license`, `citation`, `doi`, and
  `pmid`.
- `repository` is the canonical upstream repository field. `repo` is also
  accepted as a compatibility alias and is normalized to `repository` in JSON
  output.
- Empty or unknown upstream fields are ignored.
- Missing upstream metadata is omitted from JSON rather than represented as
  `null`, `none`, or `"not provided"`.
- `metadata-overrides.toml` may supplement `license`, `citation`, `doi`, and
  `pmid` on records that already have upstream data, but it does not create a
  new upstream object.

Smoke:

- Containerized projects must define `[smoke]`.
- `backend`, when present, must be `docker`, `podman`, or `apptainer`; missing `backend` defaults to `docker`.
- `timeout`, when present, must be a positive integer; missing `timeout` defaults to `60`.
- `exist` and `test`, when present, must be arrays of non-empty strings.
- `exist` and `test` cannot both be empty.
- Default `TODO` placeholders are rejected.
- Smoke commands are run by the index automation, not by local `taf check`.
- `test` entries are TOML strings and are executed through `sh -c` inside the
  smoke container. TOML escapes such as `\"` are supported, but shell snippets
  that need nested quoting are easier to read when the inner command uses single
  quotes, for example `test = ["python -c 'import vina, rdkit'"]`.

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
--metadata-overrides <PATH>  Optional metadata override TOML, default metadata-overrides.toml
--meta-overrides <PATH>      Compatibility alias for --metadata-overrides
--rejected-releases <PATH>   Optional known rejected release TOML, default rejected-releases.toml
--include-default-branch     Also index default branch snapshots
--include-archived           Include archived GitHub repositories
--include-forks              Include fork repositories
--force-recheck              Re-run digest/smoke gates even when cached trust
                             metadata exists
-h, --help                   Show command help
```

Environment variables:

| Variable | Purpose |
| --- | --- |
| `TAFFISH_ORG` | Default organization if `--org` is not provided. Defaults to `taffish`. |
| `TAFFISH_BOT_TOKEN` | GitHub API token used by the builder. |
| `TAFFISH_INDEX_INCLUDE_DEFAULT_BRANCH` | Enables default branch snapshots when set to `1`, `true`, or `yes`. |
| `TAFFISH_INDEX_FORCE_RECHECK` | Re-runs digest/smoke gates when set to `1`, `true`, or `yes`. |
| `TAFFISH_INDEX_METADATA_OVERRIDES` | Optional path to a metadata override TOML file. Defaults to `metadata-overrides.toml`. |
| `TAFFISH_INDEX_META_OVERRIDES` | Compatibility fallback for the older override path variable. |
| `TAFFISH_INDEX_REJECTED_RELEASES` | Optional path to a known rejected release TOML file. Defaults to `rejected-releases.toml` when present. |

The GitHub Actions workflow uses `TAFFISH_BOT_TOKEN` from repository secrets when
available, and falls back to `GITHUB_TOKEN`.

## Metadata Overrides

`metadata-overrides.toml` lets the index add display/search metadata and the
attribution metadata of an already declared upstream repository to published
immutable app releases without creating a new `-rN` release only for metadata
changes such as description, category, keywords, license, citation, DOI, or
PMID.

Each override section must include `repository` and `version_id`, then any
supported meta fields. To supplement attribution fields of an existing upstream
repository, use a sibling `[<section>.upstream]` table with `license`,
`citation`, `doi`, and optionally `pmid`:

```toml
[bcftools-1.23.1-r1]
repository = "taffish/bcftools"
version_id = "1.23.1-r1"
domain = "bio"
categories = ["genomics", "variant-calling", "vcf-bcf"]
keywords = ["vcf", "bcf", "variant", "htslib"]
description = "Toolkit for variant calling and manipulating VCF/BCF genomic variant files."

[bcftools-1.23.1-r1.upstream]
license = "MIT/Expat or GPL"
citation = "Danecek et al. 2021"
doi = "10.1093/gigascience/giab008"
pmid = "33590861"
```

Overrides are applied after app metadata is read from GitHub. If a future
release already carries native `[meta]` or `[upstream]`, the exact-version
override can be removed or left to intentionally adjust the published display
metadata. Upstream overrides are intentionally limited to attribution fields
(`license`, `citation`, `doi`, and `pmid`) and only merge into records that
already have upstream data, so they supplement the existing upstream repository
instead of creating a new upstream object.

## Rejected Releases

`rejected-releases.toml` records immutable app releases that should not be
rechecked or added to the main index. Use it only when a version is known to be
bad and has been superseded by a later release. Temporary network, registry, or
runner failures should stay in `index/reports/latest.json` and should not be
added here.

Example:

```toml
[fastp-1.3.3-r1]
repository = "taffish/fastp"
version_id = "1.3.3-r1"
ref = "v1.3.3-r1"
replacement = "1.3.3-r2"
reason = "Immutable release has invalid smoke commands; fixed by v1.3.3-r2."
```

Required fields are `repository`, `version_id`, and `reason`. `ref` is optional
but recommended, because it makes the rejection target explicit. `replacement`
is optional and only used for maintainer-facing reports.

## Related Repositories

- [taffish/taffish](https://github.com/taffish/taffish): open-source CLI/compiler source repository, installers, release payloads, and source-tree developer docs.
- [taffish/taffish-docs](https://github.com/taffish/taffish-docs): public documentation for users, app authors, Hub/index maintainers, MCP, and the security model.
- [taffish/taffish.github.io](https://github.com/taffish/taffish.github.io): web Hub.

## License

The index builder source code and repository automation are licensed under the
[Apache License 2.0](LICENSE).

The generated machine-readable index data under `index/` is dedicated under
[CC0 1.0 Universal](LICENSE-DATA), to make mirroring, caching, and third-party
package-index consumption straightforward.

## Status

`taffish-index` is part of the current GitHub-based TAFFISH Hub design. It is a
static index repository, not a general package publishing service and not a
custom backend server.

The official Hub is curated by the `taffish` organization. It is not an open
self-service publishing platform yet.
