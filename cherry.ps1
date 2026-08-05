[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'configure', 'models', 'ask', 'request', 'default', 'alias', 'connect', 'proxy-status', 'serve', 'help')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Value,

    [Parameter(Position = 2)]
    [string]$Alias,

    [string]$Model,
    [string]$System,
    [string]$BaseUrl,
    [string]$CLIProxyRunDirectory,
    [string]$BodyFile,
    [string]$RequestJson,
    [ValidateSet('chat', 'anthropic', 'responses')]
    [string]$Format = 'chat',
    [ValidateRange(1, 1000000)]
    [int]$MaxTokens = 1024,
    [switch]$Stream,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SecretName = 'CHERRY_STUDIO_API_KEY'
$script:DefaultBaseUrl = 'http://127.0.0.1:23333'
$script:ClientPath = Join-Path $PSScriptRoot 'cherry-client.ps1'
$script:CLIProxyConnectPath = Join-Path $PSScriptRoot 'scripts\Connect-CLIProxyAPI.ps1'
$script:VaultListPath = Join-Path $env:USERPROFILE '.codex\scripts\Get-CodexSecretNames.ps1'
$script:VaultSetPath = Join-Path $env:USERPROFILE '.codex\scripts\Set-CodexSecret.ps1'
$script:VaultInvokePath = Join-Path $env:USERPROFILE '.codex\scripts\Invoke-CodexSecretCommand.ps1'

function Get-CherryConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($env:CHERRY_CLI_CONFIG_PATH)) {
        return $env:CHERRY_CLI_CONFIG_PATH
    }

    $stateDirectory = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:LOCALAPPDATA 'CherryStudioCLI'
    }
    else {
        Join-Path $HOME '.cherry-studio-cli'
    }

    return Join-Path $stateDirectory 'config.json'
}

$script:ConfigPath = Get-CherryConfigPath

function Get-CherryConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        return @{}
    }

    try {
        $config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json -AsHashtable
        if ($null -eq $config) {
            return @{}
        }
        return $config
    }
    catch {
        throw "Cannot read Cherry CLI configuration: $script:ConfigPath"
    }
}

function Save-CherryConfig {
    param([Parameter(Mandatory)][hashtable]$Config)

    $directory = Split-Path -Parent $script:ConfigPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ConfigPath -Encoding utf8NoBOM
}

function Get-ProviderAliasesJson {
    param([hashtable]$Config)

    if (-not $Config.ContainsKey('providerAliases') -or $null -eq $Config.providerAliases) {
        return '{}'
    }
    return ($Config.providerAliases | ConvertTo-Json -Depth 8 -Compress)
}

function Get-CherryBaseUrl {
    param(
        [hashtable]$Config,
        [string]$Override
    )

    $url = if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $Override
    }
    elseif ($Config.ContainsKey('baseUrl') -and -not [string]::IsNullOrWhiteSpace([string]$Config.baseUrl)) {
        [string]$Config.baseUrl
    }
    else {
        $script:DefaultBaseUrl
    }

    return $url.TrimEnd('/')
}

function Resolve-CLIProxyRunDirectory {
    param(
        [hashtable]$Config,
        [string]$Override
    )

    $candidate = if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $Override
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:CHERRY_CLI_PROXY_RUN_DIRECTORY)) {
        $env:CHERRY_CLI_PROXY_RUN_DIRECTORY
    }
    elseif ($Config.ContainsKey('cliProxyRunDirectory') -and -not [string]::IsNullOrWhiteSpace([string]$Config.cliProxyRunDirectory)) {
        [string]$Config.cliProxyRunDirectory
    }
    else {
        throw 'CLIProxyAPI is optional and has not been configured. Set CHERRY_CLI_PROXY_RUN_DIRECTORY or pass -CLIProxyRunDirectory.'
    }

    $expandedCandidate = [Environment]::ExpandEnvironmentVariables($candidate)
    try {
        $resolved = (Resolve-Path -LiteralPath $expandedCandidate -ErrorAction Stop).Path
    }
    catch {
        throw "CLIProxyAPI run directory does not exist: $expandedCandidate"
    }

    $configPath = Join-Path $resolved 'config.yaml'
    $executablePath = Join-Path $resolved 'bin\cliproxy-server.exe'
    if (-not (Test-Path -LiteralPath $configPath) -or -not (Test-Path -LiteralPath $executablePath)) {
        throw "CLIProxyAPI run directory must contain config.yaml and bin\cliproxy-server.exe: $resolved"
    }

    return $resolved
}

