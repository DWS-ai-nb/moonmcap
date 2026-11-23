# MoonMCAP 十一月赛验收入口

申报人 **顿文爽**，GitHub ID **DWS-ai-nb**。本期在 `LilaLola67/moonmcap` 的 0.17.5 基线上新增大附件分段传输和无索引检索。贡献范围、实现对照和作者记录均可查阅。 [申报仓库](https://github.com/DWS-ai-nb/moonmcap) · [贡献分支](https://github.com/DWS-ai-nb/moonmcap/tree/contrib/streamed-attachments) · [提交历史](https://github.com/DWS-ai-nb/moonmcap/commits/contrib/streamed-attachments) · [本期申报说明](contest-proposal.md)

## 从源码复现

按 [README](../README.md#从源码运行本期功能) 克隆和构建本期贡献分支。仓库自带合成录制，可以直接重放 [附件操作示例](quickstart.md#本期大附件操作)。从其他 MoonBit 项目引用时，使用 [源码工作区示例](attachment-stream.md#在其他-moonbit-项目中引用本期源码)，在 JS 和 Wasm 上运行。

| 评审可复核的结果 | 入口与证据 |
| --- | --- |
| 无索引录制中的选择性检索 | 在含 67,174,400 字节附件的录制中定位其后的消息，15 次范围请求共读 270 字节。该数值来自源回调逻辑读取。 [前后对照](evidence/attachment-stream.json) |
| 分段导出、外部合并与校验 | JS 和 Node 托管 Wasm 提取的文件与独立参考载荷 SHA-256 相同。Python MCAP 读回合并结果并核对消息、附件、元数据和索引。 [复现命令](attachment-stream.md#同输入复核) |
| 批量导出与失败边界 | 超出 1,000 个附件时在写入前拒绝，损坏 CRC 时拒绝发布当前文件。逐文件发布、断点恢复与适配器责任见 [CLI](cli.md#大附件命令) 和 [API](api-contracts.md#附件流式-api)。 |
| 构建、测试与跨平台 | 常规 CI 运行固定工具链与当前工具链的 JS/Wasm 检查，以及 Linux、Windows 和 macOS ARM64 源码验证。干净源码重放包含七条附件 CLI 和两个 API 示例。 [运行记录](https://github.com/DWS-ai-nb/moonmcap/actions/workflows/ci.yml) |
| 新增代码与许可 | 以固定上游 `e99a19f101092c982189d85d9536cf47eb5587c4` 为基线统计实际增量，测试单列。项目保留上游 MIT 许可与第三方归属。 [行数证据](evidence/contribution-size.json) · [MIT](../LICENSE) · [第三方说明](../third_party/README.md) |

`large-source` 和 `public-corpus` 是手动可选的历史规模及公开语料验证任务。常规 CI 的跳过状态按未运行记录。本期针对大附件的同输入复验使用独立生成的合成数据。

## 交付范围

本期交付是对已有开源库的实质新增贡献。容器基线、既有压缩与工具来自上游，模块名沿用 `LilaLola67/moonmcap` 以兼容调用者。Mooncakes 上的 0.17.5 是上游发行，本期源码及校验值见 [GitHub 发布记录](https://github.com/DWS-ai-nb/moonmcap/releases)。

2026 年 11 月 23 日复核的公开官网要求以 MoonBit 为主要语言、公开可追溯的实质贡献、可运行示例、必要测试和清楚的来源许可说明。此前提出的新增 5,000 行是项目工作量目标，公开页面未列该固定数值。具体验收时间及提交方式以本期正式通知为准。 [赛事官网](https://moonbitlang.github.io/Hackathon2026/)
