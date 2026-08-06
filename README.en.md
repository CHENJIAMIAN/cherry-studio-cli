# Cherry Studio CLI

[中文](README.md)

<!-- codex-github-rules:bilingual-summary -->
> **English summary**: A Cherry Studio local API command-line client with model aliases and Chat, Anthropic, and Responses-compatible workflows.
>
> **中文简介**：Cherry Studio 本地 API 命令行工具，支持模型别名与 Chat、Anthropic、Responses 兼容工作流。

---

A Cherry Studio local API command-line client for Windows, macOS, Linux, and WSL2.

It has two independent capabilities:

- Direct calls to the Cherry Studio API Server, including model discovery, friendly
  model aliases, Chat Completions, and Anthropic Messages.
- Optional CLIProxyAPI integration that exposes Cherry Studio models to clients
  requiring OpenAI Chat Completions, OpenAI Responses, or Anthropic Messages.

Direct mode **does not require CLIProxyAPI**. CLIProxyAPI is only needed for a full
compatibility proxy, and its current run-directory convention targets Windows.

## One-Line Install

### Windows (PowerShell)

```powershell
iwr -useb https://raw.githubusercontent.com/CHENJIAMIAN/cherry-studio-cli/main/install.ps1 | iex
```

### macOS, Linux, and WSL2

```bash
curl -fsSL https://raw.githubusercontent.com/CHENJIAMIAN/cherry-studio-cli/main/install.sh | bash
```

The installer:

- Detects PowerShell 7. On Windows it installs it through `winget` when available;
  on macOS/Linux/WSL2 it downloads an official portable copy under the user profile.
- Downloads the complete CLI runtime, creates the `cherry` launcher, and adds its
  directory to the user `PATH`.
- Installs only the PowerShell runtime used by this project. **Node.js is not a dependency.**

After Windows installation, `cherry help` is available immediately. The macOS/Linux/WSL2
pipeline runs in a child shell, so open a new terminal or first run the
`~/.local/bin/cherry help` path printed by the installer.

Default locations:

| Platform | CLI runtime | Launcher |
| --- | --- | --- |
| Windows | `%LOCALAPPDATA%\Programs\CherryStudioCLI` | `%USERPROFILE%\.local\bin\cherry.cmd` |
| macOS/Linux/WSL2 | `${XDG_DATA_HOME:-~/.local/share}/cherry-studio-cli` | `~/.local/bin/cherry` |

Re-run the same command to update the CLI. The installer downloads `main` by default;
for an audited or pinned installation, clone the desired commit or tag and run the local
installer instead.

## Install From Source

```powershell
git clone https://github.com/CHENJIAMIAN/cherry-studio-cli.git
Set-Location .\cherry-studio-cli
pwsh -File .\install.ps1
```

On macOS, Linux, or WSL2:

```bash
git clone https://github.com/CHENJIAMIAN/cherry-studio-cli.git
cd cherry-studio-cli
bash ./install.sh
```

The local installer copies runtime files into the user installation directory, so the
clone may be removed afterwards.

## Prerequisites

- Cherry Studio must be installed and its API Server enabled in **Settings -> API Server**.
- `CHERRY_STUDIO_API_KEY` must be made available to the calling process through a secure
  credential-management mechanism.
- The one-line installer manages PowerShell 7. PowerShell 7 is required when invoking
  the CLI manually from source.

## Credentials

The project never creates a plaintext secret file.

- On a machine with the Codex DPAPI vault, run `cherry configure`.
- In other environments, provide `CHERRY_STUDIO_API_KEY` through the operating system,
  terminal, CI, or your organization's secret manager.

Installing the CLI does not replace this setup: every user must enable their own Cherry
Studio API Server and use their own API key.

## Friendly Model Aliases

Cherry Studio may return model prefixes containing UUIDs. Map a prefix to a short name
and the CLI will display and accept the short name while restoring the original model ID
before sending requests.

```powershell
cherry alias 08117452-f5be-4da7-a4a7-78f55a79be9b opencode
cherry models
cherry ask "Explain quicksort." -Model "opencode:deepseek-v4-flash-free"
```

`cherry alias` lists current mappings. A friendly prefix can map to only one raw prefix,
which prevents ambiguous reverse resolution. `cherry models -Json` preserves the raw `id`
and adds an `alias` field for automation and diagnostics.

## Convenient Requests

