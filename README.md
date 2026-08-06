[English](./README.en.md)

# Cherry Studio CLI

<!-- codex-github-rules:bilingual-summary -->
> **中文简介**：Cherry Studio 本地 API 命令行工具，支持模型别名与 Chat、Anthropic、Responses 兼容工作流。
>
> **English summary**: A Cherry Studio local API command-line client with model aliases and Chat, Anthropic, and Responses-compatible workflows.

---

一个面向 Windows、macOS、Linux 和 WSL2 的 Cherry Studio 本地 API 命令行客户端。

它提供两条独立能力：

- 直接调用 Cherry Studio API Server，支持模型查询、友好模型别名、Chat Completions
  与 Anthropic Messages。
- 可选地接入 CLIProxyAPI，把 Cherry Studio 的模型暴露给需要 OpenAI Chat
  Completions、OpenAI Responses 或 Anthropic Messages 的其他客户端。

直接模式**不依赖 CLIProxyAPI**。CLIProxyAPI 仅在需要完整兼容代理时使用，当前其
运行目录约定面向 Windows。

## 一键安装

### Windows（PowerShell）

```powershell
iwr -useb https://raw.githubusercontent.com/CHENJIAMIAN/cherry-studio-cli/main/install.ps1 | iex
```

### macOS、Linux 和 WSL2

```bash
curl -fsSL https://raw.githubusercontent.com/CHENJIAMIAN/cherry-studio-cli/main/install.sh | bash
```

安装器会：

- 检测 PowerShell 7；Windows 会在可用时通过 `winget` 安装它，macOS/Linux/WSL2
  会下载用户目录下的官方便携版。
- 下载完整 CLI 运行时、创建 `cherry` 启动器，并将启动器目录加入用户 `PATH`。
- 仅安装本项目实际需要的 PowerShell 运行时，**不依赖 Node.js**。

Windows 安装后可立即运行 `cherry help`。macOS/Linux/WSL2 的管道命令在子 shell
中执行，请重新打开终端，或先直接运行安装器输出的 `~/.local/bin/cherry help`。

默认安装位置如下：

| 平台 | CLI 运行时 | 启动器 |
| --- | --- | --- |
| Windows | `%LOCALAPPDATA%\Programs\CherryStudioCLI` | `%USERPROFILE%\.local\bin\cherry.cmd` |
| macOS/Linux/WSL2 | `${XDG_DATA_HOME:-~/.local/share}/cherry-studio-cli` | `~/.local/bin/cherry` |

重复运行同一条命令即可更新 CLI。安装脚本默认从 `main` 下载；需要审计或固定版本时，
请克隆对应提交或标签后从本地运行安装器。

## 从源码安装

```powershell
git clone https://github.com/CHENJIAMIAN/cherry-studio-cli.git
Set-Location .\cherry-studio-cli
pwsh -File .\install.ps1
```

在 macOS、Linux 或 WSL2 中：

```bash
git clone https://github.com/CHENJIAMIAN/cherry-studio-cli.git
cd cherry-studio-cli
bash ./install.sh
```

本地安装器会复制运行时文件到用户安装目录，因此之后可以删除克隆目录。

## 前提条件

- 已安装 Cherry Studio，并在“设置 -> API Server”中启动本地 API Server。
- 通过安全的凭据管理机制向调用进程提供 `CHERRY_STUDIO_API_KEY`。
- 一键安装会处理 PowerShell 7；从源码手动运行 CLI 时需要 PowerShell 7。

## 凭据

项目不会创建明文密钥文件。

- 已安装 Codex DPAPI 凭据库时，可运行 `cherry configure`。
- 其他环境请由操作系统、终端、CI 或组织的秘密管理机制提供
  `CHERRY_STUDIO_API_KEY`。

安装 CLI 并不替代这一步：每位用户仍需在自己的 Cherry Studio 中启用 API Server，
并使用自己的 API key。

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
cherry ask "解释快速排序" -Model "opencode:deepseek-v4-flash-free" -Format responses -Json
```

`ask` 是单轮文本便捷命令。它支持 `chat`、`anthropic` 和
`responses` 三种输出形式；当本地 Cherry Studio 没有 `/v1/responses` 时，
便捷 Responses 请求会回退为 Chat Completions 适配结果。

这条回退路径只接受提示词、模型、系统提示词和最大 token 数，再把 Chat Completions
结果包装成 Responses 形状。它不提供完整 Responses 的多轮输入、工具调用、后台任务、
事件流或其它 Responses 专属语义。

## 完整协议请求

需要多轮消息、内容块、工具、图片、思考参数、停止序列或其它协议专属字段时，使用
`request`，把完整 JSON 放在文件或标准输入中。默认 Cherry Studio 直连模式适用于
完整 Chat Completions 和 Anthropic Messages 请求：

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
端点，不是 CLI 丢弃了请求字段。`cherry request -Format responses` 不会自动切换到
CPA；完整 Responses 请求请按下方的 CPA 调用方式发送。

## 可选 CLIProxyAPI 集成

当前 CLIProxyAPI 运行目录和 `cliproxy-server.exe` 的约定面向 Windows。直接模式不受
影响，仍可在 macOS、Linux 和 WSL2 使用。

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

## 选择 Responses 调用方式

| 需求 | 调用位置 | 模型名 | 认证 |
| --- | --- | --- | --- |
| 简单单轮文本 | `cherry ask ... -Format responses` | `opencode:...` | `CHERRY_STUDIO_API_KEY` |
| 完整 Responses API | `http://127.0.0.1:8317/v1/responses` | `opencode/...` | `CLIPROXY_API_KEY` |

完整 Responses 请求由 CPA 提供，调用它的是外部客户端或 HTTP 工具，而不是
`cherry request`：

```powershell
$headers = @{
    Authorization = 'Bearer <CLIPROXY_API_KEY>'
    'Content-Type' = 'application/json'
}
$body = @{
    model = 'opencode/deepseek-v4-flash-free'
    input = @(
        @{
            role = 'user'
            content = @(
                @{
                    type = 'input_text'
                    text = '解释快速排序。'
                }
            )
        }
    )
    max_output_tokens = 1024
} | ConvertTo-Json -Depth 20

Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8317/v1/responses' -Headers $headers -Body $body
```

`CHERRY_STUDIO_API_KEY` 是 CPA 访问 Cherry Studio 上游时使用的令牌；
`CLIPROXY_API_KEY` 是客户端访问 CPA 时使用的令牌。二者不能互换。客户端的
`CLIPROXY_API_KEY` 由 CPA 自己的 `api-keys` 配置决定，应通过秘密管理机制提供。

## 边界与安全

- `request` 可以完整转发 JSON，但上游服务是否支持某个字段或模型能力仍由 Cherry Studio
  或 CLIProxyAPI 决定。
- 直接 Anthropic 调用使用 Cherry Studio 所需的 Bearer 认证，不模拟原生 Anthropic 的
  `x-api-key` / `anthropic-version` 请求头。
- 不打包 CLIProxyAPI、第三方二进制、用户配置、模型配置或令牌。

## 许可证

本项目使用 [MIT License](LICENSE)。可选代理依赖及其补丁归属见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
