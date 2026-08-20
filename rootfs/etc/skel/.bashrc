# ===========================================================================
#  podman-wrk :: .bashrc
#  Interactive bash configuration for the containerised work environment.
# ===========================================================================

# Only continue for interactive shells.
case $- in
    *i*) ;;
      *) return;;
esac

# Podman leaves USER empty inside a container, and the prompt below falls back
# to "root" in that case - which would mislabel every session. Set it here too,
# not just in /etc/profile.d, so non-login shells (podman exec) are covered.
export USER="${USER:-$(id -un)}"

# ---------------------------------------------------------------------------
#  Prompt
#
#  Same prompt as supplied - time, user, host, abbreviated path, git branch on
#  its own line - with the \[ ... \] escape pairs balanced.
#
#  Bash turns \[ into \001 and \] into \002 so readline knows which bytes are
#  non-printing colour codes. In the original the opening \[ was missing on
#  three of them (e.g. HOST started straight at \033), which leaves the closing
#  \] unmatched - and bash emits those as literal \002 bytes to the terminal.
#  Measured on a real pty: the original writes 8 stray \002 (^B) bytes on every
#  single prompt draw, the version below writes none.
#
#  Width accounting is the other half of what those markers are for, though it
#  matters less here: the prompt ends in \n$ , and readline only measures the
#  last line, which is just "$ ". So the visible symptom is control-byte litter
#  rather than broken wrapping. Appearance is identical either way.
#
#  The original is kept at the bottom of this block; swapping back is a matter
#  of commenting these out and uncommenting those.
# ---------------------------------------------------------------------------
git_branch () { git branch 2> /dev/null | sed -e "/^[^*]/d" -e "s/* \(.*\)/\1/"; }
HOST='\[\033[02;36m\]\h'; HOST=' '$HOST
TIME='\[\033[01;31m\]\t \[\033[01;32m\]'
LOCATION='\[\033[01;33m\]`pwd | sed "s#\(/[^/]\{1,\}/[^/]\{1,\}/[^/]\{1,\}/\).*\(/[^/]\{1,\}/[^/]\{1,\}\)/\{0,1\}#\1_\2#g"`\[\033[00m\]'
BRANCH=' \[\033[00;33m\]$(git_branch)\[\033[00m\]\n$ '
if [ -z "$USER" ]; then
  USER="root"
fi
PS1=$TIME$USER$HOST$LOCATION$BRANCH
PS2='\[\033[01;36m\]>\[\033[00m\] '

# --- original variant, verbatim as supplied --------------------------------
# HOST='\033[02;36m\]\h'; HOST=' '$HOST
# TIME='\033[01;31m\]\t \033[01;32m\]'
# BRANCH=' \033[00;33m\]$(git_branch)\[\033[00m\]\n$ '
# PS2='\[\033[01;36m\]>'

# ---------------------------------------------------------------------------
#  History - unlimited, shared, timestamped
# ---------------------------------------------------------------------------
HISTSIZE=-1                       # unlimited in-memory history
HISTFILESIZE=-1                   # unlimited on-disk history
HISTCONTROL=ignoreboth            # skip duplicates and space-prefixed commands
HISTTIMEFORMAT='%F %T '
HISTIGNORE='ls:ll:la:cd:pwd:exit:clear:history'
HISTFILE="$HOME/.bash_history"

shopt -s histappend               # never truncate, always append
shopt -s cmdhist                  # multi-line commands as one entry
shopt -s checkwinsize
shopt -s globstar 2>/dev/null
shopt -s autocd 2>/dev/null

# Flush every command to disk immediately so nothing is lost on an abrupt exit.
case "$PROMPT_COMMAND" in
    *'history -a'*) ;;
    '')  PROMPT_COMMAND='history -a' ;;
    *)   PROMPT_COMMAND="history -a; $PROMPT_COMMAND" ;;
esac

# ---------------------------------------------------------------------------
#  Environment
# ---------------------------------------------------------------------------
export EDITOR=nvim
export VISUAL=nvim
export PAGER=less
export LESS='-R -F -X -i'
export MANPAGER='nvim +Man!'
export PATH="$HOME/.local/bin:$HOME/.local/share/nvim/mason/bin:$PATH"

