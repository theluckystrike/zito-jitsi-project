#!/usr/bin/env bash
###############################################################################
# 04-systemd-overrides.sh
#
# Purpose : Create systemd startup ordering overrides so that
#           jitsi-00.zitovoice.com survives reboots without manual
#           intervention.
#
# Problem : Jicofo must start AFTER Prosody is fully ready. JVB must
#           start AFTER Jicofo. Without explicit ordering overrides a
#           reboot causes a startup race condition where Jicofo tries to
#           configure the JvbBrewery MUC before Prosody has initialised
#           the internal MUC component — and fails permanently.
#
# Creates :
#   /etc/systemd/system/jicofo.service.d/override.conf
#   /etc/systemd/system/jitsi-videobridge2.service.d/override.conf
#
# Usage   : sudo bash 04-systemd-overrides.sh
#           DRY_RUN=1 sudo bash 04-systemd-overrides.sh   # preview only
#
# Exit codes:
#   0  — overrides applied (or DRY_RUN preview completed)
#   1  — fatal error
#   2  — overrides already exist (idempotent, nothing to do)
#
# Author  : theluckystrike
# License : Internal — ZitoVoice Sprint 2
###############################################################################
set -euo pipefail

###############################################################################
# Constants
###############################################################################
readonly SCRIPT_NAME="04-systemd-overrides"
readonly TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
readonly DRY_RUN="${DRY_RUN:-0}"

readonly SVC_PROSODY="prosody.service"
readonly SVC_JICOFO="jicofo.service"
readonly SVC_JVB="jitsi-videobridge2.service"

readonly JICOFO_OVERRIDE_DIR="/etc/systemd/system/jicofo.service.d"
readonly JVB_OVERRIDE_DIR="/etc/systemd/system/jitsi-videobridge2.service.d"
readonly JICOFO_OVERRIDE="${JICOFO_OVERRIDE_DIR}/override.conf"
readonly JVB_OVERRIDE="${JVB_OVERRIDE_DIR}/override.conf"

readonly SERVICES=("$SVC_PROSODY" "$SVC_JICOFO" "$SVC_JVB")

# Exit codes
readonly E_OK=0
readonly E_FATAL=1
readonly E_ALREADY_APPLIED=2

