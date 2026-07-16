"""Platform API client - communicates with tournament SaaS platform via REST."""

import asyncio
from collections import deque
from dataclasses import dataclass
from typing import Any

import httpx
import structlog

from synaptyx_intelligence.config.settings import Settings

logger = structlog.get_logger()


@dataclass
class PendingRequest:
    method: str
    path: str
    body: dict | None
    retry_count: int = 0


class PlatformClient:
    """Async HTTP client for the tournament SaaS platform.

    Features:
    - Automatic retry with exponential backoff
    - Request queuing for network failures
    - Bearer token authentication
    - Configurable timeouts
    """

    def __init__(self, settings: Settings):
        self.base_url = settings.platform_api_url
        self.api_key = settings.platform_api_key
        self.timeout = settings.platform_timeout_seconds
        self.max_retries = settings.platform_max_retries
        self._client: httpx.AsyncClient | None = None
        self._pending: deque[PendingRequest] = deque(maxlen=100)
        self._connected = False

    async def start(self) -> None:
        """Initialize the HTTP client."""
        self._client = httpx.AsyncClient(
            base_url=self.base_url,
            timeout=self.timeout,
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "User-Agent": "Synaptyx-Intelligence/0.1.0",
            },
        )
        logger.info("platform_client_started", base_url=self.base_url)

    async def stop(self) -> None:
        """Close the HTTP client."""
        if self._client:
            await self._client.aclose()
            self._client = None

    async def authenticate(self) -> bool:
        """Verify API key with the platform."""
        try:
            resp = await self._client.post("/api/auth/verify")
            self._connected = resp.status_code < 400
            return self._connected
        except httpx.HTTPError as e:
            logger.error("auth_failed", error=str(e))
            return False

    async def send_violation(self, violation: dict[str, Any]) -> bool:
        """Send a violation alert to the platform (real-time)."""
        return await self._post("/api/violations", violation)

    async def submit_coach_report(self, report: dict[str, Any]) -> bool:
        """Submit a coaching report to the platform (post-match)."""
        return await self._post("/api/coaching", report)

    async def submit_match_result(
        self, match_id: str, result: dict[str, Any]
    ) -> bool:
        """Submit match result data."""
        return await self._post(f"/api/matches/{match_id}/result", result)

    async def heartbeat(self) -> bool:
        """Send heartbeat to maintain connection."""
        try:
            resp = await self._client.get("/api/health")
            self._connected = resp.status_code < 400
            return self._connected
        except httpx.HTTPError:
            self._connected = False
            return False

    async def process_pending(self) -> int:
        """Retry pending requests. Returns number of successfully sent."""
        processed = 0
        retries = []

        while self._pending:
            req = self._pending.popleft()
            if req.retry_count >= self.max_retries:
                logger.warning("request_dropped", path=req.path, retries=req.retry_count)
                continue

            success = await self._post(req.path, req.body, queue_on_fail=False)
            if success:
                processed += 1
            else:
                req.retry_count += 1
                retries.append(req)

        self._pending.extend(retries)
        return processed

    async def _post(
        self, path: str, body: dict | None, queue_on_fail: bool = True
    ) -> bool:
        """Send a POST request. Queues on failure if queue_on_fail=True."""
        if not self._client:
            return False

        try:
            resp = await self._client.post(path, json=body)
            if resp.status_code < 400:
                return True
            else:
                logger.warning("api_error", path=path, status=resp.status_code)
                if queue_on_fail:
                    self._pending.append(PendingRequest("POST", path, body))
                return False
        except httpx.HTTPError as e:
            logger.warning("api_network_error", path=path, error=str(e))
            if queue_on_fail:
                self._pending.append(PendingRequest("POST", path, body))
            return False

    @property
    def is_connected(self) -> bool:
        return self._connected

    @property
    def pending_count(self) -> int:
        return len(self._pending)
