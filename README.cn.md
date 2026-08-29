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
index/gate-state.json
index/reports/latest.json
index/reports/<timestamp>.json
```

`index/index.json` 是完整索引。拆分后的 package 和 command 文件用于更小粒度
的读取场景。

`index/gate-state.json` 是 builder 内部状态。它为新增版本和失败版本保留精确的
逐 backend gate 结果与重试 marker，使后续运行可以复用 identity 匹配的已通过工作。
其中加法增加的 `observations` 账本还会为每个已进入计划的容器 release 冻结首次成功
aggregate 的 source ref、source commit、image 名称和已观测 digest；即使该 release
在 inspect 或 required smoke 阶段失败也一样。包管理器客户端不会消费这个文件。

report 文件会记录扫描 warning、required 可信 gate 失败，以及位于
`advisory_failed` 下的 advisory backend 失败。失败的新版本不会进入主 index；
维护者需要查看 report，修复 app 仓库后，该版本才能变成可安装版本。

staged report 会保留已有的 `failed`、`rejected` 和 `warnings` 字段，并加法写入
`policy`、`counts.advisory_failed` 与 `advisory_failed` 数组。

已确认有问题的不可变 release 可以写入 `rejected-releases.toml`。rejected
版本会在 digest 或 smoke gate 运行前被跳过，不进入主 index，并且会和临时
trust-gate 失败分开报告。

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
| `counts` | packages、versions、commands、repositories、warnings、required failures、advisory failures 和已知 rejected releases 的统计。 |
| `packages` | 以 package name 为 key 的 package 记录。 |
| `commands` | 以基础 command name 为 key 的 command 查询记录。 |
| `repositories` | 以 `owner/repo` 为 key 的 repository 查询记录。 |
| `warnings` | 非致命扫描或校验 warning。 |

每个 package 记录中包含一个 `versions` object，以 version id 为 key，例如
`0.1.0-r1`。`latest` 字段继续表示按 version/release 语义得到的默认安装版本。
可选的 `recent_at` 和 `recent_version` 字段表示最近成功发布并进入主 index 的
release，用于网页展示和排序。

每个 version record 包含 package 元数据、runtime 标记、dependency 元数据、
platform 约束、可选的人类可读 meta 字段、source ref 信息、可选发布时间
元数据、可选 container 元数据、可选 smoke 元数据、trust 状态和可选 upstream
元数据。

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

兼容 builder 优先索引 release tag，也可以为开发场景显式包含默认分支 snapshot。
staged 生产 pipeline 只索引不可变 release tag；分支 snapshot 不会进入它的持久化
多 backend observation ledger。

## 可信 Gate

对于每个 `repository + version_id`，staged builder 会同时检查已有的
`index/index.json` 和内部的 `index/gate-state.json`：

- 如果该版本已经存在，并且 release tag 仍指向同一个 commit，默认复用已接受记录。
  因此日常运行只关注新增版本和此前失败的版本，不会自动回填全部历史。
- tags API 解析出 release commit 后，manifest 和全部必需文件检查都会通过该 SHA
  寻址，因此扫描过程中即使 tag 移动，也不会把一个 commit identity 与另一个
  commit 的 metadata 混合。缺失或畸形的 release commit SHA 只会产生 warning，
  不会生成 record，也绝不会退回可移动 tag 读取。
- 复用旧记录时会保留已缓存的 container、smoke 和 trust 证据，同时刷新依赖、
  platform 约束、meta、upstream 等可安全更新的解析元数据。
- `--backfill` 会把未变化的历史记录纳入 matrix 计划，但仍复用 identity 匹配的
  已通过 backend 结果；它是补齐缺失 backend 覆盖的受控方式。旧 trust-v1 证据
  不具备完整 v2 identity，因此显式回填旧记录时会真实重跑全部已配置 backend，
  不会把旧 pass 改名冒充新证据。
- `--backfill --backfill-limit N` 只把本轮新选中的 legacy release 限制在 `1-50`
  个；新增 release、持久 retry 和已纳管证据刷新会独立加入任务，不占这个额度。
  选择过程完全确定，并按每个 package 的最新 release 优先、随后依次处理旧版本；
  成功持久化的 v2 证据会让下一批自动向后推进。
- `--force-recheck` 也会纳入未变化记录，但会禁用 gate-result cache 复用，重新运行
  digest 和 smoke；它刻意不是默认行为。
- `--retry-failed` 是手动 retry-only 模式，只计划具有当前精确 `failed` /
  `not_checked` backend 证据或持久 retry marker 的 release，同时排除无关的新 release、
  legacy backfill 和纯 policy refresh。最新的精确 gate-state 结果优先于公开 index 的
  旧证据；已经通过的 backend 仍会分别复用。
- 即使使用 `--force-recheck`，release tag 的 commit 发生变化仍会被拒绝；force
  只禁用复用，不会削弱不可变 release 校验。最后一次接受的 commit 会继续保留在
  稳定 index 中，因此移动过的 tag 在后续运行中仍会失败，不会被重新识别成新 release。
- 如果此前已进入 index 的版本在本轮扫描中缺失，builder 会保留旧记录并报告
  warning，直到该版本被显式加入 `rejected-releases.toml`。
- 已接受且 source 未变化的版本进入 backfill 或重试时，会保留最后一次 accepted
  记录作为稳定 fallback，直到替代证据通过全部 required gate。Inspect 或 required
  smoke 失败仍会进入报告；`gate-state.json.retry_tasks` 会把失败带入后续普通日更，
  避免下一份报告遗忘它。required gate 通过后清除 marker；显式 reject 该不可变
  release 时也会移除 marker。
- release 不需要先进入公开 index 才开始受不可变约束。只要一次 aggregate 成功完成，
  `gate-state.json.observations` 就会保留每个已计划容器任务首次看到的 identity。首次
  inspect 尚未获得 digest 时，后续可以补齐空值；但已经存在的 source ref、source
  commit、image 名称或 digest 都不能被替换。损坏、重复或互相冲突的 observation
  状态会 fail closed。显式写入 `rejected-releases.toml` 是受支持的清理路径，即使该
  release 没有出现在当天扫描结果中也会清理。

对于容器化 app，staged gate 会：

1. 校验元数据并创建确定性 plan；
2. 使用 Docker buildx 检查镜像 digest 和平台 manifest，并拒绝同一 release 下
   digest 已变化的镜像 tag；
3. 使用 Docker、Podman 和 Apptainer 运行同一套 version-level smoke contract；
4. 严格校验 plan、manifest 和各 backend result artifact；
5. 所有 required backend 通过后接受该版本，同时单独报告 advisory failure。

初始 `multibackend-1` policy 采用渐进策略：`[smoke].backend` 声明的 backend
是 required；对当前 app 集合而言，它是 Docker。其余已配置 backend（当前为
Podman 和 Apptainer）是 advisory。它们的失败会进入 `advisory_failed` 和逐 backend
证据，但不会移除其他条件已经通过的版本。改变 required/advisory 契约时必须显式
推进 policy generation。

Docker/Podman smoke 使用 `--network none`，不会挂载仓库，也不会接收 GitHub token
或 secrets。其镜像 pull 对非超时失败提供一次有界重试；命令诊断在限制长度的同时
保留开头和最终错误。Apptainer 使用干净的 contained 环境和 digest-pinned、只读的
临时 SIF。每条 Apptainer smoke 命令都获得唯一的磁盘 workdir，作为 contained HOME、
`/tmp` 和 `/var/tmp`，并在成功或失败后删除；这不会让镜像可写，也不会增加仓库 bind。
Apptainer 只在 runner 原生平台与计划平台一致时接受结果，不会把跨架构执行静默标记为
已验证。当前 Action policy 在 `linux/amd64` 上运行 smoke；镜像 manifest 同时发布
`linux/arm64`，不等于已经在 arm64 上原生通过 backend smoke。

只有完整 cache identity 一致时，已通过 backend 结果才会被复用：task id
（`repository + version_id`）、source commit、image digest、smoke SHA-256、backend、
platform 和 policy generation。runtime/runner 版本只作为证据记录，不会自动使 cache
失效。失败新版本的部分成功结果会保留在 `gate-state.json`，inspect/required 失败
也会写入内部 `retry_tasks` 数组。所以下一轮既会继续重试已标记 release，又只重跑
identity 缺失或不再匹配的 backend 工作。对于同一 identity，gate-state 中精确匹配的
`failed` 或 `not_checked` 比公开 index 的旧 pass 更新，会否决该 fallback，直到对应
backend 再次真实运行并通过。

observation 账本只由唯一 writer `aggregate` 事务写入。如果 Action、artifact 或
required-backend 基础设施故障使 workflow 在 aggregate 成功完成前中止，本次运行就
无法提交新的 observation；失败的远端 workflow 仍是运维证据，而下一次成功完成的
aggregate 才会建立持久 baseline。这个边界避免部分写入，但无法为从未到达 writer
的运行凭空制造持久状态。

主 index 保留通过检查或此前已经接受的稳定版本。它不是对当前 GitHub 扫描结果的
破坏性镜像，而是一个偏追加的稳定账本：扫描缺失、GitHub raw/API 瞬时失败或仓库
临时不可见时，旧记录会先保留并在 report 中提醒维护者人工审核。Gate 失败会写入
`index/reports/latest.json` 和带时间戳的 report 文件。写入
`rejected-releases.toml` 的已知坏 release 会被跳过，并在 `rejected` 中报告，
不会每次重新运行 smoke。`taf update` 和 `taf install` 只消费稳定主 index，
维护者通过 reports 修复失败的 app release。

此前已经接受的版本可能暂时没有完整的多 backend 证据，直到执行受控的
`--backfill` 或 `--force-recheck`。默认不回填历史，从而保持安装稳定，并控制日常运行时间。
分阶段迁移推荐使用带 limit 的形式；裸 `--backfill` 继续保留无限量兼容语义。

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

截至 `backend_used` 的旧字段会继续保留以兼容既有消费者。staged pipeline 加法
写入 policy、platform、required/advisory 列表，以及按 backend key 确定排序的
`backend_results`。没有 staged 证据的旧记录会维持原形，直到被新 pipeline 处理。

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
- `keywords` 是经过首尾空白清理和小写归一化、用于增强发现能力的搜索词。
- `category` 和 `categories` 接受由字母、数字、`.`、`_`、`-`、`+` 和 `&`
  组成的简单筛选 token。
- 与 category 标识符不同，`keywords` 接受可打印的 Unicode 文本和标点，因此
  `Moran's I`、`Moran’s I`、`5′ UTR`、`Cα`、`ka/ks`、`cut&run`、
  `multiple sequence alignment` 这类科学名称、别名或短语都是合法搜索词；Tab、
  换行和其他控制字符仍会被拒绝。
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

定时任务始终使用日常模式。手动触发提供两个互斥控制：`backfill_limit` 接受 `1-50`
以分批回填 legacy 证据；`retry_failed` 只选择当前精确 failed/not-checked 证据。两者
都保持默认值时仍是日常模式。

workflow 被配置为由 `scripts/index-phase.lisp` 驱动的四阶段 pipeline：

1. `plan` 扫描仓库，应用 override、rejection 和历史保留规则，并上传不可变 plan artifact。
2. `inspect` 验证 plan，检查镜像 digest/platform manifest，并上传 manifest artifact。
3. `smoke` 以三个 matrix job 分别运行 Docker、Podman 和 Apptainer。每个 backend
   使用独立的标准 `ubuntu-24.04` runner，并上传一个 result artifact。
4. `aggregate` 下载全部 artifact，严格检查 identity 和覆盖度，以事务方式替换
   `index/`，而且它是唯一允许 commit/push 的 job。

配置的有界并发如下：

| 阶段 | 默认值 | 允许上限 |
| --- | ---: | ---: |
| 仓库扫描 | 8 | 8 |
| digest 检查 | 4 | 4 |
| Docker version workers | 2 | 4 |
| Podman version workers | 2 | 4 |
| Apptainer version workers | 1 | 2 |

仓库 worker 仍会串行 GitHub REST 请求，避免放大 API 压力；raw-file 工作可以并行。
digest 和 smoke pool 即使以不同顺序完成，也会按 task 顺序返回结果。Docker、Podman
和 Apptainer 位于独立 runner，因此各自的本地镜像存储、临时文件和资源限制彼此隔离。

