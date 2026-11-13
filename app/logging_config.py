"""Structured JSON logging to stdout.

Every record is one JSON object per line so that log shippers (Grafana Alloy,
CloudWatch) can parse fields without regexes.
"""

from __future__ import annotations

import json
import logging
import sys
from datetime import UTC, datetime

# Attributes every LogRecord has; anything else passed via `extra=` is emitted as a field.
_RESERVED = set(vars(logging.makeLogRecord({}))) | {"message", "asctime", "taskName", "color_message"}


class JsonFormatter(logging.Formatter):
    def __init__(self, static_fields: dict[str, str] | None = None) -> None:
        super().__init__()
        self.static_fields = static_fields or {}

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {
            "timestamp": datetime.fromtimestamp(record.created, tz=UTC).isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),
            "logger": record.name,
            "message": record.getMessage(),
            **self.static_fields,
        }
        for key, value in record.__dict__.items():
            if key not in _RESERVED and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure_logging(level: str, environment: str, version: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter({"service": "devops-task", "env": environment, "version": version}))

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)

    # Route uvicorn's own loggers through our JSON handler; we emit our own access log.
    for name in ("uvicorn", "uvicorn.error"):
        lg = logging.getLogger(name)
        lg.handlers = []
        lg.propagate = True
    logging.getLogger("uvicorn.access").disabled = True
