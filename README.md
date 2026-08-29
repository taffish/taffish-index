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
index/gate-state.json
index/reports/latest.json
index/reports/<timestamp>.json
```

`index/index.json` is the full index. Split package and command files are written
for consumers that want smaller lookups.

`index/gate-state.json` is internal builder state. It preserves exact per-backend
gate results and retry markers for new and failed versions so a later run can
reuse matching passed work. Its additive `observations` ledger also freezes the
first successfully aggregated source ref, source commit, image name, and observed
digest for every planned container release, including releases that fail inspect
or required smoke. Package-manager clients do not consume this file.

Report files record scan warnings, required trust-gate failures, and advisory
backend failures under `advisory_failed`. Failed new versions are not added to
the main index; maintainers inspect reports and fix the app repository before
the version can become installable.

Staged reports retain the existing `failed`, `rejected`, and `warnings` fields
and add `policy`, `counts.advisory_failed`, and the `advisory_failed` array.

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
| `counts` | Summary counts for packages, versions, commands, repositories, warnings, required failures, advisory failures, and known rejected releases. |
| `packages` | Package records keyed by package name. |
| `commands` | Command lookup records keyed by base command name. |
| `repositories` | Repository lookup records keyed by `owner/repo`. |
| `warnings` | Non-fatal scan or validation warnings. |

Each package record contains a `versions` object keyed by version id, such as
`0.1.0-r1`. The `latest` field keeps the default install version semantics
based on version/release ordering. The optional `recent_at` and
`recent_version` fields identify the most recently published accepted release
for registry display and sorting.

Each version record contains package metadata, runtime flags, dependency
metadata, platform constraints, optional human-facing meta fields, source ref
information, optional publication time metadata, optional container metadata,
optional smoke metadata, trust status, and optional upstream metadata.

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

The compatibility builder prefers release tags and can explicitly include
default branch snapshots for development use. The staged production pipeline
indexes immutable release tags only; branch snapshots never enter its durable
multi-backend observation ledger.

## Trust Gate

The staged builder checks both the previous `index/index.json` and the internal
`index/gate-state.json` for each `repository + version_id`:

- If the version already exists and its release tag still points to the same
  commit, the accepted record is reused by default. This keeps routine runs
  focused on new and previously failed versions rather than backfilling history.
- After the tags API resolves a release commit, every manifest and required-file
  read is addressed through that SHA, so a tag move during the scan cannot mix
  one commit identity with another commit's metadata. A missing or malformed
  release commit SHA produces a warning and no record; it never falls back to
  reading through the movable tag.
- Reused records preserve cached container, smoke, and trust evidence while
  refreshing safe parsed metadata such as dependencies, platform constraints,
  meta, and upstream fields.
- `--backfill` plans unchanged historical records for the matrix but still
  reuses identity-matching passed backend results. It is the controlled way to
  fill missing backend coverage. Legacy trust-v1 evidence does not contain the
  complete v2 identity, so an explicit legacy backfill re-runs every configured
  backend instead of relabeling the old pass.
- `--backfill --backfill-limit N` bounds only newly selected legacy releases to
  `1-50`. New releases, persistent retries, and enrolled evidence refreshes are
  always added independently and do not consume that quota. Selection is
  deterministic and ranks every package's newest release first, then its older
  releases; persisted v2 evidence automatically advances the next batch.
- `--force-recheck` also plans unchanged records, but disables gate-result cache
  reuse and re-runs digest and smoke work. It is intentionally not the default.
- `--retry-failed` is a manual retry-only mode. It plans only releases with an
  exact current `failed`/`not_checked` backend result or a persisted retry marker,
  while excluding unrelated new releases, legacy backfill, and pure policy
  refreshes. The latest exact gate-state result takes precedence over older public
  evidence, and already passed backends are still reused independently.
- A release tag that changes commit is rejected even under `--force-recheck`;
  force only disables reuse and never weakens immutable-release validation. The
  last accepted commit remains in the stable index, so the moved tag continues
  to fail on later runs instead of being rediscovered as a new release.
- If a previously indexed version is missing from the current scan, the builder
  preserves the previous record and reports a warning until the version is
  explicitly listed in `rejected-releases.toml`.
- When an accepted same-source version is scheduled for backfill or retry, its
  last accepted record remains the stable fallback until the replacement passes
  every required gate. Inspect or required-smoke failures are still reported;
  `gate-state.json.retry_tasks` carries those failures into later routine runs so
  they are retried instead of disappearing from the next report. A required pass
  clears the marker; explicitly rejecting the immutable release removes it.
- A release does not need to enter the public index before immutability begins.
  Once an aggregate completes, `gate-state.json.observations` keeps the first
  identity seen for every planned container task. A later run may fill a digest
  that was initially unavailable, but it cannot replace an existing source ref,
  source commit, image name, or digest. Malformed or conflicting observation
  state fails closed. An explicit `rejected-releases.toml` entry is the supported
  removal path, including when the rejected release is absent from that day's scan.

For containerized apps, the staged gate:

1. validates metadata and creates a deterministic plan;
2. inspects image digests and platform manifests with Docker buildx, rejecting a
   same-release image tag whose digest changed;
3. runs the same version-level smoke contract with Docker, Podman, and Apptainer;
4. strictly validates all plan, manifest, and backend result artifacts;
5. accepts the version when every required backend passes and reports advisory
   failures without turning them into required failures.

The initial `multibackend-1` policy is deliberately gradual. The backend declared
by `[smoke].backend` is required; for the current app corpus that backend is
Docker. The other configured backends, currently Podman and Apptainer, are
advisory. Their failures appear in `advisory_failed` and in per-backend evidence
but do not remove an otherwise accepted version. Changing this required/advisory
contract requires an explicit policy-generation change.

Docker/Podman smoke runs use `--network none`, do not mount the repository, and
do not receive GitHub tokens or secrets. Their image pull gets one bounded retry
for non-timeout failures. Command diagnostics preserve both the beginning and
terminal error while remaining bounded. Apptainer uses a clean contained
environment and a digest-pinned, read-only temporary SIF. Every Apptainer smoke
command receives a unique disk-backed work directory for its contained HOME,
`/tmp`, and `/var/tmp`; the directory is deleted after that command, including on
failure. This avoids the small in-memory session directory without granting a
writable image or repository bind. Apptainer smoke is accepted only when the
runner's native platform matches the planned platform; it is not silently labeled
as cross-architecture emulation. The current Action policy runs smoke on
`linux/amd64`; inspecting an image that also publishes `linux/arm64` does not
prove that backend smoke passed natively on arm64.

Passed backend results are reusable only when the full cache identity matches:
task id (`repository + version_id`), source commit, image digest, smoke SHA-256,
backend, platform, and policy generation. Runtime and runner versions are stored
as evidence but are not automatic cache invalidators. Partial successes for a
failed new version remain in `gate-state.json`, and inspect/required failures are
listed in its internal `retry_tasks` array. The next run repeats only work whose
identity is missing or no longer matches while still retrying marked releases.
For the same identity, an exact `failed` or `not_checked` gate-state result is
newer than a public-index pass and vetoes that fallback until the backend runs
successfully again.

The observation ledger is persisted transactionally by `aggregate`, the only
writer. If an Action, artifact, or required-backend infrastructure failure stops
the workflow before aggregate completes, no new observation can be committed;
the failed workflow remains the operational evidence, and the next aggregate
that completes establishes the persistent baseline. This boundary avoids a
partial write but cannot manufacture durable state from a run that never reached
the writer.

The main index keeps passed or previously accepted versions. It is not a
destructive mirror of the current GitHub scan; it is an append-oriented stable
ledger. If a version disappears from a scan because of transient GitHub raw/API
failures, repository visibility issues, or accidental deletion, the previous
record is preserved and reported for maintainer review. Gate failures are
written to `index/reports/latest.json` and timestamped report files. Known-bad
immutable releases listed in `rejected-releases.toml` are skipped and reported
under `rejected` instead of being re-smoked on every run. `taf update` and
`taf install` consume the stable main index, while maintainers use reports to
fix failed app releases.

Previously accepted versions may not have full multi-backend evidence until a
controlled `--backfill` or `--force-recheck` run. Historical records are not
backfilled by default, preserving install stability and bounded routine runtime.
The bounded form is recommended for staged migration; bare `--backfill` remains
an unlimited compatibility mode.

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
  "backend_used": "docker",
  "policy_generation": "multibackend-1",
  "platform": "linux/amd64",
  "required_backends": ["docker"],
  "advisory_backends": ["podman", "apptainer"],
  "backend_results": {
    "docker": {
      "status": "passed",
      "checked_at": "2026-05-12T08:00:00Z",
      "platform": "linux/amd64",
      "runtime_version": "Docker version ...",
      "runner_image": "ubuntu24/...",
      "policy_generation": "multibackend-1",
      "source_commit": "0123456789abcdef...",
      "image_digest": "sha256:...",
      "smoke_sha256": "...",
      "provenance": "taffish-index",
      "failure_kind": null,
      "message": null
    }
  }
}
```

