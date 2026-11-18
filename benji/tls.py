"""Engine-only CA selection. Never changes SSL_CERT_FILE or child tool trust."""
from functools import lru_cache
import os
from pathlib import Path
import ssl
import urllib.request


class TrustError(ValueError):
    """An explicit engine CA selection cannot be used; never fall back to default roots."""


@lru_cache(maxsize=4)
def _from_file(path: str, mtime_ns: int, ctime_ns: int, size: int, device: int, inode: int) -> ssl.SSLContext:
    try:
        return ssl.create_default_context(cafile=path)
    except (OSError, ssl.SSLError) as error:
        raise TrustError(f'BENJI_TLS_CA_FILE is not a usable CA bundle: {error}') from None


def context() -> ssl.SSLContext | None:
    """None preserves direct source-mode trust. An explicit file replaces default roots."""
    path = os.environ.get('BENJI_TLS_CA_FILE')
    if path is None:
        return None
    try:
        file = Path(path)
        if not path or not file.is_absolute() or not file.is_file():
            raise OSError('choose an absolute path to a readable PEM CA file')
        stat = file.stat()
    except (OSError, ValueError) as error:
        raise TrustError(f'BENJI_TLS_CA_FILE is not a usable CA bundle: {error}') from None
    return _from_file(str(file), stat.st_mtime_ns, stat.st_ctime_ns, stat.st_size, stat.st_dev, stat.st_ino)


def urlopen(request, *, timeout):
    chosen = context()
    if chosen is None:
        return urllib.request.urlopen(request, timeout=timeout)
    return urllib.request.urlopen(request, timeout=timeout, context=chosen)
