# Custom Jenkins image for Briklab
# Adds yq, jq, jv, Node.js, and pre-installed plugins

# Stage: build jv (santhosh-tekuri/jsonschema CLI) statically.
# Same pattern as brik-images/images/base/Dockerfile so prereqs_present.jv
# matches what GitLab runners report (true).
ARG JV_VERSION=v6.0.2
FROM golang:1.23-alpine AS jv-builder
ARG JV_VERSION
RUN apk add --no-cache git \
 && git clone --depth 1 --branch ${JV_VERSION} https://github.com/santhosh-tekuri/jsonschema /src
WORKDIR /src/cmd/jv
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /jv .

FROM jenkins/jenkins:2.541.3-lts-jdk21

USER root

# jv (JSON Schema validator) for brik validate + init prereqs probe
COPY --from=jv-builder /jv /usr/local/bin/jv

# Install system dependencies (gcc needed for Rust cargo test linking)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    gosu \
    gcc \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI (for pipeline docker build/push via mounted socket)
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# Install yq (Go binary) -- accept supply chain risk for local lab use
ARG YQ_VERSION=v4.44.6
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# Install Node.js LTS (for test projects) -- NodeSource setup script, local lab only
ARG NODE_MAJOR=22
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Maven (for java-complete E2E)
ARG MAVEN_VERSION=3.9.15
RUN curl -fsSL "https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
    | tar -xz -C /opt \
    && ln -s "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn

# Install Python build tools (for python-complete E2E)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m pip install --break-system-packages twine build ruff \
    && ln -sf "$(command -v pip3)" /usr/local/bin/pip \
    && ln -sf /usr/bin/python3 /usr/local/bin/python

# Install Rust toolchain (for rust-complete E2E) -- shared location readable by all users
ENV CARGO_HOME=/opt/rust/cargo RUSTUP_HOME=/opt/rust/rustup
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile default \
    && chmod -R a+rX /opt/rust \
    && ln -s /opt/rust/cargo/bin/* /usr/local/bin/

# Install .NET SDK (for dotnet-complete E2E)
RUN apt-get update && apt-get install -y --no-install-recommends libicu-dev \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 9.0 --install-dir /usr/share/dotnet \
    && ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet

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
