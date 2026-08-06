# Optional CLIProxyAPI Integration

> [中文](CLIProxyAPI.md)

`cherry connect` is not required to use Cherry Studio CLI. Use it only when other
clients need access to a compatible API running locally.

## Why a patch is required

The Cherry Studio API token must exist only for the lifetime of the proxy process;
it must not be written to `config.yaml`. This project's bridge script writes the
following configuration for CLIProxyAPI:

```yaml
api-key-entries:
  - api-key-env: 'CHERRY_STUDIO_API_KEY'
```

This field is supplied by a small compatibility patch for
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI). The patch targets
upstream commit `05d1792d43ff9c338943dd9f8b2031faaa2699e4` and preserves the
existing behavior of standard `api-key` configuration.

## Build a compatible runtime

The following example uses an independent runtime directory so generated output
does not enter this repository:

```powershell
git clone https://github.com/router-for-me/CLIProxyAPI.git D:\CodexWork\CLIProxyAPI
Set-Location D:\CodexWork\CLIProxyAPI
git checkout 05d1792d43ff9c338943dd9f8b2031faaa2699e4
git apply D:\path\to\cherry-studio-cli\patches\cliproxyapi-api-key-env.patch

$runDirectory = 'D:\CodexWork\cherry-cliproxy-run'
New-Item -ItemType Directory -Force "$runDirectory\bin" | Out-Null
Copy-Item .\config.example.yaml "$runDirectory\config.yaml"
go build -trimpath -o "$runDirectory\bin\cliproxy-server.exe" .\cmd\server
```

Before starting the proxy, configure its listener address, client access key, and
management key according to the CLIProxyAPI documentation. Do not write the
Cherry Studio API token to that file: `cherry connect` supplies it through a
short-lived environment variable.

## Start the proxy and choose model names

```powershell
$env:CHERRY_CLI_PROXY_RUN_DIRECTORY = 'D:\CodexWork\cherry-cliproxy-run'
cherry connect
cherry proxy-status
```

Models without a friendly alias use `cherry/<original model ID>` in the proxy.
For example, after mapping a UUID prefix to `opencode`, the model becomes
`opencode/<model suffix>`. CLIProxyAPI separates the provider and model name with
a slash, whereas direct Cherry CLI access uses a colon.

## Call the full Responses API

After CPA starts, external clients should call
`http://127.0.0.1:8317/v1/responses` directly. Do not substitute
`cherry request -Format responses`: that CLI command always targets Cherry
Studio's local API Server, not CPA.

Clients use the CPA access key configured as `CLIPROXY_API_KEY`, not
`CHERRY_STUDIO_API_KEY`. The latter is used only by CPA to reach the Cherry
Studio upstream.

```powershell
$headers = @{
    Authorization = 'Bearer <CLIPROXY_API_KEY>'
    'Content-Type' = 'application/json'
}
$body = @{
    model = 'opencode/deepseek-v4-flash-free'
    input = '解释快速排序。'
    max_output_tokens = 1024
} | ConvertTo-Json

Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8317/v1/responses' -Headers $headers -Body $body
```

Use CPA's slash-form model name, such as `opencode/deepseek-v4-flash-free`; do
not use the direct CLI colon form `opencode:deepseek-v4-flash-free`.

## Update

The patch pins an upstream commit for reproducibility. Before upgrading
CLIProxyAPI, inspect and revalidate the patch against the new upstream version;
do not assume its configuration structure remains compatible.
