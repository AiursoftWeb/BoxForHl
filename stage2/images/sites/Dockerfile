# ============================
# Prepare caddy Environment
FROM localhost:8080/public_mirror/caddy:builder AS caddy-build-env

ENV GOPROXY=https://goproxy.cn,direct

RUN xcaddy build \
    --with github.com/ueffel/caddy-brotli \
    --with github.com/caddyserver/transform-encoder \
    --with github.com/mholt/caddy-ratelimit

# ============================
# Prepare Caddyfile build Environment
FROM localhost:8080/box_starting/local_ubuntu AS config-build-env
WORKDIR /app

# Match the existing proxy configuration builder on Proart and Global.
RUN apt-get update && \
    apt-get install -y curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY . .

# Outputs to /app/Dist/Caddyfile
RUN chmod +x /app/build_proxy.sh
RUN /bin/bash /app/build_proxy.sh

# ============================
# Prepare Runtime Environment
FROM localhost:8080/public_mirror/caddy:latest

# Keep scheduled log rotation independent of daylight-saving changes.
ENV TZ=UTC

WORKDIR /app

EXPOSE 80 443

COPY --from=caddy-build-env /usr/bin/caddy /usr/bin/caddy
COPY --from=config-build-env /app/Dist/Caddyfile /etc/caddy/Caddyfile

# Check if any fatal errors in caddyfile
RUN caddy fmt --overwrite /etc/caddy/Caddyfile && \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && \
    mkdir -p /var/log/caddy /data/caddy/logs && \
    touch /data/caddy/logs/web.log

ENTRYPOINT ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
