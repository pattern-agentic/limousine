# syntax=docker/dockerfile:1.7
#
# Runtime-only image: expects the server binary, libflutter_pty.so, and the
# Flutter web bundle to be pre-built on the host (run `make local-build`).
# Pinned dev tooling baked in for use by services started inside the container.
#
# Single-arch (amd64) by design. Apple Silicon Macs run amd64 via Rosetta 2;
# negligible perf hit since the limousine server itself does almost no CPU
# work — it shells out to the host's docker daemon.

ARG NODE_VERSION=22.13.0
ARG UV_VERSION=0.8.4
ARG KUBECTL_VERSION=1.32.2
ARG AWS_CLI_VERSION=2.22.0
ARG NATS_CLI_VERSION=0.2.3
ARG DOCKER_CLI_VERSION=29.2.1
ARG SOPS_VERSION=3.11.0
ARG AGE_VERSION=1.2.1

FROM ubuntu:25.04

ARG NODE_VERSION
ARG UV_VERSION
ARG KUBECTL_VERSION
ARG AWS_CLI_VERSION
ARG NATS_CLI_VERSION
ARG DOCKER_CLI_VERSION
ARG SOPS_VERSION
ARG AGE_VERSION

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH=/opt/limousine/lib

# Base system + things several tools depend on (uv builds, ssh, jq, etc.).
# libnss-wrapper lets the entrypoint synthesise a /etc/passwd entry for the
# host uid we're launched as, so ssh/git stop complaining about "No user
# exists for uid <n>" when run by macOS users (uid 501) or any Linux user
# whose uid doesn't already exist in the base image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git openssh-client \
        bash jq gnupg lsb-release xz-utils unzip zip \
        python3 python3-pip pipx \
        build-essential \
        tzdata \
        libgtk-3-0 \
        libnss-wrapper \
    && rm -rf /var/lib/apt/lists/*

# Node + npm (official tarball, pinned).
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
        -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
        --exclude='*.md' --exclude='LICENSE' \
    && rm /tmp/node.tar.xz \
    && node --version && npm --version

# kubectl (pinned).
RUN curl -fsSLo /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client=true

# AWS CLI v2 (pinned).
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWS_CLI_VERSION}.zip" \
        -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install --bin-dir /usr/local/bin --install-dir /opt/aws-cli \
    && rm -rf /tmp/aws /tmp/awscliv2.zip \
    && aws --version

# uv (Astral) — pinned via the standalone installer.
RUN curl -LsSf "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-installer.sh" \
        | env UV_INSTALL_DIR=/usr/local/bin sh \
    && uv --version

# NATS CLI (pinned).
RUN curl -fsSL \
        "https://github.com/nats-io/natscli/releases/download/v${NATS_CLI_VERSION}/nats-${NATS_CLI_VERSION}-linux-amd64.zip" \
        -o /tmp/nats.zip \
    && unzip -j /tmp/nats.zip "*/nats" -d /usr/local/bin \
    && chmod +x /usr/local/bin/nats \
    && rm /tmp/nats.zip \
    && nats --version

# Docker CLI only (no daemon). Talks to host /var/run/docker.sock at runtime.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu plucky stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce-cli=5:${DOCKER_CLI_VERSION}-1~ubuntu.25.04~plucky \
    && rm -rf /var/lib/apt/lists/* \
    && docker --version

# python-dotenv CLI (every project's start command uses `dotenv -f X run …`).
RUN pipx install --global "python-dotenv[cli]" \
    && dotenv --version || true

# age — modern file-encryption tool. Used to derive the public key from the
# user-supplied age private key (`age-keygen -y`).
RUN curl -fsSL \
        "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz" \
        -o /tmp/age.tgz \
    && tar -xzf /tmp/age.tgz -C /tmp \
    && install -m 0755 /tmp/age/age /tmp/age/age-keygen /usr/local/bin/ \
    && rm -rf /tmp/age /tmp/age.tgz \
    && age --version && age-keygen --version 2>&1 | head -1

# sops — declarative secrets manager. Encrypts dotenv files per-value with
# the user's age recipient. Limousine shells out to it for read/write/edit
# of .env.secrets; project commands use `sops exec-env` to decrypt at runtime.
RUN curl -fsSL \
        "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
        -o /usr/local/bin/sops \
    && chmod +x /usr/local/bin/sops \
    && sops --version

# Pre-trust github.com SSH host keys so `git clone ssh://git@github.com/…` from
# inside the container doesn't hang on a "yes/no/[fingerprint]" prompt the user
# can't see. Pinned at build time; rebuild the image to pick up key rotations.
RUN install -d -m 0755 /etc/ssh \
    && ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> /etc/ssh/ssh_known_hosts \
    && chmod 0644 /etc/ssh/ssh_known_hosts \
    && echo "Baked host keys for github.com:" \
    && cut -d ' ' -f 1,2 /etc/ssh/ssh_known_hosts

# Stub credential helpers so docker CLI can satisfy `credsStore: desktop`
# from a macOS host's ~/.docker/config.json (mounted into the container).
# Without these, the very first `docker run <public-image>` from inside the
# container fails before even trying the pull. See the script for details.
COPY docker/docker-credential-shim.sh /usr/local/bin/docker-credential-desktop
RUN chmod +x /usr/local/bin/docker-credential-desktop \
    && ln -sf docker-credential-desktop /usr/local/bin/docker-credential-desktop-store \
    && ln -sf docker-credential-desktop /usr/local/bin/docker-credential-osxkeychain

# Pre-built limousine artifacts copied straight from the host build tree.
# Run `make local-build` first.
COPY build/bin/limousine-server      /opt/limousine/limousine-server
COPY build/bin/libflutter_pty.so     /opt/limousine/lib/libflutter_pty.so
COPY build/web/                      /opt/limousine/web/
COPY docker/entrypoint.sh            /usr/local/bin/limousine-entrypoint.sh
# The wrapper is bundled inside the image so users can extract it via the
# `export-limousine-script` subcommand without round-tripping through GitHub.
COPY scripts/limousine               /opt/limousine/scripts/limousine
RUN chmod +x /usr/local/bin/limousine-entrypoint.sh /opt/limousine/scripts/limousine

EXPOSE 7891 6891

ENTRYPOINT ["/usr/local/bin/limousine-entrypoint.sh"]
CMD ["--host", "0.0.0.0", "--port", "7891"]