每份 plan、manifest 和 result 文档都有从内容派生的 ID。aggregate 会在写入前拒绝
schema、source head、policy、platform、task 覆盖、重复/缺失 backend、result identity
或 observation/digest 不匹配。observation 属于完整性关键账本，因此必须 fail closed；
损坏的 backend-result cache 则可以保守丢弃并重跑。aggregate 先生成 staging 目录并
检查必需文件，再通过带 backup/restore 路径的目录 promotion 完成替换。前序 job 只有
`contents: read`；只有 `aggregate` 拥有 `contents: write`，而且如果 workflow 启动后
`origin/main` 已移动，它会拒绝 push。

以上描述的是仓库中已写入的 workflow 配置和本地验证契约，不代表更新后的 workflow
已经在远端 GitHub Actions 中完整运行成功。

原有 `scripts/build-index.lisp` 入口及其 CLI 继续供本地调用者兼容使用。GitHub Actions
使用 staged `scripts/index-phase.lisp` 路径；旧命令不是多 runner Action pipeline。

## 本地测试

从本仓库根目录运行：

```sh
bash tests/action-plan.sh
sbcl --script tests/project.lisp
sbcl --script tests/concurrency.lisp
sbcl --script tests/pipeline.lisp
```

如需从本地 fixture 仓库构建 index：

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
TAFFISH_BOT_TOKEN=<TOKEN> sbcl --script scripts/build-index.lisp -- --org taffish --jobs 8 --output index
```

对于公开仓库，未认证请求有时也可以工作，但使用 token 更稳定，因为 GitHub API
存在 rate limit。

默认使用 8 个仓库 worker。需要严格串行扫描时可使用 `--jobs 1`；也可以传入
1 到 8 之间的其他整数来降低本地并发度。

在 staged `index-phase.lisp plan` 路径中，每个显式 `--local-repo` 都必须是独立且
干净的 Git worktree 根目录，并且已有提交过的 `HEAD`；非 Git、借用父 monorepo、
tracked/staged 修改或 untracked 文件都会使 plan 失败。staged record 使用
commit tree 直接读取 `taffish.toml` 并检查所有必需路径是否存在，然后使用
`source.ref = "local"` 和真实 `HEAD` commit；因此只存在于 worktree 的 ignored 文件
也不能绕过不可变 identity。兼容入口 `build-index.lisp` 继续保留原有的本地 fixture
行为。

安装 Docker、Podman 和 Apptainer 后，可以在本地按四阶段复现 staged CLI。
Action 会把三条 smoke 命令放到独立 runner；下面的本地示例按顺序列出：

```sh
mkdir -p work/results

