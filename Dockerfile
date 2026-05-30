# codetainyrrr — config-only image. No Rust build: the insmaller engine binary
# is bundled and drives all install/lifecycle from the baked /etc/codetainyrrr
# config (installer.toml + catalog.json + wizard.toml + plugins/).
#
# `codetainyrrr-linux` must be present in the build context: the matching
# x86_64-unknown-linux-gnu insmaller engine binary, renamed to the product
# name (release.yml fetches it from the pinned insmaller release; locally it
# is built once from the engine source). insmaller is not forked — only the
# packaged binary is renamed.
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG HOST_UID=1000
ARG HOST_GID=1000
ARG USERNAME=dev

# Base packages always installed.
#
# Note on `gh`: pre-baked because claude-squad's upstream install.sh
# (gh: smtg-ai/claude-squad) tries to add the github-cli apt repo via
# `sudo dd`/`sudo tee`/`sudo chmod` — the container's sudoers only grants
# apt-get/apt, so the gh bootstrap would prompt for a password and fail.
# Pre-installing gh makes claude-squad's dependency check a no-op.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    bzip2 \
    ca-certificates \
    curl \
    gh \
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

# Bake the project's default user-editable configs into the dev user's home.
# Volume init copies these into the container's home volume on first mount, so
# the user gets a sensible starting config and can edit it inside the container.
# These ship with the project — they do NOT bind-mount or read from the host.
COPY --chown=${USERNAME}:${USERNAME} scripts/ccstatusline-default.json /home/${USERNAME}/.config/ccstatusline/settings.json
COPY --chown=${USERNAME}:${USERNAME} scripts/starship-default.toml      /home/${USERNAME}/.config/starship.toml
COPY --chown=${USERNAME}:${USERNAME} scripts/zshrc-extra-default.zsh    /home/${USERNAME}/.config/zsh/extra.zsh

USER root

WORKDIR /workspace

# Bundle the engine binary as `codetainyrrr` (config-only: no in-image Rust
# build). Same insmaller binary, product-renamed at packaging time.
COPY codetainyrrr-linux /usr/local/bin/codetainyrrr
RUN chmod +x /usr/local/bin/codetainyrrr

# Bake the insmaller config so the entrypoint installs without a bind-mount.
# plugins/ MUST sit beside installer.toml (insmaller bounds recipe-pack plugin
# paths to the config's directory).
COPY catalog.json    /etc/codetainyrrr/catalog.json
COPY installer.toml  /etc/codetainyrrr/installer.toml
COPY wizard.toml     /etc/codetainyrrr/wizard.toml
COPY plugins         /etc/codetainyrrr/plugins

# Thin entrypoint shim: fix ownership as root, drop to dev user, run codetainyrrr install.
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD []
