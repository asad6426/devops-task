"""Entrypoint: `python -m app`.

uvicorn installs SIGTERM/SIGINT handlers: on SIGTERM it stops accepting new
connections, waits up to `timeout_graceful_shutdown` seconds for in-flight
requests, then runs the FastAPI lifespan shutdown hook.
"""

from __future__ import annotations

import uvicorn

from app.config import load_settings
from app.main import create_app


def main() -> None:
    settings = load_settings()
    app = create_app(settings)
    uvicorn.run(
        app,
        host=settings.host,
        port=settings.port,
        log_config=None,  # keep our JSON logging configuration
        access_log=False,
        timeout_graceful_shutdown=settings.shutdown_timeout,
        proxy_headers=True,
        server_header=False,
    )


if __name__ == "__main__":
    main()
