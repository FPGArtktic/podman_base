# podman-wrk

    podman-wrk.sh - build a developer container once, run it where there is no network

Author: Mateusz Okulanis.  Public domain (Unlicense).  See `LICENSE`.

Prebuilt image for testing: <https://hub.docker.com/r/fpgartktic/podman_base> — see section 4.

---

## 1 Introduction

You have a machine with internet and a machine without one. You want the same shell, the same
editor, the same tools on both. `podman-wrk.sh` builds an Arch Linux image containing all of it,
writes it to one file, and loads that file on the other machine. Nothing is fetched at run time,
because on the target there is nothing to fetch from.

That constraint drives every design decision here. An image that "mostly works offline" is useless:
you find out what is missing on the machine that cannot install it. So the build downloads every
plugin, parser and language server up front and then *fails the build* if any of them did not land.

It is one shell script, one Containerfile, and some dotfiles. There is no daemon, no registry, no
config format to learn.

## 2 Synopsis

```
podman-wrk.sh COMMAND [OPTION]...
```

Every command accepts `--help`. Run `podman-wrk.sh` with no arguments for a summary.

## 3 Requirements

Build host: Podman 4.3 or newer, internet access, ~6 GB free in the container store.
Target host: Podman 4.3 or newer. That is the entire list.

4.3 is not arbitrary: `--userns=keep-id:uid=,gid=` was added there, and section 8 explains why the
whole design leans on it.

Run `podman-wrk.sh doctor` on either machine. It checks the Podman version, whether you are rootless,
whether you have subuid/subgid ranges, free disk, and whether your SSH keys are where it expects.

## 4 Installation

There is no installation. Clone the repository and run `./podman-wrk.sh`.

**Where `wrk` comes from.** Most examples below start with `wrk` rather than `./podman-wrk.sh`.
That is the same script on `$PATH` under a shorter name, and you get it with:

```sh
./podman-wrk.sh install          # symlinks ~/.local/bin/wrk -> this checkout
```

A symlink by default, so `git pull` updates it too; `--copy` if you would rather have a copy,
`--dir` and `--name` to put it somewhere else. On the target machine `import --install` does the
same thing with a copy, since the bundle it was extracted from is usually temporary.

If you skip this, every `wrk ...` in this README is just `./podman-wrk.sh ...`.

**Prebuilt image.** A built image is published at
<https://hub.docker.com/r/fpgartktic/podman_base>:

```sh
podman pull docker.io/fpgartktic/podman_base:v1.0.1
```

The `docker.io/` prefix is not decoration. Podman refuses to guess which registry a short name belongs
to unless `unqualified-search-registries` is configured, and a system without
`/etc/containers/registries.conf` has nothing configured — you get
`short-name "..." did not resolve to an alias`. Fully qualified names always work.

It is there to **test the configuration**, not as the supported way to get this environment. The
supported path is the offline bundle — build it, `export` it, carry the file. A registry is precisely
what the target machine does not have, so pulling from one defeats the exercise. Tags there track
whatever is being tested and are not promised to be stable.

Running the pulled image directly means spelling out by hand what `shell` normally does for you:

```sh
podman run --rm -it \
  --userns=keep-id:uid=1000,gid=1000 \
  -v "$PWD":/wrk:rw \
  -v "$HOME/.ssh":/mnt/host-ssh:ro \
  --tmpfs /home/wrk/.ssh:rw,mode=0700 \
  docker.io/fpgartktic/podman_base:v1.0.1
```

The `--tmpfs` is not optional if you intend to `commit` the result — see section 11 for why.

**One name, two meanings.** Inside the container, `wrk` is an alias for `cd /wrk`. It is a different
thing that happens to share a name; there is no conflict in practice, because the host script does
not exist inside the container and the container alias does not exist on the host. Typing
`wrk shell` inside the container fails loudly (`cd: too many arguments`) rather than doing something
surprising.

## 5 Invoking podman-wrk

The image is tagged three ways: `podman-wrk-USER:latest` (what you run), `podman-wrk:latest` (the
generic name), and `podman-wrk-base:latest` (whatever came out of the bundle, untouched). The
container is named `podman-wrk-USER`. `USER` is resolved on the machine the command runs on, so two
people on one host do not collide.

### 5.1 build

Builds the image from `Containerfile`. Needs internet. Takes a while — most of it is Neovim
downloading language servers.

```
--no-cache          rebuild every layer
--base IMAGE        base image (default: docker.io/library/archlinux:base-devel)
--tag REF           add another tag to the result
--lsp "A B C"       Mason packages to bake in
--ts "lua go ..."   tree-sitter languages to bake in
--wrk PATH          remember PATH as the host directory for /wrk
```

### 5.2 export

Saves the image and wraps it, this script, the `Containerfile`, this README, a manifest and
`SHA256SUMS` into one archive. That is the whole payload.

```
--out DIR           where to write it (default: ./dist)
--image REF         export something other than the current image
--compress MODE     zstd (default) | gzip | none
--level N           zstd level (default: 10)
```

Run `commit` first if you want the container's writable layer to come along.

### 5.3 import

Loads a bundle. This is the only command the offline machine needs.

```
--localize          bake this host's user into the image (see section 8)
--install           also copy the script to ~/.local/bin/wrk
--no-verify         skip the SHA256SUMS check
--wrk PATH          remember PATH as the host directory for /wrk
```

With no argument it looks next to itself, then for the newest bundle in `./dist`. It verifies
checksums before loading and refuses a bundle that does not match.

### 5.4 shell

Enters the environment. Creates the container the first time, reuses it afterwards.

```
--bash              bash login shell (default)
--zsh               zsh, Oh My Zsh, mtsh theme
--ephemeral         throwaway --rm session
--wrk PATH          host directory to mount at /wrk
```

### 5.5 Other commands

```
install             put this script on $PATH as 'wrk' (see section 4)
                      --dir DIR  --name NAME  --copy  --force
exec CMD...         run a command in the running container
commit              fold the writable layer back into the image
                      --snapshot   also tag :snapshot-YYYYmmdd-HHMMSS
                      --tag NAME   commit to :NAME instead of :latest
mount [PATH]        show or set the host directory behind /wrk
status              what exists on this machine
stop, restart       container control
doctor              check this machine
verify              run the image with --network=none and check it is complete
```

### 5.6 Removing things

```
images              list podman-wrk images
df                  disk used by images, container, volumes
rm                  remove the CONTAINER, destroying its writable layer
rmi [REF...]        remove IMAGES     --all  --force  --dry-run
prune               drop old snapshots and dangling layers   --keep N
purge               remove every trace of podman-wrk from this machine
```

All of them take `--dry-run` and print exactly what they intend to delete before doing it.
`purge` does not touch your work directory, your `~/.ssh`, or anything in `dist/`, and it says so
before it asks.

## 6 Examples

### 6.1 The first five minutes

```sh
git clone <this repo> && cd podman_base
./podman-wrk.sh doctor                    # is this machine capable?
./podman-wrk.sh install                   # so that plain `wrk` works from here on
./podman-wrk.sh build                     # go make coffee
./podman-wrk.sh verify                    # did everything actually land?
./podman-wrk.sh shell --wrk ~/projects    # you are in
```

### 6.2 Everyday use

Everything below assumes `install` from 6.1; otherwise substitute `./podman-wrk.sh` for `wrk`.

```sh
wrk shell                        # back into the same container, history intact
wrk shell --zsh                  # same container, zsh instead of bash
wrk shell --wrk ~/other-project  # different directory (recreates the container)
wrk exec git status              # one command, no interactive session
wrk exec nvim /wrk/README.md     # editor straight from the host shell
wrk stop                         # done for the day
wrk status                       # what exists right now
```

