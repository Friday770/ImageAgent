param(
    [Parameter(Mandatory = $true)][string]$AppDirectory,
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [string]$ReportDirectory = (Join-Path $env:TEMP ('ImageAgent-Verify-' + [guid]::NewGuid().ToString('N')))
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path $AppDirectory).Path
$exe = Join-Path $root 'ImageAgent.exe'
if (-not (Test-Path $exe)) { throw 'ImageAgent.exe is missing.' }
if (Test-Path (Join-Path $root 'ImageAgent.preview.json')) { throw 'A demo preview sidecar is present in the production package.' }
$expectedMachine = if ($Runtime -eq 'win-arm64') { 0xAA64 } else { 0x8664 }
$bytes = [IO.File]::ReadAllBytes($exe)
$pe = [BitConverter]::ToInt32($bytes, 0x3c)
if ([Text.Encoding]::ASCII.GetString($bytes, $pe, 4) -ne "PE`0`0" -or [BitConverter]::ToUInt16($bytes, $pe + 4) -ne $expectedMachine) { throw 'Executable PE architecture does not match the selected runtime.' }
$runtimeConfig = Get-Content (Join-Path $root 'ImageAgent.runtimeconfig.json') -Raw | ConvertFrom-Json
if (-not $runtimeConfig.runtimeOptions.includedFrameworks) { throw 'The package is not self-contained.' }
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null
$quotedReport = '"' + $ReportDirectory.Replace('"', '\"') + '"'
$process = Start-Process -FilePath $exe -ArgumentList @('--self-test', '--output', $quotedReport) -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "ImageAgent self-test exited with code $($process.ExitCode). Report: $ReportDirectory" }
$report = Get-Content (Join-Path $ReportDirectory 'self-test.json') -Raw | ConvertFrom-Json
if (-not $report.passed -or $report.network.realRequests -ne 0) { throw 'The isolated self-test failed or used a real network service.' }
if (-not $report.windowsCredentialManager.passed) { throw 'The unique synthetic Windows credential roundtrip did not pass.' }
Write-Output ('PASS: ' + $Runtime + '. Self-test report: ' + (Join-Path $ReportDirectory 'self-test.json'))
