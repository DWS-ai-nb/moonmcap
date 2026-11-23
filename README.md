# MoonMCAP

[![源码 CI](https://github.com/DWS-ai-nb/moonmcap/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/DWS-ai-nb/moonmcap/actions/workflows/ci.yml?query=branch%3Amain)

MoonBit 的 **MCAP 0 消息日志库**，用于读取和校验机器人、传感器与仿真日志，按主题和时间查询，并裁剪、合并或恢复可读数据。`DWS-ai-nb/moonmcap` 基于 MIT 许可的上游 0.17.5，本期新增大附件分段传输和无索引检索。交付范围与验证结果见 [本期贡献说明](docs/contest-proposal.md) 和 [十一月验收入口](docs/acceptance-november.md)。

从 [首次使用](docs/quickstart.md) 开始，选择入口前阅读 [支持范围](docs/scope.md)。完整索引见 [文档导航](docs/README.md)，异常处理见 [排错说明](docs/troubleshooting.md)。

## 从源码运行本期功能

准备 Git、**moonc 0.10.17+d971670cd**（项目固定编译基准）及 **Node.js 22.3+**。以下命令使用仓库自带的合成录制：

```sh
git clone --branch contrib/streamed-attachments https://github.com/DWS-ai-nb/moonmcap.git
cd moonmcap
moon update
moon build --target js cmd/mcap
node _build/js/debug/build/cmd/mcap/mcap.js scan-query examples/files/zstd-summary.mcap --topic /imu --start 20000000000 --end 30000000000
node _build/js/debug/build/cmd/mcap/mcap.js attachment-list examples/files/zstd-summary.mcap
node _build/js/debug/build/cmd/mcap/mcap.js attachment-extract examples/files/zstd-summary.mcap 6926 calibration.json
node _build/js/debug/build/cmd/mcap/mcap.js validate-range examples/files/zstd-summary.mcap
```

依次得到 **5 条消息**、附件 `calibration.json` 的描述、**15 字节**的提取文件，以及 **100 条消息**的完整范围校验报告。`6926` 是此示例中的附件记录偏移，处理其他文件时从 `attachment-list` 取得。输出路径须为新路径。更多可直接复现的命令见 [大附件操作示例](docs/quickstart.md#本期大附件操作)。

固定工具链使用 `async@0.20.2`。若使用 CI 验证的当前工具链与 `async@0.22.10` 组合，在 `moon update` 前先执行 `moon add --upgrade moonbitlang/async@0.22.10`。两个组合的实际版本和结果见 [源码 CI](https://github.com/DWS-ai-nb/moonmcap/actions/workflows/ci.yml)。

## 安装上游库

Mooncakes 的 `LilaLola67/moonmcap@0.17.5` 是上游发行包。本期附件接口随 [贡献仓库源码](https://github.com/DWS-ai-nb/moonmcap/tree/contrib/streamed-attachments) 交付，开发者可用 [MoonBit 工作区](docs/attachment-stream.md#在其他-moonbit-项目中引用本期源码) 将当前源码作为依赖。

在已有 MoonBit 项目中执行下面的安装命令；从空目录开始时，先创建 `moon.mod`：

```text
name = "example/use-mcap"
version = "0.0.1"
```

```sh
moon add LilaLola67/moonmcap@0.17.5
```

使用方的 `moon.pkg`：

```text
import { "LilaLola67/moonmcap" @mcap, }
pkgtype(kind:"executable")
```

将下面保存为 `main.mbt`，执行 `moon run .` 或 `moon run . --target js`：

```moonbit
///|
fn main {
  try {
    let recorder = @mcap.new_builder()
    let channel = recorder.register_channel("/events", "json")
    recorder.append(channel, 100UL, b"{\"value\":1}")
    let bytes = recorder.finish(compression=@mcap.Zstd)
    let messages = @mcap.query_file(bytes, {
      ..@mcap.all_query(), topics: ["/events"], start_time: 100UL, end_time: 100UL,
    }).messages
    assert_eq(messages.length(), 1)
    assert_eq(messages[0].data, b"{\"value\":1}")
    println("MCAP_SAMPLE_OK")
  } catch {
    @mcap.Invalid(reason) => abort(reason)
    error => abort("\{error}")
  }
}
```

预期输出 `MCAP_SAMPLE_OK`。库中的时间是 **UInt64 纳秒**，查询区间包含两端。
JSON 时间使用字符串保留精度；不根据设备字段名推断单位或时钟关系。

## 能力与边界

- **核心库（Wasm/JS）**：MCAP 0 标准记录、CRC、索引、无压缩/LZ4/Zstd、查询、变换与恢复。压缩字典、拼接帧和未声明的格式扩展不在支持范围，详见 [格式兼容表](docs/compatibility.md)。
- **宿主与大文件路径（JS/Node）**：按需读取、磁盘索引、流式输出、外部排序、持久任务、HTTP 范围读取和可选工作线程。它们分别有预算，不能把单个预算视作总进程内存上限。[大附件传输与验证](docs/attachment-stream.md)记录了分段提取、外部合并和无索引范围查询的用法。
- **消息与外部适配**：JSON/Protobuf/ROS1/plain XCDR1 解码及回写、时间与质量处理按各自文档约束使用。Python/PyArrow/Foxglove 工具为可选适配器，不属于核心运行依赖。

快速查询不等于完整校验；需要审核全文件时使用 `validate` 或 `--full`。普通查询/裁剪默认最多 **100000 条**，内存型文件处理默认编码输入预算 **64 MiB**。已有输出不覆盖；文件发布需要同目录硬链接支持。流式 stdout 失败时可能已有部分结果，需检查退出码。完整约定见 [使用边界](docs/scope.md)。

## 按目标查文档

| 目标 | 入口 |
| --- | --- |
| 查询、裁剪、合并和修复 | [CLI](docs/cli.md)、[可运行样例](examples/README.md)、[诊断](docs/source-diagnostics.md) |
| 大附件查询、切片、验证和导出 | [附件命令](docs/cli.md#大附件命令)、[附件-api](docs/api-contracts.md#附件流式-api)、[演示及实测](docs/attachment-stream.md) |
| 选择性 IO、大文件和恢复任务 | [RangeReader](docs/range-reader.md)、[索引](docs/disk-sidecar.md)、[流式片段](docs/stream-context.md)、[外部合并](docs/external-merge.md) |
| 解释或修改消息 | [解码](docs/payload-decoding.md)、[回写](docs/payload-rewrite.md)、[结构演进](docs/schema-evolution.md) |
| 时间、质量和实验处理 | [同步](docs/synchronization.md)、[TF](docs/tf.md)、[质量](docs/incident-workflows.md)、[回归](docs/regression.md) |
| 可选工具集成 | [列式导出](docs/columnar.md)、[设备桥接](docs/device-bridge.md)、[处理配方](docs/recipes.md) |

## 验证与数据来源

```sh
moon check
moon build
moon test --target wasm
moon test --target js
python tools/check_docs.py
python tools/quickstart_smoke.py
```

[测试方法](docs/testing.md) 区分单元测试、独立参考实现、真实进程中断、干净源码副本、发行包安装和公开数据验证。[本期 CI](https://github.com/DWS-ai-nb/moonmcap/actions/workflows/ci.yml) 保存各平台报告。`large-source` 与 `public-corpus` 需要手动选择，常规运行会跳过。历史规模实测见 [性能报告](docs/performance.md)，公开录制来源见 [公开语料](docs/corpus-validation.md)。设备 SDK 桥接尚未进行实体设备联调。

0.17.3 追加句柄复用与同步失败回归，见 [修复证据](examples/validation/descriptor-reuse-0.17.3.json)。

本次改进的范围和独立验证记录见 [0.17.2 质量记录](examples/validation/release-0.17.2.json)，完整验证命令及证据判读见 [验收入口](docs/verification.md)。历史记录见 [0.17.1 质量验证](examples/validation/release-0.17.1.json)。

历史验证记录保留在 [验证报告](examples/validation/release-0.16.10.json) 等文件中，版本变化见 [更新记录](CHANGELOG.md) 与 [迁移说明](docs/migration.md)。

上游包的独立安装验证命令是 `python tools/install_smoke.py --version 0.17.5`。本期源码以干净源码树和 [大附件同输入实测](docs/attachment-stream.md#同输入复核) 验证。

## 开源许可

项目主体采用 [MIT](LICENSE)。压缩与字节缓冲的适配组件保留上游 Apache-2.0 许可和来源，见 [第三方说明](third_party/README.md)；这些引用实现不计入原创核心源码统计。公开录制文件遵循其发布方的条款，项目 MIT 许可不对它们重新授权。
