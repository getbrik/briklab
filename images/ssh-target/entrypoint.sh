#!/bin/bash
# SSH target entrypoint
# Ensures authorized_keys permissions are correct, then starts sshd.

set -e

# Fix permissions (the file is mounted read-only, but the directory must be 700)
chmod 700 /home/deploy/.ssh
if [[ -f /home/deploy/.ssh/authorized_keys ]]; then
    chmod 600 /home/deploy/.ssh/authorized_keys 2>/dev/null || true
fi

# Start sshd in foreground
exec /usr/sbin/sshd -D -e
