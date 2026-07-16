"""Synaptyx Intelligence - System Tray Application.

Runs silently in the system tray. Right-click the tray icon to access:
- Open Admin Panel (web dashboard)
- Referee Status
- Coach Status
- Settings
- Exit

The FastAPI service runs in the background and the admin panel is accessible
via the web browser at http://127.0.0.1:8400/admin
"""

import asyncio
import os
import subprocess
import sys
import threading
import time
import webbrowser
from pathlib import Path

# Try to import pystray for system tray support
try:
    import pystray
    from PIL import Image, ImageDraw
    HAS_TRAY = True
except ImportError:
    HAS_TRAY = False


def create_tray_icon() -> "Image.Image":
    """Create a simple tray icon (green circle with 'S')."""
    size = 64
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    # Green circle background
    draw.ellipse([2, 2, size - 2, size - 2], fill=(0, 180, 80, 255))
    # White 'S' letter
    draw.text((size // 2 - 8, size // 2 - 12), "S", fill=(255, 255, 255, 255))
    return image


class SynaptyxTray:
    """System tray application for Synaptyx Intelligence."""

    def __init__(self):
        self.server_thread: threading.Thread | None = None
        self.server_running = False
        self.admin_url = "http://127.0.0.1:8400"
        self.icon: "pystray.Icon | None" = None

    def start_server(self):
        """Start the FastAPI server in a background thread."""
        def run_server():
            import uvicorn
            from synaptyx_intelligence.service import create_app
            from synaptyx_intelligence.config.settings import get_settings

            settings = get_settings()
            app = create_app()
            self.server_running = True
            uvicorn.run(
                app,
                host=settings.service_host,
                port=settings.service_port,
                log_level="warning",  # Silent in tray mode
            )
            self.server_running = False

        self.server_thread = threading.Thread(target=run_server, daemon=True)
        self.server_thread.start()
        # Wait for server to start
        time.sleep(1.5)

    def open_admin_panel(self, icon=None, item=None):
        """Open the admin panel in the default browser."""
        webbrowser.open(f"{self.admin_url}/admin")

    def open_referee_status(self, icon=None, item=None):
        """Open referee status page."""
        webbrowser.open(f"{self.admin_url}/referee/status")

    def open_coach_report(self, icon=None, item=None):
        """Open coach report page."""
        webbrowser.open(f"{self.admin_url}/coach/report")

    def open_health(self, icon=None, item=None):
        """Open health check."""
        webbrowser.open(f"{self.admin_url}/health")

    def quit_app(self, icon=None, item=None):
        """Exit the application."""
        if self.icon:
            self.icon.stop()
        sys.exit(0)

    def run(self):
        """Run the system tray application."""
        if not HAS_TRAY:
            print("System tray not available (install pystray and Pillow).")
            print("Running in console mode instead...")
            self.run_console()
            return

        # Start server
        self.start_server()

        # Create tray menu
        menu = pystray.Menu(
            pystray.MenuItem("Synaptyx Referee v0.1.0", None, enabled=False),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Open Admin Panel", self.open_admin_panel, default=True),
            pystray.MenuItem("Referee Status", self.open_referee_status),
            pystray.MenuItem("Coach Report", self.open_coach_report),
            pystray.MenuItem("Health Check", self.open_health),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(
                "Status: " + ("Connected" if self.server_running else "Starting..."),
                None,
                enabled=False,
            ),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Exit", self.quit_app),
        )

        # Create and run tray icon
        self.icon = pystray.Icon(
            name="synaptyx",
            icon=create_tray_icon(),
            title="Synaptyx Referee - Running",
            menu=menu,
        )

        print("Synaptyx Intelligence running in system tray.")
        print(f"Admin panel: {self.admin_url}/admin")
        self.icon.run()

    def run_console(self):
        """Fallback: run in console mode without tray icon."""
        self.start_server()
        print(f"\nSynaptyx Intelligence Service running at {self.admin_url}")
        print("Press Ctrl+C to stop.\n")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            print("\nShutting down...")


def main():
    """Entry point for the system tray application."""
    tray = SynaptyxTray()
    tray.run()


if __name__ == "__main__":
    main()
