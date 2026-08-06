[CmdletBinding()]
param(
    [string]$InstallDirectory,
    [string]$BinDirectory,
    [string]$Repository = 'CHENJIAMIAN/cherry-studio-cli',
    [string]$Ref = 'main',
    [switch]$Force,
    [switch]$NoPathUpdate,
    [switch]$SkipPowerShellInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw '此安装器仅适用于 Windows。macOS、Linux 和 WSL2 请运行 install.sh。'
}

function Get-CherryUserHome {
    foreach ($candidate in @(
            $env:USERPROFILE,
            $env:HOME,
            [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    throw '无法确定当前用户目录。'
}

function Get-PowerShellMajorVersion {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    try {
        $version = & $ExecutablePath -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.Major'
        if ($LASTEXITCODE -eq 0 -and ([string]$version).Trim() -match '^\d+$') {
            return [int]([string]$version).Trim()
        }
    }
    catch {
    }

    return 0
}

function Find-PowerShell7 {
    $candidates = @()
    $command = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
        $candidates += $command.Source
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe')
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ((Test-Path -LiteralPath $candidate) -and (Get-PowerShellMajorVersion -ExecutablePath $candidate) -ge 7) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Install-PowerShell7 {
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $winget) {
        $winget = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -eq $winget) {
        throw '未找到 PowerShell 7，且系统没有 winget。请先安装 PowerShell 7：https://learn.microsoft.com/powershell/'
    }

    Write-Output '未检测到 PowerShell 7，正在通过 winget 安装 Microsoft.PowerShell...'
    & $winget.Source install --id Microsoft.PowerShell --exact --source winget --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        throw "winget 安装 PowerShell 7 失败，退出码：$LASTEXITCODE"
    }
}

function Get-LocalSourceRoot {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return $null
    }

    $requiredPaths = @(
        'cherry.ps1',
        'cherry-client.ps1',
        'scripts\Connect-CLIProxyAPI.ps1'
    )
    foreach ($requiredPath in $requiredPaths) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $requiredPath))) {
            return $null
        }
    }

    return (Resolve-Path -LiteralPath $PSScriptRoot).Path
}

function Invoke-CherryDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )

    $parameters = @{
        Uri = $Uri
        OutFile = $OutFile
        ErrorAction = 'Stop'
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $parameters.UseBasicParsing = $true
    }

    Invoke-WebRequest @parameters
}

function Get-RemoteSource {
    param(
        [Parameter(Mandatory)][string]$OwnerAndRepository,
        [Parameter(Mandatory)][string]$Revision
    )

    if ($OwnerAndRepository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw "无效的 GitHub 仓库：$OwnerAndRepository"
    }
    if ([string]::IsNullOrWhiteSpace($Revision)) {
        throw 'GitHub ref 不能为空。'
    }

    $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cherry-cli-install-' + [Guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $temporaryRoot 'source.zip'
    $extractDirectory = Join-Path $temporaryRoot 'source'
    New-Item -ItemType Directory -Path $extractDirectory -Force | Out-Null

    try {
        $escapedRef = [Uri]::EscapeDataString($Revision)
        $uri = "https://api.github.com/repos/$OwnerAndRepository/zipball/$escapedRef"
        Write-Host "正在从 $OwnerAndRepository@$Revision 下载 Cherry Studio CLI..."
        Invoke-CherryDownload -Uri $uri -OutFile $archivePath
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDirectory -Force

        $sourceRoot = Get-ChildItem -LiteralPath $extractDirectory -Directory | Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'cherry.ps1')) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'cherry-client.ps1')) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'scripts\Connect-CLIProxyAPI.ps1'))
        } | Select-Object -First 1
        if ($null -eq $sourceRoot) {
            throw "下载的归档不包含有效的 Cherry Studio CLI：$OwnerAndRepository@$Revision"
        }

        return [PSCustomObject]@{
            Root = $sourceRoot.FullName
            TemporaryRoot = $temporaryRoot
        }
    }
    catch {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
        throw
    }
}

