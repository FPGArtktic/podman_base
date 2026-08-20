#!/usr/bin/env bash
# ===========================================================================
#  podman-wrk - build, ship and run a portable developer environment
#  Author: Mateusz Okulanis
#  License: Unlicense
#
#  Build it once on a machine with internet access, export it to a single
#  self-contained bundle, and load it on an air-gapped target:
#
#      machine A:  ./podman-wrk.sh build
#                  ./podman-wrk.sh export
#      -- copy the bundle --
#      machine B:  ./podman-wrk.sh import podman-wrk-*.tar.zst
#                  ./podman-wrk.sh shell --wrk /srv/projects
#
#  Run `./podman-wrk.sh help` for the full command reference.
# ===========================================================================

set -euo pipefail

SCRIPT_VERSION="1.0.1"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"

# --- identity of the machine we are running on RIGHT NOW --------------------
# Deliberately re-evaluated on every invocation: the build host and the target
# host are different machines with different users and different UIDs.
HOST_USER="${USER:-$(id -un)}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

# --- naming -----------------------------------------------------------------
IMAGE_ALIAS="podman-wrk"                       # generic tag, as requested
BASE_IMAGE_TAG="podman-wrk-base"               # untouched image straight from the bundle
IMAGE_NAME="podman-wrk-${HOST_USER}"           # what this user actually runs
CONTAINER_NAME="podman-wrk-${HOST_USER}"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/podman-wrk"
CONFIG_FILE="$CONFIG_DIR/config"

# --- defaults ---------------------------------------------------------------
# Precedence is flags > environment > config file > built-in default, so the
# environment values are captured here and re-applied after the config load.
ENV_WRK_PATH="${WRK_PATH:-}"
ENV_WRK_BASE_IMAGE="${WRK_BASE_IMAGE:-}"
ENV_WRK_COMPRESS_LEVEL="${WRK_COMPRESS_LEVEL:-}"

WRK_PATH="${WRK_PATH:-$PWD}"
WRK_LOCALIZED="${WRK_LOCALIZED:-0}"
WRK_BASE_IMAGE="${WRK_BASE_IMAGE:-docker.io/library/archlinux:base-devel}"
WRK_COMPRESS_LEVEL="${WRK_COMPRESS_LEVEL:-10}"
WRK_NVIM_LSP="${WRK_NVIM_LSP:-lua-language-server bash-language-server basedpyright json-lsp yaml-language-server typescript-language-server clangd stylua shfmt ruff}"
# Empty means "use the default language list inside nvim-bootstrap.lua".
WRK_NVIM_TS="${WRK_NVIM_TS:-}"

# Neutral identity baked into the image (see README "User identity").
IMG_USER_DEFAULT="wrk"
IMG_UID_DEFAULT="1000"
IMG_GID_DEFAULT="1000"

BUNDLE_FILES=(image.tar "$SCRIPT_NAME" Containerfile README.md manifest.env)

# ===========================================================================
#  Output helpers
# ===========================================================================
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'; C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'
    C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
else
    C_RESET=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_CYAN=; C_BOLD=; C_DIM=
fi

log()   { printf '%s==>%s %s\n' "$C_BLUE"   "$C_RESET" "$*" >&2; }
step()  { printf '%s ->%s %s\n' "$C_CYAN"   "$C_RESET" "$*" >&2; }
ok()    { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%serr %s %s\n' "$C_RED"   "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }
hint()  { printf '%s     %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }

confirm() {
    local prompt="$1" default="${2:-n}" reply
    if [ "${ASSUME_YES:-0}" = "1" ]; then return 0; fi
    if [ ! -t 0 ]; then
        die "$prompt (refusing to guess on a non-interactive terminal; pass --yes)"
    fi
    if [ "$default" = "y" ]; then
        printf '%s%s%s [Y/n] ' "$C_BOLD" "$prompt" "$C_RESET" >&2
    else
        printf '%s%s%s [y/N] ' "$C_BOLD" "$prompt" "$C_RESET" >&2
    fi
    read -r reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]$ ]]
}

confirm_typed() {
    local prompt="$1" word="${2:-yes}" reply
    if [ "${ASSUME_YES:-0}" = "1" ]; then return 0; fi
    [ -t 0 ] || die "$prompt (non-interactive terminal; pass --yes)"
    printf '%s%s%s\nType %s%s%s to continue: ' \
        "$C_BOLD" "$prompt" "$C_RESET" "$C_BOLD" "$word" "$C_RESET" >&2
    read -r reply
    [ "$reply" = "$word" ]
}

human() {
    local bytes="${1:-0}"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B --format='%.1f' "$bytes" 2>/dev/null || printf '%s B' "$bytes"
    else
        printf '%s B' "$bytes"
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# ===========================================================================
#  Configuration
# ===========================================================================
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    local tmp="$CONFIG_FILE.tmp.$$"
    {
        echo "# podman-wrk configuration"
        echo "# generated by $SCRIPT_NAME v$SCRIPT_VERSION on $(date -Is)"
        echo "# host identity resolved on THIS machine, not on the build host"
        printf 'WRK_PATH=%q\n'            "$WRK_PATH"
        printf 'WRK_LOCALIZED=%q\n'       "$WRK_LOCALIZED"
        printf 'WRK_HOST_USER=%q\n'       "$HOST_USER"
        printf 'WRK_HOST_UID=%q\n'        "$HOST_UID"
        printf 'WRK_HOST_GID=%q\n'        "$HOST_GID"
        printf 'WRK_BASE_IMAGE=%q\n'      "$WRK_BASE_IMAGE"
        printf 'WRK_COMPRESS_LEVEL=%q\n'  "$WRK_COMPRESS_LEVEL"
    } > "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

# ===========================================================================
#  Podman helpers
# ===========================================================================
require_podman() {
    have podman || die "podman is not installed or not on \$PATH"
}

podman_client_version() {
    podman version --format '{{.Client.Version}}' 2>/dev/null || echo "0"
}

version_ge() {
    # version_ge A B  ->  true when A >= B
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

image_exists()     { podman image exists "$1" 2>/dev/null; }
container_exists() { podman container exists "$1" 2>/dev/null; }

container_running() {
    [ "$(podman inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

image_label() {
    podman image inspect --format "{{index .Labels \"$2\"}}" "$1" 2>/dev/null || true
}

image_size() {
    podman image inspect --format '{{.Size}}' "$1" 2>/dev/null || echo 0
}

# Which image tag should we actually run? Prefer the per-user tag, fall back to
# the bundle tag and finally to the generic alias.
resolve_image() {
    local ref
    for ref in "$IMAGE_NAME:latest" "$BASE_IMAGE_TAG:latest" "$IMAGE_ALIAS:latest"; do
        if image_exists "$ref"; then echo "$ref"; return 0; fi
    done
    return 1
}

# UID/GID that the image's user actually has, read from the image labels.
img_uid() { local v; v="$(image_label "$1" wrk.uid)"; echo "${v:-$IMG_UID_DEFAULT}"; }
img_gid() { local v; v="$(image_label "$1" wrk.gid)"; echo "${v:-$IMG_GID_DEFAULT}"; }
img_user() { local v; v="$(image_label "$1" wrk.user)"; echo "${v:-$IMG_USER_DEFAULT}"; }

detect_tz() {
    local tz=""
    if [ -n "${TZ:-}" ]; then echo "$TZ"; return; fi
    if have timedatectl; then
        tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
        if [ -n "$tz" ]; then echo "$tz"; return; fi
    fi
    if [ -L /etc/localtime ]; then
        tz="$(readlink -f /etc/localtime 2>/dev/null || true)"
        tz="${tz##*/zoneinfo/}"
        if [ -n "$tz" ] && [ "$tz" != "$(readlink -f /etc/localtime 2>/dev/null)" ]; then
            echo "$tz"; return
        fi
    fi
    if [ -r /etc/timezone ]; then
        tz="$(tr -d '[:space:]' < /etc/timezone)"
        if [ -n "$tz" ]; then echo "$tz"; return; fi
    fi
    echo "UTC"
}

selinux_suffix() {
    if have selinuxenabled && selinuxenabled 2>/dev/null; then printf ',z'; fi
}

# ===========================================================================
#  build
# ===========================================================================
cmd_build() {
    local no_cache=0 tag_extra="" lsp="$WRK_NVIM_LSP" base="$WRK_BASE_IMAGE" ts="$WRK_NVIM_TS"
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-cache)  no_cache=1; shift ;;
            --base)      base="${2:?--base needs an image reference}"; shift 2 ;;
            --tag)       tag_extra="${2:?--tag needs a value}"; shift 2 ;;
            --lsp)       lsp="${2:?--lsp needs a space-separated list}"; shift 2 ;;
            --ts)        ts="${2:?--ts needs a space-separated list}"; shift 2 ;;
            --wrk)       WRK_PATH="$(readlink -f "${2:?--wrk needs a path}")"; shift 2 ;;
            -h|--help)   usage_build; return 0 ;;
            *)           die "build: unknown option '$1' (try --help)" ;;
        esac
    done

    require_podman
    [ -f "$SCRIPT_DIR/Containerfile" ] || \
        die "Containerfile not found in $SCRIPT_DIR - run 'build' from the repository checkout"

    local tz; tz="$(detect_tz)"
    local build_date; build_date="$(date -Is)"

    log "Building ${C_BOLD}$IMAGE_NAME:latest${C_RESET}"
    step "base image ...... $base"
    step "timezone ........ $tz"
    step "image identity .. $IMG_USER_DEFAULT ($IMG_UID_DEFAULT:$IMG_GID_DEFAULT) - neutral on purpose"
    step "LSP servers ..... $lsp"
    hint "your host identity ($HOST_USER $HOST_UID:$HOST_GID) is applied at run time, not baked in"

    local args=(
        build
        --file "$SCRIPT_DIR/Containerfile"
        --build-arg "WRK_BASE_IMAGE=$base"
        --build-arg "WRK_USER=$IMG_USER_DEFAULT"
        --build-arg "WRK_UID=$IMG_UID_DEFAULT"
        --build-arg "WRK_GID=$IMG_GID_DEFAULT"
        --build-arg "WRK_TZ=$tz"
        --build-arg "WRK_BUILD_DATE=$build_date"
        --build-arg "WRK_NVIM_LSP=$lsp"
        --build-arg "WRK_NVIM_TS=$ts"
        --tag "$IMAGE_NAME:latest"
        --tag "$IMAGE_ALIAS:latest"
        --tag "$BASE_IMAGE_TAG:latest"
    )
    [ "$no_cache" = "1" ] && args+=(--no-cache)
    [ -n "$tag_extra" ] && args+=(--tag "$tag_extra")
    args+=("$SCRIPT_DIR")

    podman "${args[@]}"

    WRK_LOCALIZED=0
    save_config

    ok "built $IMAGE_NAME:latest  ($(human "$(image_size "$IMAGE_NAME:latest")"))"
    hint "next: $SCRIPT_NAME verify   |   $SCRIPT_NAME shell   |   $SCRIPT_NAME export"
}

