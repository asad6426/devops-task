"""DevOps task web service."""

from __future__ import annotations

import logging
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from starlette.routing import Match

from app.config import Settings, load_settings
from app.logging_config import configure_logging
from app.metrics import APP_INFO, ERRORS, IN_PROGRESS, LATENCY, REGISTRY, REQUESTS

logger = logging.getLogger("app")

# Paths that are polled constantly; logging them at INFO would drown real traffic.
_QUIET_PATHS = {"/health", "/metrics"}


def _route_template(request: Request) -> str:
    """Return the route template that matches the request, or 'unmatched'."""
    for route in request.app.router.routes:
        match, _ = route.matches(request.scope)
        if match == Match.FULL:
            return getattr(route, "path", "unmatched")
    return "unmatched"


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or load_settings()
    configure_logging(settings.log_level, settings.environment, settings.version)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        app.state.ready = True
        APP_INFO.labels(version=settings.version, env=settings.environment).set(1)
        logger.info("application started", extra={"port": settings.port})
        yield
        # Reached after uvicorn received SIGTERM/SIGINT and drained in-flight requests.
        app.state.ready = False
        logger.info("application shutting down gracefully")

    app = FastAPI(title="devops-task", version=settings.version, lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.settings = settings
    app.state.ready = False

    @app.middleware("http")
    async def observe(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        path = _route_template(request)
        method = request.method
        start = time.perf_counter()
        status = 500
        IN_PROGRESS.inc()
        try:
            response = await call_next(request)
            status = response.status_code
            return response
        except Exception:
            logger.exception("unhandled exception", extra={"method": method, "path": path})
            return JSONResponse({"error": "internal server error"}, status_code=500)
        finally:
            duration = time.perf_counter() - start
            IN_PROGRESS.dec()
            REQUESTS.labels(method=method, path=path, status=str(status)).inc()
            LATENCY.labels(method=method, path=path).observe(duration)
            if status >= 500:
                ERRORS.labels(method=method, path=path).inc()
            level = logging.ERROR if status >= 500 else logging.WARNING if status >= 400 else logging.INFO
            if path in _QUIET_PATHS and status < 400:
                level = logging.DEBUG
            logger.log(
                level,
                "request completed",
                extra={
                    "method": method,
                    "path": path,
                    "status": status,
                    "duration_ms": round(duration * 1000, 2),
                    "client": request.client.host if request.client else None,
                },
            )

    @app.get("/")
    async def root() -> dict[str, str]:
        return {"message": "Hello from DevOps Task!", "status": "running", "version": settings.version}

    @app.get("/health")
    async def health(request: Request) -> JSONResponse:
        if not request.app.state.ready:
            return JSONResponse({"status": "unavailable"}, status_code=503)
        return JSONResponse({"status": "ok", "version": settings.version, "env": settings.environment})

    @app.get("/metrics")
    async def metrics() -> Response:
        return Response(generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST)

    if settings.enable_debug_endpoints:
        # Local-only helpers to generate errors/latency for dashboard and alert demos.
        @app.get("/debug/error")
        async def debug_error() -> None:
            raise RuntimeError("simulated failure for observability demo")

        @app.get("/debug/slow")
        async def debug_slow(seconds: float = 1.0) -> dict[str, float]:
            import asyncio

            await asyncio.sleep(min(seconds, 10.0))
            return {"slept": seconds}

    return app
