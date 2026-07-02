#!/bin/sh
set -e

ZOT_VERSION="v2.1.13"
ZOT_BIN="/config/zot"

# Download zot binary on first run, or if existing binary is broken
if [ ! -f "$ZOT_BIN" ] || [ ! -x "$ZOT_BIN" ]; then
    echo "zot binary not found or not executable. Downloading ${ZOT_VERSION}..."
    rm -f "$ZOT_BIN"
    for url in \
        "https://github.com/project-zot/zot/releases/download/${ZOT_VERSION}/zot-linux-amd64" \
        "https://ghproxy.com/https://github.com/project-zot/zot/releases/download/${ZOT_VERSION}/zot-linux-amd64" \
    ; do
        if wget --show-progress --timeout=120 --tries=3 -O "$ZOT_BIN" "$url"; then
            chmod +x "$ZOT_BIN"
            break
        fi
        echo "Download from $url failed, trying next..."
        rm -f "$ZOT_BIN"
    done
    if [ ! -f "$ZOT_BIN" ] || [ ! -x "$ZOT_BIN" ]; then
        echo "ERROR: Failed to download zot binary from all sources."
        exit 1
    fi
    echo "zot binary downloaded and installed successfully."
fi

ln -sf "$ZOT_BIN" /usr/local/bin/zot

mkdir -p /config /etc/zot /data

SRC_SETTINGS="/etc/zot/config.json"
VOL_SETTINGS="/config/config.json"
if [ ! -f "$VOL_SETTINGS" ]; then
    cp $SRC_SETTINGS $VOL_SETTINGS
fi
if [ -f "$SRC_SETTINGS" ]; then
    rm $SRC_SETTINGS
fi
ln -s $VOL_SETTINGS $SRC_SETTINGS

exec "$ZOT_BIN" serve /etc/zot/config.json
