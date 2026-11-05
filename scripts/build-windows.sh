#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
project_root="$PWD"
dotnet_command="${IMAGEAGENT_DOTNET:-}"
if [[ -z "$dotnet_command" ]]; then
  dotnet_command="$(command -v dotnet || true)"
fi
if [[ -z "$dotnet_command" && -x "$project_root/artifacts/windows-tools/dotnet/dotnet" ]]; then
  dotnet_command="$project_root/artifacts/windows-tools/dotnet/dotnet"
fi
if [[ -z "$dotnet_command" ]]; then
  echo 'Install the .NET 10 SDK or set IMAGEAGENT_DOTNET to its dotnet executable.' >&2
  exit 1
fi
dotnet_command="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dotnet_command")"
export DOTNET_ROOT="$(dirname "$dotnet_command")"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
run_dotnet() {
  (
    cd "$project_root/windows"
    "$dotnet_command" "$@"
  )
}
runtimes=(win-x64 win-arm64)
run_tests=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tests) run_tests=false; shift ;;
    --rid) runtimes=("$2"); shift 2 ;;
    --help) echo 'Usage: scripts/build-windows.sh [--skip-tests] [--rid win-x64|win-arm64]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
if [[ "$run_tests" == true ]]; then
  run_dotnet test ImageAgent.sln -c Release
fi
mkdir -p "$project_root/dist/windows" "$project_root/artifacts/windows-publish"
for runtime in "${runtimes[@]}"; do
  if [[ "$runtime" != win-x64 && "$runtime" != win-arm64 ]]; then echo 'Invalid Windows runtime.' >&2; exit 1; fi
  payload="$project_root/artifacts/windows-publish/$runtime"
  run_dotnet publish ImageAgent.Desktop/ImageAgent.Desktop.csproj -c Release -r "$runtime" --self-contained true -p:PublishTrimmed=false -p:PublishSingleFile=false -p:DebugType=None -p:DebugSymbols=false -o "$payload"
  run_dotnet publish ImageAgent.Diagnostics/ImageAgent.Diagnostics.csproj -c Release -r "$runtime" --self-contained true -p:PublishTrimmed=false -p:PublishSingleFile=false -p:DebugType=None -p:DebugSymbols=false -o "$payload"
  python3 scripts/windows/package-windows.py --publish "$payload" --rid "$runtime" --output "$project_root/dist/windows"
done
python3 - <<'PY'
from pathlib import Path
import hashlib, shutil, tempfile, zipfile
root = Path.cwd(); output = root / 'dist/windows'
with tempfile.TemporaryDirectory(prefix='.source-', dir=output) as temporary:
    stage = Path(temporary) / 'ImageAgent-Windows'; stage.mkdir()
    shutil.copytree(root / 'windows', stage / 'windows', ignore=shutil.ignore_patterns('bin', 'obj', 'TestResults', '.vs', '*.preview.json', '*.sqlite', '*.sqlite-wal', '*.sqlite-shm', '.env', '.env.*'))
    shutil.copytree(root / 'scripts/windows', stage / 'scripts/windows', ignore=shutil.ignore_patterns('__pycache__'))
    shutil.copy2(root / 'scripts/build-windows.sh', stage / 'scripts/build-windows.sh')
    for name in ['.gitignore', '.gitattributes']:
        shutil.copy2(root / name, stage / name)
    archive = output / 'ImageAgent-Windows-source.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as target:
        for path in sorted(stage.rglob('*')):
            if path.is_file(): target.write(path, path.relative_to(stage.parent).as_posix())
    with zipfile.ZipFile(archive) as target:
        assert target.testzip() is None
files = sorted(p for p in output.iterdir() if p.is_file() and p.suffix in ['.zip', '.exe'])
with (output / 'SHA256SUMS.txt').open('w') as checksums:
    for path in files:
        digest = hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()
        checksums.write(f'{digest}  {path.name}\n')
print('Windows release:', output)
PY
