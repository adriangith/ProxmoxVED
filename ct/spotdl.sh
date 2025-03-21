#!/usr/bin/env bash
# shellcheck source=../misc/build.func
source <(curl -s https://raw.githubusercontent.com/adriangith/ProxmoxVED/refs/heads/spotDL/misc/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Author: adriangith
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: [SOURCE_URL]

# App Default Values
APP="spotdl"
# Name of the app (e.g. Google, Adventurelog, Apache-Guacamole"
var_tags="media"
# Tags for Proxmox VE, maximum 2 pcs., no spaces allowed, separated by a semicolon ; (e.g. database | adblock;dhcp)
var_cpu="1"
# Number of cores (1-X) (e.g. 4) - default are 2
var_ram="2048"
# Amount of used RAM in MB (e.g. 2048 or 4096)
var_disk="4"
# Amount of used disk space in GB (e.g. 4 or 10)
var_os="debian"
# Default OS (e.g. debian, ubuntu, alpine)
var_version="12"
# Default OS version (e.g. 12 for debian, 24.04 for ubuntu, 3.20 for alpine)
var_unprivileged="1"
# 1 = unprivileged container, 0 = privileged container

header_info "$APP"
variables
color
catch_errors

function update_script() {
    header_info
    check_container_storage
    check_container_resources

    # Check if installation is present | -f for file, -d for folder
    if [[ ! -f /root/.local/bin/spotdl ]]; then
        msg_error "No ${APP} Installation Found!"
        exit
    fi

    msg_error "Currently we don't provide an update function for this ${APP}."
    exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:[PORT]${CL}"