Inside the container — note that here `wrk` means `cd /wrk`, not the script above:

```sh
cd /wrk          # or just: wrk  (the alias, not the host command)
lg               # lazygit
spf              # superfile (superfile also works)
btop             # htop is aliased to it
v file.py        # nvim
Ctrl-R           # fzf over unlimited history
Alt-C            # fzf over directories
```

### 6.3 Moving it to a machine with no network

```sh
# --- build host ---
./podman-wrk.sh build
./podman-wrk.sh shell --wrk ~/projects       # install extras, tune dotfiles
./podman-wrk.sh commit                       # keep them
./podman-wrk.sh export --out /media/usb      # ~1.3 GB with zstd

# --- air-gapped host ---
./podman-wrk.sh doctor                       # check BEFORE copying 1.3 GB around
./podman-wrk.sh import /media/usb/podman-wrk-*.tar.zst --install
wrk verify                                   # runs with --network=none
wrk shell --wrk /srv/projects
```

Check a bundle before you trust it, without loading it:

```sh
mkdir /tmp/peek && tar --zstd -xf podman-wrk-*.tar.zst -C /tmp/peek
cd /tmp/peek && sha256sum -c SHA256SUMS && cat manifest.env
```

Slower compression for a smaller file, or none at all when the transport already compresses:

```sh
./podman-wrk.sh export --level 19            # smaller, much slower
./podman-wrk.sh export --compress none       # plain tar
./podman-wrk.sh export --compress gzip       # target has no zstd
```

### 6.4 Adding your own tools

Nothing to edit — just list names:

```sh
echo 'docker-compose' >> packages/extra-pacman.txt
echo 'kubectl'        >> packages/extra-pacman.txt
echo 'lazydocker'     >> packages/extra-aur.txt
./podman-wrk.sh build       # only the last layer rebuilds
```

Or write it yourself, under the marker at the end of `Containerfile`:

```dockerfile
RUN sudo pacman -S --noconfirm --needed postgresql-libs redis
RUN yay -S --noconfirm --needed ttyd
RUN pip install --user --break-system-packages httpie
COPY my-gitconfig /home/${WRK_USER}/.gitconfig
```

Try something out first, decide later:

```sh
wrk shell
sudo pacman -S --noconfirm strace     # passwordless sudo, it just works
exit
wrk commit                            # liked it? keep it in the image
# didn't like it? wrk rm, and the next `shell` is clean again
```

### 6.5 Making the image smaller

The default bakes ten language servers and thirty parsers. If you only write shell and Python:

```sh
./podman-wrk.sh build \
    --lsp "bash-language-server basedpyright ruff shfmt" \
    --ts  "bash python json yaml markdown lua"
```

Trim `packages/pacman.txt` too — `go`, `nodejs`, `npm` and `cmake` are only there to support the
default language servers.

### 6.6 Snapshots

```sh
wrk commit --snapshot                     # :latest plus :snapshot-20260820-193000
wrk images                                # see them
wrk shell                                 # break something horribly
wrk rm --yes                              # throw the container away
podman tag podman-wrk-$USER:snapshot-20260820-193000 podman-wrk-$USER:latest
wrk shell                                 # back to the good state
wrk prune --keep 3                        # later: drop all but the newest three
```

### 6.7 Two projects, two directories

Podman cannot re-point a mount on an existing container, so switching is a recreate. The script
offers to `commit` first, so nothing is lost:

```sh
wrk mount                        # which directory is /wrk right now?
wrk mount ~/work/backend         # remember a new one
wrk shell                        # notices the change, offers to commit, recreates
```

If you want two genuinely separate environments, give them separate containers:

```sh
podman rename podman-wrk-$USER podman-wrk-$USER-backend
wrk shell --wrk ~/work/frontend  # a fresh container for the other project
```

### 6.8 Scripting against it

