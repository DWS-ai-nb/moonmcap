# 核心入口合同与错误处理

当前源码的完整签名见 [生成接口](../pkg.generated.mbti)，已发行的上游签名见 [Mooncakes API](https://mooncakes.io/docs/LilaLola67/moonmcap)。
可复制的最小 API 示例由 [首次使用](quickstart.md) 链接，且在独立源码导出树中编译执行。
以下约定补充签名不能表达的前置条件、验证强度和资源责任。

| 任务与入口 | 前置条件与成功含义 | 失败和资源责任 | 对应验证 |
| --- | --- | --- | --- |
| `read_log` | 有限内存中的完整 Bytes；支持的 MCAP 0 及可用 CRC 全部通过才返回 Log | 非法格式或预算抛 McapError；不接管宿主文件 | [容器互操作](../tools/conformance.py) |
| `scan_source` / `diagnose_source` | 源为不可变快照；记录/解压/摘要预算显式限制；前者成功扫描，后者报告中 valid=true 才是完整校验 | 诊断遇首错停止，不是所有错误列表；已观察消息可能在最终 CRC 失败前交付；源资源由调用方管理 | [诊断故障](../tools/source_diagnostic_workflows.py) |
| `open_reader` / 查询游标 | 索引/摘要和实际访问块通过对应检查；时间闭区间、UInt64 纳秒 | 未访问块可能仍损坏；提前停止时取消游标，再关闭宿主；无索引回退受独立预算 | [快速与完整区别](../tools/reliability_workflows.py) |
| `new_write_sink` / `StreamWriter` | 回调完整接受字节或抛错；finish 完成容器编码 | 不保证自定义 sink 回滚或持久化；出错后丢弃本次输出，不继续写 | [流式读回](../tools/stream_workflows.py) |
| `nodeio.output_transaction` | 新目标、父目录已存在、同目录硬链接可用；publish 创建完整目标 | 提交前失败不发布；提交后清理错明确标记 output published；abort 不删除已发布目标 | [实际宿主故障](../tools/fs_fault_workflows.py) |
| `open_recording_session` | 独占拥有目录、选项与清单一致；只把清单承认的段视为 committed | append 已接受不等于已持久提交；恢复按 committed_messages 重发未提交消息 | [杀进程恢复](../tools/recording_session_workflows.py) |
| `run_artifact_batch` | plan、数量、已完成产物身份一致；回调按给定 sink 生成一项 | 检查点错、状态非法或产物改变即拒绝；重复恢复不重复生成完整项 | [批次恢复](../tools/clip_batch_workflows.py)、[风险单元测试](../risk_paths_test.mbt) |

## 附件流式 API

| 入口 | 使用约定 |
| --- | --- |
| `RangeReader::query_scan` | 选择性扫描顶层记录，跳过附件载荷与不匹配的平铺消息负载。匹配消息有结果预算，块解压遵守既有预算。 |
| `RangeReader::visit_attachments`、`RangeReader::attachment_catalog` | 回调返回 `false` 可停止遍历。目录可按名称、媒体类型、时间和载荷预算筛选，以物理偏移区分同名附件。需要确认摘要覆盖时设置 `verify_coverage=true`。 |
| `scan_source_streaming` | 提供 `attachment_ref` 以引用接收附件描述。函数仍校验完整数据区及可用 CRC，消费方应在扫描成功后发布结果。 |
| `AttachmentRef::info`、`read_range`、`copy_to`、`verify_payload` | 引用在源可读且稳定期间有效。`info` 只返回描述，切片检查范围与当前描述，复制和整段校验会比较可用的附件 CRC。 |
| `AttachmentRef::start_copy`、`resume_copy` | 分段提取通过检查点记录进度。恢复要求同一源和一致的输出前缀，会比对前缀字节并校验附件描述和 CRC 字段。调用方管理暂存输出。 |
| `StreamWriter::begin_attachment`、`add_attachment_from`、`copy_attachment` | 增量写入必须提供确切长度。`begin_attachment` 会话独占写入器，`write` 和 `finish` 成功才完成记录。取消与错误会终止后续写入，部分输出由调用方清理。 |
| `AttachmentExportJournal`、`resume_attachment_exports` | 每次发布前保存意图，发布后保存收据。恢复需要适配器核对源身份、目标内容和归属，无法确定待发布状态时拒绝继续。 |

同步与异步兼容检查点格式，分段传输的 64 KiB 窗口约束附件载荷。Node 提供文件发布事务，自定义 sink、快照及网络源由调用方管理。见 [源码依赖示例](attachment-stream.md#在其他-moonbit-项目中引用本期源码) 和 [异步、目录及恢复](attachment-stream.md#索引异步和恢复)。

## 错误类别与安全重试

公开同步错误类型仍为 `McapError::Invalid(String)`；错误文字用于解释上下文，
除明确文档化的 `output published` 状态外，不承诺每个内部消息都是稳定错误码。
CLI 退出码和报告模式见 [CLI](cli.md)；程序不能仅凭 stderr 是否为空判断成功。

| 错误类 / 典型线索 | 当前结果的解释 | 后续动作 |
| --- | --- | --- |
| 参数、数字、无作用选项 | 不开始相应 IO 或任务创建 | 修正参数后运行；不要绕过预算断言 |
| 格式、CRC、源身份/索引指纹 | 输入不能按请求的强度接受 | 保留原文件；完整诊断或选择有明确部分语义的恢复，不关闭校验强行接受 |
| 资源预算 | 请求超过该入口的明确限制 | 按实际资源提高对应预算或选有界入口；不能把缓存预算当进程 RSS 上限 |
| ENOSPC / 写入零进度 / fsync、close、link 错误 | 未提交写入不可当作成功产物 | 排除宿主问题，检查目标是否存在及错误状态，使用新目标重试 |
| `output published; ...` | 提交点已过；完整目标可能存在，清理仍失败 | 先校验现有目标和暂存残留；不自动覆写、回滚或重做整个任务 |
| EEXIST / 目标已存在 | 新文件独占发布未执行覆盖 | 核对现有文件，显式选择另一目标 |
| 恢复清单版本/plan/代码/运行时不符 | 原任务不能在当前条件下安全恢复 | 保留现场并建立新任务；不手改清单或删除活动锁 |
| 取消 / 进程中断 | 只有明确已提交进度可重用 | 释放宿主资源，按协议恢复；stdout 已发出的数据不能撤回 |

完整数据区恢复、连续前缀恢复和独立块恢复具有不同接受条件。
`cmd/mcap recover` 可提取截断文件的连续有效前缀；`cmd/diagnose recover` 要求可用的
索引容器元信息，以提取独立可信块。损坏头尾不应通过伪造摘要绕过该区别。

取消与进程终止的测试不构成断电安全证明。支持平台、格式子集和未联调实体设备的
限制始终以 [支持范围](scope.md) 和对应专题文档为准。

0.17.3 增加 close 后数字描述符立即复用的实际回归，以及录制/批次 fsync 失败的资源检查。关闭错误不触发对已消耗描述符的再次关闭；同步失败仍返回错误，不推进已提交段/产物。
