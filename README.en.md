[中文](./README.md)

# Cherry Studio CLI

A Windows and PowerShell 7 command-line client for the local Cherry Studio API Server.

It provides two independent capabilities:

- Direct access to the Cherry Studio API Server for model discovery, friendly model aliases, OpenAI Chat Completions, and Anthropic Messages.
- Optional CLIProxyAPI integration that exposes Cherry Studio models to clients requiring OpenAI Chat Completions, OpenAI Responses, or Anthropic Messages.

Direct mode does not depend on CLIProxyAPI. CLIProxyAPI is only needed when a full compatibility proxy is required.

## Prerequisites

- Windows 10/11
- [PowerShell 7](https://learn.microsoft.com/powershell/)
- Cherry Studio with its local API Server enabled in Settings -> API Server
- CHERRY_STUDIO_API_KEY supplied to the calling process through secure credential management

## Install

~~~powershell
git clone https://github.com/CHENJIAMIAN/cherry-studio-cli.git
Set-Location .\cherry-studio-cli
pwsh -File .\install.ps1
~~~

The installer creates cherry.cmd in %USERPROFILE%\.local\bin. Add that directory to the user PATH and open a new terminal.

## Credentials

The project does not create plaintext key files.

- In an environment with the Codex DPAPI credential vault, run cherry configure.
- Elsewhere, supply CHERRY_STUDIO_API_KEY through the operating system, terminal, or CI secret-management mechanism.

## Friendly Model Aliases

Cherry Studio can return a model prefix containing a UUID. Map it to a short name so the CLI displays and accepts a friendly model id, then restores the original id before it sends requests.

~~~powershell
cherry alias 08117452-f5be-4da7-a4a7-78f55a79be9b opencode
cherry models
cherry ask "Explain quicksort." -Model "opencode:deepseek-v4-flash-free"
~~~

cherry alias lists current mappings. One friendly prefix maps to exactly one original prefix, so reverse lookup is unambiguous. cherry models -Json retains the original id and adds an alias field for automation and debugging.

## Convenient Requests

~~~powershell
cherry status
cherry models
cherry default "opencode:deepseek-v4-flash-free"
cherry ask "Tell me a joke." -Model "opencode:deepseek-v4-flash-free"
cherry ask "Explain this tool call." -Model "opencode:deepseek-v4-flash-free" -Format anthropic -Json
cherry ask "Explain quicksort." -Model "opencode:deepseek-v4-flash-free" -Format responses -Json
~~~

ask is a single-turn text command. It supports chat, anthropic, and responses output. When Cherry Studio does not expose /v1/responses, a convenient Responses request falls back to a Chat Completions result adapted into a Responses-shaped response.

That fallback accepts only a prompt, model, system prompt, and maximum tokens. It does not provide full Responses semantics such as multi-turn input, tools, background jobs, event streaming, or other Responses-specific features.

## Full Protocol Requests

For multi-turn messages, content blocks, tools, images, thinking parameters, stop sequences, or other protocol-specific fields, use request with a full JSON body from a file or standard input. Direct Cherry Studio mode supports complete Chat Completions and Anthropic Messages requests:

~~~powershell
cherry request -Format anthropic -BodyFile .\anthropic-request.json -Json
cherry request -Format chat -BodyFile .\chat-request.json -Stream
Get-Content .\request.json -Raw | cherry request -Format anthropic -BodyFile -
~~~

request parses structured JSON and preserves unknown fields. It only restores a friendly model alias, enables stream when requested, sends the original protocol endpoint, and returns the SSE or JSON response unchanged.

Verified direct Cherry Studio endpoints are:

- /v1/chat/completions
- /v1/messages

If /v1/responses returns 404, the local API Server does not provide that endpoint. The CLI did not discard any request fields. Full Responses requests should use CLIProxyAPI as described below.

## Optional CLIProxyAPI Integration

~~~powershell
$env:CHERRY_CLI_PROXY_RUN_DIRECTORY = 'C:\path\to\cliproxy-run'
cherry connect
cherry proxy-status
~~~

The run directory must contain:

~~~text
config.yaml
bin\cliproxy-server.exe
~~~

Once started, CLIProxyAPI exposes:

~~~text
http://127.0.0.1:8317/v1/chat/completions
http://127.0.0.1:8317/v1/responses
http://127.0.0.1:8317/v1/messages
~~~

CLIProxyAPI uses slash-separated client model ids. The alias above becomes opencode/deepseek-v4-flash-free. See [the CLIProxyAPI guide](docs/CLIProxyAPI.md) for build, patch, and secure configuration details.

## Choosing a Responses Path

| Need | Where to call | Model id | Authentication |
| --- | --- | --- | --- |
| Simple single-turn text | cherry ask ... -Format responses | opencode:... | CHERRY_STUDIO_API_KEY |
| Full Responses API | http://127.0.0.1:8317/v1/responses | opencode/... | CLIPROXY_API_KEY |

Full Responses requests are served by CLIProxyAPI and are called by an external client or HTTP tool, not by cherry request.

CHERRY_STUDIO_API_KEY authenticates CLIProxyAPI to the Cherry Studio upstream. CLIPROXY_API_KEY authenticates a client to CLIProxyAPI. They are different credentials and must not be exchanged. Configure the client key through the proxy's api-keys configuration and a secret-management mechanism.

## Boundaries and Security

- request can forward complete JSON, but Cherry Studio or CLIProxyAPI determines whether a given field or model capability is supported.
- Direct Anthropic calls use Cherry Studio's Bearer authentication and do not imitate native Anthropic x-api-key or anthropic-version headers.
- The repository does not package CLIProxyAPI, third-party binaries, user configuration, model configuration, or tokens.

## License

This project is licensed under [MIT](LICENSE). Optional proxy dependencies and patches are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