```sh
wrk exec bash -lc 'cd /wrk && make test'
wrk exec bash -lc 'ruff check /wrk' > lint.txt     # clean LF, no pty is allocated
```

`exec` only allocates a terminal when its output is one, so redirecting into a file gives you plain
LF instead of a CRLF mess. For an interactive throwaway session that keeps nothing outside `/wrk`:

```sh
wrk shell --ephemeral --wrk "$PWD"
```

### 6.9 Looking inside

```sh
wrk status                                    # identity, mounts, sizes
wrk df                                        # what it costs on disk
wrk images                                    # every podman-wrk tag

podman image inspect --format '{{json .Labels}}' podman-wrk:latest
podman inspect --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}
{{end}}' podman-wrk-$USER

wrk exec bash -lc 'ls ~/.local/share/nvim/mason/packages'   # which LSPs are baked in
wrk exec nvim --headless "+Lazy! health" +qa
```

### 6.10 Cleaning up

```sh
wrk rmi --all --dry-run       # what would go, and how much space
wrk prune --keep 1            # old snapshots and dangling build layers
wrk rm                        # container only; the image stays
wrk purge --dry-run           # everything, previewed
wrk purge                     # everything, for real
```

`purge` leaves your work directory, your `~/.ssh` and `dist/` alone.

### 6.11 When things are wrong

```sh
wrk doctor                                    # start here, always

# stale base image / signature errors during build
./podman-wrk.sh build --no-cache

# missing subuid range (doctor tells you this one verbatim)
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate

# out of space from repeated builds
wrk prune --keep 0 --yes

# convinced the image is broken? prove it
wrk verify
```

## 7 Air-gapped deployment

```sh
# machine with internet
./podman-wrk.sh build
./podman-wrk.sh verify
./podman-wrk.sh shell --wrk ~/projects     # settle in, install things
./podman-wrk.sh commit                     # keep what you changed
./podman-wrk.sh export                     # dist/podman-wrk-<user>-<date>.tar.zst

# copy the file: scp, USB stick, carrier pigeon

# machine without internet
./podman-wrk.sh import podman-wrk-*.tar.zst --install
wrk shell --wrk /srv/projects
```

The bundle carries the `Containerfile` too. The offline machine cannot rebuild from it, but when you
are staring at an image wondering what is in it, having the recipe beats guessing.

## 8 User identity

This is the part that makes the image portable, and it is worth two minutes of your attention.

The image is built with a **neutral** user: `wrk`, uid 1000, gid 1000. Nothing about the build
machine's user is baked in. Those numbers are recorded as image labels (`wrk.uid`, `wrk.gid`,
`wrk.user`).

The real identity is resolved on the target, at import and at container creation. `import` reads
`id -u`, `id -g` and `$USER` *there*, and the container is started with:

```
--userns=keep-id:uid=<image uid>,gid=<image gid>
```

Podman maps your uid on that machine onto the image's user. Consequences:

- files you create in `/wrk` belong to you on the host, with your real uid, on any machine;
- the mounted `~/.ssh` is readable and `ssh` accepts the permissions;
- the same bundle works for uid 1000 here and uid 4711 there.

It costs nothing. No rebuild, no extra layer, no `chown -R`.

The alternative is `import --localize`, which builds a derived layer — offline, with
`--network=none` — that renames the user and re-owns `$HOME`. Use it only if something in your
workflow runs the image directly instead of through this script. `chown -R` forces a copy-up of the
entire home directory in overlayfs, so it costs roughly 2 GB. The original stays as
`podman-wrk-base:latest`.

## 9 Adding your own packages

The end of `Containerfile` is a marked USER PACKAGES section. It is the last layer deliberately:
changing it rebuilds seconds of work instead of forty minutes.

Two ways. Either put names in these files, one per line:

```
packages/extra-pacman.txt      official repositories, via pacman
packages/extra-aur.txt         AUR, via yay
```

or write your own instructions under the marker. You are the unprivileged user with passwordless
sudo, so both of these work:

