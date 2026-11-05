param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [ValidateSet('none', 'win-x64', 'win-arm64')][string]$Runtime = 'none',
    [string]$OutputDirectory = ''
)
$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
if ($OutputDirectory) {
    # Resolve relative output paths before changing the native-command working directory.
    $OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
}
Push-Location -LiteralPath $projectRoot
try {
    & dotnet restore (Join-Path $projectRoot 'ImageAgent.sln')
    if ($LASTEXITCODE -ne 0) { throw 'NuGet restore failed.' }
    & dotnet test (Join-Path $projectRoot 'ImageAgent.sln') -c $Configuration --no-restore
    if ($LASTEXITCODE -ne 0) { throw 'Parity tests failed.' }
    & dotnet build (Join-Path $projectRoot 'ImageAgent.Desktop/ImageAgent.Desktop.csproj') -c $Configuration --no-restore
    if ($LASTEXITCODE -ne 0) { throw 'Desktop build failed.' }
    & dotnet build (Join-Path $projectRoot 'ImageAgent.Diagnostics/ImageAgent.Diagnostics.csproj') -c $Configuration --no-restore
    if ($LASTEXITCODE -ne 0) { throw 'Diagnostics build failed.' }
    if ($Runtime -ne 'none') {
        if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot "../dist/windows/$Runtime" }
        & dotnet publish (Join-Path $projectRoot 'ImageAgent.Desktop/ImageAgent.Desktop.csproj') -c $Configuration -r $Runtime --self-contained true -p:PublishSingleFile=false -o $OutputDirectory
        if ($LASTEXITCODE -ne 0) { throw 'Self-contained publish failed.' }
        & dotnet publish (Join-Path $projectRoot 'ImageAgent.Diagnostics/ImageAgent.Diagnostics.csproj') -c $Configuration -r $Runtime --self-contained true -p:PublishSingleFile=false -o $OutputDirectory
        if ($LASTEXITCODE -ne 0) { throw 'Diagnostics self-contained publish failed.' }
        if (Test-Path (Join-Path $OutputDirectory 'ImageAgent.preview.json')) { throw 'Preview sidecar must not ship in Windows releases.' }
    }
} finally {
    Pop-Location
}
