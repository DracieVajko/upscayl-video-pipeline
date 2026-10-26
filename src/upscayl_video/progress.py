"""Simple counters and ETA formatting for long-running stages."""

from __future__ import annotations

import time
from dataclasses import dataclass, field


def format_eta(seconds: float) -> str:
    value = max(0, int(round(seconds)))
    hours, remainder = divmod(value, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


@dataclass
class Progress:
    label: str
    total: int
    done: int = 0
    _started: float = field(default_factory=time.monotonic)

    def update(self, count: int = 1) -> None:
        self.done = min(self.total, self.done + count)

    @property
    def elapsed(self) -> float:
        return max(0.0, time.monotonic() - self._started)

    @property
    def rate(self) -> float:
        elapsed = self.elapsed
        if elapsed <= 0:
            return 0.0
        return self.done / elapsed

    @property
    def eta_seconds(self) -> float:
        rate = self.rate
        if rate <= 0:
            return 0.0
        return max(0.0, (self.total - self.done) / rate)

    def line(self) -> str:
        percent = (self.done / self.total * 100.0) if self.total else 100.0
        return (
            f"{self.label}: {self.done}/{self.total} ({percent:.1f}%) "
            f"{self.rate:.2f}/s ETA {format_eta(self.eta_seconds)}"
        )