```dockerfile
RUN sudo pacman -S --noconfirm --needed docker-compose kubectl
RUN yay -S --noconfirm --needed lazydocker
```

`packages/pacman.txt` and `packages/aur.txt` hold the environment's own dependencies. Leave them
alone unless you mean it.

## 10 Persistence

The container is created once and reused. `shell` starts the existing one. Its writable layer
persists: shell history, whatever you installed by hand, Neovim's undo files, lazygit state.

- `rm` destroys that layer. `commit` first if you care.
- `commit` folds it back into the image, which is how a settled environment gets into `export`.
- `shell --ephemeral` gives you a `--rm` session instead.

Changing `--wrk` needs the container recreated, because Podman cannot re-point a mount on an existing
container. The script notices, offers to `commit`, and recreates it.

The container is stopped with SIGHUP, not SIGTERM. An interactive login shell running as pid 1
ignores SIGTERM, so `stop` would sit through the full timeout and then SIGKILL — ten seconds of
nothing, every time, and no chance to flush the history file. SIGHUP is what a shell expects when its
terminal disappears: it exits and writes its history.

## 11 SSH keys

Keys come from the host the container is running on, at run time. They are never baked into the
image, so the bundle contains no secrets and you can copy it around without thinking about it.

On every start — online or offline, it is a local file copy and needs no network — the host's
`~/.ssh` is mounted read-only at `/mnt/host-ssh` and the entrypoint copies the regular files out of
it into `~/.ssh` with `700` on the directory, `600` on keys and `644` on `*.pub`. The copy is not
laziness: it keeps the host's keys immutable from inside the container, and ssh refuses to use a key
whose permissions it does not like.

**`~/.ssh` inside the container is a tmpfs, and that is load-bearing.** The obvious implementation
puts the copied keys in the container's writable layer — which means `commit` folds your private key
into the image and `export` ships it inside the bundle, to whoever you hand that bundle to. The
workflow this README recommends (`commit`, then `export`) walks straight into it. A tmpfs is not part
of the writable layer, so `commit` cannot see it and the keys evaporate when the container stops.
Verified: after `commit`, `/home/wrk/.ssh` in the resulting image is empty.

That would also throw away every host fingerprint you ever accepted, so `known_hosts` — a list of
fingerprints, not a credential — is redirected to `~/.local/state/podman-wrk/known_hosts` in the
persistent layer and symlinked back into `~/.ssh`. It survives restarts; the keys are re-copied from
the host each time.

`$SSH_AUTH_SOCK` is forwarded when an agent is running.

Only top-level regular files are copied. Sockets cannot be copied, and subdirectories are skipped.
If you keep keys in subdirectories, flatten them or use absolute paths.

## 12 The Neovim environment

LazyVim, with the network deliberately cut off at run time: `checker`, `change_detection`, automatic
installs and luarocks are all disabled, so startup never reaches for GitHub.

A verified build contains 52 plugins, 20 Mason packages and around 40 tree-sitter parsers — the
parser count moves a little between builds as upstream adds languages. `verify` prints the actual
numbers, and the build refuses to finish if any of the three collapses.

- Language servers: `lua-language-server`, `bash-language-server`, `basedpyright`, `json-lsp`,
  `yaml-language-server`, `typescript-language-server`, `clangd`, plus `stylua`, `shfmt`, `ruff`.
  Change the list with `build --lsp "..."`.
- Parsers for bash, C, C++, CSS, diff, Dockerfile, git, Go, HTML, JS/TS/TSX, JSON, Lua, Make,
  Markdown, Python, Rust, SQL, TOML, Vim, XML, YAML. Change with `build --ts "..."`.
- LazyVim extras for the above languages, plus mini-surround, Telescope, inc-rename,
  mini-hipatterns, Prettier and `dap.core`.
