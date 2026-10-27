"""Exception hierarchy and process exit codes."""

from __future__ import annotations


class PipelineError(Exception):
    """Base class for expected pipeline failures."""

    exit_code = 1

    def __init__(self, message: str, hint: str | None = None):
        super().__init__(message)
        self.message = message
        self.hint = hint

    def __str__(self) -> str:
        if self.hint:
            return f"{self.message}\nHint: {self.hint}"
        return self.message


class CommandError(PipelineError):
    """A child process exited nonzero."""

    exit_code = 1

    def __init__(
        self,
        message: str,
        *,
        returncode: int | None = None,
        stderr_tail: str = "",
        hint: str | None = None,
    ):
        super().__init__(message, hint)
        self.returncode = returncode
        self.stderr_tail = stderr_tail


class UsageError(PipelineError):
    exit_code = 2


class DependencyError(PipelineError):
    exit_code = 3


class ValidationError(PipelineError):
    exit_code = 4


class DiskSpaceError(PipelineError):
    exit_code = 5


class UpscaleError(PipelineError):
    exit_code = 6


class EncodeError(PipelineError):
    exit_code = 7


class OutputValidationError(PipelineError):
    exit_code = 8
