# ===========================================================================
#  podman-wrk :: .zshrc
#  Oh My Zsh + mtsh theme, unlimited history, fzf, matching bash aliases.
# ===========================================================================

# Podman leaves USER empty inside a container (zsh only sets USERNAME), and
# some tooling reads USER. Covered here as well as in /etc/profile.d so that
# non-login shells from `podman exec` get it too.
export USER="${USER:-$(id -un)}"

# ---------------------------------------------------------------------------
#  Oh My Zsh
# ---------------------------------------------------------------------------
export ZSH="$HOME/.oh-my-zsh"

# https://github.com/FPGArtktic/ohmyzsh-mtsh-theme  (installed at build time
# into $ZSH/custom/themes/mtsh.zsh-theme). Powerline-capable font recommended
# on the HOST terminal - the container cannot provide fonts.
ZSH_THEME="mtsh"

plugins=(
    git
    fzf
    fzf-tab
    zsh-autosuggestions
    zsh-syntax-highlighting
    sudo
    tmux
    command-not-found
    colored-man-pages
)

# Oh My Zsh manages its own history options; ours are applied afterwards.
DISABLE_AUTO_UPDATE="true"        # the container is offline by design
DISABLE_UPDATE_PROMPT="true"
ZSH_DISABLE_COMPFIX="true"

[ -f "$ZSH/oh-my-zsh.sh" ] && source "$ZSH/oh-my-zsh.sh"

# ---------------------------------------------------------------------------
#  History - unlimited, shared between sessions, timestamped
#  (must come AFTER oh-my-zsh.sh, which sets its own defaults)
# ---------------------------------------------------------------------------
HISTFILE="$HOME/.zsh_history"
HISTSIZE=1000000000
SAVEHIST=1000000000

setopt EXTENDED_HISTORY           # record timestamp and duration
setopt INC_APPEND_HISTORY         # write immediately, not on exit
setopt SHARE_HISTORY              # share across running sessions
setopt HIST_IGNORE_ALL_DUPS       # keep only the most recent copy
setopt HIST_IGNORE_SPACE          # skip commands starting with a space
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY                # expand !! before running it
setopt HIST_FIND_NO_DUPS
unsetopt HIST_EXPIRE_DUPS_FIRST   # never expire - the file is unbounded

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
#  Aliases  (kept in sync with .bashrc)
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

if [ -f /usr/share/fzf/key-bindings.zsh ]; then
    source /usr/share/fzf/key-bindings.zsh
    [ -f /usr/share/fzf/completion.zsh ] && source /usr/share/fzf/completion.zsh
elif command -v fzf >/dev/null 2>&1; then
    source <(fzf --zsh)
fi

# fzf-tab: use a preview pane for file/dir completion
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza --tree --level=2 --color=always $realpath'
zstyle ':fzf-tab:complete:*:*' fzf-preview \
    '[ -d $realpath ] && eza --tree --level=2 --color=always $realpath || bat --style=numbers --color=always --line-range=:200 $realpath 2>/dev/null'
zstyle ':fzf-tab:*' switch-group ',' '.'

# Same helper functions as bash
fe() {
    local files
    files=("${(@f)$(fzf --multi --query="${1:-}" \
        --preview 'bat --style=numbers --color=always --line-range=:200 {}')}")
    [ -n "$files" ] && "$EDITOR" "${files[@]}"
}
fcd() {
    local dir
    dir=$(fd --type d --hidden --follow --exclude .git . "${1:-.}" | fzf +m) && cd "$dir"
}
fkill() {
    local pid
    pid=$(ps -ef | sed 1d | fzf -m | awk '{print $2}')
    [ -n "$pid" ] && echo "$pid" | xargs kill "-${1:-9}"
}
fgb() {
    local branch
    branch=$(git branch --all | grep -v HEAD | sed 's/^..//;s#remotes/[^/]*/##' | sort -u | fzf +m) \
        && git checkout "$branch"
}

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
[ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
