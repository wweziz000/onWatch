#Requires -Version 5.1
<#
Place this file in the onWatch repository root.
Builds the existing browser-dashboard + Windows tray application; not an installer.
Windows-only checks run here. Full race-enabled tests run in windows-build.yml.
Based on onllm-dev/onWatch build files inspected at commit d8309522f3419d66030aed73fbe895b9eea6fb08.
This helper has not been executed on Windows; a successful CI run is required.
Never include .env, auth.json, databases, or account tokens in a release artifact.
#>
[CmdletBinding()]
param(
    [ValidateSet('amd64', 'arm64')]
    [string]$Architecture = 'amd64',
    [string]$ProjectRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [string[]]$Arguments = @()
    )
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Tool failed with exit code $LASTEXITCODE. Build stopped."
    }
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Run this script on Windows, or use the supplied GitHub Actions workflow.'
}
foreach ($tool in @('go', 'git')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Missing $tool. Install it and open a new PowerShell window."
    }
}
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
foreach ($file in @('go.mod', 'go.sum', 'VERSION', 'LICENSE', 'cmd/onwatch/main.go')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $file))) {
        throw "Missing $file. Place build-windows.ps1 in the onWatch repository root."
    }
}

$savedEnvironment = @{}
foreach ($name in @('GOOS', 'GOARCH', 'CGO_ENABLED')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

Push-Location -LiteralPath $root
try {
    $baseVersion = (Get-Content -LiteralPath 'VERSION' -Raw).Trim()
    if ($baseVersion -notmatch '^\d+\.\d+\.\d+([+-][0-9A-Za-z.-]+)?$') {
        throw 'Unexpected VERSION value. Review it before building.'
    }
    $commit = ((Invoke-Checked -Tool 'git' -Arguments @('rev-parse', 'HEAD')) -join '').Trim()
    $shortCommit = $commit.Substring(0, 10)
    $dirty = -not [string]::IsNullOrWhiteSpace(
        ((Invoke-Checked -Tool 'git' -Arguments @('status', '--porcelain')) -join "`n")
    )
    $version = "$baseVersion-custom.$shortCommit"
    if ($dirty) { $version += '.dirty' }
    $hostArch = ((Invoke-Checked -Tool 'go' -Arguments @('env', 'GOHOSTARCH')) -join '').Trim()
    $goVersion = ((Invoke-Checked -Tool 'go' -Arguments @('version')) -join '').Trim()

    # Run native Windows checks before selecting a cross-compilation target.
    $env:GOOS = 'windows'
    $env:GOARCH = $hostArch
    $env:CGO_ENABLED = '0'
    Invoke-Checked -Tool 'git' -Arguments @('diff', '--check')
    Invoke-Checked -Tool 'git' -Arguments @('diff', '--cached', '--check')
    Invoke-Checked -Tool 'go' -Arguments @('mod', 'download')
    Invoke-Checked -Tool 'go' -Arguments @('mod', 'verify')
    # Match the upstream Windows CI scope. Full-package vet includes _test.go
    # files with Unix-only references (getCredentialsFilePath and Setsid).
    # Keep full-package vet and the full race suite in the Linux workflow job.
    Write-Host 'Windows scope: vet and test internal/menubar, then build the application.'
    Invoke-Checked -Tool 'go' -Arguments @('vet', '-tags', 'menubar', './internal/menubar')
    Invoke-Checked -Tool 'go' -Arguments @('test', '-tags', 'menubar', '-count=1', './internal/menubar')

    $env:GOARCH = $Architecture
    $outDir = Join-Path $root 'dist'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $binaryName = "onwatch-windows-$Architecture.exe"
    $output = Join-Path $outDir $binaryName
    $ldflags = "-s -w -X main.version=$version"
    Invoke-Checked -Tool 'go' -Arguments @(
        'build', '-trimpath', '-tags', 'menubar', '-ldflags', $ldflags,
        '-o', $output, './cmd/onwatch'
    )
    if (-not (Test-Path -LiteralPath $output)) {
        throw 'Go returned success but the expected executable was not found.'
    }

    Copy-Item -LiteralPath 'LICENSE' -Destination (Join-Path $outDir 'LICENSE') -Force
    $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $binaryName" | Set-Content -LiteralPath (Join-Path $outDir "SHA256SUMS-windows-$Architecture.txt") -Encoding Ascii
    [ordered]@{
        version = $version
        source_commit = $commit
        working_tree_dirty = $dirty
        target = "windows/$Architecture"
        go_version = $goVersion
        built_at_utc = [DateTime]::UtcNow.ToString('o')
        build_tags = @('menubar')
        tests_here = 'Windows internal/menubar vet and tests only; full-package vet and full race suite are required in the Linux CI job.'
        binary_sha256 = $hash
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outDir "build-info-windows-$Architecture.json") -Encoding UTF8

    Write-Host "Built: $output"
    Write-Host "Version: $version"
    Write-Host 'This is a development EXE, not a signed installer.'
    Write-Host 'Require the full GitHub Actions test job to pass before distributing a release.'
}
finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    Pop-Location
}
