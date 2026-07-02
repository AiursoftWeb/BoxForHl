FROM localhost:8080/public_mirror/teddysun/xray:latest

COPY config.json /etc/xray/config.json
COPY entrypoint.sh /entrypoint.sh

RUN apk add --no-cache jq

EXPOSE 10809 10808
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
