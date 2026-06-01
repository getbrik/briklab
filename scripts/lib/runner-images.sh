#!/usr/bin/env bash
# Briklab runner-image resolver - derive the pre-pull set from brik's registry.
#
# The runner uses pull_policy: if-not-present, so briklab warms the local Docker
# cache with every image a pipeline might request before launching E2E. That set
# used to be a hardcoded array in briklab.sh that manually mirrored brik's
# registry -- a guaranteed drift source. This module reads the SAME source of
# truth the orchestrator reads, so the list cannot diverge:
#
#   - static runner classes (base/analysis/scanner/deploy):
#       brik/lib/registry/runner_classes.yml  (.classes[].image + ":" + .tag)
#   - language-stack images (all declared versions):
#       brik/lib/registry/manifests/stacks/*.yml  (spec.runner.image + ":" + versions[])
#
# The dynamic 'stack' class (image_env) is resolved per-pipeline by init and is
# materialised here via the stack manifests, so no image is missing.
#
# Usage:
#   source "path/to/lib/runner-images.sh"
#   briklab.runner_images.list      # print image refs, one per line
#   briklab.runner_images.pull      # pull the ones not already cached
#
# Override brik location with BRIK_SOURCE_DIR (default: <briklab>/../brik).

[[ -n "${_BRIKLAB_RUNNER_IMAGES_LOADED:-}" ]] && return 0
_BRIKLAB_RUNNER_IMAGES_LOADED=1

_RUNNER_IMAGES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_RUNNER_IMAGES_DIR}/common.sh"

# Resolve brik's registry directory from the source checkout.
_briklab_registry_dir() {
    local brik_src="${BRIK_SOURCE_DIR:-${BRIKLAB_ROOT:-${_RUNNER_IMAGES_DIR}/../..}/../brik}"
    ( cd "${brik_src}/lib/registry" 2>/dev/null && pwd )
}

# Print every runner image brik may request, one ref per line (sorted, unique).
# Derived from runner_classes.yml (static classes) + stack manifests (versions).
# Returns 1 if yq is missing or the registry cannot be located.
briklab.runner_images.list() {
    if ! command -v yq >/dev/null 2>&1; then
        log_error "yq is required to resolve runner images (brew install yq)"
        return 1
    fi

    local reg_dir
    reg_dir="$(_briklab_registry_dir)"
    if [[ -z "$reg_dir" || ! -f "${reg_dir}/runner_classes.yml" ]]; then
        log_error "brik registry not found (set BRIK_SOURCE_DIR; looked near ${BRIKLAB_ROOT:-.}/../brik)"
        return 1
    fi

    {
        # Static runner classes: those with an explicit image + tag.
        yq -r '.classes | to_entries[] | select(.value.image) | .value.image + ":" + .value.tag' \
            "${reg_dir}/runner_classes.yml"

        # Language-stack images: image x every declared version.
        local f
        for f in "${reg_dir}"/manifests/stacks/*.yml; do
            [[ -f "$f" ]] || continue
            # $i is a yq binding, not a shell var -- single quotes are required.
            # shellcheck disable=SC2016
            yq -r '.spec.runner.image as $i | .spec.runner.versions[] | $i + ":" + .' "$f"
        done
    } | LC_ALL=C sort -u
}

# The stub image is built locally (brik-images/images/stub/Dockerfile), not
# pulled from the registry. runner_classes.stub.yml pins every class to it.
BRIKLAB_STUB_IMAGE="brik-runner-stub:spike"

# Verify the stub image is present locally; warn with the build command if not.
# Used by `test --stub`. Returns 1 if absent (caller decides whether to abort).
briklab.runner_images.ensure_stub() {
    if docker image inspect "$BRIKLAB_STUB_IMAGE" >/dev/null 2>&1; then
        log_info "Stub image ${BRIKLAB_STUB_IMAGE} present"
        return 0
    fi
    log_warn "Stub image ${BRIKLAB_STUB_IMAGE} not found locally"
    log_info "Build it: docker build -t ${BRIKLAB_STUB_IMAGE} \\"
    log_info "          \"\${BRIK_SOURCE_DIR:-../brik}/../brik-images/images/stub\""
    return 1
}

# Pull any runner images not already present in the local Docker daemon.
briklab.runner_images.pull() {
    local images=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && images+=("$line")
    done < <(briklab.runner_images.list) || return 1

    if [[ ${#images[@]} -eq 0 ]]; then
        log_warn "No runner images resolved from registry"
        return 1
    fi

    local missing=() image
    for image in "${images[@]}"; do
        docker image inspect "$image" >/dev/null 2>&1 || missing+=("$image")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "Brik runner images: ${#images[@]} cached, none to pull"
        return 0
    fi

    log_info "Pulling ${#missing[@]} of ${#images[@]} brik runner image(s)..."
    for image in "${missing[@]}"; do
        if docker pull "$image" >/dev/null 2>&1; then
            log_ok "  pulled ${image}"
        else
            log_warn "  failed to pull ${image} (runner will retry on first use)"
        fi
    done
}
