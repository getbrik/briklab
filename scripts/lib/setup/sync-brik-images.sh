#!/usr/bin/env bash
# Sync brik-runner images into the local Docker daemon cache.
#
# For each image listed in config/brik-images.lock.yaml:
#   - if already present locally (docker image inspect): skip
#   - else: docker pull
#
# Jenkins and GitLab runners are configured to consume the cache only
# (no re-pull when present), so the pipelines never need network access
# to ghcr.io once this script has run.
#
# Usage:
#   scripts/lib/setup/sync-brik-images.sh           # sync all
#   scripts/lib/setup/sync-brik-images.sh --force   # force pull every image
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIKLAB_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CONFIG_FILE="${BRIKLAB_ROOT}/config/brik-images.lock.yaml"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *) log_error "Unknown argument: $arg"; exit 1 ;;
    esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Config not found: $CONFIG_FILE"
    exit 1
fi
command -v yq >/dev/null 2>&1 || { log_error "yq required"; exit 1; }
command -v docker >/dev/null 2>&1 || { log_error "docker required"; exit 1; }

mapfile -t IMAGES < <(yq -r '.images[]' "$CONFIG_FILE")
if [[ ${#IMAGES[@]} -eq 0 ]]; then
    log_warn "No images listed in $CONFIG_FILE"
    exit 0
fi

log_info "=== Sync brik-runner images (${#IMAGES[@]} entries) ==="

cached=0
pulled=0
failed=0

for image in "${IMAGES[@]}"; do
    if [[ "$FORCE" == "false" ]] && docker image inspect "$image" >/dev/null 2>&1; then
        log_ok "cached  $image"
        cached=$((cached + 1))
        continue
    fi
    log_info "pulling $image"
    if docker pull "$image" >/dev/null 2>&1; then
        log_ok "pulled  $image"
        pulled=$((pulled + 1))
    else
        log_error "failed  $image"
        failed=$((failed + 1))
    fi
done

echo
log_info "Summary: ${cached} cached, ${pulled} pulled, ${failed} failed"
[[ $failed -eq 0 ]]