usage_build() {
    cat >&2 <<EOF
${C_BOLD}$SCRIPT_NAME build${C_RESET} [options]   - build the image (needs internet)

  --no-cache          rebuild every layer from scratch
  --base IMAGE        override the base image (default: $WRK_BASE_IMAGE)
  --tag REF           add an extra tag to the result
  --lsp "A B C"       Mason packages to bake in
  --ts  "lua go ..."  tree-sitter languages to bake in (default: a broad set)
  --wrk PATH          remember PATH as the host directory mounted at /wrk
EOF
}

# ===========================================================================
#  export
# ===========================================================================
cmd_export() {
    local out_dir="$SCRIPT_DIR/dist" level="$WRK_COMPRESS_LEVEL" compress="auto" ref=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --out)       out_dir="${2:?--out needs a directory}"; shift 2 ;;
            --level)     level="${2:?--level needs a number}"; shift 2 ;;
            --compress)  compress="${2:?--compress needs zstd|gzip|none}"; shift 2 ;;
            --image)     ref="${2:?--image needs an image reference}"; shift 2 ;;
            -h|--help)   usage_export; return 0 ;;
            *)           die "export: unknown option '$1' (try --help)" ;;
        esac
    done

    require_podman
    if [ -z "$ref" ]; then
        ref="$(resolve_image)" || die "no podman-wrk image found - run '$SCRIPT_NAME build' first"
    fi
    image_exists "$ref" || die "image '$ref' does not exist"

    if [ "$compress" = "auto" ]; then
        if have zstd; then compress="zstd"; elif have gzip; then compress="gzip"; else compress="none"; fi
    fi

    local raw_size; raw_size="$(image_size "$ref")"
    log "Exporting ${C_BOLD}$ref${C_RESET}  (uncompressed image: $(human "$raw_size"))"
    check_space "$out_dir" "$raw_size"

    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    local bundle_base="podman-wrk-${HOST_USER}-${stamp}"
    local staging; staging="$(mktemp -d "${TMPDIR:-/tmp}/podman-wrk-export.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$staging'" RETURN

    mkdir -p "$out_dir"

    step "saving image (this takes a while) ..."
    podman save --format docker-archive --output "$staging/image.tar" "$ref"

    step "assembling bundle ..."
    cp -f "$SCRIPT_PATH" "$staging/$SCRIPT_NAME"
    chmod +x "$staging/$SCRIPT_NAME"
    for f in Containerfile README.md; do
        [ -f "$SCRIPT_DIR/$f" ] && cp -f "$SCRIPT_DIR/$f" "$staging/$f"
    done

    cat > "$staging/manifest.env" <<EOF
# podman-wrk bundle manifest - read by '$SCRIPT_NAME import'
WRK_BUNDLE_VERSION=1
WRK_SCRIPT_VERSION=$SCRIPT_VERSION
WRK_IMAGE_REF=$ref
WRK_IMG_USER=$(img_user "$ref")
WRK_IMG_UID=$(img_uid "$ref")
WRK_IMG_GID=$(img_gid "$ref")
WRK_IMG_LOCALIZED=$(image_label "$ref" wrk.localized)
WRK_IMG_BUILT=$(image_label "$ref" org.opencontainers.image.created)
WRK_IMG_SIZE=$raw_size
WRK_EXPORTED=$(date -Is)
WRK_EXPORT_PODMAN=$(podman_client_version)
EOF

    step "checksumming ..."
    (
        cd "$staging"
        local present=()
        for f in "${BUNDLE_FILES[@]}"; do [ -f "$f" ] && present+=("$f"); done
        sha256sum "${present[@]}" > SHA256SUMS
    )

    local out
    case "$compress" in
        zstd)
            have zstd || die "zstd is not installed (use --compress gzip or none)"
            out="$out_dir/$bundle_base.tar.zst"
            step "compressing with zstd -$level ..."
            tar -C "$staging" -cf - . | zstd -T0 "-$level" -f -o "$out"
            ;;
        gzip)
            out="$out_dir/$bundle_base.tar.gz"
            step "compressing with gzip ..."
            tar -C "$staging" -czf "$out" .
            ;;
        none)
            out="$out_dir/$bundle_base.tar"
            tar -C "$staging" -cf "$out" .
            ;;
        *) die "export: --compress must be zstd, gzip or none" ;;
    esac

    local final_size; final_size="$(stat -c %s "$out" 2>/dev/null || echo 0)"
    ok "bundle written: ${C_BOLD}$out${C_RESET}  ($(human "$final_size"))"
    hint "on the target machine:  ./$SCRIPT_NAME import $(basename "$out")"
    hint "the bundle contains NO ssh keys - those are mounted from the target host at run time"
}

usage_export() {
    cat >&2 <<EOF
${C_BOLD}$SCRIPT_NAME export${C_RESET} [options]  - pack the image into one portable bundle

  --out DIR           where to write the bundle (default: ./dist)
  --image REF         export a specific image instead of the current one
  --compress MODE     zstd (default when available) | gzip | none
  --level N           zstd compression level (default: $WRK_COMPRESS_LEVEL)

The bundle carries image.tar, this script, the Containerfile, the README, a
manifest and SHA256SUMS. It is everything the target machine needs.

Tip: run '$SCRIPT_NAME commit' first if you want the current container's
writable layer (shell history, tweaks) to travel with the image.
EOF
}

