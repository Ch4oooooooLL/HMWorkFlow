"""Process-wide resource cache used by the persistent Python worker.

The module is also safe in one-shot mode.  In that case its cache simply lives
for the short lifetime of that Python process.
"""
from __future__ import annotations

from collections import OrderedDict
from pathlib import Path
from typing import Any, Callable, Dict, Hashable, Mapping, Tuple


_MAX_ENTRIES = 32
_resources = OrderedDict()  # type: OrderedDict[Tuple[str, Hashable], Any]
_request_files = {}  # type: Dict[str, str]
_hits = 0
_misses = 0


def _normal_path(path: Path) -> str:
    return str(Path(path).resolve()).replace("\\", "/").lower()


def begin_request(input_fingerprints: Mapping[str, str] = None) -> None:
    """Install the immutable file identities supplied by the Tcl caller."""
    global _request_files
    _request_files = {
        _normal_path(Path(path)): str(fingerprint)
        for path, fingerprint in (input_fingerprints or {}).items()
    }


def end_request() -> None:
    global _request_files
    _request_files = {}


def file_identity(path: Path) -> Hashable:
    """Return a cross-task identity, falling back to safe same-path metadata."""
    resolved = Path(path).resolve()
    supplied = _request_files.get(_normal_path(resolved))
    if supplied is not None:
        return ("content", supplied)
    stat = resolved.stat()
    return ("file", _normal_path(resolved), stat.st_size, stat.st_mtime_ns)


def get_or_create(namespace: str, key: Hashable, factory: Callable[[], Any]) -> Any:
    """Build an immutable/read-only resource once per worker process."""
    global _hits, _misses
    cache_key = (str(namespace), key)
    try:
        value = _resources.pop(cache_key)
    except KeyError:
        _misses += 1
        value = factory()
        _resources[cache_key] = value
        while len(_resources) > _MAX_ENTRIES:
            _resources.popitem(last=False)
        return value
    _hits += 1
    _resources[cache_key] = value
    return value


def get_file_resource(namespace: str, path: Path, factory: Callable[[], Any]) -> Any:
    return get_or_create(namespace, file_identity(path), factory)


def get_kdtree(key: Hashable, factory: Callable[[], Any]) -> Any:
    """Canonical cache boundary for SciPy KDTree/cKDTree instances."""
    return get_or_create("kdtree", key, factory)


def get_adjacency(key: Hashable, factory: Callable[[], Any]) -> Any:
    """Canonical cache boundary for mesh adjacency/topology indexes."""
    return get_or_create("adjacency", key, factory)


def info() -> Dict[str, int]:
    return {"entries": len(_resources), "hits": _hits, "misses": _misses}


def clear() -> None:
    global _hits, _misses
    _resources.clear()
    end_request()
    _hits = 0
    _misses = 0
