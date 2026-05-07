# ── Stage 1: build the codetainyrrr binary ────────────────────────────────────
FROM rust:slim-bookworm AS builder

WORKDIR /build

# Cache dependency compilation separately from source changes.
# Copy manifests first, build a dummy main, then replace with real source.
COPY Cargo.toml Cargo.lock ./
COPY crates/codetainyrrr/Cargo.toml crates/codetainyrrr/
RUN mkdir -p crates/codetainyrrr/src \
    && echo 'fn main(){}' > crates/codetainyrrr/src/main.rs \
    && cargo build --release --manifest-path crates/codetainyrrr/Cargo.toml \
    && rm crates/codetainyrrr/src/main.rs

# Now build the real source
COPY crates/codetainyrrr/src crates/codetainyrrr/src
RUN touch crates/codetainyrrr/src/main.rs \
    && cargo build --release --manifest-path crates/codetainyrrr/Cargo.toml

# ── Stage 2: runtime image ────────────────────────────────────────────────────
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG HOST_UID=1000
ARG HOST_GID=1000
ARG USERNAME=dev

# Base packages always installed
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    gnupg \
    gosu \
    jq \
    less \
    locales \
    procps \
    python3 \
    python3-pip \
    python3-venv \
    sudo \
    unzip \
    vim-tiny \
    wget \
    zip \
    zsh \
    && echo "en_US.UTF-8 UTF-8" > /etc/locale.gen \
    && locale-gen en_US.UTF-8 \
    && echo 'LANG=en_US.UTF-8' > /etc/default/locale \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Create unprivileged user matching host UID/GID.
# Passwordless sudo for apt only — limits blast radius if MCP goes rogue.
RUN groupadd --gid ${HOST_GID} ${USERNAME} 2>/dev/null || true \
    && useradd \
        --uid ${HOST_UID} \
        --gid ${HOST_GID} \
        --shell /bin/zsh \
        --create-home \
        --no-log-init \
        ${USERNAME} \
    && echo "${USERNAME} ALL=(root) NOPASSWD: /usr/bin/apt-get,/usr/bin/apt" \
       > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

USER ${USERNAME}

# Pre-create home subdirs owned by the dev user so volume seeding has the right structure.
RUN mkdir -p \
    ~/.cache \
    ~/.nvm \
    ~/.sdkman \
    ~/.config/zsh \
    ~/.local/bin \
    ~/.local/share/codetainyrrr \
    ~/.claude \
    ~/.continue \
    ~/.pi \
    ~/.aider \
    ~/go \
    ~/.cargo \
    ~/.rustup \
    ~/.deno \
    ~/.bun \
    ~/.dotnet \
    ~/.codex \
    ~/.gemini \
    ~/workspaces

# Bake .zshrc into the image so connecting immediately gets a proper shell
COPY --chown=${USERNAME}:${USERNAME} scripts/zshrc /home/${USERNAME}/.zshrc

USER root

WORKDIR /workspace

# Install the codetainyrrr binary
COPY --from=builder /build/target/release/codetainyrrr /usr/local/bin/codetainyrrr

# Bake catalog.json + wizard.json so the entrypoint can read them without a bind-mount
COPY catalog.json  /etc/codetainyrrr/catalog.json
COPY wizard.json   /etc/codetainyrrr/wizard.json

# Thin entrypoint shim: fix ownership as root, drop to dev user, hand off to Rust binary
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD []
