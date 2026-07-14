"""Small dependency-free timing/counter collector."""

from __future__ import annotations

import time
from contextlib import contextmanager
from typing import Dict, Iterator


class PerformanceMetrics:
    def __init__(self) -> None:
        self.timings: Dict[str, float] = {}
        self.counters: Dict[str, int] = {}

    @contextmanager
    def measure(self, name: str) -> Iterator[None]:
        started = time.perf_counter()
        try:
            yield
        finally:
            self.timings[name] = self.timings.get(name, 0.0) + (time.perf_counter() - started)

    def increment(self, name: str, amount: int = 1) -> None:
        self.counters[name] = self.counters.get(name, 0) + amount

    def to_dict(self) -> Dict[str, object]:
        return {
            "timings_seconds": {key: round(value, 9) for key, value in sorted(self.timings.items())},
            "counters": dict(sorted(self.counters.items())),
        }
