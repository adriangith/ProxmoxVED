#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: adriangith
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: [SOURCE_URL]

# Import Functions und Setup
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Installing Dependencies with the 3 core dependencies (curl;sudo;mc)
msg_info "Installing Dependencies"
$STD apt-get install -y \
    curl \
    sudo \
    mc \
    ffmpeg \
    socat \
    jq \
    python3 \
    python3-pip
msg_ok "Installed Dependencies"

# Setup App using pip instead of binary
msg_info "Setup ${APPLICATION} via pip"
$STD pip3 install spotdl
# Create directory structure
mkdir -p /opt/spotify-downloader/downloads
# Save version info
CURRENT_VERSION=$(pip show spotdl | grep Version | awk '{print $2}')
echo "${CURRENT_VERSION}" >"/opt/spotify-downloader/${APPLICATION}_version.txt"
msg_ok "Setup ${APPLICATION}"

# Creating Flask REST API
msg_info "Creating REST API with Flask"

# Install Flask
$STD pip3 install flask

# Create Flask API script
cat <<'EOF' >/opt/spotify-downloader/rest_api.py
#!/usr/bin/env python3

from flask import Flask, request, jsonify, send_from_directory
import os
import subprocess
import json
import uuid
import glob
import time
import threading
import logging

app = Flask(__name__)

# Configuration
DOWNLOAD_DIR = "/opt/spotify-downloader/downloads"
PORT = 8080

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    filename='/var/log/spotdl-api.log'
)

# Ensure downloads directory exists
os.makedirs(DOWNLOAD_DIR, exist_ok=True)

# Track active downloads
active_downloads = {}

def download_track(spotify_link, request_id):
    """Run spotdl download in a separate thread"""
    log_file = f"/tmp/spotdl_{request_id}.log"
    result_file = f"{log_file}.result"

    # Using python module directly instead of binary
    cmd = ["python3", "-m", "spotdl", spotify_link]

    try:
        # Set current directory to downloads
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            cwd=DOWNLOAD_DIR,
            text=True
        )

        log_output = ""
        for line in process.stdout:
            log_output += line
            with open(log_file, "a") as f:
                f.write(line)

        # Wait for process to complete
        exit_code = process.wait()

        if exit_code == 0:
            # Extract filenames from output
            downloaded_files = []
            for ext in [".mp3", ".wav", ".ogg", ".m4a"]:
                files = glob.glob(os.path.join(DOWNLOAD_DIR, f"*{ext}"))
                # Get only the filenames without the path
                files = [os.path.basename(f) for f in files]
                downloaded_files.extend(files)

            result = {
                "status": "completed",
                "request_id": request_id,
                "files": downloaded_files
            }
        else:
            result = {
                "status": "failed",
                "request_id": request_id,
                "message": "Download failed",
                "error": log_output
            }

        # Save result
        with open(result_file, "w") as f:
            json.dump(result, f)

        # Remove from active downloads
        if request_id in active_downloads:
            del active_downloads[request_id]

    except Exception as e:
        logging.error(f"Error in download process: {e}")
        with open(result_file, "w") as f:
            json.dump({
                "status": "failed",
                "request_id": request_id,
                "message": f"Internal error: {str(e)}"
            }, f)

        if request_id in active_downloads:
            del active_downloads[request_id]

@app.route('/api/download', methods=['POST'])
def api_download():
    """Handle download requests"""
    try:
        data = request.json
        if not data or 'spotify_link' not in data:
            return jsonify({"error": "Missing spotify_link parameter"}), 400

        spotify_link = data['spotify_link']
        request_id = str(uuid.uuid4())[:10]

        # Start download in background
        thread = threading.Thread(
            target=download_track,
            args=(spotify_link, request_id)
        )
        thread.start()

        # Track the download
        active_downloads[request_id] = {
            "spotify_link": spotify_link,
            "start_time": time.time(),
            "thread": thread
        }

        return jsonify({
            "status": "processing",
            "request_id": request_id,
            "message": "Download started"
        })

    except Exception as e:
        logging.error(f"Error handling download request: {e}")
        return jsonify({"error": str(e)}), 500

@app.route('/api/status/<request_id>', methods=['GET'])
def api_status(request_id):
    """Check status of a download"""
    log_file = f"/tmp/spotdl_{request_id}.log"
    result_file = f"{log_file}.result"

    if os.path.exists(result_file):
        # Download finished, return result
        with open(result_file, "r") as f:
            try:
                return jsonify(json.load(f))
            except json.JSONDecodeError:
                return jsonify({
                    "status": "error",
                    "request_id": request_id,
                    "message": "Malformed result file"
                }), 500

    if request_id in active_downloads:
        # Download in progress
        elapsed = time.time() - active_downloads[request_id]["start_time"]
        return jsonify({
            "status": "processing",
            "request_id": request_id,
            "message": "Download in progress",
            "elapsed_seconds": int(elapsed)
        })

    if os.path.exists(log_file):
        # Log exists but not in active downloads and no result
        return jsonify({
            "status": "unknown",
            "request_id": request_id,
            "message": "Download status unknown"
        })

    # No record of this download
    return jsonify({
        "status": "not_found",
        "request_id": request_id,
        "message": "No download with that ID found"
    }), 404

