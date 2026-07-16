"""Admin Panel - HTML dashboard served by the FastAPI service.

Provides a simple web-based control panel for tournament organizers
to monitor the referee, view coach reports, and manage settings.
Accessed via the system tray icon or directly at /admin.
"""

ADMIN_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Synaptyx Referee - Admin Panel</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #0a0a0f;
            color: #e0e0e0;
            min-height: 100vh;
        }
        .header {
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            padding: 20px 40px;
            border-bottom: 1px solid #2a2a4a;
        }
        .header h1 { color: #00ff88; font-size: 24px; }
        .header p { color: #888; margin-top: 4px; }
        .container { max-width: 1200px; margin: 0 auto; padding: 30px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(350px, 1fr)); gap: 20px; }
        .card {
            background: #1a1a2e;
            border: 1px solid #2a2a4a;
            border-radius: 12px;
            padding: 24px;
        }
        .card h2 { color: #00ff88; font-size: 18px; margin-bottom: 16px; }
        .stat { display: flex; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid #2a2a4a; }
        .stat:last-child { border-bottom: none; }
        .stat-label { color: #888; }
        .stat-value { color: #fff; font-weight: 600; }
        .status-ok { color: #00ff88; }
        .status-warn { color: #ffaa00; }
        .status-err { color: #ff4444; }
        .btn {
            display: inline-block;
            padding: 10px 20px;
            background: #00ff88;
            color: #0a0a0f;
            border: none;
            border-radius: 6px;
            cursor: pointer;
            font-weight: 600;
            margin: 4px;
            text-decoration: none;
        }
        .btn:hover { background: #00cc6a; }
        .btn-secondary { background: #2a2a4a; color: #e0e0e0; }
        .btn-secondary:hover { background: #3a3a5a; }
        .btn-danger { background: #ff4444; }
        .btn-danger:hover { background: #cc3333; }
        .log-box {
            background: #0a0a0f;
            border: 1px solid #2a2a4a;
            border-radius: 6px;
            padding: 12px;
            font-family: monospace;
            font-size: 12px;
            max-height: 200px;
            overflow-y: auto;
            margin-top: 12px;
        }
        .violation { color: #ffaa00; padding: 4px 0; }
        .violation.critical { color: #ff4444; }
        #refresh-timer { color: #666; font-size: 12px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Synaptyx Referee</h1>
        <p>AI Tournament Integrity & Coaching System <span id="refresh-timer"></span></p>
    </div>
    <div class="container">
        <div class="grid">
            <div class="card">
                <h2>System Status</h2>
                <div class="stat">
                    <span class="stat-label">Service</span>
                    <span class="stat-value status-ok" id="service-status">Running</span>
                </div>
                <div class="stat">
                    <span class="stat-label">IPC Connection</span>
                    <span class="stat-value" id="ipc-status">Checking...</span>
                </div>
                <div class="stat">
                    <span class="stat-label">Frames Received</span>
                    <span class="stat-value" id="frames-count">0</span>
                </div>
                <div class="stat">
                    <span class="stat-label">Platform API</span>
                    <span class="stat-value" id="api-status">Not configured</span>
                </div>
            </div>
            <div class="card">
                <h2>Referee</h2>
                <div class="stat">
                    <span class="stat-label">Status</span>
                    <span class="stat-value" id="referee-enabled">Enabled</span>
                </div>
                <div class="stat">
                    <span class="stat-label">Violations Detected</span>
                    <span class="stat-value" id="violation-count">0</span>
                </div>
                <div class="stat">
                    <span class="stat-label">Strictness</span>
                    <span class="stat-value" id="referee-strictness">normal</span>
                </div>
                <button class="btn-secondary btn" onclick="clearViolations()">Clear Violations</button>
                <div class="log-box" id="violation-log">
                    <div style="color: #666;">No violations detected</div>
                </div>
            </div>
            <div class="card">
                <h2>Coach</h2>
                <div class="stat">
                    <span class="stat-label">Status</span>
                    <span class="stat-value" id="coach-enabled">Enabled</span>
                </div>
                <div class="stat">
                    <span class="stat-label">Frames Buffered</span>
                    <span class="stat-value" id="frames-buffered">0</span>
                </div>
                <div class="stat">
                    <span class="stat-label">Last Analysis</span>
                    <span class="stat-value" id="last-analysis">None</span>
                </div>
                <button class="btn" onclick="triggerAnalysis()">Run Analysis Now</button>
            </div>
            <div class="card">
                <h2>Controls</h2>
                <p style="color: #888; margin-bottom: 16px;">Tournament organizer actions</p>
                <a href="/referee/status" class="btn-secondary btn">Referee Report (JSON)</a>
                <a href="/coach/report" class="btn-secondary btn">Coach Report (JSON)</a>
                <a href="/health" class="btn-secondary btn">Health Check</a>
            </div>
        </div>
    </div>
    <script>
        async function refreshStatus() {
            try {
                const resp = await fetch('/health');
                const data = await resp.json();
                document.getElementById('ipc-status').textContent = data.ipc_connected ? 'Connected' : 'Waiting...';
                document.getElementById('ipc-status').className = 'stat-value ' + (data.ipc_connected ? 'status-ok' : 'status-warn');
                document.getElementById('frames-count').textContent = data.frames_received || 0;
                document.getElementById('violation-count').textContent = data.referee_violations || 0;
            } catch(e) {
                document.getElementById('service-status').textContent = 'Error';
                document.getElementById('service-status').className = 'stat-value status-err';
            }
        }
        async function clearViolations() {
            await fetch('/referee/clear', {method: 'POST'});
            document.getElementById('violation-count').textContent = '0';
            document.getElementById('violation-log').innerHTML = '<div style="color: #666;">Violations cleared</div>';
        }
        async function triggerAnalysis() {
            const resp = await fetch('/coach/analyze', {method: 'POST'});
            const data = await resp.json();
            document.getElementById('last-analysis').textContent = 'Triggered (' + (data.frames_buffered || 0) + ' frames)';
        }
        // Auto-refresh every 2 seconds
        setInterval(refreshStatus, 2000);
        refreshStatus();
    </script>
</body>
</html>
"""
