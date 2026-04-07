#!/bin/bash
# Fix Docker socket permissions for Jenkins (local lab only).
# On macOS (Docker Desktop) the socket GID may not match the container's docker group.
if [ -S /var/run/docker.sock ]; then
    # Make socket group-writable and assign to the docker group
    SOCK_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null)
    if [ -n "$SOCK_GID" ] && [ "$SOCK_GID" != "0" ]; then
        groupmod -g "$SOCK_GID" docker 2>/dev/null || true
    fi
    chmod 666 /var/run/docker.sock 2>/dev/null || true
fi

# Switch to jenkins user and start Jenkins
exec gosu jenkins /usr/local/bin/jenkins.sh "$@"