# ===========================================================================
#  import
# ===========================================================================
cmd_import() {
    local src="" localize=0 install=0 skip_verify=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --localize)   localize=1; shift ;;
            --install)    install=1; shift ;;
            --no-verify)  skip_verify=1; shift ;;
            --wrk)        WRK_PATH="$(readlink -f "${2:?--wrk needs a path}")"; shift 2 ;;
            -h|--help)    usage_import; return 0 ;;
            -*)           die "import: unknown option '$1' (try --help)" ;;
            *)            src="$1"; shift ;;
        esac
    done

    require_podman

    local workdir="" cleanup=""
    if [ -z "$src" ]; then
        if [ -f "$SCRIPT_DIR/image.tar" ]; then
            workdir="$SCRIPT_DIR"
        else
            src="$(find_newest_bundle)" || \
                die "no bundle given and none found - usage: $SCRIPT_NAME import <bundle.tar.zst>"
            log "using newest bundle: $src"
        fi
    fi

    if [ -n "$src" ]; then
        if [ -d "$src" ]; then
            workdir="$src"
        elif [ -f "$src" ]; then
            workdir="$(mktemp -d "${TMPDIR:-/tmp}/podman-wrk-import.XXXXXX")"
            cleanup="$workdir"
            step "extracting $(basename "$src") ..."
            extract_bundle "$src" "$workdir"
        else
            die "no such bundle: $src"
        fi
    fi

    [ -f "$workdir/image.tar" ] || { [ -n "$cleanup" ] && rm -rf "$cleanup"; die "image.tar missing in $workdir"; }

    # --- integrity ---------------------------------------------------------
    if [ "$skip_verify" = "0" ] && [ -f "$workdir/SHA256SUMS" ]; then
        step "verifying checksums ..."
        if ( cd "$workdir" && sha256sum --quiet -c SHA256SUMS ); then
            ok "checksums match"
        else
            [ -n "$cleanup" ] && rm -rf "$cleanup"
            die "checksum verification FAILED - the bundle is corrupt or was tampered with"
        fi
    elif [ "$skip_verify" = "0" ]; then
        warn "no SHA256SUMS in the bundle - skipping integrity check"
    fi

    # --- manifest ----------------------------------------------------------
    local m_ref="" m_uid="$IMG_UID_DEFAULT" m_gid="$IMG_GID_DEFAULT" m_user="$IMG_USER_DEFAULT"
    if [ -f "$workdir/manifest.env" ]; then
        # shellcheck disable=SC1091
        . "$workdir/manifest.env"
        m_ref="${WRK_IMAGE_REF:-}"
        m_uid="${WRK_IMG_UID:-$IMG_UID_DEFAULT}"
        m_gid="${WRK_IMG_GID:-$IMG_GID_DEFAULT}"
        m_user="${WRK_IMG_USER:-$IMG_USER_DEFAULT}"
        step "bundle built $( [ -n "${WRK_IMG_BUILT:-}" ] && echo "$WRK_IMG_BUILT" || echo "at an unknown time" )"
    fi

    # --- load --------------------------------------------------------------
    step "loading image into podman ..."
    local load_out
    load_out="$(podman load --input "$workdir/image.tar" 2>&1)" || {
        echo "$load_out" >&2
        [ -n "$cleanup" ] && rm -rf "$cleanup"
        # Overwhelmingly the most common cause, and podman's own message for it
        # is buried under four "payload does not match" lines.
        case "$load_out" in
            *subuid*|*"insufficient UIDs"*|*"user namespace"*)
                err "this looks like a user-namespace problem, not a corrupt bundle"
                hint "run '$SCRIPT_NAME doctor' - it checks the subuid/subgid ranges for $HOST_USER"
                hint "after fixing them: podman system migrate"
                ;;
        esac
        die "podman load failed"
    }
    echo "$load_out" | sed 's/^/     /' >&2

    local loaded="$m_ref"
    if [ -z "$loaded" ] || ! image_exists "$loaded"; then
        loaded="$(echo "$load_out" | sed -n 's/^Loaded image[s]*: *//p' | head -n1)"
    fi
    [ -n "$loaded" ] && image_exists "$loaded" || {
        [ -n "$cleanup" ] && rm -rf "$cleanup"
        die "could not work out which image was loaded"
    }

    # --- tag for this host --------------------------------------------------
    podman tag "$loaded" "$BASE_IMAGE_TAG:latest"
    podman tag "$loaded" "$IMAGE_NAME:latest"
    podman tag "$loaded" "$IMAGE_ALIAS:latest"
    ok "tagged as $IMAGE_NAME:latest, $IMAGE_ALIAS:latest, $BASE_IMAGE_TAG:latest"

    # --- resolve identity ON THIS HOST -------------------------------------
    m_uid="$(img_uid "$IMAGE_NAME:latest")"
    m_gid="$(img_gid "$IMAGE_NAME:latest")"
    m_user="$(img_user "$IMAGE_NAME:latest")"

    log "Host identity resolved on ${C_BOLD}this${C_RESET} machine"
    step "host ........ $HOST_USER  uid=$HOST_UID  gid=$HOST_GID"
    step "in image .... $m_user  uid=$m_uid  gid=$m_gid"

    WRK_LOCALIZED=0
    if [ "$localize" = "1" ]; then
        localize_image "$m_user" "$m_uid" "$m_gid"
        WRK_LOCALIZED=1
    else
        step "mapping ..... --userns=keep-id:uid=$m_uid,gid=$m_gid"
        hint "files you create in /wrk will be owned by $HOST_USER ($HOST_UID:$HOST_GID) on this host"
        hint "pass --localize if you want $HOST_USER baked into the image itself (costs ~2 GB)"
    fi

    save_config

    if [ "$install" = "1" ]; then
        local bindir="$HOME/.local/bin"
        mkdir -p "$bindir"
        cp -f "$SCRIPT_PATH" "$bindir/wrk"
        chmod +x "$bindir/wrk"
        ok "installed as $bindir/wrk"
        case ":$PATH:" in
            *":$bindir:"*) ;;
            *) hint "$bindir is not on your \$PATH" ;;
        esac
    fi

    [ -n "$cleanup" ] && rm -rf "$cleanup"

    ok "import complete"
    hint "next: $SCRIPT_NAME verify   |   $SCRIPT_NAME shell --wrk /path/to/projects"
}

usage_import() {
    cat >&2 <<EOF
${C_BOLD}$SCRIPT_NAME import${C_RESET} [bundle] [options] - load the image on this machine (offline)

  bundle              .tar.zst / .tar.gz / .tar file, or an already extracted
                      directory. Defaults to the script's own directory, then
                      to the newest bundle in ./dist.

  --localize          bake THIS host's user name and UID/GID into the image
                      with an offline 'podman build --network=none'. Costs an
                      extra layer roughly the size of \$HOME (~2 GB). Without
                      it the same result is achieved for free at run time via
                      --userns=keep-id.
  --install           also copy this script to ~/.local/bin/wrk
  --no-verify         skip SHA256SUMS verification
  --wrk PATH          remember PATH as the host directory mounted at /wrk
EOF
}

find_newest_bundle() {
    local dir f
    for dir in "$SCRIPT_DIR/dist" "$SCRIPT_DIR" "$PWD"; do
        [ -d "$dir" ] || continue
        f="$(find "$dir" -maxdepth 1 -type f \
                \( -name 'podman-wrk-*.tar.zst' -o -name 'podman-wrk-*.tar.gz' -o -name 'podman-wrk-*.tar' \) \
                -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)"
        if [ -n "$f" ]; then echo "$f"; return 0; fi
    done
    return 1
}

extract_bundle() {
    local file="$1" dest="$2"
    case "$file" in
        *.tar.zst|*.tzst)
            have zstd || die "zstd is required to unpack $file"
            zstd -dc "$file" | tar -C "$dest" -xf - ;;
        *.tar.gz|*.tgz)  tar -C "$dest" -xzf "$file" ;;
        *.tar)           tar -C "$dest" -xf  "$file" ;;
        *)               die "unknown bundle format: $file" ;;
    esac
}

