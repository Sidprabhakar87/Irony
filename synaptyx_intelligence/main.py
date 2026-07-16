"""Synaptyx Intelligence - Main entry point.

Starts the FastAPI service and connects to the Zig DLL via IPC.
"""

import asyncio

import structlog
import uvicorn

from synaptyx_intelligence.config.settings import get_settings
from synaptyx_intelligence.service import create_app

logger = structlog.get_logger()


def main() -> None:
    """Main entry point for the Synaptyx Intelligence service."""
    settings = get_settings()

    structlog.configure(
        processors=[
            structlog.stdlib.add_log_level,
            structlog.dev.ConsoleRenderer(),
        ],
    )

    logger.info(
        "starting_synaptyx_intelligence",
        version="0.1.0",
        host=settings.service_host,
        port=settings.service_port,
        referee_enabled=settings.referee_enabled,
        coach_enabled=settings.coach_enabled,
        ml_enabled=settings.ml_enabled,
    )

    app = create_app()
    uvicorn.run(
        app,
        host=settings.service_host,
        port=settings.service_port,
        log_level="info" if not settings.debug else "debug",
    )


if __name__ == "__main__":
    main()
