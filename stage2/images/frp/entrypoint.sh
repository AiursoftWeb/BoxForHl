#!/bin/sh
set -e

# Download FRP binary on first run
if [ ! -f /usr/bin/frpc ]; then
    echo "FRP binary not found. Downloading..."
    latestUrl=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest \
        | jq -r '(.assets[] | select(.browser_download_url | contains("linux_amd64"))).browser_download_url')
    echo "Downloading: $latestUrl"
    wget --show-progress -O /tmp/frp.tar.gz "$latestUrl"
    mkdir -p /tmp/frp_extract
    tar -zxf /tmp/frp.tar.gz --directory /tmp/frp_extract
    frpcPath=$(find /tmp/frp_extract/ -name "frpc")
    cp "$frpcPath" /usr/bin/frpc
    chmod +x /usr/bin/frpc
    rm -rf /tmp/frp.tar.gz /tmp/frp_extract
    echo "FRP downloaded and installed."
fi

token=$(echo $FRP_TOKEN)
serverip=$(echo $FRP_SERVER)

if [ -z "$token" ]; then
    echo "No token provided."
    exit 1
fi

if [ -z "$serverip" ]; then
    echo "No server ip provided."
    exit 1
fi

echo "Server IP: $serverip"

echo "Touching frpc.toml"
touch /etc/frp/frpc.toml

echo "Editing frpc.toml"
sed -i "s/FRP_TOKEN/$token/g" /etc/frp/frpc.toml
sed -i "s/FRP_SERVER_IP/$serverip/g" /etc/frp/frpc.toml

echo "Starting frpc"
exec /usr/bin/frpc -c /etc/frp/frpc.toml
