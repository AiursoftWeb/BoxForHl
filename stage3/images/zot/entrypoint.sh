#!/bin/sh
set -e

ZOT_VERSION="v2.1.13"
ZOT_BIN="/config/zot"

# Download zot binary on first run (persisted on volume to survive restarts)
if [ ! -f "$ZOT_BIN" ]; then
    echo "zot binary not found. Downloading ${ZOT_VERSION}..."
    for url in \
        "https://github.com/project-zot/zot/releases/download/${ZOT_VERSION}/zot-linux-amd64" \
        "https://ghproxy.com/https://github.com/project-zot/zot/releases/download/${ZOT_VERSION}/zot-linux-amd64" \
    ; do
        if wget -q --timeout=120 --tries=3 -O "$ZOT_BIN" "$url" 2>/dev/null; then
            break
        fi
        echo "Download from $url failed, trying next..."
        rm -f "$ZOT_BIN"
    done
    if [ ! -f "$ZOT_BIN" ]; then
        echo "ERROR: Failed to download zot binary from all sources."
        exit 1
    fi
    chmod +x "$ZOT_BIN"
    echo "zot binary downloaded and installed successfully."
fi

ln -sf "$ZOT_BIN" /usr/local/bin/zot

# 确保挂载点存在
mkdir -p /config /etc/zot /data

# 处理 config.json：有就用它，没就复制默认的并软链
SRC_SETTINGS="/etc/zot/config.json"
VOL_SETTINGS="/config/config.json"
if [ ! -f "$VOL_SETTINGS" ]; then
    cp $SRC_SETTINGS $VOL_SETTINGS
fi
if [ -f "$SRC_SETTINGS" ]; then
    rm $SRC_SETTINGS
fi
ln -s $VOL_SETTINGS $SRC_SETTINGS

# 启动 zot
exec "$ZOT_BIN" serve /etc/zot/config.json
