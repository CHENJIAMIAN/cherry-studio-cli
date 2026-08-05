[CmdletBinding()]
param(
    [string]$BinDirectory = (Join-Path $env:USERPROFILE '.local\bin'),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($null -eq (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    throw 'PowerShell 7 (pwsh) is required.'
}

$scriptPath = Join-Path $PSScriptRoot 'cherry.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Cherry CLI entry script was not found: $scriptPath"
}

New-Item -ItemType Directory -Path $BinDirectory -Force | Out-Null
$launcherPath = Join-Path $BinDirectory 'cherry.cmd'
if ((Test-Path -LiteralPath $launcherPath) -and -not $Force) {
    throw "Launcher already exists: $launcherPath. Re-run with -Force to replace it."
}

$escapedScriptPath = $scriptPath.Replace('"', '""')
$launcherLines = @(
    '@echo off',
    ('pwsh -NoLogo -NoProfile -File "' + $escapedScriptPath + '" %*'),
    'exit /b %ERRORLEVEL%',
    ''
)
$launcher = [string]::Join([Environment]::NewLine, $launcherLines)
[System.IO.File]::WriteAllText($launcherPath, $launcher, [System.Text.ASCIIEncoding]::new())

$pathEntries = @($env:PATH -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$inPath = $pathEntries | Where-Object { $_.TrimEnd('\') -ieq $BinDirectory.TrimEnd('\') } | Select-Object -First 1

Write-Output "Installed launcher: $launcherPath"
if ($null -eq $inPath) {
    Write-Warning "$BinDirectory is not on PATH in this session. Add it to your user PATH, then open a new terminal."
}
