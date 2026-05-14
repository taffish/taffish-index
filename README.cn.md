# taffish-index

[English](README.md) | [中文](README.cn.md)

`taffish-index` 是 TAFFISH Hub 的静态包索引仓库。

它会扫描 `taffish` GitHub 组织下的 TAFFISH app 仓库，校验这些仓库中的
`taffish.toml` 元数据和 release tag，生成 JSON 索引文件，并把生成结果提交回
本仓库。

本地 `taf` 命令会把这个仓库作为云端索引来源，用于 app 的发现与安装。

## 目录

- [在 TAFFISH Hub 中的角色](#在-taffish-hub-中的角色)
- [生成文件](#生成文件)
- [索引格式](#索引格式)
- [包发现规则](#包发现规则)
- [可信 Gate](#可信-gate)
- [可选元数据](#可选元数据)
- [GitHub 自动化](#github-自动化)
- [本地测试](#本地测试)
- [配置](#配置)
- [相关仓库](#相关仓库)
- [许可证](#许可证)
- [当前状态](#当前状态)

## 在 TAFFISH Hub 中的角色

TAFFISH Hub 当前是基于 GitHub 的。`taffish-index` 是 GitHub app 仓库与本地
`taf` 包管理器之间的桥梁：

1. app 仓库发布类似 `v0.1.0-r1` 的版本 tag。
2. `taffish-index` 扫描组织并校验 app 元数据。
3. index builder 在 `index/` 下写入静态 JSON 文件。
4. 用户执行 `taf update`，把最新索引缓存到本地。
5. `taf search`、`taf info` 和 `taf install` 从本地缓存索引中解析 package。

官方索引 URL 是：

```text
https://raw.githubusercontent.com/taffish/taffish-index/main/index/index.json
```

TAFFISH `0.2.0` 也可以通过运行时配置读取镜像 index：

```toml
[index]
url = "https://gitee.com/taffish-org/taffish-index/raw/main/index/index.json"

[[source.rewrite]]
from = "https://github.com/taffish/"
to = "https://gitee.com/taffish-org/"
enabled = true
```

`taf update` 读取 `[index].url`；`taf install` 在 clone app 仓库时应用
`source.rewrite`。镜像维护者需要保持兼容仓库、release tag 和相同的 index schema。

这个仓库不负责构建容器镜像。镜像构建属于每个 app 仓库自己的职责。

## 生成文件

index builder 会写入：

```text
index/index.json
index/packages/<package>.json
index/commands/<command>.json
index/reports/latest.json
index/reports/<timestamp>.json
```

`index/index.json` 是完整索引。拆分后的 package 和 command 文件用于更小粒度
的读取场景。

report 文件会记录扫描 warning 和可信 gate 失败。失败的新版本不会进入主 index；
维护者需要查看 report，修复 app 仓库后，该版本才能变成可安装版本。

生成文件会被有意提交到仓库中。它们就是发布出来的静态索引，使 `taf` 不需要
自定义 Hub 后端服务器也可以下载和消费索引。

## 索引格式

当前 schema 标识：

```json
"schema_version": "taffish.index/v1"
```

顶层字段包括：

| 字段 | 作用 |
| --- | --- |
| `schema_version` | 索引 schema 标识。 |
| `generated_at` | UTC 生成时间。 |
| `organization` | 被扫描的 GitHub 组织，通常是 `taffish`。 |
| `counts` | packages、versions、commands、repositories、warnings 和 failed trust gates 的统计。 |
| `packages` | 以 package name 为 key 的 package 记录。 |
| `commands` | 以基础 command name 为 key 的 command 查询记录。 |
| `repositories` | 以 `owner/repo` 为 key 的 repository 查询记录。 |
| `warnings` | 非致命扫描或校验 warning。 |

每个 package 记录中包含一个 `versions` object，以 version id 为 key，例如
`0.1.0-r1`。

每个 version record 包含 package 元数据、runtime 标记、dependency 元数据、
platform 约束、可选的人类可读 meta 字段、source ref 信息、可选 container
元数据、可选 smoke 元数据、trust 状态和可选 upstream 元数据。

## 包发现规则

一个仓库会被视为 TAFFISH app，当它满足：

- 根目录存在 `taffish.toml`。
- 必需的 `taffish.toml` section 和字段存在。
- `[package].name` 是合法的 TAFFISH project name。
- `[package].kind` 是 `tool` 或 `flow`。
- `[package].main` 指向一个存在的 `.taf` 文件。
- `docs/help.md` 存在。
- `[repository].url` 是 GitHub 仓库 URL。
- `[repository].url` 与被扫描仓库一致。
- `[command].name` 以 `taf-` 开头。
- release tag 使用 `v<version>-r<release>` 格式。

builder 优先索引 release tag。默认分支 snapshot 只在显式开启时用于开发场景。

## 可信 Gate

对于每个 `repository + version_id`，builder 会先检查已有的 `index/index.json`：

- 如果该版本已经存在，并且 release tag 仍指向同一个 commit，默认复用旧记录。
- 复用旧记录时会保留已缓存的可信 gate 结果，例如容器 digest、平台 digest、
  smoke 状态和 trust 状态，同时刷新安全的解析元数据，例如依赖、平台约束、
  meta 和 upstream 字段。
- 如果是新增版本，或使用 `--force-recheck`，builder 会执行可信 gate。
- 如果 release tag 指向的 commit 发生变化，该版本会被拒绝并写入 report，而不是静默替换旧记录。

对于容器化 app，当前可信 gate 会：

1. 校验 `[smoke]` 元数据；
2. 使用 Docker buildx 检查容器镜像 digest 和平台列表；
3. 在声明的 backend 中运行 smoke checks；
4. 只有全部通过时，才把该版本写入主 index。

Docker/Podman smoke 运行会使用 `--network none`，不会挂载仓库，也不会把 GitHub
token 或 secrets 传入容器。Apptainer smoke 在该 backend 可用时使用干净的隔离环境。

主 index 保留通过检查或此前已经接受的稳定版本。Gate 失败会写入
`index/reports/latest.json` 和带时间戳的 report 文件。`taf update` 和
`taf install` 只消费稳定主 index，维护者通过 reports 修复失败的 app release。

此前已经接受的版本可能暂时没有完整 trust 元数据，直到重新发布或使用
`--force-recheck` 重新检查。这可以在 Hub 遵循更严格的 0.8.x 可信模型时保持安装稳定。

当前 container 元数据形态：

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

当前 smoke 结果形态：

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

## 可选元数据

`taffish.toml` 可以包含依赖、平台约束、人类可读 meta 字段、smoke 元数据和
upstream 来源元数据。

TAFFISH `0.8.1` 已将 `[meta]` 和 `[upstream]` 文档化为可选生态元数据。
新的公开 Hub app 应在有价值时提供它们；已发布且不可变的旧 release 可以通过
`metadata-overrides.toml` 补充展示元数据和已有 upstream 的归属/引用信息。

示例：

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

依赖：

- key 必须是基础 taf command name，例如 `taf-fastqc`。
- value 可以是一个 version id 字符串，也可以是 version id 字符串数组。
- 数组表示列出的每个版本都需要安装，不表示多个备选版本。

平台：

- `os` 和 `arch` 是逗号分隔的 token 列表。
- `container` 默认是 `optional`。
- `min_cpus` 和 `min_memory_mb` 如果存在，必须是正整数。

Meta：

- `domain` 是大的领域 token，例如 `bio`、`ml`、`chem`、`devops` 或 `general`。
- `category` 是用于 Hub 筛选和浏览的主分类 token。
- `keywords` 是用于增强搜索的软件关键词。
- `category`、`categories` 和 `keywords` 接受由字母、数字、`.`、`_`、`-`
  和 `+` 组成的简单搜索 token，因此 `blast+` 这类别名是合法的。
- `summary` 是面向用户的简短说明，可用于 Hub 页面和仓库元数据。
- `categories` 和 `description` 是兼容的 Hub 侧别名。index 会把 `category`
  归一化到 `categories`，把 `summary` 归一化到 `description`，并在输出时保留两种形式。
- 新 app release 应优先在 `taffish.toml` 中原生提供 `[meta]`。
- 已经发布且不可变的旧 release 可以通过 `metadata-overrides.toml` 补充。

Upstream：

- 已识别字段包括 `name`、`type`、`url`、`homepage`、`repository`、
  `release_url`、`docker_image`、`version`、`license`、`citation`、`doi` 和 `pmid`。
- `repository` 是正式的上游仓库字段。`repo` 也会作为兼容别名被接受，并在
  JSON 输出中归一化为 `repository`。
- 空字段和未知字段会被忽略。
- 缺失 upstream 元数据时，JSON 中会省略 `upstream`，不会写成 `null`、
  `none` 或 `"not provided"`。
- `metadata-overrides.toml` 可以为已经存在 upstream 的 record 补充 `license`、
  `citation`、`doi` 和 `pmid`，但不会凭空创建新的 upstream object。

Smoke：

- 容器化项目必须定义 `[smoke]`。
- `backend` 如果存在，必须是 `docker`、`podman` 或 `apptainer`；缺省为 `docker`。
- `timeout` 如果存在，必须是正整数；缺省为 `60`。
- `exist` 和 `test` 如果存在，必须是由非空字符串组成的数组。
- `exist` 和 `test` 不能同时为空。
- 默认 `TODO` 占位会被拒绝。
- smoke 命令由 index 自动化运行，不由本地 `taf check` 运行。
- `test` 条目是 TOML 字符串，并会在 smoke 容器中通过 `sh -c` 执行。index
  支持 `\"` 这类 TOML 转义；但如果命令本身需要嵌套引号，建议在 shell
  片段内部使用单引号，例如 `test = ["python -c 'import vina, rdkit'"]`，可读性更好，也更不容易写错。

## GitHub 自动化

`.github/workflows/build-index.yml` 会在以下场景运行：

- 手动触发。
- 每日定时运行。

定时任务使用：

```text
17 1 * * *  # UTC
```

workflow 会：

1. checkout 本仓库。
2. 安装 SBCL。
3. 运行 Common Lisp index builder。
4. 在 `index/` 下写入生成文件。
5. 如果生成索引发生变化，则 commit 并 push。

核心构建命令是：

```sh
sbcl --script scripts/build-index.lisp -- --org "taffish" --output index
```

## 本地测试

从本仓库根目录运行：

```sh
sbcl --script scripts/build-index.lisp -- --no-org --local-repo ../../../taffish/test/my-test-tool --output index
```

也可以扫描多个本地仓库：

```sh
sbcl --script scripts/build-index.lisp -- \
  --no-org \
  --local-repo ../../../taffish/test/my-test-tool \
  --local-repo ../../../taffish/test/my-test-flow \
  --output index
```

如果要本地扫描 GitHub 组织：

```sh
TAFFISH_BOT_TOKEN=<TOKEN> sbcl --script scripts/build-index.lisp -- --org taffish --output index
```

对于公开仓库，未认证请求有时也可以工作，但使用 token 更稳定，因为 GitHub API
存在 rate limit。

## 配置

CLI 选项：

```text
--org <ORG>                  扫描 GitHub 组织
--no-org                     禁用 GitHub 组织扫描
--local-repo <PATH>          添加一个本地 TAFFISH app 仓库
--output <DIR>               输出目录，默认 index
--metadata-overrides <PATH>  可选 metadata override TOML，默认 metadata-overrides.toml
--meta-overrides <PATH>      --metadata-overrides 的兼容别名
--include-default-branch     同时索引默认分支 snapshot
--include-archived           包含 archived GitHub 仓库
--include-forks              包含 fork 仓库
--force-recheck              即使存在缓存 trust 元数据，也重新执行 digest/smoke gate
-h, --help                   显示命令帮助
```

环境变量：

| 变量 | 作用 |
| --- | --- |
| `TAFFISH_ORG` | 未提供 `--org` 时使用的默认组织。默认是 `taffish`。 |
| `TAFFISH_BOT_TOKEN` | builder 使用的 GitHub API token。 |
| `TAFFISH_INDEX_INCLUDE_DEFAULT_BRANCH` | 设为 `1`、`true` 或 `yes` 时启用默认分支 snapshot。 |
| `TAFFISH_INDEX_FORCE_RECHECK` | 设为 `1`、`true` 或 `yes` 时重新执行 digest/smoke gate。 |
| `TAFFISH_INDEX_METADATA_OVERRIDES` | 可选 metadata override TOML 路径。默认是 `metadata-overrides.toml`。 |
| `TAFFISH_INDEX_META_OVERRIDES` | 旧 override 路径环境变量的兼容回退。 |

GitHub Actions workflow 会优先使用 repository secret 中的 `TAFFISH_BOT_TOKEN`，
如果没有配置，则回退到 `GITHUB_TOKEN`。

## Metadata Overrides

`metadata-overrides.toml` 用于给已经发布且不可变的 app release 补充展示/搜索
元数据，以及已经声明的 upstream 仓库的归属/引用信息，避免只为了
description/category/keyword/license/citation/DOI/PMID 这类信息创建新的 `-rN`
release。

每个 override section 必须包含 `repository` 和 `version_id`，然后可以包含任意
支持的 meta 字段。如果要补充已有 upstream 仓库的归属/引用字段，可以使用相邻的
`[<section>.upstream]` 表，写入 `license`、`citation`、`doi`，以及可选的
`pmid`：

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

Override 会在从 GitHub 读取 app 元数据之后合并。如果未来某个新 release 已经在
`taffish.toml` 中原生携带 `[meta]` 或 `[upstream]`，对应的精确版本 override
可以删除，也可以保留用于有意调整发布后的展示元数据。Upstream override 会被刻意限制为
归属/引用字段（`license`、`citation`、`doi` 和 `pmid`），并且只合并到已经存在
upstream 的 record 上；它补充的是已有 upstream 仓库的信息，而不是创建新的
upstream object。

## 相关仓库

- [taffish/taffish](https://github.com/taffish/taffish)：CLI/编译器开源源码仓库、安装器、release 载荷和源码树开发文档。
- [taffish/taffish-docs](https://github.com/taffish/taffish-docs)：面向用户、app 作者、Hub/index 维护者、MCP 和安全模型的公共文档仓库。
- [taffish/taffish.github.io](https://github.com/taffish/taffish.github.io)：网页版 Hub。

## 许可证

index builder 源码和仓库自动化使用 [Apache License 2.0](LICENSE) 授权。

`index/` 目录下生成的机器可读索引数据使用 [CC0 1.0 Universal](LICENSE-DATA)
进行公共领域贡献，方便镜像、缓存和第三方包索引消费。

## 当前状态

`taffish-index` 是当前 GitHub-based TAFFISH Hub 设计的一部分。它是静态索引仓库，
不是通用包发布服务，也不是自定义后端服务器。

官方 Hub 当前由 `taffish` 组织维护，暂时不是开放自助发布平台。
