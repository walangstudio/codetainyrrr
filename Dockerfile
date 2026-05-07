FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG HOST_UID=1000
ARG HOST_GID=1000
ARG USERNAME=dev

# System tools that require apt — set to "true" to bake into the image.
# After changing these, rebuild with: ./run.sh --build
ARG INSTALL_CPP=false
ARG INSTALL_PHP=false
ARG INSTALL_RUBY=false

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

# Optional system packages — combined into one layer to keep image size down
RUN set -e; \
    PKGS=""; \
    [ "$INSTALL_CPP"  = "true" ] && PKGS="$PKGS build-essential clang cmake gdb valgrind"; \
    [ "$INSTALL_PHP"  = "true" ] && PKGS="$PKGS php-cli php-mbstring php-xml php-curl"; \
    [ "$INSTALL_RUBY" = "true" ] && PKGS="$PKGS ruby-full"; \
    if [ -n "$PKGS" ]; then \
        apt-get update && apt-get install -y --no-install-recommends $PKGS \
        && rm -rf /var/lib/apt/lists/*; \
    fi

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
# with correct PATH, aliases, and auto-launch logic. Plugins (zsh-autosuggestions,
# starship) are sourced if present — installed lazily into the home volume.
COPY --chown=${USERNAME}:${USERNAME} scripts/zshrc /home/${USERNAME}/.zshrc

# Switch back to root — entrypoint starts as root, fixes /home/dev ownership,
# then drops to the dev user via gosu before running any user code.
USER root

WORKDIR /workspace

COPY scripts/entrypoint.sh /entrypoint.sh
COPY catalog.json /catalog.json
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD []
