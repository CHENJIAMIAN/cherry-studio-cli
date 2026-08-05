[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunDirectory,
    [string]$CherryBaseUrl = 'http://127.0.0.1:23333',
    [int]$CLIProxyPort = 8317,
    [string]$ProviderAliasesJson = '{}'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$markerStart = '# BEGIN CHERRY STUDIO CLIPROXYAPI'
$markerEnd = '# END CHERRY STUDIO CLIPROXYAPI'

function ConvertTo-YamlSingleQuoted {
    param([Parameter(Mandatory)][string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-ProviderAliases {
    try {
        $parsed = $ProviderAliasesJson | ConvertFrom-Json -AsHashtable -Depth 32
    }
    catch {
        throw 'Provider aliases are not valid JSON.'
    }
    if ($null -eq $parsed) {
        return @{}
    }

    $result = @{}
    foreach ($entry in $parsed.GetEnumerator()) {
        $key = [string]$entry.Key
        $value = [string]$entry.Value
        if (-not [string]::IsNullOrWhiteSpace($key) -and -not [string]::IsNullOrWhiteSpace($value)) {
            $result[$key] = $value
        }
    }
    return $result
}

function Get-CherryModelIds {
    param([Parameter(Mandatory)][string]$BaseUrl)

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, ($BaseUrl.TrimEnd('/') + '/v1/models'))
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $env:CHERRY_STUDIO_API_KEY)
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "Cherry Studio model discovery failed with HTTP $([int]$response.StatusCode)."
        }

        $payload = $body | ConvertFrom-Json -Depth 64
        $ids = @($payload.data | ForEach-Object { [string]$_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        if ($ids.Count -eq 0) {
            throw 'Cherry Studio API Server did not expose any models.'
        }
        return $ids
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-RouteParts {
    param(
        [Parameter(Mandatory)][string]$ModelId,
        [Parameter(Mandatory)][hashtable]$ProviderAliases
    )

    $separator = $ModelId.IndexOf(':')
    if ($separator -le 0) {
        return [PSCustomObject]@{
            Prefix = 'cherry'
            Name = $ModelId
        }
    }

    $rawPrefix = $ModelId.Substring(0, $separator)
    $name = $ModelId.Substring($separator + 1)
    $prefix = if ($ProviderAliases.ContainsKey($rawPrefix)) {
        [string]$ProviderAliases[$rawPrefix]
    }
    else {
        'cherry'
    }

    if ([string]::IsNullOrWhiteSpace($prefix)) {
        $prefix = 'cherry'
    }
    return [PSCustomObject]@{
        Prefix = $prefix
        Name = if ($prefix -eq 'cherry') { $ModelId } else { $name }
    }
}

function Set-CherryProviderConfig {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string[]]$ModelIds,
        [Parameter(Mandatory)][hashtable]$ProviderAliases
    )

    $text = [System.IO.File]::ReadAllText($ConfigPath)
    $markerPattern = '(?ms)^# BEGIN CHERRY STUDIO CLIPROXYAPI\r?\n.*?^# END CHERRY STUDIO CLIPROXYAPI\r?\n?'
    $text = [regex]::Replace($text, $markerPattern, '')

    $groups = @{}
    foreach ($modelId in $ModelIds) {
        $parts = Get-RouteParts -ModelId $modelId -ProviderAliases $ProviderAliases
        if (-not $groups.ContainsKey($parts.Prefix)) {
            $groups[$parts.Prefix] = [System.Collections.Generic.List[object]]::new()
        }
        $groups[$parts.Prefix].Add([PSCustomObject]@{
            Name = $parts.Name
            Alias = $parts.Name
        })
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($markerStart)
    foreach ($group in $groups.GetEnumerator() | Sort-Object Key) {
        $providerPrefix = [string]$group.Key
        $providerName = 'cherry-studio-' + $providerPrefix
        $lines.Add(('  - name: ' + (ConvertTo-YamlSingleQuoted -Value $providerName)))
        $lines.Add(('    prefix: ' + (ConvertTo-YamlSingleQuoted -Value $providerPrefix)))
        $lines.Add(('    base-url: ' + (ConvertTo-YamlSingleQuoted -Value ($BaseUrl.TrimEnd('/') + '/v1'))))
        $lines.Add('    api-key-entries:')
        $lines.Add('      - api-key-env: ''CHERRY_STUDIO_API_KEY''')
        $lines.Add('    models:')
        foreach ($model in $group.Value | Sort-Object Name) {
            $lines.Add(('      - name: ' + (ConvertTo-YamlSingleQuoted -Value ([string]$model.Name))))
            $lines.Add(('        alias: ' + (ConvertTo-YamlSingleQuoted -Value ([string]$model.Alias))))
        }
        $lines.Add('    priority: 100')
    }
    $lines.Add($markerEnd)
    $block = ($lines -join [Environment]::NewLine) + [Environment]::NewLine

    $sectionMatch = [regex]::Match($text, '(?m)^openai-compatibility:\s*(?:#.*)?$')
    if ($sectionMatch.Success) {
        $nextTopLevelPattern = [regex]::new('(?m)^[^\s#][^:\r\n]*:')
        $nextTopLevel = $nextTopLevelPattern.Match($text, $sectionMatch.Index + $sectionMatch.Length)
        $insertAt = if ($nextTopLevel.Success) { $nextTopLevel.Index } else { $text.Length }
        $before = $text.Substring(0, $insertAt).TrimEnd() + [Environment]::NewLine
        $after = $text.Substring($insertAt)
        $text = $before + $block + [Environment]::NewLine + $after
    }
    else {
        $text = $text.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + 'openai-compatibility:' + [Environment]::NewLine + $block
    }

    $temporaryPath = "$ConfigPath.$PID.tmp"
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $text, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $ConfigPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Stop-CurrentCLIProxy {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    $targetPath = [System.IO.Path]::GetFullPath($ExecutablePath)
    $processes = Get-Process -Name 'cliproxy-server' -ErrorAction SilentlyContinue
    foreach ($process in $processes) {
        if ($process.Path -ieq $targetPath) {
            Stop-Process -Id $process.Id -Force
            Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue
        }
    }
}

function Assert-CLIProxyPortAvailable {
    param([int]$Port)

    $listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $listener) {
        throw "Port $Port is already in use by process $($listener.OwningProcess). Stop that process or choose another CLIProxyAPI port."
    }
}

function Wait-ForCLIProxy {
    param(
        [int]$Port,
        [int]$ProcessId
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        $listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $listener -and $listener.OwningProcess -eq $ProcessId) {
            return
        }
        Start-Sleep -Milliseconds 200
    }
    throw "CLIProxyAPI process $ProcessId did not start listening on port $Port."
}

if ([string]::IsNullOrWhiteSpace($env:CHERRY_STUDIO_API_KEY)) {
    throw 'CHERRY_STUDIO_API_KEY was not injected into the connection process.'
}

$providerAliases = Get-ProviderAliases
$resolvedRunDirectory = (Resolve-Path -LiteralPath $RunDirectory).Path
$configPath = Join-Path $resolvedRunDirectory 'config.yaml'
$executablePath = Join-Path $resolvedRunDirectory 'bin\cliproxy-server.exe'
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "CLIProxyAPI config was not found: $configPath"
}
if (-not (Test-Path -LiteralPath $executablePath)) {
    throw "CLIProxyAPI executable was not found: $executablePath"
}

$modelIds = Get-CherryModelIds -BaseUrl $CherryBaseUrl
Set-CherryProviderConfig -ConfigPath $configPath -BaseUrl $CherryBaseUrl -ModelIds $modelIds -ProviderAliases $providerAliases
Stop-CurrentCLIProxy -ExecutablePath $executablePath
Assert-CLIProxyPortAvailable -Port $CLIProxyPort

$process = Start-Process -FilePath $executablePath -ArgumentList @('-config', $configPath) -WorkingDirectory $resolvedRunDirectory -WindowStyle Hidden -PassThru
Wait-ForCLIProxy -Port $CLIProxyPort -ProcessId $process.Id

[PSCustomObject]@{
    ProxyUrl = "http://127.0.0.1:$CLIProxyPort"
    ProcessId = $process.Id
    CherryModelsSynced = $modelIds.Count
    ClientModelPrefix = 'provider-prefix/model-name'
    Protocols = @('/v1/chat/completions', '/v1/responses', '/v1/messages')
} | ConvertTo-Json -Depth 8
