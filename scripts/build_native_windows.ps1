param([switch]$Launch, [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release', [string]$Python = 'python')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Push-Location $repo
try {
    & $Python scripts/sync_native_design.py --check
    if ($LASTEXITCODE -ne 0) { throw 'Native design assets are stale.' }
    cargo build --locked -p wisp-service
    if ($LASTEXITCODE -ne 0) { throw 'Rust query service build failed.' }
    $output = Join-Path $repo 'target/native-windows'
    dotnet publish apps/windows/Wisp.Science.Preview -c $Configuration -p:Platform=x64 -o $output
    if ($LASTEXITCODE -ne 0) { throw 'WinUI preview build failed.' }
    Copy-Item -LiteralPath (Join-Path $repo 'target/debug/wisp-service.exe') -Destination $output
    Write-Host "Native Windows preview: $output/Wisp.Science.Preview.exe"
    if ($Launch) { Start-Process -FilePath (Join-Path $output 'Wisp.Science.Preview.exe') }
} finally { Pop-Location }
