# ===========================================================================
#  podman-wrk :: portable developer work environment
#  Author: Mateusz Okulanis
#
#  Built ONCE on a machine with internet access, then exported and loaded on
#  air-gapped targets. Everything the environment needs - packages, Oh My Zsh,
#  Neovim plugins, LSP servers, tree-sitter parsers - is materialised here so
#  that nothing has to be fetched at runtime.
#
#  Build it through the script, not by hand:
#      ./podman-wrk.sh build
#
#  Identity note: the image intentionally carries a NEUTRAL user (wrk/1000).
#  The real UID/GID/username is resolved on the target host at import time and
#  applied via `--userns=keep-id:uid=,gid=`. See §"User identity" in README.md.
# ===========================================================================

ARG WRK_BASE_IMAGE=docker.io/library/archlinux:base-devel
FROM ${WRK_BASE_IMAGE}

ARG WRK_USER=wrk
ARG WRK_UID=1000
ARG WRK_GID=1000
ARG WRK_TZ=UTC
ARG WRK_BUILD_DATE=unknown
ARG WRK_NVIM_LSP="lua-language-server bash-language-server basedpyright json-lsp yaml-language-server typescript-language-server clangd stylua shfmt ruff"
ARG WRK_NVIM_TS=""

ENV EDITOR=nvim \
    VISUAL=nvim \
    PAGER=less \
    TERM=xterm-256color

# pipefail matters here: several RUN steps pipe a verbose command into `tail`,
# and without it a failure on the left-hand side would be silently swallowed.
# (Podman warns that SHELL is not persisted in OCI images - harmless, the final
# ENTRYPOINT/CMD are set explicitly.)
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---------------------------------------------------------------------------
#  1. System packages
#     archlinux-keyring first: base images go stale and signature checks then
#     fail on an otherwise perfectly good mirror.
# ---------------------------------------------------------------------------
RUN pacman -Sy --noconfirm --needed archlinux-keyring \
 && pacman -Su --noconfirm

# `grep -v` exits 1 when it filters everything out, which under pipefail would
# abort the build on a comments-only list. Hence the `|| true` on every read.
COPY packages/pacman.txt /tmp/pacman.txt
RUN pkgs="$(grep -vE '^[[:space:]]*(#|$)' /tmp/pacman.txt | tr '\n' ' ' || true)" \
 && echo "installing: $pkgs" \
 && pacman -S --noconfirm --needed $pkgs \
 && rm -f /tmp/pacman.txt

# ---------------------------------------------------------------------------
#  2. Locales and timezone
#     LANG is only exported once the locale actually exists - setting it any
#     earlier makes every later command complain "cannot change locale".
# ---------------------------------------------------------------------------
RUN sed -i -e 's/^#\(en_US\.UTF-8 UTF-8\)/\1/' \
           -e 's/^#\(pl_PL\.UTF-8 UTF-8\)/\1/' /etc/locale.gen \
 && locale-gen \
 && echo 'LANG=en_US.UTF-8' > /etc/locale.conf \
 && ln -snf "/usr/share/zoneinfo/${WRK_TZ}" /etc/localtime \
 && echo "${WRK_TZ}" > /etc/timezone

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# ---------------------------------------------------------------------------
#  3. Unprivileged user with passwordless sudo
#     bash is the login shell - zsh is one `wrk shell --zsh` away.
# ---------------------------------------------------------------------------
RUN groupadd -g "${WRK_GID}" "${WRK_USER}" \
 && useradd -m -u "${WRK_UID}" -g "${WRK_GID}" -G wheel -s /bin/bash "${WRK_USER}" \
 && printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${WRK_USER}" > /etc/sudoers.d/99-wrk \
 && chmod 0440 /etc/sudoers.d/99-wrk \
 && mkdir -p /wrk \
 && chown "${WRK_UID}:${WRK_GID}" /wrk

# ---------------------------------------------------------------------------
#  4. yay (AUR helper) - must be built as a non-root user
# ---------------------------------------------------------------------------
USER ${WRK_USER}
WORKDIR /home/${WRK_USER}

RUN git clone --depth 1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin \
 && cd /tmp/yay-bin \
 && makepkg -si --noconfirm \
 && cd / \
 && rm -rf /tmp/yay-bin

COPY packages/aur.txt /tmp/aur.txt
RUN pkgs="$(grep -vE '^[[:space:]]*(#|$)' /tmp/aur.txt | tr '\n' ' ' || true)" \
 && if [ -n "$pkgs" ]; then \
        echo "installing from AUR: $pkgs"; \
        yay -S --noconfirm --needed --removemake --answerdiff None --answerclean All $pkgs; \
    else \
        echo "no AUR packages requested"; \
    fi

