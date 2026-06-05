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

# Digest pins live in briklab's generated lock (from versions.yml). They overlay
# the brik-resolved tags above: brik decides WHICH image:tag, versions.yml pins
# the exact digest so a clean rebuild pulls the same image the E2E suite validated.
_BRIKLAB_IMAGES_LOCK="${BRIKLAB_ROOT:-${_RUNNER_IMAGES_DIR}/../..}/config/brik-images.lock.yaml"

# Print "ref:tag<TAB>ref@digest" for every pinned image in the lock.
# Registry hosts here have no port, so ${name_tag%:*} safely strips the tag.
_briklab_runner_images.pins() {
    [[ -f "$_BRIKLAB_IMAGES_LOCK" ]] || return 0
    command -v yq >/dev/null 2>&1 || return 0
    local entry name_tag digest ref
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        name_tag="${entry%@*}"      # ref:tag
        digest="${entry##*@}"       # sha256:...
        ref="${name_tag%:*}"        # ref
        printf '%s\t%s@%s\n' "$name_tag" "$ref" "$digest"
    done < <(yq -r '.images[]' "$_BRIKLAB_IMAGES_LOCK" 2>/dev/null)
}

# Verify the digest lock covers exactly the tags brik resolves (no drift).
# Skips (returns 0) when the brik registry is unreachable so the artifact
# staleness check in generate-versions.sh still runs standalone.
briklab.runner_images.verify_pins() {
    local resolved pinned
    resolved="$(briklab.runner_images.list 2>/dev/null)" || {
        log_warn "brik registry not found -- skipping runner-image pin coverage check"
        return 0
    }
    pinned="$(_briklab_runner_images.pins | cut -f1)"
    local missing extra rc=0
    missing="$(comm -23 <(printf '%s\n' "$resolved" | LC_ALL=C sort -u) \
                        <(printf '%s\n' "$pinned"   | LC_ALL=C sort -u))"
    extra="$(comm -13 <(printf '%s\n' "$resolved" | LC_ALL=C sort -u) \
                      <(printf '%s\n' "$pinned"   | LC_ALL=C sort -u))"
    if [[ -n "$missing" ]]; then
        log_error "Runner tags resolved by brik but NOT pinned in versions.yml:"
        printf '%s\n' "$missing" | sed 's/^/  /' >&2
        rc=1
    fi
    if [[ -n "$extra" ]]; then
        log_error "Runner tags pinned in versions.yml but NOT requested by brik:"
        printf '%s\n' "$extra" | sed 's/^/  /' >&2
        rc=1
    fi
    [[ $rc -eq 0 ]] && log_ok "Runner image pins cover exactly brik's resolved tags"
    return $rc
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

# Warm the local Docker cache with every runner image brik may request.
# brik decides the ref:tag (list); versions.yml pins the digest (pins). For a
# pinned tag we pull ref@digest and tag it ref:tag locally, so a job's
# pull_policy=if-not-present resolves the tag to the exact pinned image instead
# of re-pulling the mutable tag from ghcr.io. Unpinned tags fall back to a tag
# pull and are flagged (drift between versions.yml and brik's registry).
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

    # Build the ref:tag -> ref@digest pin map from the lock.
    local nt pd
    declare -A pin=()
    while IFS=$'\t' read -r nt pd; do
        [[ -n "$nt" ]] && pin["$nt"]="$pd"
    done < <(_briklab_runner_images.pins)

    local cached=0 pulled=0 unpinned=0 failed=0 image target
    for image in "${images[@]}"; do
        target="${pin[$image]:-}"

        if [[ -z "$target" ]]; then
            unpinned=$((unpinned + 1))
            log_warn "  no digest pin for ${image} -- add it to versions.yml (pulling mutable tag)"
            if docker image inspect "$image" >/dev/null 2>&1; then
                cached=$((cached + 1))
            elif docker pull "$image" >/dev/null 2>&1; then
                pulled=$((pulled + 1))
            else
                failed=$((failed + 1))
                log_warn "  failed to pull ${image} (runner will retry on first use)"
            fi
            continue
        fi

        # Pinned: already present at the pinned digest? just (re)assert the tag.
        if docker image inspect "$target" >/dev/null 2>&1; then
            docker tag "$target" "$image" 2>/dev/null || true
            cached=$((cached + 1))
            continue
        fi

        if docker pull "$target" >/dev/null 2>&1 && docker tag "$target" "$image"; then
            log_ok "  pulled ${image} (${target##*@})"
            pulled=$((pulled + 1))
        else
            failed=$((failed + 1))
            log_warn "  failed to pull ${target} (runner will retry on first use)"
        fi
    done

    log_info "Brik runner images: ${cached} cached, ${pulled} pulled, ${unpinned} unpinned, ${failed} failed"
    # Non-fatal by design (preserves the original contract): a failed warm-pull
    # is only a warning -- the runner retries the image on first use. Reproducibility
    # is enforced by the digest pins + generate-versions.sh --check, not here.
    return 0
}