- On top: Catppuccin, diffview.nvim, oil.nvim, lazygit on `<leader>gg`, conform.nvim and nvim-lint
  wired to the real `shellcheck` and `shfmt` binaries in the image.

Keys worth knowing: `<leader>gg` lazygit, `<leader>gv` diffview, `-` oil.nvim, `<leader>ff` files,
`<leader>sg` grep, `<leader>e` tree, `<leader>` alone for which-key.

Getting all of that into the image is where the interesting bug lives, and `nvim-bootstrap.lua`
exists because of it. The obvious incantation:

```sh
nvim --headless -c "MasonInstall lua-language-server ..." -c "qa"
```

starts the downloads, then quits. Mason kills them on the way out — it even says so, in a message
nobody reads because it is buried in ten thousand lines of build log. The build reports success and
produces an image with no language servers at all. The bootstrap issues the same installs and then
blocks until they finish.

It is invoked as `-c luafile`, not `nvim -l`, because `-l` does not source `init.lua`, so lazy.nvim
never loads and none of the commands exist. Both of these are the kind of thing you only find by
checking what actually ended up on disk, which is why the build now counts the plugins, Mason
packages and parsers and **fails** when the numbers are wrong. An incomplete offline image cannot be
repaired on the target, so it must not leave the build host.

## 13 The shell environment

bash is the default. zsh is `shell --zsh`.

**Prompt.** bash uses the supplied prompt: time, user, host, abbreviated path, git branch on its own
line. Two notes.

First, the snippet ends with `if [ -z "$USER" ]; then USER="root"; fi`, and Podman does not set
`USER` in a container — so the prompt claimed to be root in every session while actually running as
`wrk`. Fixed at the cause, in `/etc/profile.d/wrk-env.sh` and both rc files, not by touching the
prompt.

Second, three of the `\[ ... \]` pairs were missing their opening `\[`. Bash translates `\[` to
`\001` and `\]` to `\002` so readline can tell which bytes are non-printing colour codes; an
unmatched `\]` is emitted to the terminal as a literal `\002`. Measured on a pty: the original wrote
**8 stray `\002` (`^B`) bytes on every prompt draw**, the balanced version writes none. The other
half of what those markers do — width accounting — matters less here, because the prompt ends in
`\n$ ` and readline only measures the last line, which is just `$ `; so the symptom was control-byte
litter rather than broken wrapping. The balanced version is what runs now and looks identical; the
original is preserved in a comment directly below it in `.bashrc`.

zsh uses the `mtsh` theme. Its glyphs need a Powerline-capable font on the **host** terminal — a
container cannot supply fonts.

**History is unlimited in both.** bash: `HISTSIZE=-1`, `HISTFILESIZE=-1`, appended and flushed on
every prompt. zsh: `HISTSIZE`/`SAVEHIST` at a billion, `EXTENDED_HISTORY`, `INC_APPEND_HISTORY`,
`SHARE_HISTORY`. Both files live in `$HOME`, inside the persistent layer.

**Aliases**, identical in both shells:

```sh
alias cp='rsync -avh --progress'
alias htop='btop'
```

plus `ll`/`la`/`lt` on eza, `cat` on bat, `v`/`vi` on nvim, `lg` for lazygit, `wrk` to reach `/wrk`.
The superfile package installs its binary as `spf`, so `superfile` is aliased to `spf` and both names
work.

**fzf** in both shells, sourced from `fd`, previews through `bat` and `eza`: `Ctrl-R` history,
`Ctrl-T` files, `Alt-C` directories, `Ctrl-/` toggles the preview. zsh also gets `fzf-tab`, so
ordinary tab completion opens an fzf picker. Four helpers in both: `fe` (edit), `fcd` (jump),
`fkill` (pick a process), `fgb` (checkout a branch).

**neofetch** runs on every interactive shell. It was dropped from the official Arch repositories when
upstream archived it, so it comes from the AUR via yay; `fastfetch` is installed as a fallback and
used automatically if neofetch is ever unavailable. `WRK_NO_FETCH=1` silences it.