# 1. Plan：日常模式只检查新增版本和此前失败的版本。
sbcl --script scripts/index-phase.lisp plan \
  --org taffish \
  --index-dir index \
  --output work/plan.json \
  --jobs 8 \
  --backends docker,podman,apptainer \
  --policy-generation multibackend-1 \
  --platform linux/amd64

# 2. Inspect：解析不可变镜像 identity。
sbcl --script scripts/index-phase.lisp inspect \
  --plan work/plan.json \
  --output work/manifest.json \
  --jobs 4

# 3. Smoke：生产 Action 中三个 backend 各用独立 runner。
sbcl --script scripts/index-phase.lisp smoke \
  --manifest work/manifest.json --backend docker \
  --output work/results/docker.json --jobs 2
sbcl --script scripts/index-phase.lisp smoke \
  --manifest work/manifest.json --backend podman \
  --output work/results/podman.json --jobs 2
sbcl --script scripts/index-phase.lisp smoke \
  --manifest work/manifest.json --backend apptainer \
  --output work/results/apptainer.json --jobs 1

# 4. Aggregate：验证全部 artifact，并且只执行一次事务聚合。
sbcl --script scripts/index-phase.lisp aggregate \
  --plan work/plan.json \
  --manifest work/manifest.json \
  --result work/results/docker.json \
  --result work/results/podman.json \
  --result work/results/apptainer.json \
  --index-dir index
```

## 配置

staged command 提供按 phase 划分的帮助：

```sh
sbcl --script scripts/index-phase.lisp --help
```

重要 staged 选项如下：

```text
plan      --jobs <1-8> --backends <CSV> --policy-generation <ID>
          --platform <OS/ARCH>
          [--backfill [--backfill-limit <1-50>] | --force-recheck |
           --retry-failed]
