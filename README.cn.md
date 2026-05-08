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
- [可选元数据](#可选元数据)
- [GitHub 自动化](#github-自动化)
- [本地测试](#本地测试)
- [配置](#配置)
- [相关仓库](#相关仓库)
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

这个仓库不负责构建容器镜像。镜像构建属于每个 app 仓库自己的职责。

## 生成文件

index builder 会写入：

```text
index/index.json
index/packages/<package>.json
index/commands/<command>.json
```

`index/index.json` 是完整索引。拆分后的 package 和 command 文件用于更小粒度
的读取场景。

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
| `counts` | packages、versions、commands、repositories 和 warnings 的统计。 |
| `packages` | 以 package name 为 key 的 package 记录。 |
| `commands` | 以基础 command name 为 key 的 command 查询记录。 |
| `repositories` | 以 `owner/repo` 为 key 的 repository 查询记录。 |
| `warnings` | 非致命扫描或校验 warning。 |

每个 package 记录中包含一个 `versions` object，以 version id 为 key，例如
`0.1.0-r1`。

每个 version record 包含 package 元数据、runtime 标记、dependency 元数据、
platform 约束、source ref 信息、可选 container 元数据和可选 upstream 元数据。

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

## 可选元数据

`taffish.toml` 可以包含依赖、平台约束和 upstream 来源元数据。

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

依赖：

- key 必须是基础 taf command name，例如 `taf-fastqc`。
- value 可以是一个 version id 字符串，也可以是 version id 字符串数组。
- 数组表示列出的每个版本都需要安装，不表示多个备选版本。

平台：

- `os` 和 `arch` 是逗号分隔的 token 列表。
- `container` 默认是 `optional`。
- `min_cpus` 和 `min_memory_mb` 如果存在，必须是正整数。

Upstream：

- 已识别字段包括 `name`、`type`、`homepage`、`repository`、`release_url`、
  `docker_image`、`version`、`license`、`citation`、`doi` 和 `pmid`。
- 空字段和未知字段会被忽略。
- 缺失 upstream 元数据时，JSON 中会省略 `upstream`，不会写成 `null`、
  `none` 或 `"not provided"`。

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
--include-default-branch     同时索引默认分支 snapshot
--include-archived           包含 archived GitHub 仓库
--include-forks              包含 fork 仓库
-h, --help                   显示命令帮助
```

环境变量：

| 变量 | 作用 |
| --- | --- |
| `TAFFISH_ORG` | 未提供 `--org` 时使用的默认组织。默认是 `taffish`。 |
| `TAFFISH_BOT_TOKEN` | builder 使用的 GitHub API token。 |
| `TAFFISH_INDEX_INCLUDE_DEFAULT_BRANCH` | 设为 `1`、`true` 或 `yes` 时启用默认分支 snapshot。 |

GitHub Actions workflow 会优先使用 repository secret 中的 `TAFFISH_BOT_TOKEN`，
如果没有配置，则回退到 `GITHUB_TOKEN`。

## 相关仓库

- [taffish/taffish](https://github.com/taffish/taffish)：CLI 和编译器二进制发布仓库。
- [taffish/taffish-docs](https://github.com/taffish/taffish-docs)：开发者文档仓库。
- [taffish/taffish.github.io](https://github.com/taffish/taffish.github.io)：网页版 Hub。

## 当前状态

`taffish-index` 是当前 GitHub-based TAFFISH Hub 设计的一部分。它是静态索引仓库，
不是通用包发布服务，也不是自定义后端服务器。

官方 Hub 当前由 `taffish` 组织维护，暂时不是开放自助发布平台。
