# Base image is pinned in versions.yml and passed as a build arg by docker compose.
ARG SSH_TARGET_BASE_IMAGE=alpine:3.23
FROM ${SSH_TARGET_BASE_IMAGE}

RUN apk add --no-cache openssh-server rsync bash \
    && adduser -D -s /bin/bash deploy \
    && passwd -u deploy \
    && mkdir -p /home/deploy/.ssh /opt/app \
    && chown -R deploy:deploy /home/deploy/.ssh /opt/app \
    && chmod 700 /home/deploy/.ssh \
    && ssh-keygen -A

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