# Build a thin derived layer that renames the image user to this host's user.
# Runs with --network=none so it is provably offline.
localize_image() {
    local old_user="$1" old_uid="$2" old_gid="$3"
    local ctx; ctx="$(mktemp -d "${TMPDIR:-/tmp}/podman-wrk-localize.XXXXXX")"

    log "Localizing the image for $HOST_USER ($HOST_UID:$HOST_GID)"
    warn "this duplicates \$HOME into a new layer - expect a couple of GB of extra disk use"
    check_space "$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo "$HOME")" \
                "$(image_size "$IMAGE_NAME:latest")"

    cat > "$ctx/Containerfile" <<'CFEOF'
ARG WRK_SOURCE_IMAGE
FROM ${WRK_SOURCE_IMAGE}

ARG NEW_USER
ARG NEW_UID
ARG NEW_GID
ARG OLD_USER

USER root
RUN set -eux; \
    if [ "$NEW_GID" != "$(id -g "$OLD_USER")" ]; then groupmod -g "$NEW_GID" "$OLD_USER"; fi; \
    if [ "$NEW_UID" != "$(id -u "$OLD_USER")" ]; then usermod  -u "$NEW_UID" "$OLD_USER"; fi; \
    if [ "$NEW_USER" != "$OLD_USER" ]; then \
        usermod -l "$NEW_USER" -d "/home/$NEW_USER" -m "$OLD_USER"; \
        groupmod -n "$NEW_USER" "$OLD_USER" || true; \
    fi; \
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$NEW_USER" > /etc/sudoers.d/99-wrk; \
    chmod 0440 /etc/sudoers.d/99-wrk; \
    chown -R "$NEW_UID:$NEW_GID" "/home/$NEW_USER" /wrk

USER ${NEW_USER}
WORKDIR /wrk
LABEL wrk.user="${NEW_USER}" wrk.uid="${NEW_UID}" wrk.gid="${NEW_GID}" wrk.localized="1"
CFEOF

    podman build \
        --network=none \
        --file "$ctx/Containerfile" \
        --build-arg "WRK_SOURCE_IMAGE=$BASE_IMAGE_TAG:latest" \
        --build-arg "NEW_USER=$HOST_USER" \
        --build-arg "NEW_UID=$HOST_UID" \
        --build-arg "NEW_GID=$HOST_GID" \
        --build-arg "OLD_USER=$old_user" \
        --tag "$IMAGE_NAME:latest" \
        --tag "$IMAGE_ALIAS:latest" \
        "$ctx"

    rm -rf "$ctx"
    ok "image localized: the container user is now $HOST_USER ($HOST_UID:$HOST_GID)"
    hint "old identity was $old_user ($old_uid:$old_gid); $BASE_IMAGE_TAG:latest still holds the original"
}

check_space() {
    local target="$1" needed="${2:-0}"
    local dir="$target"
    while [ -n "$dir" ] && [ ! -d "$dir" ]; do dir="$(dirname "$dir")"; done
    [ -d "$dir" ] || return 0
    local avail
    avail="$(df -PB1 "$dir" 2>/dev/null | awk 'NR==2 {print $4}')" || return 0
    [ -n "$avail" ] || return 0
    if [ "$avail" -lt "$needed" ]; then
        warn "only $(human "$avail") free on $dir, roughly $(human "$needed") may be needed"
    fi
}

# ===========================================================================
#  running the environment
# ===========================================================================
container_wrk_mount() {
    podman inspect --format \
        '{{range .Mounts}}{{if eq .Destination "/wrk"}}{{.Source}}{{end}}{{end}}' \
        "$CONTAINER_NAME" 2>/dev/null || true
}

create_container() {
    local image="$1"
    local uid gid sel
    uid="$(img_uid "$image")"
    gid="$(img_gid "$image")"
    sel="$(selinux_suffix)"

    [ -d "$WRK_PATH" ] || die "work directory does not exist: $WRK_PATH"

    local args=(
        create --interactive --tty
        --name "$CONTAINER_NAME"
        --hostname wrk
        --workdir /wrk
        # An interactive login shell as PID 1 ignores SIGTERM, so a plain
        # `stop` would sit through the full timeout and then SIGKILL it.
        # SIGHUP is what a shell expects when its terminal goes away: it exits
        # cleanly and flushes its history file on the way out.
        --stop-signal SIGHUP
        --stop-timeout 5
        --volume "$WRK_PATH:/wrk:rw$sel"
        --env "TERM=${TERM:-xterm-256color}"
        --env "WRK_HOST=$(hostname 2>/dev/null || echo unknown)"
    )

    # Identity mapping. A localized image already has the right UID/GID baked
    # in, so a plain keep-id is enough there.
    if [ "$(image_label "$image" wrk.localized)" = "1" ]; then
        args+=(--userns "keep-id")
    else
        args+=(--userns "keep-id:uid=$uid,gid=$gid")
    fi

    # ~/.ssh inside the container is a tmpfs, and that is a security control,
    # not a detail. The entrypoint copies the host's private keys into it on
    # every start; if it were part of the writable layer, `commit` would fold
    # those keys into the image and `export` would ship them inside the bundle
    # - breaking the one guarantee this tool makes about secrets. A tmpfs is
    # never captured by commit and disappears when the container stops.
    args+=(--tmpfs "/home/$(img_user "$image")/.ssh:rw,mode=0700")

    # SSH material from the host this container runs on, read-only.
    if [ -d "$HOME/.ssh" ]; then
        args+=(--volume "$HOME/.ssh:/mnt/host-ssh:ro$sel")
    else
        warn "no $HOME/.ssh on this host - the container will start without keys"
    fi

    # Forward the agent socket when one is running.
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK}" ]; then
        args+=(--volume "$SSH_AUTH_SOCK:/run/ssh-agent" --env "SSH_AUTH_SOCK=/run/ssh-agent")
    fi

    [ -n "${COLORTERM:-}" ] && args+=(--env "COLORTERM=$COLORTERM")
    args+=(--env "TZ=$(detect_tz)")
    args+=("$image")

    step "creating container $CONTAINER_NAME"
    hint "/wrk  <-  $WRK_PATH"
    podman "${args[@]}" >/dev/null
}

ensure_container() {
    local image="$1"

    if container_exists "$CONTAINER_NAME"; then
        local current; current="$(container_wrk_mount)"
        if [ -n "$current" ] && [ "$current" != "$WRK_PATH" ]; then
            warn "the container currently mounts $current at /wrk, you asked for $WRK_PATH"
            hint "podman cannot change a mount on an existing container - it has to be recreated"
            if confirm "Commit the writable layer to $IMAGE_NAME:latest and recreate?" y; then
                cmd_commit
                podman rm -f "$CONTAINER_NAME" >/dev/null
                create_container "$(resolve_image)"
            else
                WRK_PATH="$current"
                warn "keeping the existing container and its /wrk -> $current"
            fi
        fi
        return 0
    fi

    create_container "$image"
}

cmd_shell() {
    local want_shell="bash" ephemeral=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --bash)       want_shell="bash"; shift ;;
            --zsh)        want_shell="zsh"; shift ;;
            --ephemeral)  ephemeral=1; shift ;;
            --wrk)        WRK_PATH="$(readlink -f "${2:?--wrk needs a path}")"; shift 2 ;;
            -h|--help)    usage_shell; return 0 ;;
            *)            die "shell: unknown option '$1' (try --help)" ;;
        esac
    done

    require_podman
    local image; image="$(resolve_image)" || \
        die "no podman-wrk image on this machine - run '$SCRIPT_NAME build' or '$SCRIPT_NAME import'"

    save_config

    if [ "$ephemeral" = "1" ]; then
        run_ephemeral "$image" "$want_shell"
        return
    fi

    ensure_container "$image"

    if container_running "$CONTAINER_NAME"; then
        step "attaching to the running container"
        exec podman exec --interactive --tty \
            --env "TERM=${TERM:-xterm-256color}" \
            "$CONTAINER_NAME" "/bin/$want_shell" -l
    fi

    if [ "$want_shell" = "bash" ]; then
        # bash is the container's own command, so attach to it directly:
        # leaving the shell stops the container, which is the tidy behaviour.
        exec podman start --attach --interactive "$CONTAINER_NAME"
    fi

    podman start "$CONTAINER_NAME" >/dev/null
    exec podman exec --interactive --tty \
        --env "TERM=${TERM:-xterm-256color}" \
        "$CONTAINER_NAME" "/bin/$want_shell" -l
}