function Test-CodexVaultAvailable {
    return (Test-Path -LiteralPath $script:VaultListPath) -and
        (Test-Path -LiteralPath $script:VaultSetPath) -and
        (Test-Path -LiteralPath $script:VaultInvokePath)
}

function Test-CherryApiToken {
    if (-not [string]::IsNullOrWhiteSpace($env:CHERRY_STUDIO_API_KEY)) {
        return $true
    }
    if (-not (Test-CodexVaultAvailable)) {
        return $false
    }

    $names = @(& $script:VaultListPath)
    return $names -contains $script:SecretName
}

function Show-Usage {
    @'
Cherry Studio CLI

Usage:
  cherry status [-BaseUrl http://127.0.0.1:23333]
  cherry configure
  cherry models [-Json]
  cherry alias [provider-prefix] [friendly-prefix]
  cherry default <model-id>
  cherry ask "prompt" -Model <model-id> [-Format chat|anthropic|responses] [-MaxTokens 1024] [-System "system prompt"] [-Json]
  cherry request -Format <chat|anthropic|responses> -BodyFile <path-or-> [-Model <model-id>] [-Stream] [-Json]
  cherry connect [-CLIProxyRunDirectory <path>]
  cherry proxy-status
  cherry serve [-CLIProxyRunDirectory <path>]

Direct commands use Cherry Studio's local API server. Start it in
Cherry Studio > Settings > API Server before running model commands.

Set CHERRY_STUDIO_API_KEY through your secret manager or current process
environment. On systems with the Codex DPAPI vault, configure stores the
token there and injects it only into request child processes.

request forwards a complete JSON request body without dropping format-specific
fields. connect and serve are optional CLIProxyAPI integrations.
'@ | Write-Output
}

function Invoke-CherryStatus {
    param([string]$Url, [switch]$AsJson)

    try {
        $response = Invoke-RestMethod -Method Get -Uri "$Url/health" -TimeoutSec 5
    }
    catch {
        throw "Cherry Studio API Server is unavailable at $Url. Start it in Settings > API Server. Details: $($_.Exception.Message)"
    }

    if ($AsJson) {
        $response | ConvertTo-Json -Depth 8
        return
    }

    Write-Output "Cherry Studio API Server: $Url"
    Write-Output "Status: $($response.status)"
    Write-Output "Version: $($response.version)"
}

function Invoke-CherryChild {
    param([Parameter(Mandatory)][string[]]$Arguments)

    if (-not (Test-CherryApiToken)) {
        throw 'CHERRY_STUDIO_API_KEY is not configured. Set it through your secret manager or environment, or use cherry configure when the Codex DPAPI vault is available.'
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CHERRY_STUDIO_API_KEY)) {
        & pwsh @Arguments
    }
    else {
        & $script:VaultInvokePath -SecretName $script:SecretName -FilePath 'pwsh' -ArgumentList $Arguments
    }
    exit $LASTEXITCODE
}

