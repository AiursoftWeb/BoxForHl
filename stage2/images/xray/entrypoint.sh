#!/bin/sh
set -e

if [ -z "$XRAY_SERVER" ] || [ -z "$XRAY_UUID" ]; then
    echo "ERROR: XRAY_SERVER and XRAY_UUID must be set."
    exit 1
fi

echo "Generating xray config..."
jq \
    --arg server "$XRAY_SERVER" \
    --arg uuid   "$XRAY_UUID" \
    '.outbounds[0].settings.vnext[0].address = $server | .outbounds[0].settings.vnext[0].users[0].id = $uuid' \
    /etc/xray/config.json > /etc/xray/config.json.tmp

mv /etc/xray/config.json.tmp /etc/xray/config.json
echo "Starting xray..."
exec /usr/bin/xray -config /etc/xray/config.json
