FROM python:3.11-slim-bookworm

ARG APP_VERSION=1.5.1
LABEL org.opencontainers.image.title="Aliyun Guard" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/Felix666-ship-It/aliyun-guard"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai \
    ALIYUN_GUARD_CONTAINER=1 \
    ALIYUN_GUARD_CONTAINER_WEB_PORT=8765 \
    ALIYUN_GUARD_CONFIG=/data/config.json \
    ALIYUN_GUARD_STATE=/data/state.json \
    ALIYUN_GUARD_LOCK=/data/cycle.lock \
    ALIYUN_GUARD_LOG_DIR=/data/logs

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        tini \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN python -m pip install --no-cache-dir --disable-pip-version-check \
        -r /tmp/requirements.txt \
    && rm -f /tmp/requirements.txt

WORKDIR /opt/aliyun-guard
COPY src/aliyun_guard.py src/manager.py src/telegram_proxy.py src/telegram_control.py ./
COPY src/web_actions.py src/web_panel.py src/web_panel.html ./
COPY version.json ./version.json
COPY docker/entrypoint.sh /usr/local/bin/aliyun-guard-container

RUN chmod 700 /usr/local/bin/aliyun-guard-container \
    && mkdir -p /data/logs /opt/aliyun-guard/bin \
    && chmod 700 /data /data/logs /opt/aliyun-guard /opt/aliyun-guard/bin \
    && python -m py_compile \
        aliyun_guard.py manager.py telegram_proxy.py telegram_control.py web_actions.py web_panel.py

VOLUME ["/data", "/opt/aliyun-guard/bin"]
EXPOSE 8765
STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/aliyun-guard-container"]
CMD ["daemon"]
