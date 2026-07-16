"""FastAPI service definition with IPC integration."""

import asyncio
from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI

from synaptyx_intelligence.api.platform_client import PlatformClient
from synaptyx_intelligence.coach.analyzer import CoachAnalyzer
from synaptyx_intelligence.coach.report import CoachReport
from synaptyx_intelligence.config.settings import get_settings
from synaptyx_intelligence.ipc.client import IpcClient
from synaptyx_intelligence.ipc.protocol import FrameData, MatchEvent
from synaptyx_intelligence.referee.engine import RefereeEngine

logger = structlog.get_logger()


# Global state
_referee: RefereeEngine | None = None
_coach: CoachAnalyzer | None = None
_ipc_client: IpcClient | None = None
_platform_client: PlatformClient | None = None
_frame_buffer: list[FrameData] = []
_ipc_task: asyncio.Task | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifecycle - start/stop IPC and API connections."""
    global _referee, _coach, _ipc_client, _platform_client, _ipc_task

    settings = get_settings()

    # Initialize components
    _referee = RefereeEngine(settings)
    _coach = CoachAnalyzer(player_id="player_1")
    _ipc_client = IpcClient(settings)
    _platform_client = PlatformClient(settings)

    # Start platform API client
    if settings.platform_api_url:
        await _platform_client.start()

    # Start IPC frame streaming in background
    _ipc_task = asyncio.create_task(_frame_processing_loop())

    logger.info("service_started")
    yield

    # Shutdown
    if _ipc_task:
        _ipc_client.stop()
        _ipc_task.cancel()
    if _platform_client:
        await _platform_client.stop()
    logger.info("service_stopped")


async def _frame_processing_loop():
    """Background task that reads frames from IPC and processes them."""
    global _frame_buffer

    settings = get_settings()

    async for message in _ipc_client.stream_frames():
        if isinstance(message, FrameData):
            # Real-time referee processing
            if settings.referee_enabled and _referee:
                violations = _referee.process_frame(message)
                for v in violations:
                    logger.warning("violation_detected", **v.to_api_dict())
                    if _platform_client and _platform_client.is_connected:
                        await _platform_client.send_violation(v.to_api_dict())

            # Buffer frames for coach analysis
            if settings.coach_enabled:
                _frame_buffer.append(message)

        elif isinstance(message, MatchEvent):
            logger.info("match_event", event_type=message.event_type.name)
            # On match end, trigger coach analysis
            if message.event_type.value == 0x02 and _frame_buffer:
                await _run_coach_analysis()


async def _run_coach_analysis():
    """Run coach analysis on buffered frames and submit report."""
    global _frame_buffer

    if not _coach or not _frame_buffer:
        return

    settings = get_settings()
    if len(_frame_buffer) < settings.coach_min_frames_for_analysis:
        logger.info("coach_skip", reason="insufficient_frames", count=len(_frame_buffer))
        _frame_buffer.clear()
        return

    analysis = _coach.analyze(_frame_buffer)
    report = CoachReport(
        match_id=settings.referee_match_id,
        player_id="player_1",
        opponent_id="player_2",
        analysis=analysis,
    )

    logger.info(
        "coach_report_generated",
        missed_punishes=len(analysis.missed_punishments),
        playstyle=analysis.opponent_profile.playstyle.value,
    )

    # Submit to platform
    if _platform_client and _platform_client.is_connected:
        await _platform_client.submit_coach_report(report.to_api_dict())

    _frame_buffer.clear()


def create_app() -> FastAPI:
    """Create the FastAPI application."""
    app = FastAPI(
        title="Synaptyx Intelligence",
        description="AI Referee & Coach for Tekken 8 Esports",
        version="0.1.0",
        lifespan=lifespan,
    )

    @app.get("/health")
    async def health():
        return {
            "status": "ok",
            "ipc_connected": _ipc_client.is_connected if _ipc_client else False,
            "frames_received": _ipc_client.frames_received if _ipc_client else 0,
            "referee_violations": _referee.get_violation_count() if _referee else 0,
        }

    @app.get("/referee/status")
    async def referee_status():
        if not _referee:
            return {"enabled": False}
        return _referee.get_report()

    @app.post("/referee/clear")
    async def referee_clear():
        if _referee:
            _referee.clear_violations()
        return {"status": "cleared"}

    @app.post("/coach/analyze")
    async def coach_analyze():
        """Trigger coach analysis on buffered frames."""
        await _run_coach_analysis()
        return {"status": "analysis_triggered", "frames_buffered": len(_frame_buffer)}

    @app.get("/coach/report")
    async def coach_report():
        """Get the latest coach report."""
        if not _coach:
            return {"status": "coach_disabled"}
        # Return last analysis if available
        return {"status": "ok", "frames_buffered": len(_frame_buffer)}

    return app
