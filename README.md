# Cherry Studio CLI

一个面向 Windows 和 PowerShell 7 的 Cherry Studio 本地 API 命令行客户端。

它提供两条独立能力：

- 直接调用 Cherry Studio API Server，支持模型查询、友好模型别名、Chat Completions
  与 Anthropic Messages。
- 可选地接入 CLIProxyAPI，把 Cherry Studio 的模型暴露给需要 OpenAI Chat
  Completions、OpenAI Responses 或 Anthropic Messages 的其他客户端。

直接模式**不依赖 CLIProxyAPI**。CLIProxyAPI 仅在需要完整兼容代理时使用。

## 前提条件

- Windows 10/11。
- [PowerShell 7](https://learn.microsoft.com/powershell/)。
- 已安装 Cherry Studio，并在“设置 -> API Server”中启动本地 API Server。
- 通过安全的凭据管理机制向调用进程提供 `CHERRY_STUDIO_API_KEY`。

## 安装

```powershell
git clone https://github.com/CHENJIAMIAN/cherry-studio-cli.git
Set-Location .\cherry-studio-cli
pwsh -File .\install.ps1
```

安装器会在 `%USERPROFILE%\.local\bin` 创建 `cherry.cmd`。将该目录加入用户
`PATH` 后重新打开终端。

## 凭据

项目不会创建明文密钥文件。

- 已安装 Codex DPAPI 凭据库时，可运行 `cherry configure`。
- 其他环境请由操作系统、终端或 CI 的秘密管理机制提供
  `CHERRY_STUDIO_API_KEY`。

## 友好模型别名

Cherry Studio 可能返回含 UUID 的模型前缀。将前缀映射为短名称后，CLI 会在显示和
输入时使用短名称，并在发送请求前还原原始模型 ID。

```powershell
cherry alias 08117452-f5be-4da7-a4a7-78f55a79be9b opencode
cherry models
cherry ask "解释快速排序" -Model "opencode:deepseek-v4-flash-free"
```

`cherry alias` 可列出当前映射。一个友好前缀只能对应一个原始前缀，避免反向解析歧义。
`cherry models -Json` 同时保留原始 `id` 并增加 `alias` 字段，便于自动化程序排障。

## 便捷请求

```powershell
cherry status
cherry models
cherry default "opencode:deepseek-v4-flash-free"
cherry ask "讲一个笑话" -Model "opencode:deepseek-v4-flash-free"
cherry ask "说明这个工具调用" -Model "opencode:deepseek-v4-flash-free" -Format anthropic -Json
```

`ask` 是单轮文本便捷命令。它支持 `chat`、`anthropic` 和
`responses` 三种输出形式；当本地 Cherry Studio 没有 `/v1/responses` 时，
便捷 Responses 请求会回退为 Chat Completions 适配结果。

## 完整协议请求

需要多轮消息、内容块、工具、图片、思考参数、停止序列或其它协议专属字段时，使用
`request`，把完整 JSON 放在文件或标准输入中：

```powershell
cherry request -Format anthropic -BodyFile .\anthropic-request.json -Json
cherry request -Format chat -BodyFile .\chat-request.json -Stream
Get-Content .\request.json -Raw | cherry request -Format anthropic -BodyFile -
```

`request` 使用结构化 JSON 解析并保留未知字段；它只会：

- 将 `model` 中的友好别名还原为 Cherry Studio 原始模型 ID；
- 在给出 `-Stream` 时将 `stream` 设为 `true`；
- 按原始协议端点发送请求，并原样输出 SSE 或 JSON 响应。

直接 Cherry Studio API Server 当前可验证的端点是：

- `/v1/chat/completions`
- `/v1/messages`

若它返回 `/v1/responses` 的 404，说明该本地 API Server 本身不提供 Responses
端点，不是 CLI 丢弃了请求字段。请启用下方的 CLIProxyAPI 集成。

## 可选 CLIProxyAPI 集成

```powershell
$env:CHERRY_CLI_PROXY_RUN_DIRECTORY = 'C:\path\to\cliproxy-run'
cherry connect
cherry proxy-status
```

运行目录必须包含：

```text
config.yaml
bin\cliproxy-server.exe
```

代理成功启动后，CLIProxyAPI 提供：

```text
http://127.0.0.1:8317/v1/chat/completions
http://127.0.0.1:8317/v1/responses
http://127.0.0.1:8317/v1/messages
```

CLIProxyAPI 的客户端模型名采用斜杠分隔。例如上述别名会成为
`opencode/deepseek-v4-flash-free`。完整的构建、补丁和安全配置步骤见
[docs/CLIProxyAPI.md](docs/CLIProxyAPI.md)。

## 边界与安全

- `request` 可以完整转发 JSON，但上游服务是否支持某个字段或模型能力仍由 Cherry Studio
  或 CLIProxyAPI 决定。
- 直接 Anthropic 调用使用 Cherry Studio 所需的 Bearer 认证，不模拟原生 Anthropic 的
  `x-api-key` / `anthropic-version` 请求头。
- 不打包 CLIProxyAPI、第三方二进制、用户配置、模型配置或令牌。

## 许可证

本项目使用 [MIT License](LICENSE)。可选代理依赖及其补丁归属见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
