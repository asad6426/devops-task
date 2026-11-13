"""Runtime configuration, read exclusively from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass

_VALID_LOG_LEVELS = {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}


@dataclass(frozen=True)
class Settings:
    port: int
    host: str
    log_level: str
    environment: str
    version: str
    shutdown_timeout: int
    enable_debug_endpoints: bool


def _bool(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


def load_settings() -> Settings:
    log_level = os.getenv("LOG_LEVEL", "INFO").upper()
    if log_level not in _VALID_LOG_LEVELS:
        raise ValueError(f"LOG_LEVEL must be one of {sorted(_VALID_LOG_LEVELS)}, got {log_level!r}")

    return Settings(
        port=int(os.getenv("PORT", "8080")),
        host=os.getenv("HOST", "0.0.0.0"),  # noqa: S104 - binding all interfaces is intended inside a container
        log_level=log_level,
        environment=os.getenv("APP_ENV", "local"),
        version=os.getenv("APP_VERSION", "0.0.0-dev"),
        shutdown_timeout=int(os.getenv("SHUTDOWN_TIMEOUT_SECONDS", "20")),
        enable_debug_endpoints=_bool(os.getenv("ENABLE_DEBUG_ENDPOINTS", "false")),
    )