function Copy-CherryApplicationFiles {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    $requiredFiles = @('cherry.ps1', 'cherry-client.ps1')
    foreach ($fileName in $requiredFiles) {
        $sourcePath = Join-Path $SourceRoot $fileName
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "安装源缺少运行时文件：$sourcePath"
        }
        Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $DestinationRoot $fileName) -Force
    }

    $scriptsPath = Join-Path $SourceRoot 'scripts'
    if (-not (Test-Path -LiteralPath $scriptsPath)) {
        throw "安装源缺少运行时目录：$scriptsPath"
    }
    Copy-Item -LiteralPath $scriptsPath -Destination (Join-Path $DestinationRoot 'scripts') -Recurse -Force

    foreach ($fileName in @('LICENSE', 'THIRD_PARTY_NOTICES.md', 'install.ps1', 'install.sh')) {
        $sourcePath = Join-Path $SourceRoot $fileName
        if (Test-Path -LiteralPath $sourcePath) {
            Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $DestinationRoot $fileName) -Force
        }
    }
}

function Install-CherryApplication {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [switch]$ReplaceUnrecognizedDirectory
    )

    $parent = Split-Path -Parent $DestinationRoot
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "无效的安装目录：$DestinationRoot"
    }
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    if (Test-Path -LiteralPath $DestinationRoot) {
        $installedEntry = Join-Path $DestinationRoot 'cherry.ps1'
        if (-not (Test-Path -LiteralPath $installedEntry) -and -not $ReplaceUnrecognizedDirectory) {
            throw "安装目录已存在且不属于 Cherry Studio CLI：$DestinationRoot。确认替换后请追加 -Force。"
        }
    }

    $stagingRoot = Join-Path $parent ('.cherry-studio-cli-staging-' + [Guid]::NewGuid().ToString('N'))
    $backupRoot = Join-Path $parent ('.cherry-studio-cli-backup-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    try {
        Copy-CherryApplicationFiles -SourceRoot $SourceRoot -DestinationRoot $stagingRoot
        if (-not (Test-Path -LiteralPath (Join-Path $stagingRoot 'cherry.ps1'))) {
            throw '安装暂存目录校验失败。'
        }

        if (Test-Path -LiteralPath $DestinationRoot) {
            Move-Item -LiteralPath $DestinationRoot -Destination $backupRoot -Force
        }

        try {
            Move-Item -LiteralPath $stagingRoot -Destination $DestinationRoot -Force
        }
        catch {
            if (-not (Test-Path -LiteralPath $DestinationRoot) -and (Test-Path -LiteralPath $backupRoot)) {
                Move-Item -LiteralPath $backupRoot -Destination $DestinationRoot -Force
            }
            throw
        }

        if (Test-Path -LiteralPath $backupRoot) {
            Remove-Item -LiteralPath $backupRoot -Recurse -Force
        }
    }
    finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force
        }
    }
}

function New-CherryLauncher {
    param(
        [Parameter(Mandatory)][string]$LauncherDirectory,
        [Parameter(Mandatory)][string]$PowerShellExecutable,
        [Parameter(Mandatory)][string]$ApplicationDirectory,
        [switch]$ReplaceExistingLauncher
    )

    New-Item -ItemType Directory -Path $LauncherDirectory -Force | Out-Null
    $launcherPath = Join-Path $LauncherDirectory 'cherry.cmd'
    if (Test-Path -LiteralPath $launcherPath) {
        $existingContent = Get-Content -LiteralPath $launcherPath -Raw
        if ($existingContent -notmatch '(?i)cherry\.ps1' -and -not $ReplaceExistingLauncher) {
            throw "已存在非 Cherry Studio CLI 的命令启动器：$launcherPath。确认替换后请追加 -Force。"
        }
    }

    $scriptPath = Join-Path $ApplicationDirectory 'cherry.ps1'
    $escapedPowerShell = $PowerShellExecutable.Replace('"', '""')
    $escapedScript = $scriptPath.Replace('"', '""')
    $lines = @(
        '@echo off',
        ('"' + $escapedPowerShell + '" -NoLogo -NoProfile -File "' + $escapedScript + '" %*'),
        'exit /b %ERRORLEVEL%',
        ''
    )
    $content = [string]::Join([Environment]::NewLine, $lines)
    [System.IO.File]::WriteAllText($launcherPath, $content, [System.Text.Encoding]::Default)
    return $launcherPath
}

