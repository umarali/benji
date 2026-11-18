#!/usr/bin/env python3
"""Offline arm64 distribution assembly. Consumes explicitly pre-provisioned pinned files.

This candidate signs ad hoc only. Developer ID and notarisation remain owner release work.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def digest_check(path, expected):
    if sha(path) != expected:
        raise ValueError(f'pinned SHA-256 mismatch: {path.name}')


def unpack(archive, destination):
    # The compressed input has been pinned before invoking even the decompressor.
    tar = destination / 'runtime.tar'
    with tar.open('wb') as out:
        run('zstd', '-dc', archive, stdout=out)
    with tarfile.open(tar) as stream:
        members = stream.getmembers()
        if len(members) > 100000 or sum(m.size for m in members) > 2_000_000_000:
            raise ValueError('runtime archive exceeds reviewed bounds')
        for member in members:
            if member.name.startswith('/') or '..' in Path(member.name).parts:
                raise ValueError('unsafe archive path')
            tarfile.data_filter(member, destination)
        stream.extractall(destination, filter='data')
    tar.unlink()


def code_inventory(app):
    out = []
    for file in sorted(app.rglob('*')):
        if file.is_symlink() or not file.is_file():
            continue
        with file.open('rb') as stream:
            magic = stream.read(4)
        if magic not in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe'):
            continue
        arch = subprocess.check_output(['/usr/bin/lipo', '-archs', str(file)], text=True).strip()
        if arch != 'arm64':
            raise ValueError(f'unexpected architecture: {file}: {arch}')
        commands = subprocess.check_output(['/usr/bin/otool', '-l', str(file)], text=True)
        minima = re.findall(r'\bminos (\d+\.\d+)', commands) or re.findall(r'\bversion (\d+\.\d+)\n\s+sdk', commands)
        if not minima or any(tuple(map(int, v.split('.'))) > (14, 0) for v in minima):
            raise ValueError(f'unreviewed minimum macOS: {file}: {minima}')
        deps = subprocess.check_output(['/usr/bin/otool', '-L', str(file)], text=True)
        rpaths = re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset', commands)
        for dependency in re.findall(r'\n\s+(.*?) \(compatibility', deps):
            # A dylib's LC_ID_DYLIB is its own install name, not a loaded dependency.
            if file.suffix == '.dylib' and Path(dependency).name == file.name:
                continue
            if dependency.startswith(('/usr/lib/', '/System/Library/')):
                continue
            def expand(value):
                return Path(value.replace('@loader_path', str(file.parent)).replace('@executable_path', str(app / 'Contents/MacOS'))).resolve()
            candidates = ([expand(r + dependency[len('@rpath'):]) for r in rpaths] if dependency.startswith('@rpath/') else [expand(dependency)])
            if not any(p.is_relative_to(app) and p.is_file() for p in candidates):
                raise ValueError(f'external/unresolved load path: {file}: {dependency}')
        out.append({'path': str(file.relative_to(app)), 'architecture': arch, 'minimum_macos': minima,
                    'load_commands': commands, 'dependencies': deps, 'before_signing_sha256': sha(file)})
    return out


def trim_static_python(prefix):
    """These archives link new executables, never the shipped interpreter or extension modules."""
    for name in ('lib/libpython3.12.a', 'lib/python3.12/config-3.12-darwin/libpython3.12.a'):
        (prefix / name).unlink()  # Exact pinned payload only; retain headers, stdlib and notices.


def source_provenance():
    # Scratch/exported sources have no Git identity. Do not mistake a containing repo for ours.
    if not (ROOT / '.git').exists():
        return {'head': None, 'dirty': None, 'kind': 'exported-source'}
    head = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = bool(subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain'], text=True).strip())
    return {'head': head, 'dirty': dirty, 'kind': 'git-checkout'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-archive', type=Path, required=True)
    parser.add_argument('--ca-bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='new empty build directory, outside the source tree')
    parser.add_argument('--source-commit', required=True, help='base commit for this candidate; local diff is recorded separately')
    parser.add_argument('--identity', required=True, choices=['-'], help='explicit ad-hoc only; no identity discovery')
    args = parser.parse_args()
    lock = json.loads((HERE / 'runtime.lock.json').read_text())
    digest_check(args.runtime_archive, lock['runtime']['sha256'])
    digest_check(args.ca_bundle, lock['ca']['sha256'])
    digest_check(HERE / 'notices/MPL-2.0.txt', lock['ca']['license_sha256'])
    output = args.output.resolve()
    if output.exists() or output.is_relative_to(ROOT):
        raise ValueError('output must be a new directory outside the source tree')
    output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='benji-runtime-', dir=output) as td:
        td = Path(td)
        unpack(args.runtime_archive, td)
        python = td / 'python'
        metadata = json.loads((python / 'PYTHON.json').read_text())
        if (metadata['python_version'], metadata['target_triple'], metadata['python_exe']) != (lock['runtime']['python'], lock['runtime']['target'], 'install/bin/python3.12'):
            raise ValueError('runtime metadata disagrees with pin')
        # Require every metadata-referenced licence and preserve all upstream notices.
        licence_paths = {metadata['license_path']}
        for variants in metadata['build_info']['extensions'].values():
            for variant in variants:
                licence_paths.update(variant.get('license_paths', []))
        for path in licence_paths:
            if not (python / path).resolve().is_relative_to(python) or not (python / path).is_file():
                raise ValueError('missing runtime licence: ' + path)
        build = output / 'swift-build'
        run('xcrun', 'swift', 'build', '-c', 'release', '--arch', 'arm64', '-Xswiftc', '-DBENJI_DISTRIBUTION', '--scratch-path', build, cwd=ROOT / 'companion')
        app = output / 'Benji.app'
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        shutil.copy2(build / 'arm64-apple-macosx/release/BenjiApp', contents / 'MacOS/Benji')
        resources = contents / 'Resources'; resources.mkdir()
        for name in ('Assets.car', 'AppIcon.icns', 'MenuBarGlyph.svg', 'MenuBarGlyphWorking.svg', 'Fonts', 'Cues'):
            path = ROOT / 'companion/Resources' / name
            if path.is_dir(): shutil.copytree(path, resources / name)
            elif path.is_file(): shutil.copy2(path, resources / name)
        engine = resources / 'engine'; engine.mkdir()
        for name in ('benji', 'skills', 'browser-extension'):
            shutil.copytree(ROOT / name, engine / name, ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '.DS_Store', 'test'))
        shutil.copy2(HERE / 'bootstrap.py', engine / 'bootstrap.py')
        trust = resources / 'trust'; trust.mkdir(); shutil.copy2(args.ca_bundle, trust / 'cacert.pem')
        notices = resources / 'Notices'; notices.mkdir()
        shutil.copytree(python / 'licenses', notices / 'Python')
        shutil.copy2(python / 'PYTHON.json', notices / 'PYTHON.json')
        shutil.copy2(ROOT / 'LICENSE', notices / 'Benji-LICENSE.txt')
        shutil.copy2(HERE / 'notices/MPL-2.0.txt', notices / 'Mozilla-MPL-2.0.txt')
        shutil.copy2(HERE / 'notices/README.txt', notices / 'README.txt')
        framework = contents / 'Frameworks/BenjiPython.framework'; prefix = framework / 'Versions/A'
        prefix.parent.mkdir(parents=True)
        shutil.copytree(python / 'install', prefix, symlinks=True)
        trim_static_python(prefix)
        # codesign requires a regular principal executable in Versions/A, not a symlink.
        (prefix / 'bin/python3.12').rename(prefix / 'BenjiPython')
        (prefix / 'bin/python3.12').symlink_to('../BenjiPython')
        (prefix / 'Resources').mkdir()
        (prefix / 'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'BenjiPython', 'CFBundleIdentifier': 'com.emerssive.heybenji.python', 'CFBundleName': 'BenjiPython', 'CFBundlePackageType': 'FMWK', 'CFBundleVersion': lock['runtime']['python']}))
        (framework / 'Versions/Current').symlink_to('A')
        (framework / 'BenjiPython').symlink_to('Versions/Current/BenjiPython')
        (framework / 'Resources').symlink_to('Versions/Current/Resources')
        info = {'CFBundleExecutable': 'Benji', 'CFBundleIdentifier': 'com.emerssive.heybenji.app', 'CFBundleName': 'Benji', 'CFBundleDisplayName': 'Benji', 'CFBundleIconFile': 'AppIcon', 'CFBundleIconName': 'AppIcon', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '0.1.0', 'LSMinimumSystemVersion': '14.0', 'LSUIElement': True, 'NSHighResolutionCapable': True,
                'NSMicrophoneUsageDescription': 'Benji listens through the microphone only while you hold the talk key, or while you have a hands-free conversation open. Your voice is turned into text on this Mac.',
                'NSAppleEventsUsageDescription': 'Benji runs AppleScript tasks you ask for, and controls an app only after you approve the task.',
                'NSSpeechRecognitionUsageDescription': 'Benji transcribes what you say on this Mac (on-device) so it can act on your spoken request.'}
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        inventory = code_inventory(app)
        for item in inventory:
            run('/usr/bin/codesign', '--force', '--sign', '-', app / item['path'], capture_output=True)
        run('/usr/bin/codesign', '--force', '--sign', '-', framework, capture_output=True)
        for item in inventory: item['signed_sha256'] = sha(app / item['path'])
        (output / 'macho-inventory.json').write_text(json.dumps(inventory, indent=2) + '\n')
        # All runtime aliases and code/assets are checked, including symlink targets.
        files = {str(f.relative_to(app)): sha(f) for f in sorted(app.rglob('*')) if f.is_file() and '_CodeSignature' not in f.parts and f != contents / 'MacOS/Benji'}
        source_files = {str(f.relative_to(ROOT)): sha(f) for n in ('benji', 'skills', 'browser-extension', 'companion/Sources', 'companion/distribution', 'companion/Resources') for f in sorted((ROOT / n).rglob('*')) if f.is_file() and '__pycache__' not in f.parts and f.suffix != '.pyc'}
        for name in ('companion/build.sh', 'companion/Package.swift', 'LICENSE'):
            source_files[name] = sha(ROOT / name)
        source_digest = hashlib.sha256(json.dumps(source_files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        manifest = {'schema': 1, 'architecture': 'arm64', 'python': lock['runtime']['python'], 'claimed_source_commit': args.source_commit, 'source_provenance': source_provenance(), 'source_tree_sha256': source_digest, 'upstream': lock,
                    'modifications': ['Unused static libpython archive and its alias removed; headers, runtime modules and notices retained.', 'Principal executable moved from bin/python3.12 to BenjiPython; bin alias retained.', 'Every Mach-O signed ad hoc inside out; no Developer ID or hardened-runtime claim.'], 'files': files}
        (resources / 'distribution.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        (output / 'source-files.json').write_text(json.dumps(source_files, indent=2, sort_keys=True) + '\n')
        run('/usr/bin/codesign', '--force', '--sign', '-', app, capture_output=True)
        verify = run('/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=4', app, capture_output=True, text=True)
        (output / 'strict-verify.txt').write_text(verify.stdout + verify.stderr)
        print(app)


if __name__ == '__main__':
    main()
