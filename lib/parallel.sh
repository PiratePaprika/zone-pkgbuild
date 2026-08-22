#!/bin/bash
# Parallel build runner: FIFO semaphore, dependency ordering, summary table.

: "${ZONE_JOBS:=1}"
declare -gA ZONE_DEPS   # [pkg_basename]="dep1 dep2 ..."

_fmt_ms() {
    local ms="$1"
    if (( ms < 1000 )); then
        printf '%dms' "$ms"
    else
        printf '%d.%ds' "$(( ms / 1000 ))" "$(( (ms % 1000) / 100 ))"
    fi
}

# run_builds <state_dir> <pkg_dir>...
# Launches build_pkg in parallel (up to ZONE_JOBS slots) for each pkg_dir.
# Packages blocked by a failed dep are marked blocked instead of built.
# Results: state_dir/ok/<pkg>  contains elapsed ms
#          state_dir/fail/<pkg> empty on failure
#          state_dir/blocked/<pkg> contains the blocking dep name
run_builds() {
    local state_dir="$1"; shift
    [[ $# -eq 0 ]] && return 0

    mkdir -p "$state_dir/ok" "$state_dir/fail" "$state_dir/blocked"

    local FIFO
    FIFO="$(mktemp -u)"
    mkfifo "$FIFO"
    local SEMFD
    exec {SEMFD}<>"$FIFO"
    rm -f "$FIFO"

    local i
    for (( i=0; i<ZONE_JOBS; i++ )); do printf '%s' x >&"$SEMFD"; done

    local pids=()

    for pkg_dir; do
        local pkg
        pkg="$(basename "$pkg_dir")"

        # Wait for each declared dep to settle (ok, fail, or blocked).
        local dep_ok=1 blocking=""
        for dep in ${ZONE_DEPS[$pkg]:-}; do
            while [[ ! -f "$state_dir/ok/$dep"      && \
                     ! -f "$state_dir/fail/$dep"     && \
                     ! -f "$state_dir/blocked/$dep" ]]; do
                sleep 0.05
            done
            if [[ -f "$state_dir/fail/$dep" || -f "$state_dir/blocked/$dep" ]]; then
                dep_ok=0; blocking="$dep"; break
            fi
        done

        if [[ $dep_ok -eq 0 ]]; then
            echo "$blocking" > "$state_dir/blocked/$pkg"
            log_warn "Blocked: $pkg (dep '$blocking' failed)"
            continue
        fi

        # Acquire a job slot (blocks when all slots are in use).
        read -r -n1 -u"$SEMFD"
        local t0
        t0="$(date +%s%N)"

        (
            if build_pkg "$pkg_dir"; then
                local t1
                t1="$(date +%s%N)"
                echo $(( (t1 - t0) / 1000000 )) > "$state_dir/ok/$pkg"
            else
                touch "$state_dir/fail/$pkg"
            fi
            printf '%s' x >&"$SEMFD"
        ) &
        pids+=($!)
    done

    wait "${pids[@]}" 2>/dev/null || true
    exec {SEMFD}>&-
}

# print_summary <state_dir> <pkg_dir>...
# Prints a status table for each package; returns 1 if any failed or blocked.
print_summary() {
    local state_dir="$1"; shift
    local failed=0

    printf '\n%s%-10s  %-34s  %s%s\n' "$_YEL" "STATUS" "PACKAGE" "TIME" "$_RST"
    printf '%s' "$_YEL"; printf '%.0s─' {1..58}; printf '%s\n' "$_RST"

    for pkg_dir; do
        local pkg
        pkg="$(basename "$pkg_dir")"
        if [[ -f "$state_dir/ok/$pkg" ]]; then
            local ms
            ms="$(cat "$state_dir/ok/$pkg")"
            printf '%s%-10s%s  %-34s  %s\n' \
                "$_GRN" "[DONE]" "$_RST" "$pkg" "$(_fmt_ms "$ms")"
        elif [[ -f "$state_dir/fail/$pkg" ]]; then
            printf '%s%-10s%s  %-34s  %s\n' \
                "$_RED" "[FAILED]" "$_RST" "$pkg" "— see log above"
            failed=1
        elif [[ -f "$state_dir/blocked/$pkg" ]]; then
            local dep
            dep="$(cat "$state_dir/blocked/$pkg")"
            printf '%s%-10s%s  %-34s  %s\n' \
                "$_YEL" "[BLOCKED]" "$_RST" "$pkg" "— dep '$dep' failed"
            failed=1
        else
            printf '%-10s  %-34s  %s\n' "[SKIPPED]" "$pkg" "—"
        fi
    done
    printf '\n'
    return $failed
}