# ---------------------------------------------------------------------------
#  Aliases
# ---------------------------------------------------------------------------
alias cp='rsync -avh --progress'
alias htop='btop'

alias ll='eza -lah --group-directories-first --git'
alias la='eza -a --group-directories-first'
alias ls='eza --group-directories-first'
alias lt='eza --tree --level=2 --group-directories-first'
alias cat='bat --paging=never'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias mv='mv -i'
alias rm='rm -i'
alias df='df -h'
alias du='du -h'
alias free='free -h'

alias v='nvim'
alias vi='nvim'
alias lg='lazygit'
# The superfile package installs its binary as `spf`; alias the long name so
# both work.
alias superfile='spf'
alias gs='git status -sb'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate --all'
alias ..='cd ..'
alias ...='cd ../..'
alias wrk='cd /wrk'

# ---------------------------------------------------------------------------
#  fzf
# ---------------------------------------------------------------------------
export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
export FZF_DEFAULT_OPTS="
  --height=60% --layout=reverse --border=rounded --info=inline
  --marker='+' --pointer='>' --prompt='  '
  --bind='ctrl-/:toggle-preview,ctrl-a:select-all,ctrl-y:execute-silent(echo {+} | wl-copy 2>/dev/null || echo {+} | xclip -sel clip)'
"
export FZF_CTRL_T_OPTS="--preview 'bat --style=numbers --color=always --line-range=:200 {} 2>/dev/null || eza --tree --level=2 --color=always {} 2>/dev/null' --preview-window=right:60%:wrap"
export FZF_ALT_C_OPTS="--preview 'eza --tree --level=2 --color=always {}' --preview-window=right:60%"
export FZF_CTRL_R_OPTS="--preview 'echo {}' --preview-window=down:3:hidden:wrap --bind='?:toggle-preview'"

# Arch ships the shell integration as plain files; newer fzf can emit it itself.
if [ -f /usr/share/fzf/key-bindings.bash ]; then
    source /usr/share/fzf/key-bindings.bash
    [ -f /usr/share/fzf/completion.bash ] && source /usr/share/fzf/completion.bash
elif command -v fzf >/dev/null 2>&1; then
    eval "$(fzf --bash)"
fi

# fzf-powered helpers
if command -v fzf >/dev/null 2>&1; then
    # fe - open one or more files in $EDITOR
    fe() {
        local files
        mapfile -t files < <(fzf --multi --query="${1:-}" \
            --preview 'bat --style=numbers --color=always --line-range=:200 {}')
        [ ${#files[@]} -gt 0 ] && "$EDITOR" "${files[@]}"
    }
    # fcd - jump to a directory
    fcd() {
        local dir
        dir=$(fd --type d --hidden --follow --exclude .git . "${1:-.}" | fzf +m) && cd "$dir" || return
    }
    # fkill - pick a process to kill
    fkill() {
        local pid
        pid=$(ps -ef | sed 1d | fzf -m | awk '{print $2}')
        [ -n "$pid" ] && echo "$pid" | xargs kill "-${1:-9}"
    }
    # fgb - checkout a git branch
    fgb() {
        local branch
        branch=$(git branch --all | grep -v HEAD | sed 's/^..//;s#remotes/[^/]*/##' | sort -u | fzf +m) \
            && git checkout "$branch"
    }
fi

# ---------------------------------------------------------------------------
#  Completion
# ---------------------------------------------------------------------------
[ -f /usr/share/bash-completion/bash_completion ] && source /usr/share/bash-completion/bash_completion

# ---------------------------------------------------------------------------
#  Greeting  (set WRK_NO_FETCH=1 to silence)
# ---------------------------------------------------------------------------
if [ -z "$WRK_NO_FETCH" ] && [ -t 1 ] && [ -z "$WRK_FETCH_SHOWN" ]; then
    export WRK_FETCH_SHOWN=1
    if command -v neofetch >/dev/null 2>&1; then
        neofetch
    elif command -v fastfetch >/dev/null 2>&1; then
        fastfetch
    fi
fi

# ---------------------------------------------------------------------------
#  Local overrides - not managed by podman-wrk, safe across image rebuilds
# ---------------------------------------------------------------------------
[ -f "$HOME/.bashrc.local" ] && source "$HOME/.bashrc.local"
