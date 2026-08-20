#!/usr/bin/env bash
# ===========================================================================
#  podman-wrk :: container entrypoint
#
#  Runs on every `podman start`, i.e. every time you enter the environment.
#  Its whole job is to make the container's private state line up with the
#  host it happens to be running on right now:
#
#    1. copy the host's SSH material into a writable, correctly-permissioned
#       ~/.ssh (the host directory itself is mounted read-only)
#    2. make sure /wrk exists
#    3. seed an empty $HOME from /etc/skel
#
#  Then it hands control to the requested command (bash by default).
# ===========================================================================
set -uo pipefail

HOST_SSH="${WRK_HOST_SSH_DIR:-/mnt/host-ssh}"
HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"
export HOME

# Persistent per-container state that must survive ~/.ssh being a tmpfs.
STATE_DIR="$HOME/.local/state/podman-wrk"

wrk_warn() { printf '\033[0;33mpodman-wrk:\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
#  1. SSH keys from the host
#
#  The mount is read-only so the host's keys can never be modified from inside
#  the container. We copy them out so that ssh can enforce its strict
#  permission checks and so known_hosts stays writable. Only regular files in
#  the top level are copied - this deliberately skips sockets such as
#  ~/.ssh/agent, which cannot be copied and are exposed via SSH_AUTH_SOCK
#  instead.
# ---------------------------------------------------------------------------
if [ -d "$HOST_SSH" ]; then
    # podman mounts the tmpfs as root:root and its --tmpfs option has no
    # uid=/gid=, so take ownership before writing anything into it. Harmless
    # when ~/.ssh is an ordinary directory.
    if [ -d "$HOME/.ssh" ] && [ ! -O "$HOME/.ssh" ]; then
        sudo -n chown "$(id -u):$(id -g)" "$HOME/.ssh" 2>/dev/null || \
            wrk_warn "could not take ownership of $HOME/.ssh"
    fi

    if mkdir -p "$HOME/.ssh" 2>/dev/null; then
        while IFS= read -r -d '' src; do
            cp -f "$src" "$HOME/.ssh/" 2>/dev/null || \
                wrk_warn "could not copy $(basename "$src") from the host"
        done < <(find "$HOST_SSH" -maxdepth 1 -type f -print0 2>/dev/null)

        chmod 700 "$HOME/.ssh" 2>/dev/null

        # Everything is private by default; only *.pub is world-readable.
        find "$HOME/.ssh" -maxdepth 1 -type f -exec chmod 600 {} + 2>/dev/null
        find "$HOME/.ssh" -maxdepth 1 -type f -name '*.pub' -exec chmod 644 {} + 2>/dev/null

        # ~/.ssh is a tmpfs so that `commit` can never bake private keys into
        # the image. That would also throw away every host fingerprint you
        # accepted, so known_hosts - which is not a credential - is redirected
        # to a real file in the persistent layer and symlinked back into place.
        if mkdir -p "$STATE_DIR" 2>/dev/null; then
            if [ ! -f "$STATE_DIR/known_hosts" ] && [ -f "$HOST_SSH/known_hosts" ]; then
                cp -f "$HOST_SSH/known_hosts" "$STATE_DIR/known_hosts" 2>/dev/null
            fi
            [ -f "$STATE_DIR/known_hosts" ] || touch "$STATE_DIR/known_hosts" 2>/dev/null
            chmod 600 "$STATE_DIR/known_hosts" 2>/dev/null
            rm -f "$HOME/.ssh/known_hosts" 2>/dev/null
            ln -sfn "$STATE_DIR/known_hosts" "$HOME/.ssh/known_hosts" 2>/dev/null
        fi
    else
        wrk_warn "cannot create $HOME/.ssh - host keys are not available"
    fi
fi

# ---------------------------------------------------------------------------
#  2. Work directory
# ---------------------------------------------------------------------------
[ -d /wrk ] || mkdir -p /wrk 2>/dev/null || wrk_warn "/wrk is missing and could not be created"

# ---------------------------------------------------------------------------
#  3. Seed an empty home (only happens if $HOME was replaced by a volume)
# ---------------------------------------------------------------------------
if [ -d /etc/skel ] && [ -z "$(ls -A "$HOME" 2>/dev/null)" ]; then
    cp -a /etc/skel/. "$HOME/" 2>/dev/null || wrk_warn "could not seed \$HOME from /etc/skel"
fi

# ---------------------------------------------------------------------------
#  4. Hand over
# ---------------------------------------------------------------------------
if [ "$#" -eq 0 ]; then
    exec /bin/bash -l
fi
exec "$@"