function Test-PathEntry {
    param(
        [AllowNull()][string]$PathValue,
        [Parameter(Mandatory)][string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $false
    }

    $normalizedCandidate = $Candidate.TrimEnd('\')
    foreach ($entry in @($PathValue -split ';')) {
        if ($entry.Trim().TrimEnd('\') -ieq $normalizedCandidate) {
            return $true
        }
    }
    return $false
}

function Add-CherryBinToPath {
    param([Parameter(Mandatory)][string]$LauncherDirectory)

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (Test-PathEntry -PathValue $userPath -Candidate $LauncherDirectory)) {
        $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
            $LauncherDirectory
        }
        else {
            $userPath.TrimEnd(';') + ';' + $LauncherDirectory
        }
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    }

    if (-not (Test-PathEntry -PathValue $env:Path -Candidate $LauncherDirectory)) {
        $env:Path = $env:Path.TrimEnd(';') + ';' + $LauncherDirectory
    }
}

$userHome = Get-CherryUserHome
if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
    $localApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localApplicationData)) {
        $localApplicationData = Join-Path $userHome 'AppData\Local'
    }
    $InstallDirectory = Join-Path $localApplicationData 'Programs\CherryStudioCLI'
}
if ([string]::IsNullOrWhiteSpace($BinDirectory)) {
    $BinDirectory = Join-Path $userHome '.local\bin'
}

$InstallDirectory = [System.IO.Path]::GetFullPath($InstallDirectory)
$BinDirectory = [System.IO.Path]::GetFullPath($BinDirectory)

$powerShellExecutable = Find-PowerShell7
if ($null -eq $powerShellExecutable) {
    if ($SkipPowerShellInstall) {
        throw '未检测到 PowerShell 7。请先安装后再重试。'
    }
    Install-PowerShell7
    $powerShellExecutable = Find-PowerShell7
}
if ($null -eq $powerShellExecutable) {
    throw 'PowerShell 7 安装完成后仍未找到 pwsh.exe。请重新打开终端后再运行安装器。'
}

$source = $null
try {
    $localSourceRoot = Get-LocalSourceRoot
    if ($null -ne $localSourceRoot) {
        Write-Output "正在从本地源码安装 Cherry Studio CLI：$localSourceRoot"
        $source = [PSCustomObject]@{
            Root = $localSourceRoot
            TemporaryRoot = $null
        }
    }
    else {
        $source = Get-RemoteSource -OwnerAndRepository $Repository -Revision $Ref
    }

    Install-CherryApplication -SourceRoot $source.Root -DestinationRoot $InstallDirectory -ReplaceUnrecognizedDirectory:$Force
    $launcherPath = New-CherryLauncher -LauncherDirectory $BinDirectory -PowerShellExecutable $powerShellExecutable -ApplicationDirectory $InstallDirectory -ReplaceExistingLauncher:$Force
    if (-not $NoPathUpdate) {
        Add-CherryBinToPath -LauncherDirectory $BinDirectory
    }

    Write-Output "Cherry Studio CLI 已安装到：$InstallDirectory"
    Write-Output "命令启动器：$launcherPath"
    Write-Output '可运行 cherry help 查看命令。使用模型前，请先在 Cherry Studio 中启动 API Server 并配置 CHERRY_STUDIO_API_KEY。'
}
finally {
    if ($null -ne $source -and -not [string]::IsNullOrWhiteSpace($source.TemporaryRoot) -and (Test-Path -LiteralPath $source.TemporaryRoot)) {
        Remove-Item -LiteralPath $source.TemporaryRoot -Recurse -Force
    }
}