The fields through `backend_used` are retained for compatibility. The staged
pipeline adds the policy, platform, required/advisory lists, and deterministically
keyed `backend_results`. Legacy records without staged evidence keep the original
shape until they are processed by the new pipeline.

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
- `keywords` are trimmed, lowercased search terms used to improve package discovery.
- `category` and `categories` accept simple filter tokens made of letters,
  digits, `.`, `_`, `-`, `+`, and `&`.
- Unlike category identifiers, `keywords` accept printable Unicode text and
  punctuation. Scientific names and phrases such as `Moran's I`, `Moran’s I`,
  `5′ UTR`, `Cα`, `ka/ks`, `cut&run`, and `multiple sequence alignment` are
  valid. Tabs, newlines, and other control characters are rejected.
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

Scheduled runs always use routine mode. Manual dispatch exposes two mutually
exclusive controls: `backfill_limit` accepts `1-50` for a bounded legacy
backfill, while `retry_failed` selects only exact current failed/not-checked
evidence. Leave both at their defaults for routine mode.

The workflow is configured as a four-stage pipeline driven by
`scripts/index-phase.lisp`:

1. `plan` scans repositories, applies overrides/rejections/history rules, and
   uploads an immutable plan artifact.
2. `inspect` verifies the plan and inspects image digests/platform manifests,
   then uploads a manifest artifact.
