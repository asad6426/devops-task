"""Prometheus metrics.

Label cardinality is bounded on purpose: `path` is the matched *route template*
(e.g. "/health"), never the raw URL, and anything that does not match a route
is collapsed into "unmatched" so a scanner hitting random URLs cannot explode
the time-series count.
"""

from __future__ import annotations

from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram

REGISTRY = CollectorRegistry(auto_describe=True)

REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests handled.",
    ["method", "path", "status"],
    registry=REGISTRY,
)

ERRORS = Counter(
    "http_request_errors_total",
    "HTTP requests that ended in a 5xx response or an unhandled exception.",
    ["method", "path"],
    registry=REGISTRY,
)

LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
    registry=REGISTRY,
)

IN_PROGRESS = Gauge(
    "http_requests_in_progress",
    "HTTP requests currently being processed.",
    registry=REGISTRY,
)

APP_INFO = Gauge(
    "app_info",
    "Static application info; value is always 1.",
    ["version", "env"],
    registry=REGISTRY,
)