# ---------------------------------------------------------------------------
#  5. Oh My Zsh, plugins and the mtsh theme
# ---------------------------------------------------------------------------
RUN OMZ="/home/${WRK_USER}/.oh-my-zsh" \
 && git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$OMZ" \
 && git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git \
        "$OMZ/custom/plugins/zsh-autosuggestions" \
 && git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting.git \
        "$OMZ/custom/plugins/zsh-syntax-highlighting" \
 && git clone --depth 1 https://github.com/Aloxaf/fzf-tab.git \
        "$OMZ/custom/plugins/fzf-tab" \
 && mkdir -p "$OMZ/custom/themes" \
 && git clone --depth 1 https://github.com/FPGArtktic/ohmyzsh-mtsh-theme.git /tmp/mtsh \
 && cp /tmp/mtsh/mtsh.zsh-theme "$OMZ/custom/themes/mtsh.zsh-theme" \
 && rm -rf /tmp/mtsh "$OMZ/.git"

# ---------------------------------------------------------------------------
#  6. Dotfiles and entrypoint
# ---------------------------------------------------------------------------
USER root
COPY rootfs/ /
RUN chmod 0755 /usr/local/bin/wrk-entrypoint.sh \
 && cp -a /etc/skel/. "/home/${WRK_USER}/" \
 && chown -R "${WRK_UID}:${WRK_GID}" "/home/${WRK_USER}"

# ---------------------------------------------------------------------------
#  7. Neovim: LazyVim + every plugin, parser and language server baked in
#
#     WRK_BUILD=1 tells our lua config that fetching is allowed right now.
#     `Lazy! sync` runs twice on purpose: the first pass installs LazyVim
#     itself, the second one picks up the extras in wrk-extras.lua, which can
#     only be probed once LazyVim exists on disk.
# ---------------------------------------------------------------------------
USER ${WRK_USER}
WORKDIR /home/${WRK_USER}

RUN git clone --depth 1 https://github.com/LazyVim/starter.git /tmp/lazyvim-starter \
 && rm -rf /tmp/lazyvim-starter/.git /tmp/lazyvim-starter/lua/plugins/example.lua \
 && mkdir -p "/home/${WRK_USER}/.config/nvim" \
 && rsync -a --ignore-existing /tmp/lazyvim-starter/ "/home/${WRK_USER}/.config/nvim/" \
 && rm -rf /tmp/lazyvim-starter

RUN WRK_BUILD=1 nvim --headless "+Lazy! sync" +qa 2>&1 | tail -n 20 \
 && WRK_BUILD=1 nvim --headless "+Lazy! sync" +qa 2>&1 | tail -n 20 \
 && WRK_BUILD=1 nvim --headless "+Lazy! sync" +qa 2>&1 | tail -n 20

# Language servers, formatters, linters and tree-sitter parsers.
#
# This deliberately does NOT use `nvim --headless -c "MasonInstall ..." -c qa`:
# that fires the installs and immediately quits, mason kills them on the way
# out, and the build "succeeds" with an image that has no language servers at
# all. nvim-bootstrap.lua issues the same installs and then blocks until they
# have finished. It is also not run with `nvim -l`, which skips init.lua and so
# never loads lazy.nvim in the first place.
RUN WRK_BUILD=1 WRK_NVIM_LSP="${WRK_NVIM_LSP}" WRK_NVIM_TS="${WRK_NVIM_TS}" \
    nvim --headless -c "luafile /usr/local/share/podman-wrk/nvim-bootstrap.lua" 2>&1 | tail -n 40

# Fail loudly rather than shipping a half-built environment: an offline image
# whose LSP servers or parsers are missing cannot be repaired on the target.
RUN set -eu; \
    mason_count="$( (ls -1 "$HOME/.local/share/nvim/mason/packages" 2>/dev/null || true) | wc -l )"; \
    parser_count="$(find "$HOME/.local/share/nvim" -name '*.so' -path '*parser*' 2>/dev/null | wc -l)"; \
    plugin_count="$( (ls -1 "$HOME/.local/share/nvim/lazy" 2>/dev/null || true) | wc -l )"; \
    echo "baked in: $plugin_count plugins, $mason_count mason packages, $parser_count parsers"; \
    [ "$plugin_count" -ge 20 ] || { echo "FATAL: too few plugins installed"; exit 1; }; \
    [ "$mason_count"  -ge 5  ] || { echo "FATAL: mason packages missing - the image would be useless offline"; exit 1; }; \
    [ "$parser_count" -ge 10 ] || { echo "FATAL: tree-sitter parsers missing"; exit 1; }

