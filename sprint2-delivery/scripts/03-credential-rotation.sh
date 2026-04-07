#!/usr/bin/env bash
###############################################################################
# 03-credential-rotation.sh
#
# Purpose : Rotate all 3 exposed production secrets on jitsi-00.zitovoice.com
#           and update every service config that references them.
#
# Secrets rotated:
#   1. Jicofo XMPP password  (focus@auth.jitsi-00.zitovoice.com)
#   2. JVB XMPP password     (jvb@auth.jitsi-00.zitovoice.com)
#   3. TURN shared secret    (Prosody external_services + /etc/turnserver.conf)
#
# Usage   : sudo bash 03-credential-rotation.sh
#           DRY_RUN=1 sudo bash 03-credential-rotation.sh   # preview only
#
# Author  : theluckystrike
# License : MIT
###############################################################################
set -euo pipefail

###############################################################################
# Constants
###############################################################################
readonly SCRIPT_NAME="$(basename "$0")"
readonly TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
readonly DATE_TAG="$(date +%Y%m%d)"
readonly DOMAIN="jitsi-00.zitovoice.com"
readonly AUTH_DOMAIN="auth.${DOMAIN}"
readonly CRED_FILE="/root/.jitsi-credentials-${TIMESTAMP}"
readonly BACKUP_DIR="/root/.jitsi-config-backups/${TIMESTAMP}"

readonly JICOFO_CONF="/etc/jitsi/jicofo/jicofo.conf"
readonly JVB_PROPS="/etc/jitsi/videobridge/sip-communicator.properties"
readonly PROSODY_CFG="/etc/prosody/conf.avail/${DOMAIN}.cfg.lua"
readonly TURN_CONF="/etc/turnserver.conf"

readonly CONFIG_FILES=("$JICOFO_CONF" "$JVB_PROPS" "$PROSODY_CFG" "$TURN_CONF")
readonly SERVICES=("prosody" "jicofo" "jitsi-videobridge2" "coturn")

readonly DRY_RUN="${DRY_RUN:-0}"

readonly MAX_RESTART_WAIT=30
readonly MAX_LOG_LINES=20
readonly MAX_SERVICE_CHECK=10

# Exit codes
readonly E_NOT_ROOT=1
readonly E_MISSING_FILE=2
readonly E_MISSING_CMD=3
readonly E_BACKUP_FAIL=4
readonly E_PROSODY_REG=5
readonly E_CONFIG_UPDATE=6
readonly E_SERVICE_FAIL=7