Put your own settings in `~/.bashrc.local` or `~/.zshrc.local`. They are sourced last and survive
image rebuilds.

## 14 Files

```
podman-wrk.sh                       the tool
Containerfile                       the recipe; USER PACKAGES at the end
packages/pacman.txt                 base packages, official repositories
packages/aur.txt                    base packages, AUR
packages/extra-pacman.txt           yours
packages/extra-aur.txt              yours
rootfs/etc/skel/                    .bashrc, .zshrc, .tmux.conf, Neovim config
rootfs/etc/profile.d/wrk-env.sh     USER, LOGNAME, PATH for login shells
rootfs/usr/local/bin/               wrk-entrypoint.sh
rootfs/usr/local/share/podman-wrk/  nvim-bootstrap.lua
dist/                               bundles written by `export`
~/.config/podman-wrk/config         remembered /wrk path and host identity
```

## 15 Environment

```
WRK_PATH               host directory for /wrk
WRK_BASE_IMAGE         base image for build
WRK_NVIM_LSP           Mason packages to bake in
WRK_NVIM_TS            tree-sitter languages to bake in
WRK_COMPRESS_LEVEL     zstd level for export
WRK_NO_FETCH           set to 1 inside the container to silence neofetch
NO_COLOR               suppress coloured output
```

Precedence is flags, then environment, then the config file, then the built-in default.

## 16 Problems

**Files in `/wrk` are owned by a strange uid.** The container was created without the identity
mapping. Check `status`; recreate with `rm` then `shell`.

**`--userns=keep-id:uid=...` is rejected.** Podman older than 4.3. `doctor` says so.

**"there might not be enough IDs available in the namespace".** No subuid/subgid range:

```sh
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate
```

**Permission denied on the mount under SELinux.** The script appends `,z` when `selinuxenabled`
says SELinux is on. If a local policy still refuses, relabel the directory yourself.

**Neovim shows download errors.** Something wants a plugin or Mason package that was not baked in.
Add it and rebuild on a machine with internet. It cannot be fixed on the target.

**The build fails on `archlinux-keyring` or a signature.** The base image is stale relative to the
mirrors. `build --no-cache` pulls a fresh base and redoes the keyring refresh.

**Out of space mid-build.** A build wants about 6 GB. `doctor` reports what is free; `prune`
reclaims failed attempts.

## 17 Bugs and limitations

Known, deliberate, or not worth fixing yet:

- The image is about 4 GB and the bundle around 1.5 GB. That is what LazyVim plus a compiler
  toolchain plus ten language servers costs. Trim `packages/pacman.txt` and `--lsp` if it matters.
- `--localize` roughly doubles the disk footprint, for the reason in section 8. Do not use it out of
  habit.
- Only top-level files in `~/.ssh` reach the container (section 11).
- `prune` calls `podman image prune`, which is Podman-wide. It removes dangling images that other
  projects left behind too. It warns first.
- The bundle is not signed. `SHA256SUMS` catches corruption, not tampering. If you care, sign it.
- `verify` proves the tools are present and Neovim starts. It does not prove your workflow works.
- `commit` produces a docker-format image, because `podman commit --message` refuses OCI. The
  `wrk.*` labels survive, which is what matters, and `export` writes a docker-archive anyway.
- Anything you leave in the container's writable layer *is* captured by `commit` and shipped by
  `export`. `~/.ssh` is handled (section 11); credentials you drop elsewhere in `$HOME` are not.
- Podman warns that `SHELL` is not persisted in OCI images on nearly every build step. It is noise;
  the final `ENTRYPOINT` and `CMD` are set explicitly.

## 18 Author

Written by Mateusz Okulanis.

## 19 Copying

This is free and unencumbered software released into the public domain, under the Unlicense. Do
whatever you want with it. See `LICENSE`.