function Invoke-CherryClient {
    param(
        [ValidateSet('models', 'ask', 'request')]
        [string]$ClientCommand,
        [string]$Url,
        [string]$ArgumentValue,
        [string]$SelectedModel,
        [string]$SystemPrompt,
        [ValidateSet('chat', 'anthropic', 'responses')]
        [string]$RequestFormat,
        [int]$MaxOutputTokens,
        [string]$RequestBodyFile,
        [string]$RequestBodyJson,
        [switch]$RequestStream,
        [switch]$AsJson
    )

    $arguments = @('-NoLogo', '-NoProfile', '-File', $script:ClientPath, '-Command', $ClientCommand, '-BaseUrl', $Url)
    if (-not [string]::IsNullOrWhiteSpace($ArgumentValue)) {
        $arguments += @('-Value', $ArgumentValue)
    }
    if (-not [string]::IsNullOrWhiteSpace($SelectedModel)) {
        $arguments += @('-Model', $SelectedModel)
    }
    if (-not [string]::IsNullOrWhiteSpace($SystemPrompt)) {
        $arguments += @('-System', $SystemPrompt)
    }
    if ($ClientCommand -in @('ask', 'request')) {
        $arguments += @('-Format', $RequestFormat, '-MaxTokens', $MaxOutputTokens)
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestBodyFile)) {
        $arguments += @('-BodyFile', $RequestBodyFile)
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestBodyJson)) {
        $arguments += @('-RequestJson', $RequestBodyJson)
    }
    if ($RequestStream) {
        $arguments += '-Stream'
    }
    if ($AsJson) {
        $arguments += '-Json'
    }
    $arguments += @('-ProviderAliasesJson', (Get-ProviderAliasesJson -Config $config))

    Invoke-CherryChild -Arguments $arguments
}

function Invoke-CLIProxyConnection {
    param(
        [string]$Url,
        [hashtable]$Config,
        [string]$RunDirectory
    )

    if (-not (Test-Path -LiteralPath $script:CLIProxyConnectPath)) {
        throw "CLIProxyAPI bridge script was not found: $script:CLIProxyConnectPath"
    }

    $resolvedRunDirectory = Resolve-CLIProxyRunDirectory -Config $Config -Override $RunDirectory
    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-File',
        $script:CLIProxyConnectPath,
        '-RunDirectory',
        $resolvedRunDirectory,
        '-CherryBaseUrl',
        $Url,
        '-ProviderAliasesJson',
        (Get-ProviderAliasesJson -Config $Config)
    )
    Invoke-CherryChild -Arguments $arguments
}

function Invoke-CherryConfigure {
    if (Test-CodexVaultAvailable) {
        Write-Output 'Copy the API key shown in Cherry Studio > Settings > API Server.'
        Write-Output 'The next prompt is secure and does not echo the token.'
        & $script:VaultSetPath $script:SecretName
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CHERRY_STUDIO_API_KEY)) {
        Write-Output 'CHERRY_STUDIO_API_KEY is already available in the current process environment.'
        return
    }

    throw 'No supported secure vault was found. Configure CHERRY_STUDIO_API_KEY with your operating system or shell secret manager before calling cherry.'
}

function Set-ProviderAlias {
    param(
        [hashtable]$Config,
        [string]$ProviderPrefix,
        [string]$FriendlyPrefix
    )

    $aliases = @{}
    if ($Config.ContainsKey('providerAliases') -and $null -ne $Config.providerAliases) {
        foreach ($entry in $Config.providerAliases.GetEnumerator()) {
            $aliases[[string]$entry.Key] = [string]$entry.Value
        }
    }

    if ([string]::IsNullOrWhiteSpace($ProviderPrefix)) {
        if ($aliases.Count -eq 0) {
            Write-Output 'No provider aliases configured.'
        }
        else {
            foreach ($entry in $aliases.GetEnumerator() | Sort-Object Key) {
                Write-Output ("{0}{1}{2}" -f $entry.Key, [char]9, $entry.Value)
            }
        }
        return
    }

    if ([string]::IsNullOrWhiteSpace($FriendlyPrefix)) {
        throw 'A friendly prefix is required. Example: cherry alias 08117452-f5be-4da7-a4a7-78f55a79be9b opencode'
    }
    if ($ProviderPrefix.Contains(':') -or $FriendlyPrefix.Contains(':')) {
        throw 'Provider prefixes must not contain a colon.'
    }
    foreach ($entry in $aliases.GetEnumerator()) {
        if ($entry.Key -ine $ProviderPrefix -and $entry.Value -ieq $FriendlyPrefix) {
            throw "Friendly prefix '$FriendlyPrefix' is already assigned to provider prefix '$($entry.Key)'."
        }
    }

    $aliases[$ProviderPrefix] = $FriendlyPrefix
    $Config.providerAliases = $aliases
    Save-CherryConfig -Config $Config
    Write-Output "Provider alias set: $ProviderPrefix -> $FriendlyPrefix"
}

