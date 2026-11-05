#!/usr/bin/env python3
"""Validate and package a self-contained Windows publish without executing Windows code."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zipfile


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def machine(path: Path) -> int:
    with path.open('rb') as stream:
        if stream.read(2) != b'MZ':
            raise ValueError(f'Not a Windows PE: {path.name}')
        stream.seek(0x3c)
        offset = struct.unpack('<I', stream.read(4))[0]
        stream.seek(offset)
        if stream.read(4) != b'PE\0\0':
            raise ValueError(f'Invalid PE signature: {path.name}')
        return struct.unpack('<H', stream.read(2))[0]


def native_dll(path: Path) -> bool:
    with path.open('rb') as stream:
        if stream.read(2) != b'MZ':
            raise ValueError(f'Not a Windows PE: {path.name}')
        stream.seek(0x3c)
        offset = struct.unpack('<I', stream.read(4))[0] + 24
        stream.seek(offset)
        magic = struct.unpack('<H', stream.read(2))[0]
        if magic not in (0x10b, 0x20b):
            raise ValueError(f'Invalid PE optional header: {path.name}')
        stream.seek(offset + (112 if magic == 0x20b else 96) + 14 * 8)
        return struct.unpack('<I', stream.read(4))[0] == 0


def validate(publish: Path, rid: str) -> dict:
    expected = 0xAA64 if rid == 'win-arm64' else 0x8664
    required = ['ImageAgent.exe', 'ImageAgent.dll', 'ImageAgent.Core.dll', 'ImageAgent.deps.json', 'ImageAgent.runtimeconfig.json', 'ImageAgentDiagnostics.exe', 'ImageAgentDiagnostics.dll', 'ImageAgentDiagnostics.deps.json', 'ImageAgentDiagnostics.runtimeconfig.json', 'coreclr.dll', 'hostfxr.dll', 'hostpolicy.dll', 'libSkiaSharp.dll', 'libHarfBuzzSharp.dll', 'e_sqlite3.dll']
    for name in required:
        if not (publish / name).is_file():
            raise ValueError(f'Missing standalone runtime component: {name}')
    native = ['ImageAgent.exe', 'ImageAgentDiagnostics.exe', 'coreclr.dll', 'hostfxr.dll', 'hostpolicy.dll', 'av_libglesv2.dll', 'libSkiaSharp.dll', 'libHarfBuzzSharp.dll', 'e_sqlite3.dll']
    native = sorted(set(native) | {path.name for path in publish.glob('*.dll') if native_dll(path)})
    for name in native:
        if machine(publish / name) != expected:
            raise ValueError(f'Wrong {rid} architecture: {name}')
    for name in ['ImageAgent', 'ImageAgentDiagnostics']:
        config = json.loads((publish / f'{name}.runtimeconfig.json').read_text())['runtimeOptions']
        if not config.get('includedFrameworks') or config.get('framework') or config.get('frameworks'):
            raise ValueError(f'Runtime is not fully bundled: {name}')
    for path in publish.rglob('*'):
        if path.is_symlink():
            raise ValueError('Release payload contains a symlink')
        name = path.name.lower()
        if name.endswith(('.sqlite', '.sqlite-wal', '.sqlite-shm')) or name.startswith('.env') or name == 'imageagent.preview.json' or name == 'offline-credential-markers.json':
            raise ValueError(f'Private/demo data in release: {path.name}')
    return {'runtime': rid, 'nativeMachine': hex(expected), 'selfContained': True, 'nativeComponentsVerified': native, 'previewSidecarAbsent': True}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--publish', type=Path, required=True)
    parser.add_argument('--rid', choices=['win-x64', 'win-arm64'], required=True)
    parser.add_argument('--output', type=Path, default=Path('dist/windows'))
    parser.add_argument('--version', default='1.5.0')
    parser.add_argument('--build', type=int, default=8)
    parser.add_argument('--makensis', default=shutil.which('makensis'))
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[2]
    publish = args.publish.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    verification = validate(publish, args.rid)
    if not args.makensis:
        raise RuntimeError('makensis is required to create the Windows installer')
    architecture = args.rid.removeprefix('win-')
    portable = output / f'ImageAgent-{args.version}-windows-{architecture}.zip'
    installer = output / f'ImageAgent-{args.version}-windows-{architecture}-Setup.exe'
    with tempfile.TemporaryDirectory(prefix='.package-', dir=output) as temporary:
        folder = Path(temporary) / f'ImageAgent-windows-{architecture}'
        shutil.copytree(publish, folder, ignore=shutil.ignore_patterns('*.pdb', '*.dbg'))
        shutil.copy2(project / 'windows/README.md', folder / '使用说明.md')
        shutil.copy2(project / 'scripts/windows/verify-windows.ps1', folder / 'Verify-Windows.ps1')
        notices = project / 'windows/licenses'
        if notices.is_dir():
            shutil.copytree(notices, folder / 'licenses', dirs_exist_ok=True)
        info = {'application': 'ImageAgent', 'version': args.version, 'build': args.build, 'runtime': args.rid, 'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=project, text=True).strip(), 'selfContained': True, 'windowsRuntimeExecution': 'not executed on the macOS build host', 'authenticodeSigned': False}
        (folder / 'BUILDINFO.json').write_text(json.dumps(info, ensure_ascii=False, indent=2) + '\n')
        files = sorted(path for path in folder.rglob('*') if path.is_file())
        (folder / 'SHA256SUMS.txt').write_text(''.join(f'{sha256(path)}  {path.relative_to(folder).as_posix()}\n' for path in files))
        files = sorted(path for path in folder.rglob('*') if path.is_file())
        with zipfile.ZipFile(portable, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for path in files:
                archive.write(path, path.relative_to(folder.parent).as_posix())
        with zipfile.ZipFile(portable) as archive:
            if archive.testzip() is not None:
                raise RuntimeError('Portable ZIP integrity check failed')
        uninstall = Path(temporary) / 'uninstall-files.nsh'
        def nsis_escape(value: str) -> str:
            return value.replace('$', '$$').replace('"', '$\\"')
        lines = [f'Delete "$INSTDIR\\{nsis_escape(path.relative_to(folder).as_posix().replace(chr(47), chr(92)))}"' for path in files]
        directories = sorted((path for path in folder.rglob('*') if path.is_dir()), key=lambda p: len(p.parts), reverse=True)
        lines += [f'RMDir "$INSTDIR\\{nsis_escape(path.relative_to(folder).as_posix().replace(chr(47), chr(92)))}"' for path in directories]
        uninstall.write_text('\n'.join(lines) + '\n', encoding='utf-8-sig')
        quad = '.'.join(args.version.split('.')[:3] + [str(args.build)])
        command = [str(args.makensis), '-V2', f'-DAPP_VERSION={args.version}', f'-DVERSION_QUAD={quad}', f'-DAPP_RID={args.rid}', f'-DPAYLOAD_DIR={folder}', f'-DOUTPUT_EXE={installer}', f'-DICON_FILE={project / "windows/ImageAgent.Desktop/Assets/AppIcon.ico"}', f'-DUNINSTALL_INCLUDE={uninstall}', f'-DESTIMATED_SIZE_KB={sum(p.stat().st_size for p in files) // 1024}', str(project / 'windows/Installer/ImageAgent.nsi')]
        subprocess.run(command, check=True, cwd=project)
        machine(installer)
    record = dict(verification, version=args.version, build=args.build, portable=portable.name, installer=installer.name, portableSHA256=sha256(portable), installerSHA256=sha256(installer), portableBytes=portable.stat().st_size, installerBytes=installer.stat().st_size, authenticodeSigned=False, windowsNativeExecution='not-run-on-macOS')
    (output / f'{args.rid}-manifest.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(record, ensure_ascii=False))


if __name__ == '__main__':
    main()
