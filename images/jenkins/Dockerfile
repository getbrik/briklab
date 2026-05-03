# Custom Jenkins image for Briklab
#
# Minimal master agent. Every Brik stage now runs inside a brik-runner
# image (init in brik-runner-base, build/test in brik-runner-<stack>,
# sast/lint in brik-runner-analysis, scan in brik-runner-scanner, deploy
# in brik-runner-deploy), so this image only needs:
#   - Jenkins itself (base image)
#   - git (for checkout scm on the master)
#   - docker-cli (to launch brik-runner containers via docker.image())
#   - jq + yq + curl (for the Notify stage which still runs on the master
#     to aggregate per-stage fragments and post webhooks)
#   - gosu + entrypoint (to fix docker socket permissions at startup)
#
# Anything else (node, maven, python, rust, dotnet, jv, gcc, libicu...)
# is provided by the brik-runner images and must NOT be installed here.

FROM jenkins/jenkins:2.541.3-lts-jdk21

USER root

# System dependencies needed on the master for Notify and SCM
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI (for pipeline docker build/push via mounted socket)
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# Install yq (Go binary) -- accept supply chain risk for local lab use.
# Used by the Notify stage's transverse helpers on the master.
ARG YQ_VERSION=v4.44.6
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# Allow jenkins user to access Docker socket (local lab only)
RUN groupadd -g 999 docker || true \
    && usermod -aG docker jenkins

# Pre-install plugins (single source of truth: config/jenkins/plugins.txt)
# This file is copied via docker-compose build context (see docker-compose.yml)
COPY config/jenkins/plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Entrypoint: fix docker socket permissions at startup (macOS GID differs)
COPY images/jenkins/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Entrypoint runs as root to fix socket permissions, then drops to jenkins
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