run_ephemeral() {
    local image="$1" want_shell="$2"
    local uid gid sel
    uid="$(img_uid "$image")"; gid="$(img_gid "$image")"; sel="$(selinux_suffix)"

    warn "ephemeral session: nothing written outside /wrk survives"
    local args=(run --rm --interactive --tty --hostname wrk --workdir /wrk
                --volume "$WRK_PATH:/wrk:rw$sel"
                --env "TERM=${TERM:-xterm-256color}")
    if [ "$(image_label "$image" wrk.localized)" = "1" ]; then
        args+=(--userns "keep-id")
    else
        args+=(--userns "keep-id:uid=$uid,gid=$gid")
    fi
    args+=(--tmpfs "/home/$(img_user "$image")/.ssh:rw,mode=0700")
    [ -d "$HOME/.ssh" ] && args+=(--volume "$HOME/.ssh:/mnt/host-ssh:ro$sel")
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK}" ]; then
        args+=(--volume "$SSH_AUTH_SOCK:/run/ssh-agent" --env "SSH_AUTH_SOCK=/run/ssh-agent")
    fi
    args+=("$image" "/bin/$want_shell" -l)
    exec podman "${args[@]}"
}

usage_shell() {
    cat >&2 <<EOF
${C_BOLD}$SCRIPT_NAME shell${C_RESET} [options]   - enter the environment

  --bash              bash login shell (default)
  --zsh               zsh with Oh My Zsh and the mtsh theme
  --ephemeral         throwaway --rm session, nothing persists outside /wrk
  --wrk PATH          host directory to mount at /wrk (remembered afterwards)

The container is created once and then reused, so its writable layer - shell
history, installed odds and ends, Neovim state - persists between sessions.
EOF
}

cmd_exec() {
    require_podman
    [ $# -gt 0 ] || die "exec: nothing to run - usage: $SCRIPT_NAME exec <command> [args...]"
    container_exists "$CONTAINER_NAME" || die "no container '$CONTAINER_NAME' - run '$SCRIPT_NAME shell' first"
    container_running "$CONTAINER_NAME" || podman start "$CONTAINER_NAME" >/dev/null

    # Allocate a pty only when the output really is a terminal. With --tty the
    # runtime turns every \n into \r\n, so `wrk exec ... > file` would quietly
    # produce a CRLF file and break whatever reads it next.
    local -a io=(--interactive)
    [ -t 1 ] && io+=(--tty)

    exec podman exec "${io[@]}" \
        --env "TERM=${TERM:-xterm-256color}" \
        "$CONTAINER_NAME" "$@"
}

# ===========================================================================
#  commit / mount / status / stop / restart
# ===========================================================================
cmd_commit() {
    local snapshot=0 tag=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --snapshot) snapshot=1; shift ;;
            --tag)      tag="${2:?--tag needs a value}"; shift 2 ;;
            -h|--help)  usage_commit; return 0 ;;
            *)          die "commit: unknown option '$1' (try --help)" ;;
        esac
    done

    require_podman
    container_exists "$CONTAINER_NAME" || die "no container '$CONTAINER_NAME' to commit"

    local target="$IMAGE_NAME:latest"
    [ -n "$tag" ] && target="$IMAGE_NAME:$tag"

    step "committing the writable layer of $CONTAINER_NAME -> $target"
    # --message requires the docker image format; podman rejects it on OCI.
    # docker format is the right choice anyway - export saves a docker-archive,
    # and the wrk.* labels this script depends on survive the conversion.
    podman commit --pause=false \
        --format docker \
        --author "Mateusz Okulanis" \
        --message "podman-wrk snapshot $(date -Is)" \
        "$CONTAINER_NAME" "$target" >/dev/null

    if [ "$snapshot" = "1" ] && [ -z "$tag" ]; then
        local snap="$IMAGE_NAME:snapshot-$(date +%Y%m%d-%H%M%S)"
        podman tag "$target" "$snap"
        ok "also tagged $snap"
    fi

    ok "committed to $target  ($(human "$(image_size "$target")"))"
    hint "run '$SCRIPT_NAME prune' now and then to clear the dangling images this leaves behind"
}

usage_commit() {
    cat >&2 <<EOF
${C_BOLD}$SCRIPT_NAME commit${C_RESET} [options]  - freeze the container's writable layer into the image

  --snapshot          additionally tag the result as :snapshot-YYYYmmdd-HHMMSS
  --tag NAME          commit to $IMAGE_NAME:NAME instead of :latest

Do this before 'export' if you want your shell history and local tweaks to
travel to the target machine.
EOF
}

cmd_mount() {
    if [ $# -gt 0 ]; then
        case "$1" in
            -h|--help) echo "usage: $SCRIPT_NAME mount [PATH]" >&2; return 0 ;;
        esac
        WRK_PATH="$(readlink -f "$1")"
        [ -d "$WRK_PATH" ] || die "not a directory: $WRK_PATH"
        save_config
        ok "/wrk will map to $WRK_PATH"
        if container_exists "$CONTAINER_NAME"; then
            local current; current="$(container_wrk_mount)"
            [ "$current" != "$WRK_PATH" ] && \
                hint "the existing container still mounts $current - it will be recreated on the next 'shell'"
        fi
    else
        printf '%s\n' "$WRK_PATH"
    fi
}

cmd_status() {
    require_podman
    local image; image="$(resolve_image || true)"

    printf '%s%s%s\n' "$C_BOLD" "podman-wrk status" "$C_RESET"
    printf '  script .......... v%s  (%s)\n' "$SCRIPT_VERSION" "$SCRIPT_PATH"
    printf '  host identity ... %s  uid=%s gid=%s\n' "$HOST_USER" "$HOST_UID" "$HOST_GID"
    printf '  /wrk source ..... %s\n' "$WRK_PATH"
    printf '  config .......... %s\n' "$CONFIG_FILE"

    if [ -n "$image" ]; then
        printf '  image ........... %s  %s\n' "$image" "$(human "$(image_size "$image")")"
        printf '  image identity .. %s uid=%s gid=%s  (localized=%s)\n' \
            "$(img_user "$image")" "$(img_uid "$image")" "$(img_gid "$image")" \
            "$(image_label "$image" wrk.localized)"
        printf '  image built ..... %s\n' "$(image_label "$image" org.opencontainers.image.created)"
    else
        printf '  image ........... %snone - run build or import%s\n' "$C_YELLOW" "$C_RESET"
    fi

    if container_exists "$CONTAINER_NAME"; then
        local state; state="$(podman inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)"
        printf '  container ....... %s  [%s]\n' "$CONTAINER_NAME" "$state"
        printf '  container /wrk .. %s\n' "$(container_wrk_mount)"
        # --size is not optional: without it podman reports an empty .Size.
        local rw
        rw="$(podman ps --all --size --filter "name=^${CONTAINER_NAME}$" --format '{{.Size}}' 2>/dev/null || true)"
        if [ -n "$rw" ]; then
            printf '  writable layer .. %s\n' "$rw"
        fi
    else
        printf '  container ....... %snot created yet%s\n' "$C_DIM" "$C_RESET"
    fi
    # Never let the last conditional above decide this function's exit status:
    # `status` reports, it does not pass judgement.
    return 0
}

cmd_stop() {
    require_podman
    container_exists "$CONTAINER_NAME" || { warn "no container '$CONTAINER_NAME'"; return 0; }
    podman stop "$CONTAINER_NAME" >/dev/null && ok "stopped $CONTAINER_NAME"
}

cmd_restart() {
    require_podman
    container_exists "$CONTAINER_NAME" || die "no container '$CONTAINER_NAME'"
    podman restart "$CONTAINER_NAME" >/dev/null && ok "restarted $CONTAINER_NAME"
}

