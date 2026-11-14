#!/usr/bin/env bash
# Thin launcher so you can run ./benji.sh instead of `python3 -m benji`.
# Symlink it onto your PATH if you like:  ln -s "$(pwd)/benji.sh" /usr/local/bin/benji
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -m benji "$@"
