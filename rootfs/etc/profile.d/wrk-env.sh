# ===========================================================================
#  podman-wrk :: environment fixups for login shells
#
#  Podman does not populate USER or LOGNAME in a container's environment. That
#  matters here because the bash prompt falls back to "root" when $USER is
#  empty, which would label every session as root while actually running as an
#  unprivileged user. Fix the cause rather than the prompt.
#
#  Sourced by /etc/profile for bash, and by zsh too - /etc/zsh/zprofile runs
#  `emulate sh -c 'source /etc/profile'`. Keep this POSIX sh.
# ===========================================================================

if [ -z "${USER:-}" ]; then
    USER="$(id -un 2>/dev/null || echo unknown)"
    export USER
fi

if [ -z "${LOGNAME:-}" ]; then
    LOGNAME="$USER"
    export LOGNAME
fi

if [ -z "${HOME:-}" ]; then
    HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
    [ -n "$HOME" ] && export HOME
fi

# Language servers installed by Mason live in the user's home, not in /usr/bin.
# Putting them on PATH here rather than only in .bashrc/.zshrc means
# non-interactive shells - scripts, `podman exec ... bash -lc ...` - find them
# too. Guarded so repeated sourcing does not stack up duplicate entries.
case ":$PATH:" in
    *":$HOME/.local/share/nvim/mason/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$HOME/.local/share/nvim/mason/bin:$PATH"; export PATH ;;
esac