# ===========================================================================
#  doctor / verify
# ===========================================================================
cmd_doctor() {
    local problems=0
    printf '%s%s%s\n' "$C_BOLD" "podman-wrk doctor" "$C_RESET"

    if have podman; then
        local pv; pv="$(podman_client_version)"
        if version_ge "$pv" "4.3"; then
            ok "podman $pv (>= 4.3, supports --userns=keep-id:uid=,gid=)"
        else
            err "podman $pv is too old - keep-id with explicit uid/gid needs 4.3+"
            problems=$((problems + 1))
        fi
    else
        err "podman is not installed"
        problems=$((problems + 1))
    fi

    if have podman; then
        local rootless; rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo unknown)"
        if [ "$rootless" = "true" ]; then
            ok "running rootless"
            if grep -q "^${HOST_USER}:" /etc/subuid 2>/dev/null && \
               grep -q "^${HOST_USER}:" /etc/subgid 2>/dev/null; then
                ok "subuid/subgid ranges present for $HOST_USER"
            else
                err "no subuid/subgid range for $HOST_USER - user namespaces will not work"
                hint "fix: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $HOST_USER"
                problems=$((problems + 1))
            fi
        else
            warn "not running rootless (rootless=$rootless) - /wrk ownership may differ"
        fi

        local root; root="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo "")"
        if [ -n "$root" ] && [ -d "$root" ]; then
            local avail; avail="$(df -PB1 "$root" 2>/dev/null | awk 'NR==2 {print $4}')"
            if [ -n "$avail" ]; then
                if [ "$avail" -lt 6000000000 ]; then
                    warn "storage at $root has $(human "$avail") free - a full build wants ~6 GB"
                else
                    ok "storage at $root: $(human "$avail") free"
                fi
            fi
        fi
    fi

    have zstd  && ok "zstd available (best bundle compression)" || warn "zstd missing - export falls back to gzip"
    have rsync && ok "rsync available" || warn "rsync missing on the host (only needed inside the image)"

    if [ -d "$HOME/.ssh" ]; then
        local keys; keys="$(find "$HOME/.ssh" -maxdepth 1 -type f -name 'id_*' ! -name '*.pub' 2>/dev/null | wc -l)"
        ok "$HOME/.ssh present ($keys private key(s) will be mounted read-only)"
    else
        warn "no $HOME/.ssh - the container will have no ssh keys"
    fi

    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK}" ]; then
        ok "ssh-agent socket detected - it will be forwarded"
    else
        hint "no ssh-agent running; keys will be used from the mounted ~/.ssh instead"
    fi

    if [ -d "$WRK_PATH" ]; then
        ok "/wrk source exists: $WRK_PATH"
    else
        warn "/wrk source does not exist: $WRK_PATH  (fix with '$SCRIPT_NAME mount <path>')"
    fi

    local image
    if image="$(resolve_image)"; then
        ok "image $image  ($(human "$(image_size "$image")"))"
        printf '       identity in image: %s uid=%s gid=%s  localized=%s\n' \
            "$(img_user "$image")" "$(img_uid "$image")" "$(img_gid "$image")" \
            "$(image_label "$image" wrk.localized)"
    else
        warn "no podman-wrk image yet - run build (online) or import (offline)"
    fi

    echo
    if [ "$problems" -eq 0 ]; then
        ok "no blocking problems found"
    else
        err "$problems blocking problem(s) found"
        return 1
    fi
}

cmd_verify() {
    require_podman
    local image; image="$(resolve_image)" || die "no image to verify"

    log "Smoke-testing $image with the network disabled"

    local script='
set -u
missing=0
# spf is superfile: the Arch package installs the binary under the short name.
for b in bash zsh nvim vim nano mc spf lazygit git tmux btop lynx fzf rsync yay \
         rg fd bat eza jq ssh sudo; do
    if command -v "$b" >/dev/null 2>&1; then
        printf "  ok   %s\n" "$b"
    else
        printf "  MISS %s\n" "$b"
        missing=$((missing+1))
    fi
done
if command -v neofetch >/dev/null 2>&1; then printf "  ok   neofetch\n"
elif command -v fastfetch >/dev/null 2>&1; then printf "  ok   fastfetch (neofetch fallback)\n"
else printf "  MISS neofetch/fastfetch\n"; missing=$((missing+1)); fi

printf "\n  oh-my-zsh theme: "
[ -f "$HOME/.oh-my-zsh/custom/themes/mtsh.zsh-theme" ] && printf "mtsh present\n" || { printf "MISSING\n"; missing=$((missing+1)); }

printf "  neovim headless: "
if nvim --headless "+qa" >/dev/null 2>&1; then printf "starts cleanly\n"; else printf "FAILED\n"; missing=$((missing+1)); fi

plugins=$( (ls -1 "$HOME/.local/share/nvim/lazy" 2>/dev/null || true) | wc -l )
masons=$(  (ls -1 "$HOME/.local/share/nvim/mason/packages" 2>/dev/null || true) | wc -l )
parsers=$( find "$HOME/.local/share/nvim" -name "*.so" -path "*parser*" 2>/dev/null | wc -l )

printf "  lazy.nvim plugins:  %s\n" "$plugins"
printf "  mason packages:     %s\n" "$masons"
printf "  treesitter parsers: %s\n" "$parsers"

# These are the whole point of an offline image: if they are empty the image
# builds and starts but is useless on a machine without a network.
[ "$plugins" -ge 20 ] || { printf "  FAIL too few plugins\n";  missing=$((missing+1)); }
[ "$masons"  -ge 5  ] || { printf "  FAIL no mason packages\n"; missing=$((missing+1)); }
[ "$parsers" -ge 10 ] || { printf "  FAIL no treesitter parsers\n"; missing=$((missing+1)); }

exit $missing
'
    if podman run --rm --network=none --entrypoint /bin/bash "$image" -lc "$script"; then
        ok "verification passed"
    else
        die "verification failed - see the MISS lines above"
    fi
}

# ===========================================================================
#  images / df / rm / rmi / prune / purge
# ===========================================================================
wrk_image_refs() {
    podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -E "^(localhost/)?podman-wrk" || true
}

# Sum the on-disk size of the given references, counting each distinct image
# once. Several tags normally point at one image, so a naive per-tag sum claims
# a 4 GB image is 12 GB.
distinct_image_bytes() {
    local total=0 ref id s
    local -a seen=()
    for ref in "$@"; do
        [ -n "$ref" ] || continue
        image_exists "$ref" || continue
        id="$(podman image inspect --format '{{.Id}}' "$ref" 2>/dev/null || echo "$ref")"
        case " ${seen[*]-} " in
            *" $id "*) continue ;;
        esac
        seen+=("$id")
        s="$(image_size "$ref")"
        total=$((total + s))
    done
    printf '%s' "$total"
}

cmd_images() {
    require_podman
    local rows
    rows="$(podman images \
        --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Created}}\t{{.Size}}' 2>/dev/null \
        | { read -r header; printf '%s\n' "$header"; grep -E 'podman-wrk|<none>' || true; })"
    if [ "$(printf '%s\n' "$rows" | wc -l)" -le 1 ]; then
        warn "no podman-wrk images on this machine"
        return 0
    fi
    printf '%s\n' "$rows"
    hint "<none> rows are dangling layers left behind by build/commit - '$SCRIPT_NAME prune' clears them"
}

cmd_df() {
    require_podman
    printf '%s%s%s\n' "$C_BOLD" "podman-wrk disk usage" "$C_RESET"

    local total=0 ref size
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        size="$(image_size "$ref")"
        printf '  image      %-42s %s\n' "$ref" "$(human "$size")"
    done < <(wrk_image_refs)

    # Distinct layers, not the sum of tags: ask podman for unique image IDs.
    local id
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        size="$(podman image inspect --format '{{.Size}}' "$id" 2>/dev/null || echo 0)"
        total=$((total + size))
    done < <(wrk_image_refs | xargs -r -n1 podman image inspect --format '{{.Id}}' 2>/dev/null | sort -u)

    printf '  %s---%s\n' "$C_DIM" "$C_RESET"
    printf '  unique image data ......... %s\n' "$(human "$total")"

    if container_exists "$CONTAINER_NAME"; then
        local rw; rw="$(podman ps --all --filter "name=^${CONTAINER_NAME}$" --format '{{.Size}}' 2>/dev/null)"
        printf '  container writable layer .. %s\n' "${rw:-unknown}"
    fi

    echo
    podman system df 2>/dev/null || true
}

cmd_rm() {
    local dry=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes|-y)   ASSUME_YES=1; shift ;;
            --dry-run)  dry=1; shift ;;
            -h|--help)  echo "usage: $SCRIPT_NAME rm [--yes] [--dry-run]   - remove the CONTAINER" >&2; return 0 ;;
            *)          die "rm: unknown option '$1'" ;;
        esac
    done

    require_podman
    container_exists "$CONTAINER_NAME" || { warn "no container '$CONTAINER_NAME'"; return 0; }

    if [ "$dry" = "1" ]; then
        log "would remove container $CONTAINER_NAME (and its writable layer)"
        return 0
    fi

    warn "removing the container also destroys its writable layer:"
    hint "shell history, anything installed inside, Neovim state - all of it"
    hint "run '$SCRIPT_NAME commit' first if you want to keep it"
    confirm "Remove container $CONTAINER_NAME?" || { log "cancelled"; return 0; }

    podman rm --force "$CONTAINER_NAME" >/dev/null
    ok "removed container $CONTAINER_NAME"
    hint "the image is untouched - '$SCRIPT_NAME shell' will create a fresh container"
}