function Show-CLIProxyStatus {
    $process = Get-Process -Name 'cliproxy-server' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $process) {
        Write-Output 'CLIProxyAPI is stopped.'
        return
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(5)
    try {
        $response = $client.GetAsync('http://127.0.0.1:8317/').GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        [PSCustomObject]@{
            ProcessId = $process.Id
            Status = [int]$response.StatusCode
            Endpoint = 'http://127.0.0.1:8317'
            Metadata = $body | ConvertFrom-Json
        } | ConvertTo-Json -Depth 12
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

$config = Get-CherryConfig
$resolvedBaseUrl = Get-CherryBaseUrl -Config $config -Override $BaseUrl

switch ($Command) {
    'status' {
        Invoke-CherryStatus -Url $resolvedBaseUrl -AsJson:$Json
        break
    }
    'configure' {
        Invoke-CherryConfigure
        break
    }
    'models' {
        Invoke-CherryClient -ClientCommand 'models' -Url $resolvedBaseUrl -AsJson:$Json
        break
    }
    'alias' {
        Set-ProviderAlias -Config $config -ProviderPrefix $Value -FriendlyPrefix $Alias
        break
    }
    'default' {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            if ($config.ContainsKey('defaultModel')) {
                Write-Output "Default model: $($config.defaultModel)"
                break
            }
            throw 'No default model is set. Use: cherry default <model-id>'
        }

        $config.defaultModel = $Value
        Save-CherryConfig -Config $config
        Write-Output "Default model set to: $Value"
        break
    }
    'ask' {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            throw 'A prompt is required. Use: cherry ask "prompt" -Model <model-id>'
        }

        $selectedModel = if (-not [string]::IsNullOrWhiteSpace($Model)) {
            $Model
        }
        elseif ($config.ContainsKey('defaultModel')) {
            [string]$config.defaultModel
        }
        else {
            throw 'No model was supplied and no default is configured. Use: cherry models, then cherry default <model-id>'
        }

        Invoke-CherryClient -ClientCommand 'ask' -Url $resolvedBaseUrl -ArgumentValue $Value -SelectedModel $selectedModel -SystemPrompt $System -RequestFormat $Format -MaxOutputTokens $MaxTokens -RequestBodyFile $BodyFile -RequestBodyJson $RequestJson -RequestStream:$Stream -AsJson:$Json
        break
    }
    'request' {
        Invoke-CherryClient -ClientCommand 'request' -Url $resolvedBaseUrl -SelectedModel $Model -RequestFormat $Format -MaxOutputTokens $MaxTokens -RequestBodyFile $BodyFile -RequestBodyJson $RequestJson -RequestStream:$Stream -AsJson:$Json
        break
    }
    'connect' {
        Invoke-CLIProxyConnection -Url $resolvedBaseUrl -Config $config -RunDirectory $CLIProxyRunDirectory
        break
    }
    'proxy-status' {
        Show-CLIProxyStatus
        break
    }
    'serve' {
        Invoke-CLIProxyConnection -Url $resolvedBaseUrl -Config $config -RunDirectory $CLIProxyRunDirectory
        break
    }
    default {
        Show-Usage
        break
    }
}
