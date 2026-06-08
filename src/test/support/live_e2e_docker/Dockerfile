FROM node:20-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    git \
    openssh-server \
    python3 \
    ripgrep \
  && rm -rf /var/lib/apt/lists/*

RUN install -d -m 700 /root/.ssh /root/.codex /run/aiur/ssh /var/run/sshd

RUN npm install --global @openai/codex

COPY aiur-live-worker.conf /etc/ssh/sshd_config.d/aiur-live-worker.conf
COPY live_worker_entrypoint.sh /usr/local/bin/aiur-live-worker
RUN chmod 755 /usr/local/bin/aiur-live-worker

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/aiur-live-worker"]
