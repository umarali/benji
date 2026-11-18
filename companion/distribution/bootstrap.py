"""Trusted isolated entry point. Never accepts an import root or a module name."""
import hashlib
import json
import os
from pathlib import Path
import runpy
import sys


def main():
    root = Path(__file__).resolve().parent
    contents = root.parent.parent
    bundle = contents.parent
    try:
        manifest = json.loads((contents / 'Resources/distribution.json').read_text())
        if manifest['schema'] != 1 or manifest['architecture'] != 'arm64' or manifest['python'] != '3.12.16':
            raise ValueError('unsupported runtime manifest')
        required = {'Contents/Frameworks/BenjiPython.framework/Versions/A/BenjiPython',
                    'Contents/Resources/engine/bootstrap.py', 'Contents/Resources/engine/benji/__main__.py',
                    'Contents/Resources/trust/cacert.pem', 'Contents/Resources/engine/browser-extension/manifest.json',
                    'Contents/Resources/engine/skills/SKILLS.sha256.json'}
        if not required <= manifest['files'].keys():
            raise ValueError('incomplete runtime manifest')
        checked = {}
        for name, digest in manifest['files'].items():
            path = (bundle / name).resolve()
            if name.startswith('/') or '..' in Path(name).parts or not path.is_relative_to(bundle):
                raise ValueError('invalid manifest path')
            # Runtime aliases name the same bytes. Stream each resolved file once per process.
            if path not in checked:
                with path.open('rb') as stream:
                    checked[path] = hashlib.file_digest(stream, 'sha256').hexdigest()
            if checked[path] != digest:
                raise ValueError('bundle checksum mismatch')
        entry = sys.argv.pop(1)
        if entry not in {'engine', 'remote', 'model-setup', 'native-host', 'tts'}:
            raise ValueError('unknown bundled entry point')
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        print('Benji bundled engine is missing or damaged: ' + str(error), file=sys.stderr)
        return 78
    for name in list(os.environ):
        if name.startswith('PYTHON'):
            del os.environ[name]
    os.environ.pop('BENJI_DIR', None)
    os.environ.pop('BENJI_PHONE_DIR', None)
    os.environ['PATH'] = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
    os.environ.setdefault('BENJI_TLS_CA_FILE', str(contents / 'Resources/trust/cacert.pem'))
    # -I omits CWD and the script directory. Add only this bundled engine root after validating its listed files.
    sys.path.insert(0, str(root))
    if entry == 'model-setup':
        from benji.model_setup import model_setup_main
        model_setup_main()
    else:
        if entry == 'tts':
            sys.argv.insert(1, '--tts')
        runpy.run_module({'engine': 'benji', 'remote': 'benji.remote',
                          'native-host': 'benji.browser_host', 'tts': 'benji'}[entry], run_name='__main__')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