###############################################################################
# Logging
###############################################################################
log_info()  { printf '[%s] [INFO]  %s\n' "$(date '+%H:%M:%S')" "$*"; }
log_warn()  { printf '[%s] [WARN]  %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
log_error() { printf '[%s] [ERROR] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
log_pass()  { printf '[%s] [PASS]  %s\n' "$(date '+%H:%M:%S')" "$*"; }
log_fail()  { printf '[%s] [FAIL]  %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

die() {
    log_error "$1"
    exit "$E_FATAL"
}

log_dry() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '[%s] [DRY]   %s\n' "$(date '+%H:%M:%S')" "$*"
        return 0
    fi
    return 1
}

###############################################################################
# Phase 1 — Pre-flight checks
###############################################################################
preflight_verify_root() {
    log_info "Verifying root privileges..."
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This script must be run as root. Use: sudo $0"
    fi
    log_pass "Running as root."
}

preflight_verify_systemd() {
    log_info "Verifying systemd is the init system..."
    if ! command -v systemctl &>/dev/null; then
        die "systemctl not found — systemd does not appear to be the init system."
    fi
    # PID 1 should be systemd (or at least systemctl should work)
    if ! systemctl --version &>/dev/null; then
        die "systemctl --version failed — systemd may not be running."
    fi
    log_pass "systemd detected."
}

preflight_verify_services() {
    log_info "Verifying required service units exist..."
    local missing=0
    local i=0
    for svc in "${SERVICES[@]}"; do
        if [[ $i -ge 10 ]]; then break; fi
        if systemctl list-unit-files "$svc" &>/dev/null \
           && systemctl list-unit-files "$svc" 2>/dev/null | grep -q "$svc"; then
            log_pass "Found unit: $svc"
        else
            log_fail "Unit not found: $svc"
            missing=1
        fi
        i=$((i + 1))
    done
    if [[ "$missing" -ne 0 ]]; then
        die "One or more required service units are missing. Cannot continue."
    fi
}

preflight_check_existing() {
    log_info "Checking for existing overrides (idempotency check)..."
    local jicofo_exists=0
    local jvb_exists=0

    if [[ -f "$JICOFO_OVERRIDE" ]]; then
        log_info "Jicofo override already exists: $JICOFO_OVERRIDE"
        jicofo_exists=1
    fi
    if [[ -f "$JVB_OVERRIDE" ]]; then
        log_info "JVB override already exists: $JVB_OVERRIDE"
        jvb_exists=1
    fi

    if [[ "$jicofo_exists" -eq 1 && "$jvb_exists" -eq 1 ]]; then
        log_warn "Both overrides already exist. Nothing to do."
        print_summary "$E_ALREADY_APPLIED"
        exit "$E_ALREADY_APPLIED"
    fi

    if [[ "$jicofo_exists" -eq 1 || "$jvb_exists" -eq 1 ]]; then
        log_warn "Partial overrides detected — will create missing ones."
    else
        log_info "No existing overrides found. Proceeding with creation."
    fi
}

run_preflight() {
    log_info "========== PHASE 1: PRE-FLIGHT CHECKS =========="
    preflight_verify_root
    preflight_verify_systemd
    preflight_verify_services
    preflight_check_existing
    log_pass "Pre-flight checks passed."
}

###############################################################################
# Phase 2 — Create overrides
###############################################################################
create_jicofo_override() {
    if [[ -f "$JICOFO_OVERRIDE" ]]; then
        log_info "Jicofo override already exists — skipping."
        return 0
    fi

    log_info "Creating Jicofo override: $JICOFO_OVERRIDE"

    if log_dry "Would create directory: $JICOFO_OVERRIDE_DIR"; then
        log_dry "Would write: $JICOFO_OVERRIDE"
        return 0
    fi

    mkdir -p "$JICOFO_OVERRIDE_DIR"

    cat > "$JICOFO_OVERRIDE" <<'OVERRIDE_EOF'
# Startup ordering override — Sprint 2 (theluckystrike)
# Ensures Jicofo starts after Prosody to prevent race condition
# where Jicofo tries to configure JvbBrewery MUC before Prosody
# has initialized the internal MUC component.
[Unit]
After=prosody.service
Requires=prosody.service

[Service]
# Brief startup delay to ensure Prosody XMPP listeners are ready
ExecStartPre=/bin/sleep 3
OVERRIDE_EOF

    chmod 644 "$JICOFO_OVERRIDE"
    log_pass "Created: $JICOFO_OVERRIDE"
}

create_jvb_override() {
    if [[ -f "$JVB_OVERRIDE" ]]; then
        log_info "JVB override already exists — skipping."
        return 0
    fi

    log_info "Creating JVB override: $JVB_OVERRIDE"

    if log_dry "Would create directory: $JVB_OVERRIDE_DIR"; then
        log_dry "Would write: $JVB_OVERRIDE"
        return 0
    fi

    mkdir -p "$JVB_OVERRIDE_DIR"

    cat > "$JVB_OVERRIDE" <<'OVERRIDE_EOF'
# Startup ordering override — Sprint 2 (theluckystrike)
# Ensures JVB starts after Jicofo and Prosody.
[Unit]
After=jicofo.service prosody.service
Requires=prosody.service

[Service]
ExecStartPre=/bin/sleep 3
OVERRIDE_EOF

    chmod 644 "$JVB_OVERRIDE"
    log_pass "Created: $JVB_OVERRIDE"
}

run_create_overrides() {
    log_info "========== PHASE 2: CREATE OVERRIDES =========="
    create_jicofo_override
    create_jvb_override
    log_pass "Override creation complete."
}

###############################################################################
# Phase 3 — Apply and verify
###############################################################################
apply_daemon_reload() {
    log_info "Running systemctl daemon-reload..."
    if log_dry "Would run: systemctl daemon-reload"; then
        return 0
    fi
    if ! systemctl daemon-reload; then
        die "systemctl daemon-reload failed."
    fi
    log_pass "systemctl daemon-reload succeeded."
}

verify_jicofo_override_loaded() {
    log_info "Verifying Jicofo override is loaded..."
    if log_dry "Would verify: systemctl show jicofo.service -p After | grep prosody"; then
        return 0
    fi

    local after_value
    after_value="$(systemctl show jicofo.service -p After 2>/dev/null || true)"

    if echo "$after_value" | grep -q "prosody"; then
        log_pass "Jicofo After= includes prosody.service"
    else
        log_fail "Jicofo After= does NOT include prosody.service"
        log_error "  Got: $after_value"
        return 1
    fi
    return 0
}

verify_jvb_override_loaded() {
    log_info "Verifying JVB override is loaded..."
    if log_dry "Would verify: systemctl show jitsi-videobridge2.service -p After | grep jicofo"; then
        return 0
    fi

    local after_value
    after_value="$(systemctl show jitsi-videobridge2.service -p After 2>/dev/null || true)"

    if echo "$after_value" | grep -q "jicofo"; then
        log_pass "JVB After= includes jicofo.service"
    else
        log_fail "JVB After= does NOT include jicofo.service"
        log_error "  Got: $after_value"
        return 1
    fi

    if echo "$after_value" | grep -q "prosody"; then
        log_pass "JVB After= includes prosody.service"
    else
        log_fail "JVB After= does NOT include prosody.service"
        return 1
    fi
    return 0
}

print_dependency_chain() {
    log_info "Effective startup dependency chain:"
    if log_dry "Would display dependency chain"; then
        log_dry "  prosody.service"
        log_dry "    -> jicofo.service  (After + Requires prosody, ExecStartPre sleep 3)"
        log_dry "      -> jitsi-videobridge2.service  (After jicofo + prosody, ExecStartPre sleep 3)"
        return 0
    fi

    echo ""
    echo "  Boot sequence:"
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │  1. prosody.service          (starts normally)             │"
    echo "  │       ↓ (After + Requires)                                 │"
    echo "  │  2. jicofo.service           (waits 3s, then starts)       │"
    echo "  │       ↓ (After)                                            │"
    echo "  │  3. jitsi-videobridge2.service (waits 3s, then starts)     │"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""
}

run_apply_and_verify() {
    log_info "========== PHASE 3: APPLY & VERIFY =========="
    local failures=0

    apply_daemon_reload
    verify_jicofo_override_loaded  || failures=$((failures + 1))
    verify_jvb_override_loaded     || failures=$((failures + 1))
    print_dependency_chain

    if [[ "$failures" -gt 0 ]]; then
        log_fail "Verification found $failures problem(s)."
        return 1
    fi

    log_pass "All overrides applied and verified."
    return 0
}

###############################################################################
# Summary
###############################################################################
print_summary() {
    local exit_code="$1"

    echo ""
    echo "============================================================"
    echo "  SYSTEMD STARTUP ORDERING — SUMMARY"
    echo "============================================================"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "  Mode            : DRY RUN (no changes made)"
    else
        echo "  Mode            : LIVE"
    fi

    echo "  Timestamp       : ${TIMESTAMP}"
    echo "  Jicofo override : ${JICOFO_OVERRIDE}"
    echo "  JVB override    : ${JVB_OVERRIDE}"
    echo ""

    case "$exit_code" in
        "$E_OK")
            echo "  Result          : PASS"
            echo ""
            echo "  Startup ordering overrides installed."
            echo "  Prosody -> Jicofo -> JVB boot sequence enforced."
            echo "  The server will survive reboots without manual intervention."
            ;;
        "$E_ALREADY_APPLIED")
            echo "  Result          : ALREADY APPLIED (exit 2)"
            echo ""
            echo "  Both overrides were already in place."
            echo "  No changes were made. Safe to re-run."
            ;;
        *)
            echo "  Result          : FAIL (exit code ${exit_code})"
            echo ""
            echo "  Review logs above for details."
            ;;
    esac

    echo "============================================================"
    echo ""
}

###############################################################################
# Main
###############################################################################
main() {
    echo ""
    echo "============================================================"
    echo "  ${SCRIPT_NAME} — Systemd Startup Ordering"
    echo "  Target: jitsi-00.zitovoice.com"
    echo "  Timestamp: ${TIMESTAMP}"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "  *** DRY RUN MODE — no changes will be made ***"
    fi
    echo "============================================================"
    echo ""

    run_preflight
    run_create_overrides

    local result=0
    run_apply_and_verify || result=$?

    print_summary "$result"

    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "DRY-RUN complete. Re-run without DRY_RUN=1 to apply changes."
        exit "$E_OK"
    fi

    exit "$result"
}

main "$@"
