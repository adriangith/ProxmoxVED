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
$STD get install -y \
    curl \
    sudo \
    mc \
    ffmpeg \
    socat \
    jq
msg_ok "Installed Dependencies"

# Setup App
msg_info "Setup ${APPLICATION}"
RELEASE=$(curl -s https://api.github.com/repos/spotdl/spotify-downloader/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3) }')
set -x
wget -q "https://github.com/spotdl/spotify-downloader/archive/refs/tags/v${RELEASE}/${APPLICATION}-${RELEASE}-linux"
set +x
mv "${APPLICATION}"-"${RELEASE}"-linux /opt/"${APPLICATION}"/"${APPLICATION}"-"${RELEASE}"-linux
chmod +x /opt/"${APPLICATION}"/spotdl
#
#
#
echo "${RELEASE}" >/opt/${APPLICATION}_version.txt
msg_ok "Setup ${APPLICATION}"

# Creating REST API script
msg_info "Creating REST API"
cat <<'EOF' >/opt/${APPLICATION}/rest_api.sh
#!/bin/bash

PORT=8080
DOWNLOAD_DIR="/opt/spotify-downloader/downloads"
SPOTDL_BIN="/opt/spotify-downloader/spotdl"

process_spotify_link() {
    local spotify_link="$1"
    local request_id=$(date +%s%N | md5sum | head -c 10)
    local log_file="/tmp/spotdl_${request_id}.log"

    echo "{\"status\":\"processing\",\"request_id\":\"${request_id}\",\"message\":\"Download started\"}"

    # Run spotdl in the background
    (
        cd "$DOWNLOAD_DIR"
        $SPOTDL_BIN "$spotify_link" > "$log_file" 2>&1
        download_status=$?

        if [ $download_status -eq 0 ]; then
            # Get the filename from the log
            downloaded_files=$(grep -o "[^ ]*\.\(mp3\|wav\|ogg\|m4a\)" "$log_file" | sort | uniq)
            echo "{\"status\":\"completed\",\"request_id\":\"${request_id}\",\"files\":\"${downloaded_files}\"}" > "${log_file}.result"
        else
            echo "{\"status\":\"failed\",\"request_id\":\"${request_id}\",\"message\":\"Download failed\"}" > "${log_file}.result"
        fi
    ) &

    return 0
}

check_status() {
    local request_id="$1"
    local log_file="/tmp/spotdl_${request_id}.log"
    local result_file="${log_file}.result"

    if [ -f "$result_file" ]; then
        cat "$result_file"
    else
        if [ -f "$log_file" ]; then
            echo "{\"status\":\"processing\",\"request_id\":\"${request_id}\",\"message\":\"Download in progress\"}"
        else
            echo "{\"status\":\"not_found\",\"message\":\"No download with that ID found\"}"
        fi
    fi
}

start_server() {
    while true; do
        echo "HTTP/1.1 200 OK
Content-Type: application/json

$(
    read -r request_line
    if [[ "$request_line" =~ ^(GET|POST)\ /api/(.*)\ HTTP/[0-9.]+$ ]]; then
        method=${BASH_REMATCH[1]}
        path=${BASH_REMATCH[2]}

        # Parse headers
        content_length=0
        while read -r header; do
            header=$(echo "$header" | tr -d '\r\n')
            [ -z "$header" ] && break
            if [[ "$header" =~ ^Content-Length:\ ([0-9]+)$ ]]; then
                content_length=${BASH_REMATCH[1]}
            fi
        done

        # Read body if POST
        if [ "$method" = "POST" ] && [ "$content_length" -gt 0 ]; then
            body=$(dd bs=1 count=$content_length 2>/dev/null)
        fi

        # Process API endpoints
        if [ "$method" = "POST" ] && [ "$path" = "download" ]; then
            # Extract spotify_link from JSON body
            spotify_link=$(echo "$body" | jq -r '.spotify_link')
            if [ -n "$spotify_link" ] && [ "$spotify_link" != "null" ]; then
                process_spotify_link "$spotify_link"
            else
                echo "{\"error\":\"Missing or invalid spotify_link parameter\"}"
            fi
        elif [ "$method" = "GET" ] && [[ "$path" =~ ^status/([a-z0-9]+)$ ]]; then
            request_id=${BASH_REMATCH[1]}
            check_status "$request_id"
        elif [ "$method" = "GET" ] && [ "$path" = "downloads" ]; then
            # List all downloads
            files=$(ls -1 "$DOWNLOAD_DIR" | grep -E '\.mp3$|\.wav$|\.ogg$|\.m4a$' | jq -R . | jq -s .)
            echo "{\"files\":$files}"
        else
            echo "{\"error\":\"Invalid endpoint\",\"available_endpoints\":[\"POST /api/download\",\"GET /api/status/{request_id}\",\"GET /api/downloads\"]}"
        fi
    else
        echo "{\"error\":\"Invalid request\"}"
    fi
)" | socat - TCP-LISTEN:$PORT,fork,reuseaddr
    done
}

start_server
EOF

chmod +x /opt/"${APPLICATION}"/rest_api.sh
msg_ok "Created REST API"

# Creating Service
msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/${APPLICATION}.service
[Unit]
Description=${APPLICATION} Service
After=network.target

[Service]
ExecStart=/opt/${APPLICATION}/rest_api.sh
Restart=always
User=root
WorkingDirectory=/opt/${APPLICATION}

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now ${APPLICATION}.service
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
cat <<EOF >/opt/${APPLICATION}/README.md
# Spotify Downloader API

This service provides a REST API for downloading Spotify tracks using spotdl.

## API Endpoints

1. Download tracks: \`POST /api/download\`
   - Request body: \`{"spotify_link": "https://open.spotify.com/track/..."}\`
   - Response: \`{"status": "processing", "request_id": "abc123", "message": "Download started"}\`

2. Check download status: \`GET /api/status/{request_id}\`
   - Response: \`{"status": "completed|processing|failed", "request_id": "abc123", "files": "file1.mp3,file2.mp3"}\`

3. List downloads: \`GET /api/downloads\`
   - Response: \`{"files": ["file1.mp3", "file2.mp3", ...]}\`

## Examples

- Download a track:
  \`curl -X POST -H "Content-Type: application/json" -d '{"spotify_link":"https://open.spotify.com/track/..."}'  http://localhost:8080/api/download\`

- Check status:
  \`curl http://localhost:8080/api/status/abc123\`

- List downloads:
  \`curl http://localhost:8080/api/downloads\`

Downloaded files are stored in: /opt/${APPLICATION}/downloads
EOF

# Cleanup
msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