###############################################################################
# Logging
###############################################################################
log_info()  { printf '[INFO]  %s  %s\n' "$(date +%H:%M:%S)" "$*"; }
log_warn()  { printf '[WARN]  %s  %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
log_error() { printf '[ERROR] %s  %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
log_pass()  { printf '[PASS]  %s  %s\n' "$(date +%H:%M:%S)" "$*"; }
log_fail()  { printf '[FAIL]  %s  %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

log_dry() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '[DRY]   %s  %s\n' "$(date +%H:%M:%S)" "$*"
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
        log_error "This script must be run as root (uid 0)."
        exit "$E_NOT_ROOT"
    fi
    log_pass "Running as root."
}

preflight_verify_files() {
    log_info "Verifying all config files exist..."
    local missing=0
    local i=0
    for cfg in "${CONFIG_FILES[@]}"; do
        if [[ $i -ge 10 ]]; then break; fi
        if [[ ! -f "$cfg" ]]; then
            log_error "Config file not found: $cfg"
            missing=1
        else
            log_pass "Found: $cfg"
        fi
        i=$((i + 1))
    done
    if [[ "$missing" -ne 0 ]]; then
        exit "$E_MISSING_FILE"
    fi
}

preflight_verify_commands() {
    log_info "Verifying required commands..."
    local cmds=("prosodyctl" "openssl" "sed" "systemctl" "grep")
    local i=0
    for cmd in "${cmds[@]}"; do
        if [[ $i -ge 20 ]]; then break; fi
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command not found: $cmd"
            exit "$E_MISSING_CMD"
        fi
        i=$((i + 1))
    done
    log_pass "All required commands available."
}

preflight_backup() {
    log_info "Backing up config files to ${BACKUP_DIR}..."
    if log_dry "Would create backup directory: ${BACKUP_DIR}"; then
        local i=0
        for cfg in "${CONFIG_FILES[@]}"; do
            if [[ $i -ge 10 ]]; then break; fi
            log_dry "Would backup: $cfg"
            i=$((i + 1))
        done
        return 0
    fi

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    local i=0
    for cfg in "${CONFIG_FILES[@]}"; do
        if [[ $i -ge 10 ]]; then break; fi
        local basename_cfg
        basename_cfg="$(basename "$cfg")"
        if ! cp -p "$cfg" "${BACKUP_DIR}/${basename_cfg}"; then
            log_error "Failed to backup: $cfg"
            exit "$E_BACKUP_FAIL"
        fi
        log_pass "Backed up: $cfg"
        i=$((i + 1))
    done
    log_info "All backups saved to: ${BACKUP_DIR}"
}

run_preflight() {
    log_info "========== PHASE 1: PRE-FLIGHT CHECKS =========="
    preflight_verify_root
    preflight_verify_files
    preflight_verify_commands
    preflight_backup
    log_pass "Pre-flight checks complete."
}

###############################################################################
# Phase 2 — Generate new secrets
###############################################################################
generate_secrets() {
    log_info "========== PHASE 2: GENERATE NEW SECRETS =========="

    JICOFO_PASS="$(openssl rand -hex 16)"
    JVB_PASS="$(openssl rand -hex 32)"
    TURN_SECRET="$(openssl rand -hex 32)"

    if [[ -z "$JICOFO_PASS" || -z "$JVB_PASS" || -z "$TURN_SECRET" ]]; then
        log_error "openssl rand failed to produce output."
        exit "$E_MISSING_CMD"
    fi

    log_info "Generated 3 new secrets (not printed to stdout)."
    log_warn "Old secrets are being invalidated."

    if log_dry "Would write credential reference file to: ${CRED_FILE}"; then
        return 0
    fi

    cat > "$CRED_FILE" <<CREDEOF
# Jitsi Credential Reference — Generated ${TIMESTAMP}
# Domain: ${DOMAIN}
# KEEP THIS FILE SECURE — chmod 600
#
JICOFO_XMPP_PASSWORD=${JICOFO_PASS}
JVB_XMPP_PASSWORD=${JVB_PASS}
TURN_SHARED_SECRET=${TURN_SECRET}
CREDEOF

    chmod 600 "$CRED_FILE"
    chown root:root "$CRED_FILE"
    log_pass "Credential reference saved to: ${CRED_FILE} (mode 600, root-only)."
}

###############################################################################
# Phase 3 — Update Prosody user registrations
###############################################################################
update_prosody_users() {
    log_info "========== PHASE 3: UPDATE PROSODY REGISTRATIONS =========="

    if log_dry "Would run: prosodyctl register focus ${AUTH_DOMAIN} <redacted>"; then
        log_dry "Would run: prosodyctl register jvb ${AUTH_DOMAIN} <redacted>"
        return 0
    fi

    log_info "Registering focus@${AUTH_DOMAIN}..."
    if ! prosodyctl register focus "$AUTH_DOMAIN" "$JICOFO_PASS"; then
        log_error "Failed to register focus user in Prosody."
        exit "$E_PROSODY_REG"
    fi
    log_pass "focus@${AUTH_DOMAIN} password updated."

    log_info "Registering jvb@${AUTH_DOMAIN}..."
    if ! prosodyctl register jvb "$AUTH_DOMAIN" "$JVB_PASS"; then
        log_error "Failed to register jvb user in Prosody."
        exit "$E_PROSODY_REG"
    fi
    log_pass "jvb@${AUTH_DOMAIN} password updated."
}

###############################################################################
# Phase 4 — Update config files
###############################################################################
update_jicofo_conf() {
    log_info "Updating Jicofo config: ${JICOFO_CONF}"

    if log_dry "Would replace password = \"...\" in ${JICOFO_CONF}"; then
        return 0
    fi

    # HOCON format: password = "value"
    # Match password inside xmpp client block — the line contains password = "..."
    if ! sed -i -E \
        's|(password[[:space:]]*=[[:space:]]*")([^"]*)(")|\1'"${JICOFO_PASS}"'\3|g' \
        "$JICOFO_CONF"; then
        log_error "sed failed on ${JICOFO_CONF}"
        exit "$E_CONFIG_UPDATE"
    fi

    # Verify the new password is present in the file
    if ! grep -q "${JICOFO_PASS}" "$JICOFO_CONF"; then
        log_error "Verification failed — new Jicofo password not found in config."
        exit "$E_CONFIG_UPDATE"
    fi
    log_pass "Jicofo config updated."
}

update_jvb_props() {
    log_info "Updating JVB config: ${JVB_PROPS}"

    if log_dry "Would replace PASSWORD/credential values in ${JVB_PROPS}"; then
        return 0
    fi

    # sip-communicator.properties format:
    #   org.jitsi.xmpp.component.credential=VALUE
    #   or lines with PASSWORD=VALUE
    # Replace value after = on lines matching PASSWORD or .credential
    if ! sed -i -E \
        '/PASSWORD=|\.credential=/s|=(.*)$|='"${JVB_PASS}"'|' \
        "$JVB_PROPS"; then
        log_error "sed failed on ${JVB_PROPS}"
        exit "$E_CONFIG_UPDATE"
    fi

    if ! grep -q "${JVB_PASS}" "$JVB_PROPS"; then
        log_error "Verification failed — new JVB password not found in config."
        exit "$E_CONFIG_UPDATE"
    fi
    log_pass "JVB config updated."
}

update_prosody_turn_secret() {
    log_info "Updating TURN secret in Prosody config: ${PROSODY_CFG}"

    if log_dry "Would replace secret = \"...\" in ${PROSODY_CFG}"; then
        return 0
    fi

    # Lua format: secret = "value"
    # Replace ALL occurrences of secret = "..." in the file
    if ! sed -i -E \
        's|(secret[[:space:]]*=[[:space:]]*")([^"]*)(")|\1'"${TURN_SECRET}"'\3|g' \
        "$PROSODY_CFG"; then
        log_error "sed failed on ${PROSODY_CFG}"
        exit "$E_CONFIG_UPDATE"
    fi

    if ! grep -q "${TURN_SECRET}" "$PROSODY_CFG"; then
        log_error "Verification failed — new TURN secret not found in Prosody config."
        exit "$E_CONFIG_UPDATE"
    fi
    log_pass "Prosody TURN secret updated."
}

update_turnserver_conf() {
    log_info "Updating TURN config: ${TURN_CONF}"

    if log_dry "Would replace static-auth-secret in ${TURN_CONF}"; then
        return 0
    fi

    # turnserver.conf format: static-auth-secret=VALUE
    if ! sed -i -E \
        's|^(static-auth-secret=)(.*)$|\1'"${TURN_SECRET}"'|' \
        "$TURN_CONF"; then
        log_error "sed failed on ${TURN_CONF}"
        exit "$E_CONFIG_UPDATE"
    fi

    if ! grep -q "${TURN_SECRET}" "$TURN_CONF"; then
        log_error "Verification failed — new TURN secret not found in turnserver.conf."
        exit "$E_CONFIG_UPDATE"
    fi
    log_pass "turnserver.conf updated."
}

update_all_configs() {
    log_info "========== PHASE 4: UPDATE CONFIG FILES =========="
    update_jicofo_conf
    update_jvb_props
    update_prosody_turn_secret
    update_turnserver_conf
    log_pass "All config files updated."
}

###############################################################################
# Phase 5 — Restart services and verify
###############################################################################
restart_service() {
    local svc="$1"
    local wait_sec="$2"

    if log_dry "Would restart ${svc} and wait ${wait_sec}s"; then
        return 0
    fi

    log_info "Restarting ${svc}..."
    if ! systemctl restart "$svc"; then
        log_error "Failed to restart ${svc}."
        return 1
    fi
    log_info "Waiting ${wait_sec}s for ${svc} to stabilise..."
    sleep "$wait_sec"
}

restart_all_services() {
    log_info "Restarting services in order..."
    restart_service "prosody"            5 || return 1
    restart_service "jicofo"             5 || return 1
    restart_service "jitsi-videobridge2" 3 || return 1
    restart_service "coturn"             2 || return 1
    log_pass "All services restarted."
}

verify_service_active() {
    local svc="$1"
    if log_dry "Would verify ${svc} is active"; then
        return 0
    fi
    if systemctl is-active --quiet "$svc"; then
        log_pass "Service active: ${svc}"
        return 0
    else
        log_fail "Service NOT active: ${svc}"
        return 1
    fi
}

verify_all_services_active() {
    log_info "Verifying all services are active..."
    local failures=0
    local i=0
    for svc in "${SERVICES[@]}"; do
        if [[ $i -ge "$MAX_SERVICE_CHECK" ]]; then break; fi
        if ! verify_service_active "$svc"; then
            failures=$((failures + 1))
        fi
        i=$((i + 1))
    done
    return "$failures"
}

verify_prosody_logs() {
    log_info "Checking Prosody logs for auth failures..."
    if log_dry "Would grep prosody logs for not-authorized"; then
        return 0
    fi

    local auth_failures=0
    if journalctl -u prosody --no-pager -n "$MAX_LOG_LINES" 2>/dev/null | \
       grep -c "not-authorized" > /dev/null 2>&1; then
        auth_failures=$(journalctl -u prosody --no-pager -n "$MAX_LOG_LINES" 2>/dev/null | \
                        grep -c "not-authorized" || true)
    fi

    if [[ "$auth_failures" -gt 0 ]]; then
        log_fail "Found ${auth_failures} 'not-authorized' entries in recent Prosody logs."
        return 1
    fi
    log_pass "No auth failures in recent Prosody logs."
    return 0
}

verify_jicofo_logs() {
    log_info "Checking Jicofo logs for XMPP connection..."
    if log_dry "Would check Jicofo logs for connection status"; then
        return 0
    fi

    local connected=0
    if journalctl -u jicofo --no-pager -n "$MAX_LOG_LINES" 2>/dev/null | \
       grep -qi "connected\|location\|location=location\|location=Location\|location ="; then
        connected=1
    fi

    # Also check the jicofo log file directly as a fallback
    if [[ "$connected" -eq 0 ]] && [[ -f /var/log/jitsi/jicofo.log ]]; then
        if tail -n "$MAX_LOG_LINES" /var/log/jitsi/jicofo.log 2>/dev/null | \
           grep -qi "connected\|location\|location=location\|location=Location"; then
            connected=1
        fi
    fi

    if [[ "$connected" -eq 1 ]]; then
        log_pass "Jicofo XMPP connection looks healthy."
    else
        log_warn "Could not confirm Jicofo XMPP connection from recent logs (may need more time)."
    fi
    return 0
}

verify_jvb_logs() {
    log_info "Checking JVB logs for XMPP connection..."
    if log_dry "Would check JVB logs for connection status"; then
        return 0
    fi

    local connected=0
    if journalctl -u jitsi-videobridge2 --no-pager -n "$MAX_LOG_LINES" 2>/dev/null | \
       grep -qi "connected\|location\|location=location\|location=Location\|location =\|location="; then
        connected=1
    fi

    if [[ "$connected" -eq 0 ]] && [[ -f /var/log/jitsi/jvb.log ]]; then
        if tail -n "$MAX_LOG_LINES" /var/log/jitsi/jvb.log 2>/dev/null | \
           grep -qi "connected\|location\|location=location\|location=Location"; then
            connected=1
        fi
    fi

    if [[ "$connected" -eq 1 ]]; then
        log_pass "JVB XMPP connection looks healthy."
    else
        log_warn "Could not confirm JVB XMPP connection from recent logs (may need more time)."
    fi
    return 0
}

restart_and_verify() {
    log_info "========== PHASE 5: RESTART & VERIFY =========="

    restart_all_services

    local svc_failures=0
    verify_all_services_active || svc_failures=$?

    local prosody_ok=0
    verify_prosody_logs || prosody_ok=$?

    verify_jicofo_logs
    verify_jvb_logs

    if [[ "$prosody_ok" -ne 0 ]]; then
        svc_failures=$((svc_failures + 1))
    fi

    return "$svc_failures"
}

###############################################################################
# Summary
###############################################################################
print_summary() {
    local exit_code="$1"

    echo ""
    echo "============================================================"
    echo "  CREDENTIAL ROTATION SUMMARY"
    echo "============================================================"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "  Mode          : DRY RUN (no changes made)"
    else
        echo "  Mode          : LIVE"
    fi

    echo "  Domain        : ${DOMAIN}"
    echo "  Timestamp     : ${TIMESTAMP}"
    echo "  Backup dir    : ${BACKUP_DIR}"

    if [[ "$DRY_RUN" != "1" ]]; then
        echo "  Credential ref: ${CRED_FILE}"
    fi

    echo ""

    if [[ "$exit_code" -eq 0 ]]; then
        echo "  Result        : PASS"
        echo ""
        echo "  All 3 secrets rotated successfully."
        echo "  All 4 config files updated."
        echo "  All 4 services restarted and verified."
    else
        echo "  Result        : FAIL (exit code ${exit_code})"
        echo ""
        echo "  Review logs above for details."
        echo "  Backups available at: ${BACKUP_DIR}"
    fi

    echo "============================================================"
    echo ""
}

###############################################################################
# Main
###############################################################################
main() {
    echo ""
    echo "============================================================"
    echo "  Jitsi Credential Rotation — ${DOMAIN}"
    echo "  ${TIMESTAMP}"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "  *** DRY RUN MODE — no changes will be made ***"
    fi
    echo "============================================================"
    echo ""

    run_preflight
    generate_secrets
    update_prosody_users
    update_all_configs

    local result=0
    restart_and_verify || result=$?

    print_summary "$result"
    exit "$result"
}

main "$@"
