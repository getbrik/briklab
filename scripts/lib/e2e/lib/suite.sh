#!/usr/bin/env bash
# E2E suite orchestration engine.
#
# Provides argument parsing, project deduplication, scenario filtering,
# batched/sequential execution with dependency resolution, and summary reporting.
#
# The calling script must define these callback functions:
#   _suite_get_name    scenario_string  -> echo name
#   _suite_get_project scenario_string  -> echo project_name
#   _suite_get_depends_on scenario_string -> echo dependency_name (or empty)
#   _suite_get_group   scenario_string  -> echo group_letter (optional, default "")
#   _suite_run_scenario scenario_string -> return 0/1
#   _suite_list_scenarios               -> display scenario table
#   _suite_push_projects projects_csv   -> push projects to VCS
#
# Then call:
#   e2e.suite.run "$@"

[[ -n "${_E2E_SUITE_LOADED:-}" ]] && return 0
_E2E_SUITE_LOADED=1

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

# Parse CLI arguments into module-level variables.
# Sets: _SUITE_ONLY, _SUITE_COMPLETE, _SUITE_BATCH_SIZE, _SUITE_GROUPS, _SUITE_PARALLEL_GROUPS
e2e.suite.parse_args() {
    _SUITE_ONLY=""
    _SUITE_COMPLETE=""
    _SUITE_BATCH_SIZE="${E2E_BATCH_SIZE:-0}"
    _SUITE_GROUPS=""
    _SUITE_PARALLEL_GROUPS=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)
                _suite_list_scenarios
                exit 0
                ;;
            --only)
                if [[ -z "${2:-}" ]]; then
                    log_error "--only requires a scenario name"
                    exit 1
                fi
                _SUITE_ONLY="$2"
                shift 2
                ;;
            --complete)
                _SUITE_COMPLETE="true"
                shift
                ;;
            --batch-size)
                if [[ -z "${2:-}" ]]; then
                    log_error "--batch-size requires a number"
                    exit 1
                fi
                _SUITE_BATCH_SIZE="$2"
                shift 2
                ;;
            --groups)
                if [[ -z "${2:-}" ]]; then
                    log_error "--groups requires comma-separated group letters (e.g. A,D,H)"
                    exit 1
                fi
                _SUITE_GROUPS="$2"
                shift 2
                ;;
            --parallel-groups)
                _SUITE_PARALLEL_GROUPS="true"
                if [[ "$_SUITE_BATCH_SIZE" -eq 0 ]]; then
                    _SUITE_BATCH_SIZE=4
                fi
                shift
                ;;
            *)
                log_error "Unknown argument: $1"
                echo "Usage: $0 [--list] [--only NAME] [--complete] [--batch-size N] [--groups A,D,H] [--parallel-groups]"
                exit 1
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Project collection (deduplication)
# ---------------------------------------------------------------------------

# Collect unique projects from the scenario list.
# Args: scenarios array name (passed by reference via nameref)
# Output: comma-separated project list on stdout
e2e.suite.collect_projects() {
    local -n _scenarios_ref=$1

    if [[ -n "$_SUITE_ONLY" ]]; then
        # Find the matching scenario's project
        local found=false
        for scenario in "${_scenarios_ref[@]}"; do
            local name
            name=$(_suite_get_name "$scenario")
            if [[ "$name" == "$_SUITE_ONLY" ]]; then
                found=true
                _suite_get_project "$scenario"
                return 0
            fi
        done
        if [[ "$found" != "true" ]]; then
            log_error "Scenario '${_SUITE_ONLY}' not found"
            _suite_list_scenarios
            exit 1
        fi
    elif [[ "$_SUITE_COMPLETE" == "true" ]]; then
        # Collect only *-complete projects
        local result=""
        declare -A _seen=()
        for scenario in "${_scenarios_ref[@]}"; do
            local name project
            name=$(_suite_get_name "$scenario")
            if [[ "$name" == *-complete ]]; then
                project=$(_suite_get_project "$scenario")
                if [[ -z "${_seen[$project]:-}" ]]; then
                    _seen["$project"]=1
                    result="${result:+${result},}${project}"
                fi
            fi
        done
        echo "$result"
    else
        # Deduplicate all projects
        local result=""
        declare -A _seen=()
        for scenario in "${_scenarios_ref[@]}"; do
            local project
            project=$(_suite_get_project "$scenario")
            if [[ -z "${_seen[$project]:-}" ]]; then
                _seen["$project"]=1
                result="${result:+${result},}${project}"
            fi
        done
        echo "$result"
    fi
}

