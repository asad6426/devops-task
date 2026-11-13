# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# Stage 1: build dependencies with a full Python toolchain.
# Must match the distroless runtime: Debian 13 (trixie) + CPython 3.13.
# ---------------------------------------------------------------------------
FROM python:3.13-slim-trixie@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90 AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

# Dependencies first so this layer is cached until requirements.txt changes.
COPY requirements.txt .
RUN pip install --no-cache-dir --target /opt/deps -r requirements.txt

COPY app/ /opt/src/app/
# Pre-compile bytecode so the runtime never needs to write to a read-only root FS.
RUN python -m compileall -q /opt/deps /opt/src

# ---------------------------------------------------------------------------
# Stage 2: minimal runtime. No shell, no package manager, runs as UID 65532.
# ---------------------------------------------------------------------------
FROM gcr.io/distroless/python3-debian13:nonroot@sha256:6c4cb3bfa4b555429dd19541796a6ba6b30c84675b460bd0bd5072f7d5bdae71

ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="devops-task" \
      org.opencontainers.image.description="Small FastAPI service with health checks and Prometheus metrics" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/asad6426/devops-task" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="gcr.io/distroless/python3-debian13:nonroot"

ENV PYTHONPATH=/opt/deps:/opt/app \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_VERSION=${APP_VERSION} \
    PORT=8080 \
    LOG_LEVEL=INFO \
    APP_ENV=production

WORKDIR /opt/app
COPY --from=builder --chown=65532:65532 /opt/deps /opt/deps
COPY --from=builder --chown=65532:65532 /opt/src /opt/app

USER 65532:65532
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python3", "-m", "app.healthcheck"]

# Exec form: python is PID 1 and receives SIGTERM directly -> graceful shutdown.
ENTRYPOINT ["python3", "-m", "app"]
