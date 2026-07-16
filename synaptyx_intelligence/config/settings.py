"""Application settings loaded from environment variables."""

from functools import lru_cache

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Synaptyx Intelligence service configuration."""

    # Service
    service_name: str = "synaptyx-intelligence"
    service_host: str = "127.0.0.1"
    service_port: int = 8400
    debug: bool = False

    # IPC - Connection to Zig DLL
    ipc_pipe_name: str = r"\\.\pipe\synaptyx_referee_ipc"
    ipc_reconnect_interval_seconds: float = 2.0
    ipc_protocol_version: int = 1

    # Tournament Platform API
    platform_api_url: str = ""
    platform_api_key: str = ""
    platform_timeout_seconds: float = 5.0
    platform_max_retries: int = 3

    # Referee settings
    referee_enabled: bool = True
    referee_strictness: str = "normal"  # lenient, normal, strict
    referee_match_id: str = ""

    # Coach settings
    coach_enabled: bool = True
    coach_analysis_depth: str = "detailed"  # basic, detailed, comprehensive
    coach_min_frames_for_analysis: int = 300  # ~5 seconds of gameplay

    # ML settings (provisions for future)
    ml_enabled: bool = False
    ml_model_path: str = "./models/"
    ml_device: str = "cpu"  # cpu, cuda

    # Data collection (for future ML training)
    data_collection_enabled: bool = False
    data_collection_path: str = "./data/collected/"
    data_anonymize: bool = True

    model_config = {"env_prefix": "SYNAPTYX_", "env_file": ".env"}


@lru_cache
def get_settings() -> Settings:
    """Get cached application settings."""
    return Settings()