3. `smoke` runs Docker, Podman, and Apptainer as three matrix jobs. Each backend
   receives its own standard `ubuntu-24.04` runner and uploads one result artifact.
4. `aggregate` downloads every artifact, performs strict identity and coverage
   validation, transactionally replaces `index/`, and is the only job allowed to
   commit and push.

The configured bounded concurrency is:

| Stage | Default | Accepted maximum |
| --- | ---: | ---: |
| Repository scan | 8 | 8 |
| Digest inspection | 4 | 4 |
| Docker version workers | 2 | 4 |
| Podman version workers | 2 | 4 |
| Apptainer version workers | 1 | 2 |

Repository workers still serialize GitHub REST requests to avoid multiplying API
pressure, while raw-file work may overlap. Digest and smoke pools return results
in task order even when execution completes out of order. Docker, Podman, and
Apptainer run on independent runners, so their local image stores, temporary
files, and resource limits are isolated from one another.

Every plan, manifest, and result document has a content-derived ID. Aggregation
rejects schema, source-head, policy, platform, task coverage, duplicate/missing
backend, result-identity, and observation/digest mismatches before writing.
Observation state is integrity-critical and fails closed even though malformed
backend-result cache entries can be conservatively ignored and rerun. Aggregate
builds a staging directory first, verifies required files, then promotes the
directory with a backup/restore path. Earlier jobs have only `contents: read`;
only `aggregate` has `contents: write`, and it refuses to push if `origin/main`
moved since the workflow began.

This describes the checked-in workflow configuration and local validation
contract. It does not claim that this updated workflow has already completed a
remote GitHub Actions run.

The original `scripts/build-index.lisp` entry point and its CLI remain available
for compatibility with local callers. GitHub Actions uses the staged
`scripts/index-phase.lisp` path; the legacy command is not the multi-runner Action
pipeline.

## Local Test

From this repository root:

```sh
bash tests/action-plan.sh
sbcl --script tests/project.lisp
sbcl --script tests/concurrency.lisp
sbcl --script tests/pipeline.lisp
```

To build an index from a local fixture repository:

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
TAFFISH_BOT_TOKEN=<TOKEN> sbcl --script scripts/build-index.lisp -- --org taffish --jobs 8 --output index
```

For public repositories, unauthenticated requests may work, but a token is more
reliable because of GitHub API rate limits.

The default is eight repository workers. Use `--jobs 1` for a strictly serial
scan or another integer from 1 through 8 to reduce local concurrency.

On the staged `index-phase.lisp plan` path, every explicit `--local-repo` must
be the root of its own clean Git worktree with a committed `HEAD`; non-Git,
nested-monorepo, modified, staged, or untracked inputs fail the plan. The staged
record reads `taffish.toml` and every required-path existence gate directly from
the committed tree, then uses `source.ref = "local"` and the real `HEAD` commit.
Ignored worktree-only files therefore cannot escape the immutable identity. The
compatibility `build-index.lisp` command retains its historical local-fixture
behavior.

The staged CLI can be reproduced locally in four phases when Docker, Podman, and
Apptainer are installed. The Action runs the three smoke commands on independent
runners; this local example lists them sequentially:

```sh
mkdir -p work/results

