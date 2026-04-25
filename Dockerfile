FROM nvidia/cuda:12.8.0-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_VERSION=v22.19.0
ARG OLLAMA_DOWNLOAD_URL=https://ollama.com/download/ollama-linux-amd64.tar.zst

ENV OLLAMA_HOST=127.0.0.1:11434
ENV OLLAMA_SERVER_HOST=0.0.0.0:11434
ENV OLLAMA_MODELS=/data/ollama/models
ENV OPENCLAW_HOME=/data/openclaw
ENV OPENCLAW_CONFIG_DIR=/data/openclaw/config
ENV OPENCLAW_WORKSPACE_DIR=/data/openclaw/workspace
ENV HOME=/data/home
ENV KC_DEFAULT_SKILLS_DIR=/opt/kclawbox/default-skills
ENV KC_DEFAULT_OPENCLAW_SKILLS_DIR=/opt/kclawbox/default-openclaw-skills
ENV KC_DEFAULT_OPENCLAW_WORKSPACE_DIR=/opt/kclawbox/default-openclaw-workspace
ENV PATH=/usr/local/node/bin:/usr/local/bin:/usr/bin:/bin

COPY vendor/node-${NODE_VERSION}-linux-x64.tar.gz /tmp/node.tar.gz
RUN mkdir -p /usr/local/node \
  && tar -xzf /tmp/node.tar.gz -C /usr/local/node --strip-components=1 \
  && rm -f /tmp/node.tar.gz

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl zstd python3 python3-pip \
  && rm -rf /var/lib/apt/lists/* \
  && curl -fL "${OLLAMA_DOWNLOAD_URL}" -o /tmp/ollama.tar.zst \
  && zstd -dc /tmp/ollama.tar.zst | tar -xf - -C /usr/local \
  && rm -f /tmp/ollama.tar.zst \
  && pip3 install --no-cache-dir SRTrain==2.6.7

RUN mkdir -p /data/home /data/ollama/models /data/openclaw/config /data/openclaw/workspace \
  /usr/lib/git-core /lib/x86_64-linux-gnu

COPY vendor/host-root/usr/git /usr/bin/git
COPY vendor/host-root/usr/ssh /usr/bin/ssh
COPY vendor/host-root/usr/git-core/ /usr/lib/git-core/
COPY vendor/host-root/lib/x86_64-linux-gnu/libcurl-gnutls.so.4* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libnghttp2.so.14* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/librtmp.so.1 /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libssh.so.4* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libpsl.so.5* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libnettle.so.7* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libhogweed.so.5* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libldap_r-2.4.so.2* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/liblber-2.4.so.2* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libbrotlidec.so.1* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libbrotlicommon.so.1* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libgssapi.so.3* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libheimntlm.so.0* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libkrb5.so.26* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libasn1.so.8* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libhcrypto.so.4* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libroken.so.18* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libwind.so.0* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libheimbase.so.1* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libhx509.so.5* /lib/x86_64-linux-gnu/
COPY vendor/host-root/lib/x86_64-linux-gnu/libcrypto.so.1.1 /lib/x86_64-linux-gnu/
COPY default-skills/ /opt/kclawbox/default-skills/
COPY default-openclaw-skills/ /opt/kclawbox/default-openclaw-skills/
COPY default-openclaw-workspace/ /opt/kclawbox/default-openclaw-workspace/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN printf '%s\n' \
  '[url "https://github.com/"]' \
  '    insteadOf = ssh://git@github.com/' \
  '    insteadOf = git@github.com:' \
  > /etc/gitconfig \
  && chmod 755 /usr/local/bin/entrypoint.sh

EXPOSE 11434 18789

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