# ---------------------------------------------------------------------------
# Scenario filtering
# ---------------------------------------------------------------------------

# Filter scenarios based on --only / --complete / --groups flags.
# Args: scenarios array name (nameref), output array name (nameref)
e2e.suite.collect_scenarios() {
    local -n _src_ref=$1
    local -n _dst_ref=$2

    # Parse --groups into an associative array for O(1) lookup
    declare -A _group_filter=()
    if [[ -n "$_SUITE_GROUPS" ]]; then
        IFS=',' read -ra _groups <<< "$_SUITE_GROUPS"
        for g in "${_groups[@]}"; do
            _group_filter["$(echo "$g" | tr -d '[:space:]')"]=1
        done
    fi

    _dst_ref=()
    for scenario in "${_src_ref[@]}"; do
        local name
        name=$(_suite_get_name "$scenario")

        # Skip if --only is set and this isn't the target
        if [[ -n "$_SUITE_ONLY" && "$name" != "$_SUITE_ONLY" ]]; then
            continue
        fi

        # Skip if --complete and this isn't a *-complete scenario
        if [[ "$_SUITE_COMPLETE" == "true" && "$name" != *-complete ]]; then
            continue
        fi

        # Skip if --groups is set and this scenario's group isn't in the filter
        if [[ ${#_group_filter[@]} -gt 0 ]]; then
            local group=""
            if type _suite_get_group &>/dev/null; then
                group=$(_suite_get_group "$scenario")
            fi
            if [[ -z "$group" || -z "${_group_filter[$group]:-}" ]]; then
                continue
            fi
        fi

        _dst_ref+=("$scenario")
    done
}

# ---------------------------------------------------------------------------
# Execution engine
# ---------------------------------------------------------------------------

# Run all collected scenarios with dependency resolution and optional batching.
# Args: scenarios_to_run array name (nameref), suite_title
e2e.suite.run_all() {
    local -n _run_ref=$1
    local suite_title="${2:-E2E Suite}"

    local total=${#_run_ref[@]}
    local passed=0
    local failed=0
    local results=()

    # Separate independent and dependent scenarios
    local independent=()
    local dependent=()
    if [[ -n "$_SUITE_ONLY" ]]; then
        independent=("${_run_ref[@]}")
    else
        for scenario in "${_run_ref[@]}"; do
            local dep
            dep=$(_suite_get_depends_on "$scenario")
            if [[ -n "$dep" ]]; then
                dependent+=("$scenario")
            else
                independent+=("$scenario")
            fi
        done
    fi

    local ind_total=${#independent[@]}
    local dep_total=${#dependent[@]}
    [[ $dep_total -gt 0 ]] && log_info "${dep_total} scenario(s) with dependencies will run after their dependency passes"

    # Track passed scenario names for dependency resolution
    declare -A passed_scenarios=()

    # --- Phase 1: Run independent scenarios (batched or sequential) ---
    if [[ $_SUITE_BATCH_SIZE -gt 1 && $ind_total -gt 1 ]]; then
        log_info "Running ${ind_total} independent scenarios in batches of ${_SUITE_BATCH_SIZE}"
        echo ""

        local result_dir
        result_dir=$(mktemp -d)
        trap 'rm -rf "$result_dir"' EXIT

        local idx=0
        while [[ $idx -lt $ind_total ]]; do
            local batch_end=$((idx + _SUITE_BATCH_SIZE))
            [[ $batch_end -gt $ind_total ]] && batch_end=$ind_total
            local batch_num=$(( (idx / _SUITE_BATCH_SIZE) + 1 ))

            echo ""
            log_info "--- Batch ${batch_num}: scenarios $((idx + 1)) to ${batch_end} ---"

            local pids=()
            local batch_names=()
            for (( i=idx; i<batch_end; i++ )); do
                local scenario="${independent[$i]}"
                local name
                name=$(_suite_get_name "$scenario")
                batch_names+=("$name")

                (
                    if _suite_run_scenario "$scenario" > "${result_dir}/${name}.log" 2>&1; then
                        echo "PASS" > "${result_dir}/${name}.result"
                    else
                        echo "FAIL" > "${result_dir}/${name}.result"
                    fi
                ) &
                pids+=($!)
            done

            # Wait for all processes in this batch
            for pid in "${pids[@]}"; do
                wait "$pid" 2>/dev/null || true
            done

            # Collect results from this batch
            for name in "${batch_names[@]}"; do
                local result_file="${result_dir}/${name}.result"
                if [[ -f "$result_file" && "$(cat "$result_file")" == "PASS" ]]; then
                    passed=$((passed + 1))
                    results+=("PASS: ${name}")
                    passed_scenarios["$name"]=1
                    log_ok "PASS: ${name}"
                else
                    failed=$((failed + 1))
                    results+=("FAIL: ${name}")
                    log_error "FAIL: ${name}"
                    if [[ -f "${result_dir}/${name}.log" ]]; then
                        echo "  --- last 10 lines ---"
                        tail -10 "${result_dir}/${name}.log" | sed 's/^/  /'
                        echo "  ---"
                    fi
                fi
            done

            idx=$batch_end
        done
    else
        # Sequential execution (default)
        for scenario in "${independent[@]}"; do
            local name
            name=$(_suite_get_name "$scenario")

            if _suite_run_scenario "$scenario"; then
                passed=$((passed + 1))
                results+=("PASS: ${name}")
                passed_scenarios["$name"]=1
            else
                failed=$((failed + 1))
                results+=("FAIL: ${name}")
            fi
        done
    fi

    # --- Phase 2: Run dependent scenarios sequentially ---
    if [[ $dep_total -gt 0 ]]; then
        echo ""
        log_info "--- Running ${dep_total} dependent scenario(s) ---"

        for scenario in "${dependent[@]}"; do
            local name dep
            name=$(_suite_get_name "$scenario")
            dep=$(_suite_get_depends_on "$scenario")

            # Check that the dependency passed
            if [[ -z "${passed_scenarios[$dep]:-}" ]]; then
                log_warn "SKIP: ${name} (dependency '${dep}' did not pass)"
                failed=$((failed + 1))
                results+=("SKIP: ${name} (dependency '${dep}' failed)")
                continue
            fi

            log_info "Dependency '${dep}' passed - running ${name}"
            if _suite_run_scenario "$scenario"; then
                passed=$((passed + 1))
                results+=("PASS: ${name}")
                passed_scenarios["$name"]=1
            else
                failed=$((failed + 1))
                results+=("FAIL: ${name}")
            fi
        done
    fi

    # --- Summary ---
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  ${suite_title} Summary${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""

    for result in "${results[@]}"; do
        if [[ "$result" == PASS:* ]]; then
            log_ok "$result"
        elif [[ "$result" == SKIP:* ]]; then
            log_warn "$result"
        else
            log_error "$result"
        fi
    done

    echo ""
    echo -e "  Total: ${total} | Passed: ${GREEN}${passed}${NC} | Failed: ${RED}${failed}${NC}"
    echo ""

    if [[ $failed -gt 0 ]]; then
        log_error "=== ${suite_title} FAILED ==="
        return 1
    else
        log_ok "=== ${suite_title} PASSED ==="
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

# Full suite orchestration. Called from platform-specific suite scripts.
# Args: scenarios array name (nameref), suite_title, then "$@" (CLI args)
e2e.suite.run() {
    local -n _all_scenarios=$1
    local suite_title="$2"
    shift 2

    e2e.suite.parse_args "$@"

    echo ""
    log_info "=== ${suite_title} ==="
    echo ""

    # Collect and push projects
    local projects_to_push
    projects_to_push=$(e2e.suite.collect_projects _all_scenarios)

    log_info "Pushing test projects: ${projects_to_push}"
    echo ""

    _suite_push_projects "$projects_to_push"

    # Collect scenarios to run (used via nameref in collect_scenarios/run_all)
    # shellcheck disable=SC2034
    local scenarios_to_run=()
    e2e.suite.collect_scenarios _all_scenarios scenarios_to_run

    # Run
    e2e.suite.run_all scenarios_to_run "$suite_title"
}
