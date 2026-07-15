"""Simple deterministic statistics used by geometry analyzers."""
from __future__ import annotations

import math
from typing import Iterable, List


def mean(values: Iterable[float]) -> float:
    rows = [float(value) for value in values]
    if not rows:
        raise ValueError("mean requires at least one value")
    return sum(rows) / len(rows)


def median(values: Iterable[float]) -> float:
    rows = sorted(float(value) for value in values)
    if not rows:
        raise ValueError("median requires at least one value")
    middle = len(rows) // 2
    return rows[middle] if len(rows) % 2 else (rows[middle - 1] + rows[middle]) / 2.0


def population_stddev(values: Iterable[float]) -> float:
    rows = [float(value) for value in values]
    average = mean(rows)
    return math.sqrt(sum((value - average) ** 2 for value in rows) / len(rows))


def mode_with_tolerance(values: Iterable[float], tolerance: float) -> float:
    rows = sorted(float(value) for value in values)
    if not rows:
        raise ValueError("mode requires at least one value")
    if tolerance < 0.0:
        raise ValueError("tolerance must be non-negative")
    groups = []  # type: List[List[float]]
    for value in rows:
        if groups and abs(value - mean(groups[-1])) <= tolerance:
            groups[-1].append(value)
        else:
            groups.append([value])
    groups.sort(key=lambda group: (-len(group), mean(group)))
    return mean(groups[0])
