#!/bin/bash
# SSH target entrypoint
# Copies the bind-mounted authorized_keys (read-only, root-owned) to the correct
# location with proper ownership and permissions for sshd.

set -e

chmod 700 /home/deploy/.ssh

# The authorized_keys file is bind-mounted read-only at a different path.
# Copy it with correct ownership so sshd accepts it.
if [[ -f /home/deploy/.ssh/authorized_keys_mounted ]]; then
    cp /home/deploy/.ssh/authorized_keys_mounted /home/deploy/.ssh/authorized_keys
    chown deploy:deploy /home/deploy/.ssh/authorized_keys
    chmod 600 /home/deploy/.ssh/authorized_keys
fi

# Start sshd in foreground
exec /usr/sbin/sshd -D -e
