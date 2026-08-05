[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scripts = @(
    (Join-Path $ProjectRoot 'cherry.ps1'),
    (Join-Path $ProjectRoot 'cherry-client.ps1'),
    (Join-Path $ProjectRoot 'install.ps1'),
    (Join-Path $ProjectRoot 'scripts\Connect-CLIProxyAPI.ps1')
)

foreach ($scriptPath in $scripts) {
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "缺少脚本文件: $scriptPath"
    }

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw ("PowerShell 语法错误: " + ($errors | ForEach-Object Message | Join-String -Separator '; '))
    }
}

$help = & pwsh -NoLogo -NoProfile -File (Join-Path $ProjectRoot 'cherry.ps1') help
$helpText = $help -join [Environment]::NewLine
if ($LASTEXITCODE -ne 0 -or $helpText -notmatch 'Cherry Studio CLI') {
    throw 'CLI 帮助命令未能正常运行。'
}

$temporaryConfig = Join-Path ([System.IO.Path]::GetTempPath()) ('cherry-cli-' + [Guid]::NewGuid().ToString('N') + '.json')
$previousConfigPath = $env:CHERRY_CLI_CONFIG_PATH
try {
    $env:CHERRY_CLI_CONFIG_PATH = $temporaryConfig
    & pwsh -NoLogo -NoProfile -File (Join-Path $ProjectRoot 'cherry.ps1') alias 'raw-provider' 'friendly-provider'
    $aliases = & pwsh -NoLogo -NoProfile -File (Join-Path $ProjectRoot 'cherry.ps1') alias
    $aliasesText = $aliases -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -or $aliasesText -notmatch 'raw-provider') {
        throw '模型别名配置未能正常保存。'
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryConfig) {
        [System.IO.File]::Delete($temporaryConfig)
    }
    if ($null -eq $previousConfigPath) {
        Remove-Item Env:CHERRY_CLI_CONFIG_PATH -ErrorAction SilentlyContinue
    }
    else {
        $env:CHERRY_CLI_CONFIG_PATH = $previousConfigPath
    }
}

$portableFiles = @(
    (Join-Path $ProjectRoot 'cherry.ps1'),
    (Join-Path $ProjectRoot 'cherry-client.ps1'),
    (Join-Path $ProjectRoot 'scripts\Connect-CLIProxyAPI.ps1')
)
foreach ($portableFile in $portableFiles) {
    if (Select-String -LiteralPath $portableFile -SimpleMatch 'D:\CodexWork' -Quiet) {
        throw "发现本机硬编码路径: $portableFile"
    }
}

Write-Output 'Smoke checks passed.'
