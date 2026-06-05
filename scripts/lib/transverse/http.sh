#!/usr/bin/env bash
# briklab.http.* - the single HTTP transport (transverse notion).
# Sourced, not executed.
#
# Auth is passed BY THE CALLER as extra curl args, keeping the transport generic:
#   briklab.http.get "$url" -H "PRIVATE-TOKEN: $pat"
#   briklab.http.get "$url" -H "Authorization: token $pat"        # Gitea
#   briklab.http.code "$url" -k -H "Authorization: Bearer $tok"   # ArgoCD (self-signed TLS)
#   briklab.http.get "$url" -u "user:pass"                        # HTTP basic
#
# Convention: <url> first, extra curl args after. Override the timeout via
# BRIKLAB_HTTP_MAX_TIME (default 30s). Does NOT set shell options.

[[ -n "${_BRIKLAB_HTTP_LOADED:-}" ]] && return 0
_BRIKLAB_HTTP_LOADED=1

# GET: response body on stdout, nonzero exit on transport error or HTTP >= 400.
briklab.http.get() {
    local url="$1"; shift
    curl -sf --max-time "${BRIKLAB_HTTP_MAX_TIME:-30}" "$@" "$url"
}

# POST JSON: response body on stdout, nonzero exit on HTTP >= 400.
briklab.http.post_json() {
    local url="$1" data="$2"; shift 2
    curl -sf --max-time "${BRIKLAB_HTTP_MAX_TIME:-30}" \
        -X POST -H "Content-Type: application/json" --data "$data" "$@" "$url"
}

# DELETE: nonzero exit on HTTP >= 400.
briklab.http.delete() {
    local url="$1"; shift
    curl -sf --max-time "${BRIKLAB_HTTP_MAX_TIME:-30}" -X DELETE "$@" "$url"
}

# CODE: HTTP status code on stdout, "000" on any failure. Never returns nonzero.
briklab.http.code() {
    local url="$1"; shift
    curl -s -o /dev/null -w '%{http_code}' \
        --max-time "${BRIKLAB_HTTP_MAX_TIME:-30}" "$@" "$url" 2>/dev/null || echo "000"
}

# REQUEST: response body followed by a final line carrying the HTTP status code
# (always 3 digits, "000" on transport failure). Never returns nonzero -- the
# status is conveyed in the output, for create-or-update flows that branch on it.
# Split with:  code="${out##*$'\n'}"   body="${out%$'\n'*}"
# (or the classic  tail -1 / sed '$d').
briklab.http.request() {
    local url="$1"; shift
    curl -s -w '\n%{http_code}' \
        --max-time "${BRIKLAB_HTTP_MAX_TIME:-30}" "$@" "$url" 2>/dev/null || printf '\n000'
}
