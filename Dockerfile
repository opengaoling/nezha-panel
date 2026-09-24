FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates tzdata && rm -rf /var/lib/apt/lists/*

COPY ./script/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /dashboard
ARG TARGETOS
ARG TARGETARCH
COPY dist/dashboard-${TARGETOS}-${TARGETARCH} ./app
COPY cmd/dashboard/user-dist ./user-dist
COPY cmd/dashboard/admin-dist ./admin-dist

VOLUME ["/dashboard/data"]
EXPOSE 2052
ARG TZ=Asia/Shanghai
ENV TZ=$TZ
ENTRYPOINT ["/entrypoint.sh"]