# 1. Plan: routine mode checks new and previously failed versions.
sbcl --script scripts/index-phase.lisp plan \
  --org taffish \
  --index-dir index \
  --output work/plan.json \
  --jobs 8 \
  --backends docker,podman,apptainer \
  --policy-generation multibackend-1 \
  --platform linux/amd64

# 2. Inspect immutable image identities.
sbcl --script scripts/index-phase.lisp inspect \
  --plan work/plan.json \
  --output work/manifest.json \
  --jobs 4

# 3. Smoke each backend (independent Action runners in production).
sbcl --script scripts/index-phase.lisp smoke \
  --manifest work/manifest.json --backend docker \
  --output work/results/docker.json --jobs 2
sbcl --script scripts/index-phase.lisp smoke \
  --manifest work/manifest.json --backend podman \
  --output work/results/podman.json --jobs 2
sbcl --script scripts/index-phase.lisp smoke \
  --manifest work/manifest.json --backend apptainer \
  --output work/results/apptainer.json --jobs 1

# 4. Validate all artifacts and transactionally aggregate once.
sbcl --script scripts/index-phase.lisp aggregate \
  --plan work/plan.json \
  --manifest work/manifest.json \
  --result work/results/docker.json \
  --result work/results/podman.json \
  --result work/results/apptainer.json \
  --index-dir index
```

## Configuration

The staged command has phase-specific help:

```sh
sbcl --script scripts/index-phase.lisp --help
```

Important staged options are:

```text
plan      --jobs <1-8> --backends <CSV> --policy-generation <ID>
          --platform <OS/ARCH>
          [--backfill [--backfill-limit <1-50>] | --force-recheck |
           --retry-failed]
inspect   --plan <PATH> --output <PATH> --jobs <1-4>
smoke     --manifest <PATH> --backend <NAME> --output <PATH> --jobs <N>
aggregate --plan <PATH> --manifest <PATH> --result <PATH>... --index-dir <DIR>
```

`--backfill` includes unchanged historical records while reusing exact passed
cache matches. Add `--backfill-limit N` to select at most N new legacy release
tasks; the limit does not cap new releases, retries, or policy refreshes. A limit
requires `--backfill` and cannot be combined with `--force-recheck`. Bare
`--backfill` keeps the unlimited compatibility behavior. `--force-recheck`
includes historical records but ignores matching gate cache results. Neither
mode weakens changed-source-commit rejection, and routine Action runs use neither
mode.

`--retry-failed` is mutually exclusive with both backfill forms and
`--force-recheck`. It selects only exact evidence for the current source commit,
image digest, smoke signature, platform, and policy generation. Rejection and
immutable-source drift checks still run first and cannot be bypassed by this mode.

The compatibility `scripts/build-index.lisp` CLI remains:

```text
--org <ORG>                  Scan GitHub organization
--no-org                     Disable GitHub organization scan
--local-repo <PATH>          Add a local TAFFISH app repository
--output <DIR>               Output directory, default index
--jobs <N>                   Concurrent repository workers, 1-8, default 8
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
| `TAFFISH_INDEX_JOBS` | Default concurrent repository worker count when `--jobs` is omitted. Must be from 1 through 8; defaults to 8. |
| `TAFFISH_INDEX_INCLUDE_DEFAULT_BRANCH` | Enables default branch snapshots when set to `1`, `true`, or `yes`. |
| `TAFFISH_INDEX_FORCE_RECHECK` | Re-runs digest/smoke gates when set to `1`, `true`, or `yes`. |
| `TAFFISH_INDEX_APPTAINER_WORK_ROOT` | Optional absolute disk directory under which unique contained Apptainer smoke workdirs are created and removed. Defaults to the system temporary directory. |
| `TAFFISH_INDEX_POLICY_GENERATION` | Default staged cache-policy generation. Defaults to `multibackend-1`. |
| `TAFFISH_INDEX_PLATFORM` | Explicit staged smoke platform. Defaults to `linux/amd64`. |
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
