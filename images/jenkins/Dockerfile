# Custom Jenkins image for Briklab
# Adds yq, jq, Node.js, and pre-installed plugins
FROM jenkins/jenkins:2.541.3-lts-jdk21

USER root

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install yq (Go binary) -- accept supply chain risk for local lab use
ARG YQ_VERSION=v4.44.6
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# Install Node.js LTS (for test projects) -- NodeSource setup script, local lab only
ARG NODE_MAJOR=22
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Pre-install plugins (single source of truth: config/jenkins/plugins.txt)
# This file is copied via docker-compose build context (see docker-compose.level2.yml)
COPY config/jenkins/plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

USER jenkins