inspect   --plan <PATH> --output <PATH> --jobs <1-4>
smoke     --manifest <PATH> --backend <NAME> --output <PATH> --jobs <N>
aggregate --plan <PATH> --manifest <PATH> --result <PATH>... --index-dir <DIR>
```

`--backfill` 会纳入未变化的历史记录，同时复用精确匹配的已通过 cache；增加
`--backfill-limit N` 后，每轮最多新选 N 个 legacy release task，但新增版本、retry
和 policy refresh 不受此上限影响。limit 必须与 `--backfill` 同用，也不能与
`--force-recheck` 组合；裸 `--backfill` 保留无限量兼容行为。`--force-recheck`
会纳入历史记录，但忽略匹配的 gate cache。两者都不会削弱 changed-source-commit
rejection，日常 Action 也不会使用这两个模式。

`--retry-failed` 与两种 backfill 形式、`--force-recheck` 均互斥。它只选择与当前 source
commit、image digest、smoke signature、platform 和 policy generation 精确匹配的
问题证据。rejection 和 immutable-source drift 检查始终先执行，不能被该模式绕过。

兼容入口 `scripts/build-index.lisp` 的 CLI 继续保持：

```text
--org <ORG>                  扫描 GitHub 组织
--no-org                     禁用 GitHub 组织扫描
--local-repo <PATH>          添加一个本地 TAFFISH app 仓库
--output <DIR>               输出目录，默认 index
--jobs <N>                   并发仓库 worker 数，1-8，默认 8
--metadata-overrides <PATH>  可选 metadata override TOML，默认 metadata-overrides.toml
--meta-overrides <PATH>      --metadata-overrides 的兼容别名
--rejected-releases <PATH>   可选 rejected release TOML，默认 rejected-releases.toml
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
| `TAFFISH_INDEX_JOBS` | 未提供 `--jobs` 时使用的并发仓库 worker 数。必须是 1 到 8，默认 8。 |
| `TAFFISH_INDEX_INCLUDE_DEFAULT_BRANCH` | 设为 `1`、`true` 或 `yes` 时启用默认分支 snapshot。 |
| `TAFFISH_INDEX_FORCE_RECHECK` | 设为 `1`、`true` 或 `yes` 时重新执行 digest/smoke gate。 |
| `TAFFISH_INDEX_APPTAINER_WORK_ROOT` | 可选绝对磁盘目录；每条 contained Apptainer smoke 会在其下创建并删除唯一 workdir。默认使用系统临时目录。 |
| `TAFFISH_INDEX_POLICY_GENERATION` | staged cache policy generation 默认值。默认是 `multibackend-1`。 |
| `TAFFISH_INDEX_PLATFORM` | 显式 staged smoke platform。默认是 `linux/amd64`。 |
| `TAFFISH_INDEX_METADATA_OVERRIDES` | 可选 metadata override TOML 路径。默认是 `metadata-overrides.toml`。 |
| `TAFFISH_INDEX_META_OVERRIDES` | 旧 override 路径环境变量的兼容回退。 |
| `TAFFISH_INDEX_REJECTED_RELEASES` | 可选 rejected release TOML 路径。存在时默认使用 `rejected-releases.toml`。 |

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

## Rejected Releases

`rejected-releases.toml` 用于记录不应再次检查、也不应进入主 index 的不可变 app
release。只有当某个版本已经确认有问题，并且已经由后续 release 替代时，才应该写入这里。
临时网络、registry 或 runner 故障应继续留在 `index/reports/latest.json` 中，不应该加入
rejected 列表。

示例：

```toml
[fastp-1.3.3-r1]
repository = "taffish/fastp"
version_id = "1.3.3-r1"
ref = "v1.3.3-r1"
replacement = "1.3.3-r2"
reason = "Immutable release has invalid smoke commands; fixed by v1.3.3-r2."
```

必需字段是 `repository`、`version_id` 和 `reason`。`ref` 可选但推荐填写，
因为它能让 rejected 目标更明确。`replacement` 可选，只用于维护者侧 report。

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
