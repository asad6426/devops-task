"""Container HEALTHCHECK probe (distroless has no curl/wget/shell)."""

from __future__ import annotations

import os
import sys
import urllib.request


def main() -> int:
    url = f"http://127.0.0.1:{os.getenv('PORT', '8080')}/health"
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:
            return 0 if resp.status == 200 else 1
    except Exception:
        return 1


if __name__ == "__main__":
    sys.exit(main())
