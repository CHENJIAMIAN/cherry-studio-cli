# CLIProxyAPI 可选集成

> [English](CLIProxyAPI.en.md)

`cherry connect` 不是使用 Cherry Studio CLI 的前提条件。它只在需要让其他客户端
访问本机兼容 API 时使用。

## 为什么需要补丁

Cherry Studio 的 API token 应只在代理进程生命周期内存在，不能被写入
`config.yaml`。本项目的桥接脚本为 CLIProxyAPI 写入：

```yaml
api-key-entries:
  - api-key-env: 'CHERRY_STUDIO_API_KEY'
```

该字段由 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) 的一个小型
兼容补丁提供。补丁目标是上游提交
`05d1792d43ff9c338943dd9f8b2031faaa2699e4`，并保留普通
`api-key` 配置的既有行为。

## 构建兼容运行时

以下示例使用独立运行目录，避免将生成物放进本仓库：

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

在启动代理前，按 CLIProxyAPI 的文档配置其监听地址、客户端访问密钥和管理密钥。
不要把 Cherry Studio API token 写入该文件；`cherry connect` 会通过短生命周期环境变量
提供它。

## 启动与模型名

```powershell
$env:CHERRY_CLI_PROXY_RUN_DIRECTORY = 'D:\CodexWork\cherry-cliproxy-run'
cherry connect
cherry proxy-status
```

没有配置友好别名的模型在代理中使用 `cherry/<原始模型 ID>`。
例如将 UUID 前缀映射为 `opencode` 后，模型改为
`opencode/<模型后缀>`。CLIProxyAPI 使用斜杠作为 provider 与模型名的分隔符，
而直连 Cherry CLI 使用冒号。

## 调用完整 Responses API

CPA 启动后，外部客户端应直接调用 `http://127.0.0.1:8317/v1/responses`。
不要使用 `cherry request -Format responses` 代替这一步：该 CLI 命令始终面向
Cherry Studio 的本地 API Server，而不是 CPA。

客户端使用 CPA 配置中的访问密钥，即 `CLIPROXY_API_KEY`，而不是
`CHERRY_STUDIO_API_KEY`。后者仅用于 CPA 访问 Cherry Studio 上游。

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

模型名使用 CPA 的斜杠格式，例如 `opencode/deepseek-v4-flash-free`；不要使用
直连 CLI 的冒号格式 `opencode:deepseek-v4-flash-free`。

## 更新

补丁锁定了上游提交以保证可复现性。升级 CLIProxyAPI 前，应先在新的上游版本上检查
并重新验证补丁，不要直接假定配置结构保持兼容。