# ---------------------------------------------------------------------------
#  8. Trim the image
#     Only the package cache goes; the pacman sync databases stay so that the
#     USER PACKAGES section below still works without a network refresh.
# ---------------------------------------------------------------------------
USER root
RUN rm -rf /var/cache/pacman/pkg/* \
           "/home/${WRK_USER}/.cache/yay" \
           "/home/${WRK_USER}/.cargo/registry" \
           /tmp/* /var/tmp/* \
 && rm -rf /usr/share/doc/* \
 && find "/home/${WRK_USER}/.local/share/nvim/lazy" -type d -name '.git' -prune -exec rm -rf {} + 2>/dev/null || true


##############################################################################
##############################################################################
##                                                                          ##
##   >>>>>>>>>>>>>>   U S E R   P A C K A G E S   -   A D D                  ##
##                    Y O U R   O W N   S T U F F   H E R E   <<<<<<<<<<<<   ##
##                                                                          ##
##   Two ways, pick either or both:                                         ##
##                                                                          ##
##   A) Edit nothing here. Just list package names, one per line, in         ##
##        packages/extra-pacman.txt   (official repos, installed by pacman)  ##
##        packages/extra-aur.txt      (AUR, installed by yay)                ##
##      The RUN below picks them up automatically and is a no-op when both   ##
##      files are empty.                                                     ##
##                                                                          ##
##   B) Write your own RUN instructions under the marker further down.       ##
##      You are running as the unprivileged user with passwordless sudo,     ##
##      so both `sudo pacman -S ...` and `yay -S ...` work.                  ##
##                                                                          ##
##   This is the LAST layer of the image on purpose: changing it rebuilds    ##
##   only a few seconds' worth of work instead of the whole environment.     ##
##                                                                          ##
##############################################################################
##############################################################################

USER ${WRK_USER}
WORKDIR /home/${WRK_USER}

COPY packages/extra-pacman.txt packages/extra-aur.txt /tmp/

RUN extra_pac="$(grep -vE '^[[:space:]]*(#|$)' /tmp/extra-pacman.txt | tr '\n' ' ' || true)" \
 && extra_aur="$(grep -vE '^[[:space:]]*(#|$)' /tmp/extra-aur.txt | tr '\n' ' ' || true)" \
 && if [ -n "$extra_pac" ]; then \
        echo "user packages (pacman): $extra_pac"; \
        sudo pacman -S --noconfirm --needed $extra_pac; \
    fi \
 && if [ -n "$extra_aur" ]; then \
        echo "user packages (AUR): $extra_aur"; \
        yay -S --noconfirm --needed --removemake --answerdiff None --answerclean All $extra_aur; \
    fi \
 && sudo rm -rf /var/cache/pacman/pkg/* "/home/${WRK_USER}/.cache/yay" \
 && sudo rm -f /tmp/extra-pacman.txt /tmp/extra-aur.txt

# --------------------------------------------------------------------------
# --- ADD YOUR OWN RUN INSTRUCTIONS BELOW THIS LINE ------------------------
# --------------------------------------------------------------------------
#
# RUN sudo pacman -S --noconfirm --needed docker-compose kubectl
# RUN yay -S --noconfirm --needed lazydocker
# RUN pip install --user --break-system-packages httpie
# COPY my-config/ /home/${WRK_USER}/.config/my-config/
#
# --------------------------------------------------------------------------
# --- END OF USER SECTION --------------------------------------------------
# --------------------------------------------------------------------------


# ---------------------------------------------------------------------------
#  Final image metadata. podman-wrk.sh reads these labels back to decide how to
#  map the host user into the container, so keep them last and keep them right.
# ---------------------------------------------------------------------------
USER ${WRK_USER}
WORKDIR /wrk

LABEL org.opencontainers.image.title="podman-wrk" \
      org.opencontainers.image.description="Portable air-gapped developer work environment (Arch Linux)" \
      org.opencontainers.image.authors="Mateusz Okulanis" \
      org.opencontainers.image.licenses="Unlicense" \
      org.opencontainers.image.created="${WRK_BUILD_DATE}" \
      wrk.user="${WRK_USER}" \
      wrk.uid="${WRK_UID}" \
      wrk.gid="${WRK_GID}" \
      wrk.localized="0"

ENTRYPOINT ["/usr/local/bin/wrk-entrypoint.sh"]
CMD ["/bin/bash", "-l"]
