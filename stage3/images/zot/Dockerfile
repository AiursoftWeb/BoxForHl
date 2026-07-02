FROM localhost:8080/box_starting/local_ubuntu

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends wget ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/zot /config /data

COPY default-config.json /etc/zot/default-config.json
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 5000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]