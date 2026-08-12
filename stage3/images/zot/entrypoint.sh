#!/bin/sh
set -e

ZOT_VERSION="v2.1.20"
ZOT_BIN="/config/zot"

# Download zot when it is missing, broken, or does not match ZOT_VERSION.
if [ ! -x "$ZOT_BIN" ] || ! "$ZOT_BIN" --version 2>&1 | grep -q "\"commit\":\"${ZOT_VERSION}-"; then
    echo "zot binary is missing or outdated. Downloading ${ZOT_VERSION}..."
    ZOT_DOWNLOAD="${ZOT_BIN}.download.$$"
    trap 'rm -f "$ZOT_DOWNLOAD"' EXIT INT TERM
    rm -f "$ZOT_DOWNLOAD"
    for url in \
        "https://github.com/project-zot/zot/releases/download/${ZOT_VERSION}/zot-linux-amd64" \
        "https://ghproxy.com/https://github.com/project-zot/zot/releases/download/${ZOT_VERSION}/zot-linux-amd64" \
    ; do
        if wget --show-progress --timeout=120 --tries=3 -O "$ZOT_DOWNLOAD" "$url"; then
            chmod +x "$ZOT_DOWNLOAD"
            if "$ZOT_DOWNLOAD" --version 2>&1 | grep -q "\"commit\":\"${ZOT_VERSION}-"; then
                mv "$ZOT_DOWNLOAD" "$ZOT_BIN"
                trap - EXIT INT TERM
                echo "zot ${ZOT_VERSION} downloaded and installed successfully."
                break
            fi
            echo "Downloaded binary does not report ${ZOT_VERSION}, trying next source..."
        else
            echo "Download from $url failed, trying next..."
        fi
        rm -f "$ZOT_DOWNLOAD"
    done
    if [ ! -x "$ZOT_BIN" ] || ! "$ZOT_BIN" --version 2>&1 | grep -q "\"commit\":\"${ZOT_VERSION}-"; then
        echo "ERROR: Failed to install zot ${ZOT_VERSION} from all sources."
        exit 1
    fi
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
