#!/usr/bin/env bash
# Briklab notion - versions.* : derive version artifacts from versions.yml (SoT).
#
# versions.yml  --(briklab.versions.generate)-->  versions.env
#                                                  config/jenkins/plugins.txt
#                                                  config/brik-images.lock.yaml
#
# Sourced by scripts/infra.sh (the `versions` command). Relies on BRIKLAB_ROOT
# being set by lib/common.sh before this file is sourced. Not meant to run
# standalone.
#
#   briklab.versions.generate    rewrite all artifacts from versions.yml
#   briklab.versions.check       return non-zero if any artifact is stale (CI gate)

[[ -n "${_BRIKLAB_VERSIONS_LOADED:-}" ]] && return 0
_BRIKLAB_VERSIONS_LOADED=1

_BRIKLAB_VERSIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Prefer the ecosystem root (set by common.sh); fall back to self-location so the
# module works even when sourced without the dispatcher's BRIKLAB_ROOT prefix.
_BRIKLAB_VERSIONS_ROOT="${BRIKLAB_ROOT:-$(cd "${_BRIKLAB_VERSIONS_DIR}/../.." && pwd)}"

_briklab_versions_source()       { echo "${_BRIKLAB_VERSIONS_ROOT}/versions.yml"; }
_briklab_versions_env_path()     { echo "${_BRIKLAB_VERSIONS_ROOT}/versions.env"; }
_briklab_versions_plugins_path() { echo "${_BRIKLAB_VERSIONS_ROOT}/config/jenkins/plugins.txt"; }
_briklab_versions_lock_path()    { echo "${_BRIKLAB_VERSIONS_ROOT}/config/brik-images.lock.yaml"; }

_BRIKLAB_VERSIONS_HEADER="# GENERATED from versions.yml by 'make versions' -- DO NOT EDIT"

# --- Renderers (each prints one artifact to stdout) -------------------------

_briklab_versions_render_env() {
    local src; src="$(_briklab_versions_source)"
    echo "$_BRIKLAB_VERSIONS_HEADER"
    echo "# Loaded into the shell environment by scripts/lib/common.sh (load_versions)"
    echo "# so docker compose and the setup scripts resolve every version from one place."
    echo ""
    echo "GITLAB_IMAGE=$(yq -r '.infra.gitlab' "$src")"
    echo "GITLAB_RUNNER_IMAGE=$(yq -r '.infra.gitlab_runner' "$src")"
    echo "GITLAB_RUNNER_HELPER_IMAGE=$(yq -r '.infra.gitlab_runner_helper' "$src")"
    echo "GITEA_IMAGE=$(yq -r '.infra.gitea' "$src")"
    echo "NEXUS_IMAGE=$(yq -r '.infra.nexus' "$src")"
    echo "JENKINS_BASE_IMAGE=$(yq -r '.infra.jenkins_base' "$src")"
    echo "SSH_TARGET_BASE_IMAGE=$(yq -r '.infra.ssh_target_base' "$src")"
    echo "K3S_IMAGE=$(yq -r '.kubernetes.k3s' "$src")"
    echo "ARGOCD_VERSION=$(yq -r '.kubernetes.argocd' "$src")"
    echo "YQ_VERSION=$(yq -r '.tools.yq' "$src")"
}

_briklab_versions_render_plugins() {
    local src; src="$(_briklab_versions_source)"
    echo "$_BRIKLAB_VERSIONS_HEADER"
    echo "# Source of truth: versions.yml (jenkins_plugins). Consumed by images/jenkins/Dockerfile."
    yq -r '.jenkins_plugins | to_entries | .[] | .key + ":" + .value' "$src"
}

_briklab_versions_render_lock() {
    local src; src="$(_briklab_versions_source)"
    echo "$_BRIKLAB_VERSIONS_HEADER"
    echo "# Source of truth: versions.yml (runner_images). Consumed by scripts/lib/runner-images.sh (briklab.runner_images.pull)."
    echo "# Digest-pinned so a clean rebuild pulls the exact images the E2E suite was validated against."
    echo "# Format: <ref>:<tag>@<digest>. The pull helper fetches the digest and tags it <ref>:<tag> locally."
    echo "images:"
    yq -r '.runner_images[] | "  - " + .ref + ":" + .tag + "@" + .digest' "$src"
}

_briklab_versions_render() {
    case "$1" in
        env)     _briklab_versions_render_env ;;
        plugins) _briklab_versions_render_plugins ;;
        lock)    _briklab_versions_render_lock ;;
    esac
}

_briklab_versions_path() {
    case "$1" in
        env)     _briklab_versions_env_path ;;
        plugins) _briklab_versions_plugins_path ;;
        lock)    _briklab_versions_lock_path ;;
    esac
}

# --- Guards -----------------------------------------------------------------

_briklab_versions_require() {
    command -v yq >/dev/null 2>&1 || { briklab.log.error "yq is required"; return 1; }
    [[ -f "$(_briklab_versions_source)" ]] || {
        briklab.log.error "$(_briklab_versions_source) not found"; return 1; }
}

# --- Public API -------------------------------------------------------------

# Rewrite every derived artifact from versions.yml.
briklab.versions.generate() {
    _briklab_versions_require || return 1
    local key path
    for key in env plugins lock; do
        path="$(_briklab_versions_path "$key")"
        _briklab_versions_render "$key" > "$path"
        briklab.log.ok "wrote ${path#"${_BRIKLAB_VERSIONS_ROOT}"/}"
    done
}

# Return non-zero if any artifact (or runner-image pin set) drifts from versions.yml.
briklab.versions.check() {
    _briklab_versions_require || return 1
    local key path stale=0
    for key in env plugins lock; do
        path="$(_briklab_versions_path "$key")"
        if ! diff -q <(_briklab_versions_render "$key") "$path" >/dev/null 2>&1; then
            briklab.log.error "STALE: ${path#"${_BRIKLAB_VERSIONS_ROOT}"/} differs from versions.yml"
            stale=1
        fi
    done
    # Coverage: the runner-image pins must match exactly the tags brik resolves.
    # Best-effort -- skips when brik's registry checkout is not next to briklab.
    # shellcheck source=runner-images.sh
    if source "${_BRIKLAB_VERSIONS_DIR}/runner-images.sh" 2>/dev/null; then
        briklab.runner_images.verify_pins || stale=1
    fi
    if [[ $stale -eq 0 ]]; then
        briklab.log.ok "All version artifacts are in sync with versions.yml"
        return 0
    fi
    briklab.log.error "Run: make versions"
    return 1
}