```powershell
cherry status
cherry models
cherry default "opencode:deepseek-v4-flash-free"
cherry ask "Tell me a joke." -Model "opencode:deepseek-v4-flash-free"
cherry ask "Explain this tool call." -Model "opencode:deepseek-v4-flash-free" -Format anthropic -Json
cherry ask "Explain quicksort." -Model "opencode:deepseek-v4-flash-free" -Format responses -Json
```

`ask` is a convenience command for single-turn text requests. It supports `chat`,
`anthropic`, and `responses` output. When the local Cherry Studio server does not expose
`/v1/responses`, a convenient Responses request falls back to an adapted Chat Completions
result.

The fallback accepts only a prompt, model, system prompt, and maximum token count, then
wraps the Chat Completions result in Responses-shaped output. It does not provide full
Responses semantics such as multi-turn input, tool calls, background tasks, event streams,
or other Responses-only behavior.

## Complete Protocol Requests

For multi-turn messages, content blocks, tools, images, reasoning parameters, stop
sequences, or other protocol-specific fields, use `request` with complete JSON from a file
or standard input. Direct Cherry Studio mode supports complete Chat Completions and
Anthropic Messages requests:

```powershell
cherry request -Format anthropic -BodyFile .\anthropic-request.json -Json
cherry request -Format chat -BodyFile .\chat-request.json -Stream
Get-Content .\request.json -Raw | cherry request -Format anthropic -BodyFile -
```

`request` parses structured JSON and preserves unknown fields. It only:

- Restores friendly aliases in `model` to their Cherry Studio model IDs.
- Sets `stream` to `true` when `-Stream` is supplied.
- Sends the original protocol request and emits the raw SSE or JSON response.

The currently verified direct Cherry Studio API Server endpoints are:

- `/v1/chat/completions`
- `/v1/messages`

A 404 from `/v1/responses` means that the local API Server itself does not provide the
Responses endpoint; it does not mean that the CLI dropped request fields. `cherry request -Format responses`
does not automatically switch to CPA. Send complete Responses requests through CPA as described below.

## Optional CLIProxyAPI Integration

The current CLIProxyAPI run-directory convention and `cliproxy-server.exe` target Windows.
This does not affect direct mode, which remains available on macOS, Linux, and WSL2.

```powershell
$env:CHERRY_CLI_PROXY_RUN_DIRECTORY = 'C:\path\to\cliproxy-run'
cherry connect
cherry proxy-status
```

The run directory must contain:

```text
config.yaml
bin\cliproxy-server.exe
```

After the proxy starts, CLIProxyAPI provides:

```text
http://127.0.0.1:8317/v1/chat/completions
http://127.0.0.1:8317/v1/responses
http://127.0.0.1:8317/v1/messages
```

CLIProxyAPI client model names use slash separators. The preceding alias becomes
`opencode/deepseek-v4-flash-free`. See the complete build, patch, and security instructions
in [docs/CLIProxyAPI.en.md](docs/CLIProxyAPI.en.md).

## Choosing A Responses Call

| Need | Destination | Model name | Authentication |
| --- | --- | --- | --- |
| Simple single-turn text | `cherry ask ... -Format responses` | `opencode:...` | `CHERRY_STUDIO_API_KEY` |
| Complete Responses API | `http://127.0.0.1:8317/v1/responses` | `opencode/...` | `CLIPROXY_API_KEY` |

CPA provides complete Responses requests, which are called by an external client or HTTP
tool rather than by `cherry request`:

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
                    text = 'Explain quicksort.'
                }
            )
        }
    )
    max_output_tokens = 1024
} | ConvertTo-Json -Depth 20

Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8317/v1/responses' -Headers $headers -Body $body
```

`CHERRY_STUDIO_API_KEY` authenticates CPA to the Cherry Studio upstream. `CLIPROXY_API_KEY`
authenticates a client to CPA. They are not interchangeable. CPA clients get
`CLIPROXY_API_KEY` from CPA's own `api-keys` configuration and should provide it through a
secret-management mechanism.

## Boundaries And Security

- `request` can forward complete JSON, but support for a field or model capability is still
  determined by Cherry Studio or CLIProxyAPI.
- Direct Anthropic calls use the Bearer authentication required by Cherry Studio. They do not
  emulate native Anthropic `x-api-key` or `anthropic-version` headers.
- The project does not package CLIProxyAPI, third-party binaries, user configuration, model
  configuration, or tokens.

## License

This project uses the [MIT License](LICENSE). Optional proxy dependencies and patches are
listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