@app.route('/api/downloads', methods=['GET'])
def api_downloads():
    """List all downloaded files"""
    files = []
    for ext in [".mp3", ".wav", ".ogg", ".m4a"]:
        found = glob.glob(os.path.join(DOWNLOAD_DIR, f"*{ext}"))
        files.extend([os.path.basename(f) for f in found])

    return jsonify({
        "files": files,
        "count": len(files)
    })

@app.route('/api/file/<filename>', methods=['GET'])
def api_download_file(filename):
    """Download a specific file"""
    return send_from_directory(DOWNLOAD_DIR, filename, as_attachment=True)

@app.route('/api/health', methods=['GET'])
def api_health():
    """Health check endpoint"""
    return jsonify({
        "status": "ok",
        "downloads_active": len(active_downloads),
        "spotdl_version": open("/opt/spotify-downloader/spotdl_version.txt").read().strip() if os.path.exists("/opt/spotify-downloader/spotdl_version.txt") else "unknown"
    })

@app.route('/api', methods=['GET'])
def api_docs():
    """API documentation"""
    base_url = request.url_root.rstrip('/')
    return jsonify({
        "name": "Spotify Downloader API",
        "endpoints": [
            {
                "path": "/api/download",
                "method": "POST",
                "description": "Download a Spotify track/album/playlist",
                "body": {"spotify_link": "URL to Spotify content"},
                "example": f"curl -X POST {base_url}/api/download -H 'Content-Type: application/json' -d '{{\"spotify_link\":\"https://open.spotify.com/track/...\"}}'"
            },
            {
                "path": "/api/status/{request_id}",
                "method": "GET",
                "description": "Check download status",
                "example": f"curl {base_url}/api/status/abc123def"
            },
            {
                "path": "/api/downloads",
                "method": "GET",
                "description": "List all downloaded files",
                "example": f"curl {base_url}/api/downloads"
            },
            {
                "path": "/api/file/{filename}",
                "method": "GET",
                "description": "Download a specific file",
                "example": f"curl -O {base_url}/api/file/song.mp3"
            },
            {
                "path": "/api/health",
                "method": "GET",
                "description": "API health status",
                "example": f"curl {base_url}/api/health"
            }
        ]
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
EOF

chmod +x /opt/spotify-downloader/rest_api.py
msg_ok "Created Flask REST API"

# Creating Service
msg_info "Creating Service"
cat <<EOF >"/etc/systemd/system/${APPLICATION}.service"
[Unit]
Description=${APPLICATION} REST API Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/spotify-downloader/rest_api.py
Restart=always
User=root
WorkingDirectory=/opt/spotify-downloader

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now "${APPLICATION}.service"
msg_ok "Created Service"

motd_ssh
customize

# Configuring firewall if needed
if command -v ufw &>/dev/null; then
    msg_info "Configuring firewall"
    ufw allow 8080/tcp
    msg_ok "Configured firewall"
fi

# Adding usage instructions
cat <<EOF >/opt/spotify-downloader/README.md
# Spotify Downloader API

This service provides a REST API for downloading Spotify tracks using spotdl.

## API Endpoints

1. Download content: \`POST /api/download\`
   - Request body: \`{"spotify_link": "https://open.spotify.com/track/..."}\`
   - Response: \`{"status": "processing", "request_id": "abc123", "message": "Download started"}\`

2. Check download status: \`GET /api/status/{request_id}\`
   - Response: \`{"status": "completed|processing|failed", "request_id": "abc123", "files": ["file1.mp3", "file2.mp3"]}\`

3. List all downloads: \`GET /api/downloads\`
   - Response: \`{"files": ["file1.mp3", "file2.mp3", ...], "count": 2}\`

4. Download a file: \`GET /api/file/{filename}\`
   - Downloads the specified file

5. API health check: \`GET /api/health\`
   - Response: \`{"status": "ok", "downloads_active": 1, "spotdl_version": "4.1.0"}\`

6. API documentation: \`GET /api\`
   - Returns all available endpoints with examples

## Examples

- Download a track:
  \`curl -X POST -H "Content-Type: application/json" -d '{"spotify_link":"https://open.spotify.com/track/..."}'  http://your-server:8080/api/download\`

- Check status:
  \`curl http://your-server:8080/api/status/abc123def\`

- List downloads:
  \`curl http://your-server:8080/api/downloads\`

- Download a file:
  \`curl -O http://your-server:8080/api/file/song.mp3\`

Downloaded files are stored in: /opt/spotify-downloader/downloads
EOF

# Cleanup
msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