cmd_rmi() {
    local all=0 force=0 dry=0
    local -a targets=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --all|-a)   all=1; shift ;;
            --force|-f) force=1; shift ;;
            --yes|-y)   ASSUME_YES=1; shift ;;
            --dry-run)  dry=1; shift ;;
            -h|--help)  usage_rmi; return 0 ;;
            -*)         die "rmi: unknown option '$1' (try --help)" ;;
            *)          targets+=("$1"); shift ;;
        esac
    done

    require_podman

    if [ "$all" = "1" ]; then
        mapfile -t targets < <(wrk_image_refs)
    elif [ ${#targets[@]} -eq 0 ]; then
        local image
        image="$(resolve_image)" || { warn "no podman-wrk image to remove"; return 0; }
        targets=("$image")
    fi

    [ ${#targets[@]} -gt 0 ] || { warn "nothing to remove"; return 0; }

    local ref
    log "images selected for removal:"
    for ref in "${targets[@]}"; do
        if image_exists "$ref"; then
            printf '    %-44s %s\n' "$ref" "$(human "$(image_size "$ref")")" >&2
        else
            warn "  $ref does not exist - skipping"
        fi
    done
    hint "about $(human "$(distinct_image_bytes "${targets[@]}")") of distinct layer data, if nothing else references it"

    if [ "$dry" = "1" ]; then log "dry run - nothing removed"; return 0; fi

    if container_exists "$CONTAINER_NAME"; then
        if [ "$force" = "1" ]; then
            warn "container $CONTAINER_NAME uses these images and will be removed first"
            confirm "Remove the container too?" || { log "cancelled"; return 0; }
            podman rm --force "$CONTAINER_NAME" >/dev/null
            ok "removed container $CONTAINER_NAME"
        else
            hint "container $CONTAINER_NAME still exists; podman will refuse images it uses (pass --force)"
        fi
    fi

    confirm "Remove ${#targets[@]} image(s)?" || { log "cancelled"; return 0; }

    local failed=0
    for ref in "${targets[@]}"; do
        image_exists "$ref" || continue
        if podman rmi "$ref" >/dev/null 2>&1; then
            ok "removed $ref"
        elif [ "$force" = "1" ] && podman rmi --force "$ref" >/dev/null 2>&1; then
            ok "force-removed $ref"
        else
            err "could not remove $ref (still in use? try --force)"
            failed=$((failed + 1))
        fi
    done

    [ "$failed" -eq 0 ] || return 1
}

usage_rmi() {
    cat >&2 <<EOF
${C_BOLD}$SCRIPT_NAME rmi${C_RESET} [REF...] [options]  - remove podman-wrk IMAGES

  (no args)           remove the image this user currently runs
  REF...              remove the named references
  --all, -a           remove every podman-wrk* image, snapshots included
  --force, -f         remove the container first and force image removal
  --yes, -y           do not ask
  --dry-run           list what would go, remove nothing
EOF
}

cmd_prune() {
    local keep=3 dry=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --keep)     keep="${2:?--keep needs a number}"; shift 2 ;;
            --yes|-y)   ASSUME_YES=1; shift ;;
            --dry-run)  dry=1; shift ;;
            -h|--help)  usage_prune; return 0 ;;
            *)          die "prune: unknown option '$1' (try --help)" ;;
        esac
    done

    require_podman

    # --- old snapshots -----------------------------------------------------
    #
    # Do NOT use `--filter reference=NAME:snapshot-*` here. That filter selects
    # IMAGES, and podman then prints a row for every tag the matched image
    # carries - so a snapshot that shares an image id with :latest drags
    # :latest into the list and prune deletes the image you actually use.
    # Match the tag text itself instead, and refuse anything not a snapshot.
    local -a snaps=()
    mapfile -t snaps < <(
        podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
            | sed -n "s#^\(localhost/\)\{0,1\}${IMAGE_NAME}:\(snapshot-.*\)\$#\2#p" \
            | sort -ru
    )

    if [ ${#snaps[@]} -gt "$keep" ]; then
        local i
        for (( i = keep; i < ${#snaps[@]}; i++ )); do
            local ref="$IMAGE_NAME:${snaps[$i]}"
            case "${snaps[$i]}" in
                snapshot-*) ;;
                *) warn "refusing to prune non-snapshot tag ${snaps[$i]}"; continue ;;
            esac
            if [ "$dry" = "1" ]; then
                log "would remove snapshot $ref  ($(human "$(image_size "$ref")"))"
            else
                podman rmi "$ref" >/dev/null 2>&1 && ok "removed snapshot $ref" \
                    || warn "could not remove $ref"
            fi
        done
    else
        step "${#snaps[@]} snapshot(s), keeping up to $keep - nothing to drop"
    fi

    # --- dangling layers ---------------------------------------------------
    local dangling
    dangling="$(podman images --filter dangling=true --quiet 2>/dev/null | wc -l)"
    if [ "$dangling" -eq 0 ]; then
        step "no dangling images"
    elif [ "$dry" = "1" ]; then
        log "would prune $dangling dangling image(s)"
    else
        warn "$dangling dangling image(s) will be pruned - this is podman-wide, not just podman-wrk"
        if confirm "Prune dangling images?" y; then
            local out; out="$(podman image prune --force 2>/dev/null || true)"
            local reclaimed; reclaimed="$(printf '%s' "$out" | sed -n 's/^Total reclaimed space: *//p')"
            ok "pruned dangling images${reclaimed:+ - reclaimed $reclaimed}"
        fi
    fi
}

usage_prune() {
    cat >&2 <<EOF
${C_BOLD}$SCRIPT_NAME prune${C_RESET} [options]  - drop old snapshots and dangling layers

  --keep N            how many :snapshot-* tags to keep (default: 3)
  --yes, -y           do not ask
  --dry-run           list what would go, remove nothing
EOF
}

cmd_purge() {
    local dry=0 keep_config=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes|-y)       ASSUME_YES=1; shift ;;
            --dry-run)      dry=1; shift ;;
            --keep-config)  keep_config=1; shift ;;
            -h|--help)      usage_purge; return 0 ;;
            *)              die "purge: unknown option '$1' (try --help)" ;;
        esac
    done

    require_podman

    local -a images=()
    mapfile -t images < <(wrk_image_refs)
    local -a volumes=()
    mapfile -t volumes < <(podman volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^podman-wrk' || true)

    printf '%s%s%s\n' "$C_BOLD" "podman-wrk purge - everything below will be removed from THIS machine" "$C_RESET"

    if container_exists "$CONTAINER_NAME"; then
        printf '  container ....... %s (and its writable layer)\n' "$CONTAINER_NAME"
    fi
    local ref
    local total; total="$(distinct_image_bytes "${images[@]-}")"
    for ref in "${images[@]}"; do
        [ -n "$ref" ] || continue
        printf '  image ........... %-40s %s\n' "$ref" "$(human "$(image_size "$ref")")"
    done
    for ref in "${volumes[@]}"; do
        [ -n "$ref" ] && printf '  volume .......... %s\n' "$ref"
    done
    [ "$keep_config" = "0" ] && [ -d "$CONFIG_DIR" ] && printf '  config .......... %s\n' "$CONFIG_DIR"
    [ -f "$HOME/.local/bin/wrk" ] && printf '  installed script  %s\n' "$HOME/.local/bin/wrk"

    echo
    printf '  %sNOT touched:%s the host directory mounted at /wrk (%s)\n' "$C_GREEN" "$C_RESET" "$WRK_PATH"
    printf '  %sNOT touched:%s your ~/.ssh, and any exported bundles under ./dist\n' "$C_GREEN" "$C_RESET"
    echo

    if [ "$dry" = "1" ]; then log "dry run - nothing removed"; return 0; fi

    confirm_typed "This cannot be undone." "yes" || { log "cancelled"; return 0; }

    if container_exists "$CONTAINER_NAME"; then
        podman rm --force "$CONTAINER_NAME" >/dev/null 2>&1 && ok "removed container $CONTAINER_NAME"
    fi
    for ref in "${images[@]}"; do
        [ -n "$ref" ] || continue
        podman rmi --force "$ref" >/dev/null 2>&1 && ok "removed image $ref" || warn "could not remove $ref"
    done
    for ref in "${volumes[@]}"; do
        [ -n "$ref" ] || continue
        podman volume rm --force "$ref" >/dev/null 2>&1 && ok "removed volume $ref"
    done
    if [ "$keep_config" = "0" ] && [ -d "$CONFIG_DIR" ]; then
        rm -rf "$CONFIG_DIR" && ok "removed $CONFIG_DIR"
    fi
    if [ -f "$HOME/.local/bin/wrk" ]; then
        rm -f "$HOME/.local/bin/wrk" && ok "removed $HOME/.local/bin/wrk"
    fi

    ok "purge complete - freed roughly $(human "$total")"
}

