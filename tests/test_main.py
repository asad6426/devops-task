from __future__ import annotations

import json
import logging

import pytest
from fastapi.testclient import TestClient

from app.config import Settings, load_settings
from app.logging_config import JsonFormatter
from app.main import create_app


def make_settings(**overrides: object) -> Settings:
    base = {
        "port": 8080,
        "host": "127.0.0.1",
        "log_level": "INFO",
        "environment": "test",
        "version": "9.9.9",
        "shutdown_timeout": 5,
        "enable_debug_endpoints": False,
    }
    base.update(overrides)
    return Settings(**base)  # type: ignore[arg-type]


@pytest.fixture
def client() -> TestClient:
    with TestClient(create_app(make_settings())) as c:
        yield c


def test_root_returns_expected_payload(client: TestClient) -> None:
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.json() == {"message": "Hello from DevOps Task!", "status": "running", "version": "9.9.9"}


def test_health_ok_when_ready(client: TestClient) -> None:
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


def test_health_503_when_not_ready() -> None:
    # Without entering the lifespan context the app has not started (or is shutting down).
    c = TestClient(create_app(make_settings()))
    resp = c.get("/health")
    assert resp.status_code == 503


def test_metrics_exposes_counters_and_histogram(client: TestClient) -> None:
    client.get("/")
    client.get("/does-not-exist")
    body = client.get("/metrics").text
    assert 'http_requests_total{method="GET",path="/",status="200"}' in body
    # Unknown URLs are collapsed to a single label value to bound cardinality.
    assert 'path="unmatched",status="404"' in body
    assert "http_request_duration_seconds_bucket" in body
    assert "http_request_errors_total" in body


def test_errors_are_counted_and_return_500() -> None:
    with TestClient(create_app(make_settings(enable_debug_endpoints=True)), raise_server_exceptions=False) as c:
        resp = c.get("/debug/error")
        assert resp.status_code == 500
        body = c.get("/metrics").text
        assert 'http_request_errors_total{method="GET",path="/debug/error"}' in body


def test_debug_endpoints_disabled_by_default(client: TestClient) -> None:
    assert client.get("/debug/error").status_code == 404


def test_load_settings_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PORT", "9000")
    monkeypatch.setenv("LOG_LEVEL", "debug")
    monkeypatch.setenv("APP_ENV", "staging")
    monkeypatch.setenv("APP_VERSION", "1.2.3")
    s = load_settings()
    assert (s.port, s.log_level, s.environment, s.version) == (9000, "DEBUG", "staging", "1.2.3")


def test_invalid_log_level_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LOG_LEVEL", "LOUD")
    with pytest.raises(ValueError):
        load_settings()


def test_healthcheck_probe_fails_when_nothing_listens(monkeypatch: pytest.MonkeyPatch) -> None:
    from app import healthcheck

    monkeypatch.setenv("PORT", "1")  # nothing listens on port 1
    assert healthcheck.main() == 1


def test_json_formatter_emits_structured_fields() -> None:
    record = logging.makeLogRecord(
        {"name": "app", "levelname": "INFO", "levelno": 20, "msg": "hello", "path": "/", "status": 200}
    )
    out = json.loads(JsonFormatter({"service": "devops-task"}).format(record))
    assert out["level"] == "info"
    assert out["message"] == "hello"
    assert out["path"] == "/"
    assert out["status"] == 200
    assert out["service"] == "devops-task"
