#!/usr/bin/env bash
# briklab.log.* - colors + leveled logging (transverse notion).
# Sourced, not executed. Does NOT set shell options - callers control their own.

[[ -n "${_BRIKLAB_LOG_LOADED:-}" ]] && return 0
_BRIKLAB_LOG_LOADED=1

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
# BOLD is consumed by callers (preflight.sh, infra-refresh.sh, ...) via the
# global scope after sourcing, hence flagged unused here.
# shellcheck disable=SC2034
BOLD='\033[1m'
NC='\033[0m'

briklab.log.info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
briklab.log.ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
briklab.log.warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
briklab.log.error() { echo -e "${RED}[ERROR]${NC} $*"; }