usage_purge() {
    cat >&2 <<EOF
${C_BOLD}$SCRIPT_NAME purge${C_RESET} [options]  - remove podman-wrk from this machine entirely

Removes the container, every podman-wrk* image, podman-wrk volumes, the config
directory and ~/.local/bin/wrk. Your work directory, your ssh keys and any
exported bundles are left alone.

  --yes, -y           skip the confirmation prompt
  --dry-run           list what would go, remove nothing
  --keep-config       leave ~/.config/podman-wrk in place
EOF
}

# ===========================================================================
#  install
# ===========================================================================
cmd_install() {
    local bindir="${XDG_BIN_HOME:-$HOME/.local/bin}" name="wrk" mode="symlink" force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir)      bindir="${2:?--dir needs a directory}"; shift 2 ;;
            --name)     name="${2:?--name needs a value}"; shift 2 ;;
            --copy)     mode="copy"; shift ;;
            --symlink)  mode="symlink"; shift ;;
            --force|-f) force=1; shift ;;
            -h|--help)  usage_install; return 0 ;;
            *)          die "install: unknown option '$1' (try --help)" ;;
        esac
    done

    local target="$bindir/$name"
    if [ -L "$target" ]; then
        local current; current="$(readlink -f "$target" 2>/dev/null || echo '?')"
        if [ "$force" = "0" ]; then
            [ "$current" = "$SCRIPT_PATH" ] && { ok "$target already links to this script"; return 0; }
            die "$target is a symlink to $current - pass --force to replace it"
        fi
        rm -f "$target"
    elif [ -e "$target" ]; then
        if [ "$force" = "0" ]; then
            if cmp -s "$target" "$SCRIPT_PATH"; then
                ok "$target is already an identical copy of this script"
                return 0
            fi
            die "$target exists and is a different file - pass --force to replace it"
        fi
        rm -f "$target"
    fi

    mkdir -p "$bindir"
    if [ "$mode" = "symlink" ]; then
        ln -s "$SCRIPT_PATH" "$target"
        ok "installed $target -> $SCRIPT_PATH"
        hint "a symlink, so 'git pull' in the checkout updates it too"
    else
        cp -f "$SCRIPT_PATH" "$target"
        chmod +x "$target"
        ok "installed $target (copy of $SCRIPT_PATH)"
    fi

    case ":$PATH:" in
        *":$bindir:"*) ;;
        *) warn "$bindir is not on your \$PATH - '$name' will not be found"
           hint "add to your shell rc:  export PATH=\"$bindir:\$PATH\"" ;;
    esac

    hint "note: inside the container '$name' is an alias for 'cd /wrk' - different thing"
}

usage_install() {
    cat >&2 <<EOF
${C_BOLD}$SCRIPT_NAME install${C_RESET} [options]  - put this script on \$PATH as 'wrk'

Every example in the README that starts with 'wrk' assumes you have done this.
'import --install' does the same thing on the target machine.

  --dir DIR           where to install (default: ~/.local/bin)
  --name NAME         install under a different name (default: wrk)
  --symlink           symlink to this checkout (default; survives git pull)
  --copy              copy the file instead
  --force, -f         replace an existing file of that name

Remove it again with '$SCRIPT_NAME purge', or just delete the file.
EOF
}

# ===========================================================================
#  help / version
# ===========================================================================
cmd_version() {
    cat <<EOF
podman-wrk.sh $SCRIPT_VERSION
This is free and unencumbered software released into the public domain.
There is NO WARRANTY, to the extent permitted by law.

Written by Mateusz Okulanis.
EOF
}

cmd_help() {
    cat >&2 <<EOF
${C_BOLD}podman-wrk${C_RESET} v$SCRIPT_VERSION - portable, air-gapped developer environment
Author: Mateusz Okulanis

  ${C_BOLD}usage:${C_RESET} $SCRIPT_NAME <command> [options]

${C_BOLD}Life cycle${C_RESET}
  install            put this script on \$PATH as 'wrk' (what the docs assume)
  build              build the image from the Containerfile (needs internet)
  export             pack the image into one portable bundle
  import [BUNDLE]    load a bundle on this machine (works fully offline)
  shell              enter the environment (creates the container once)
  exec CMD...        run a command in the running container
  commit             freeze the container's writable layer into the image
  mount [PATH]       show or set the host directory mounted at /wrk
  status             what exists on this machine right now
  stop / restart     container control
  doctor             check this machine can build and run the environment
  verify             smoke-test the image with the network disabled

${C_BOLD}Cleanup${C_RESET}
  images             list podman-wrk images (like 'docker images')
  df                 disk used by images, container and volumes
  rm                 remove the CONTAINER (destroys its writable layer)
  rmi [REF...]       remove IMAGES        (--all, --force, --dry-run)
  prune              drop old snapshots and dangling layers (--keep N)
  purge              remove everything podman-wrk from this machine

${C_BOLD}Typical flow${C_RESET}
  machine with internet:
      ./$SCRIPT_NAME build
      ./$SCRIPT_NAME verify
      ./$SCRIPT_NAME shell --wrk ~/projects      # use it, tweak it
      ./$SCRIPT_NAME commit                      # keep the tweaks
      ./$SCRIPT_NAME export
  air-gapped machine:
      ./$SCRIPT_NAME import podman-wrk-*.tar.zst --install
      wrk shell --wrk /srv/projects

Every command takes --help. Current config: $CONFIG_FILE
EOF
}

# ===========================================================================
#  main
# ===========================================================================
main() {
    load_config

    # The environment wins over a stored config, and a config written on
    # another machine must never override this host's identity.
    [ -n "$ENV_WRK_PATH" ]           && WRK_PATH="$ENV_WRK_PATH"
    [ -n "$ENV_WRK_BASE_IMAGE" ]     && WRK_BASE_IMAGE="$ENV_WRK_BASE_IMAGE"
    [ -n "$ENV_WRK_COMPRESS_LEVEL" ] && WRK_COMPRESS_LEVEL="$ENV_WRK_COMPRESS_LEVEL"

    IMAGE_NAME="podman-wrk-${HOST_USER}"
    CONTAINER_NAME="podman-wrk-${HOST_USER}"

    local cmd="${1:-help}"
    [ $# -gt 0 ] && shift

    case "$cmd" in
        install)            cmd_install "$@" ;;
        build)              cmd_build "$@" ;;
        export|save)        cmd_export "$@" ;;
        import|load)        cmd_import "$@" ;;
        shell|run|sh)       cmd_shell "$@" ;;
        exec)               cmd_exec "$@" ;;
        commit)             cmd_commit "$@" ;;
        mount)              cmd_mount "$@" ;;
        status|info)        cmd_status "$@" ;;
        stop)               cmd_stop "$@" ;;
        restart)            cmd_restart "$@" ;;
        doctor)             cmd_doctor "$@" ;;
        verify|test)        cmd_verify "$@" ;;
        images|ls)          cmd_images "$@" ;;
        df|usage)           cmd_df "$@" ;;
        rm)                 cmd_rm "$@" ;;
        rmi|rmimage)        cmd_rmi "$@" ;;
        prune)              cmd_prune "$@" ;;
        purge|uninstall)    cmd_purge "$@" ;;
        version|--version)  cmd_version ;;
        help|--help|-h)     cmd_help ;;
        *)                  err "unknown command: $cmd"; echo >&2; cmd_help; exit 1 ;;
    esac
}

main "$@"
