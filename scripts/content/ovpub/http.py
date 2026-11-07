"""The one HTTP client the publisher uses for reads. Polite User-Agent, retries, follows redirects."""
from __future__ import annotations

import time
from typing import Protocol

import requests

USER_AGENT = "OfflineVaultPublisher/1 (+https://offlinevault.dev; namit.chadha@gmail.com)"


class Http(Protocol):
    def get_text(self, url: str) -> str: ...
    def get_json(self, url: str) -> object: ...
    def head(self, url: str) -> dict[str, str] | None: ...


class RequestsHttp:
    def __init__(self, timeout: float = 60, retries: int = 3, session: requests.Session | None = None):
        self.timeout, self.retries = timeout, retries
        self.session = session or requests.Session()
        self.session.headers["User-Agent"] = USER_AGENT

    def _retry(self, fn):
        delay = 1.0
        for attempt in range(self.retries):
            try:
                return fn()
            except requests.RequestException:
                if attempt == self.retries - 1:
                    raise
                time.sleep(delay)
                delay *= 2

    def get_text(self, url: str) -> str:
        def go():
            r = self.session.get(url, timeout=self.timeout)
            r.raise_for_status()
            return r.text
        return self._retry(go)

    def get_json(self, url: str) -> object:
        def go():
            r = self.session.get(url, timeout=self.timeout)
            r.raise_for_status()
            return r.json()
        return self._retry(go)

    def head(self, url: str) -> dict[str, str] | None:
        """Final response headers after redirects, lower-cased; None on 404. Other errors raise."""
        def go():
            r = self.session.head(url, timeout=self.timeout, allow_redirects=True)
            if r.status_code == 404:
                return None
            if r.status_code in (403, 405):
                # Some hosts refuse HEAD; a one-byte range GET answers the same questions.
                g = self.session.get(url, timeout=self.timeout, headers={"Range": "bytes=0-0"}, stream=True)
                g.close()
                if g.status_code == 404:
                    return None
                g.raise_for_status()
                h = {k.lower(): v for k, v in g.headers.items()}
                if "content-range" in h:
                    h["content-length"] = h["content-range"].rsplit("/", 1)[-1]
                return h
            r.raise_for_status()
            return {k.lower(): v for k, v in r.headers.items()}
        return self._retry(go)
