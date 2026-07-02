FROM localhost:8080/box_starting/local_ubuntu AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends wget curl jq tar \
    && rm -rf /var/lib/apt/lists/*

COPY ./frpc.toml /etc/frp/
COPY ./entrypoint.sh /
RUN chmod +x /entrypoint.sh

ENTRYPOINT [ "sh", "-c", "/entrypoint.sh" ]
