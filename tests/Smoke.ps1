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
    (Join-Path $ProjectRoot 'scripts\Connect-CLIProxyAPI.ps1'),
    (Join-Path $ProjectRoot 'install.ps1'),
    (Join-Path $ProjectRoot 'install.sh')
)
foreach ($portableFile in $portableFiles) {
    if (Select-String -LiteralPath $portableFile -SimpleMatch 'D:\CodexWork' -Quiet) {
        throw "发现本机硬编码路径: $portableFile"
    }
}

$windows = [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if ($windows) {
    $installerTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cherry-cli-installer-' + [Guid]::NewGuid().ToString('N'))
    try {
        $applicationDirectory = Join-Path $installerTestRoot 'application'
        $binDirectory = Join-Path $installerTestRoot 'bin'
        & pwsh -NoLogo -NoProfile -File (Join-Path $ProjectRoot 'install.ps1') -InstallDirectory $applicationDirectory -BinDirectory $binDirectory -NoPathUpdate
        if ($LASTEXITCODE -ne 0) {
            throw "安装器退出码异常: $LASTEXITCODE"
        }

        $launcherPath = Join-Path $binDirectory 'cherry.cmd'
        $requiredInstallFiles = @(
            (Join-Path $applicationDirectory 'cherry.ps1'),
            (Join-Path $applicationDirectory 'cherry-client.ps1'),
            (Join-Path $applicationDirectory 'scripts\Connect-CLIProxyAPI.ps1'),
            $launcherPath
        )
        foreach ($requiredInstallFile in $requiredInstallFiles) {
            if (-not (Test-Path -LiteralPath $requiredInstallFile)) {
                throw "安装器缺少产物: $requiredInstallFile"
            }
        }

        $launcher = Get-Content -LiteralPath $launcherPath -Raw
        $installedEntry = Join-Path $applicationDirectory 'cherry.ps1'
        if ($launcher -notmatch [regex]::Escape($installedEntry)) {
            throw '命令启动器没有指向独立安装目录。'
        }

        $installedHelp = & $launcherPath help
        $installedHelpText = $installedHelp -join [Environment]::NewLine
        if ($LASTEXITCODE -ne 0 -or $installedHelpText -notmatch 'Cherry Studio CLI') {
            throw '通过安装后的命令启动器执行帮助命令失败。'
        }
    }
    finally {
        if (Test-Path -LiteralPath $installerTestRoot) {
            Remove-Item -LiteralPath $installerTestRoot -Recurse -Force
        }
    }
}

$shellInstaller = Join-Path $ProjectRoot 'install.sh'
if (-not (Test-Path -LiteralPath $shellInstaller)) {
    throw '缺少 macOS/Linux/WSL2 安装器 install.sh。'
}
$shellInstallerText = Get-Content -LiteralPath $shellInstaller -Raw
if ($shellInstallerText.Contains("`r")) {
    throw 'install.sh 必须使用 LF 换行。'
}
foreach ($expectedText in @('curl -fsSL', 'PowerShell/PowerShell/releases/latest', 'cherry.ps1')) {
    if (-not $shellInstallerText.Contains($expectedText)) {
        throw "install.sh 缺少预期安装逻辑: $expectedText"
    }
}

$bash = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -ne $bash) {
    & $bash.Source --version *> $null
    if ($LASTEXITCODE -eq 0) {
        & $bash.Source -n $shellInstaller
        if ($LASTEXITCODE -ne 0) {
            throw 'install.sh Bash 语法检查失败。'
        }
    }
}

$documentPairs = @(
    @{ Chinese = 'README.md'; English = 'README.en.md' },
    @{ Chinese = 'docs\CLIProxyAPI.md'; English = 'docs\CLIProxyAPI.en.md' }
)
foreach ($documentPair in $documentPairs) {
    $chinesePath = Join-Path $ProjectRoot $documentPair.Chinese
    $englishPath = Join-Path $ProjectRoot $documentPair.English
    if (-not (Test-Path -LiteralPath $chinesePath) -or -not (Test-Path -LiteralPath $englishPath)) {
        throw "缺少中英文文档对: $($documentPair.Chinese) / $($documentPair.English)"
    }

    $englishName = Split-Path -Leaf $englishPath
    $chineseName = Split-Path -Leaf $chinesePath
    if (-not (Get-Content -LiteralPath $chinesePath -Raw).Contains($englishName)) {
        throw "中文文档缺少英文跳转链接: $chinesePath"
    }
    if (-not (Get-Content -LiteralPath $englishPath -Raw).Contains($chineseName)) {
        throw "英文文档缺少中文跳转链接: $englishPath"
    }
}

Write-Output 'Smoke checks passed.'
