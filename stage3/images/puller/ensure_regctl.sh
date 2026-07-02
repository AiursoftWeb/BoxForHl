#!/bin/bash
set -e

if [ -x /usr/local/bin/regctl ]; then
    echo "regctl already installed."
    exit 0
fi

echo "regctl not found. Downloading..."

for url in \
    "https://github.com/regclient/regclient/releases/latest/download/regctl-linux-amd64" \
    "https://git.aiursoft.com/PublicVault/regclient/releases/download/mirror/regctl-linux-amd64" \
; do
    if curl -m 120 --retry 3 -L "$url" -o /tmp/regctl-dl 2>/dev/null; then
        break
    fi
    echo "Download from $url failed, trying next..."
    rm -f /tmp/regctl-dl
done

if [ ! -f /tmp/regctl-dl ]; then
    echo "ERROR: Failed to download regctl from all sources."
    exit 1
fi

# Validate the download is an ELF binary
if ! head -c 4 /tmp/regctl-dl | od -An -tx1 | tr -d ' \n' | grep -q '7f454c46'; then
    echo "ERROR: Downloaded regctl is not a valid ELF binary (likely blocked by CDN)."
    head -c 200 /tmp/regctl-dl
    rm -f /tmp/regctl-dl
    exit 1
fi

mv /tmp/regctl-dl /usr/local/bin/regctl
chmod 755 /usr/local/bin/regctl
echo "regctl downloaded and installed successfully."
