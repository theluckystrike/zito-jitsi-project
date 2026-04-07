#!/usr/bin/env bash
###############################################################################
# 02-guest-domain.sh
#
# Purpose : Configure the guest VirtualHost pattern on jitsi-00.zitovoice.com
#           so that invite links work for unauthenticated participants without
#           JWT tokens. Adds guest.jitsi-00.zitovoice.com as an anonymous
#           domain to Prosody, Jitsi Meet config.js, and Jicofo.
#
# Host    : jitsi-00.zitovoice.com
# Platform: Debian 12 (Incus LXC container)
#
# Usage   : sudo ./02-guest-domain.sh
#           DRY_RUN=1 sudo ./02-guest-domain.sh   # preview changes only
#
# Exit    : 0 = success, 1 = failure, 2 = already applied (idempotent)
#
# Author  : theluckystrike
# Date    : 2026-04-07
# License : Internal -- ZitoVoice Sprint 2
###############################################################################
set -euo pipefail

###############################################################################
# Constants
###############################################################################
readonly SCRIPT_NAME="02-guest-domain"
readonly DOMAIN="jitsi-00.zitovoice.com"
readonly GUEST_DOMAIN="guest.jitsi-00.zitovoice.com"
readonly PROSODY_CFG="/etc/prosody/conf.avail/${DOMAIN}.cfg.lua"
readonly MEET_CFG="/etc/jitsi/meet/${DOMAIN}-config.js"
readonly JICOFO_CFG="/etc/jitsi/jicofo/jicofo.conf"
readonly LOG_BASE="/var/log/zito-sprint2"
readonly DRY_RUN="${DRY_RUN:-0}"
readonly TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
readonly LOG_DIR="${LOG_BASE}/${TIMESTAMP}-guest-domain"

readonly PROSODY_SERVICE="prosody"
readonly JICOFO_SERVICE="jicofo"
readonly JVB_SERVICE="jitsi-videobridge2"

readonly PROSODY_WAIT_SECS=5
readonly JICOFO_WAIT_SECS=5
readonly JVB_WAIT_SECS=3
readonly MAX_SERVICE_CHECK_ATTEMPTS=6

# Counters for summary
CHANGES_MADE=0

###############################################################################
# Utility functions
###############################################################################
log_info() {
    printf "[%s] [INFO]  %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

log_warn() {
    printf "[%s] [WARN]  %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

log_error() {
    printf "[%s] [ERROR] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

log_pass() {
    printf "[%s] [PASS]  %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

log_fail() {
    printf "[%s] [FAIL]  %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

die() {
    log_error "$1"
    exit 1
}

###############################################################################
# Phase 1 -- Pre-flight checks
###############################################################################
preflight_check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This script must be run as root. Use: sudo $0"
    fi
    log_info "Running as root: OK"
}

preflight_check_dry_run() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        log_warn "========================================="
        log_warn "  DRY-RUN MODE -- no changes will be made"
        log_warn "========================================="
    fi
}

preflight_check_files() {
    local all_ok=true
    local f
    for f in "${PROSODY_CFG}" "${MEET_CFG}" "${JICOFO_CFG}"; do
        if [[ ! -f "${f}" ]]; then
            log_error "Required file not found: ${f}"
            all_ok=false
        else
            log_info "Found: ${f}"
        fi
    done
    if [[ "${all_ok}" != "true" ]]; then
        die "One or more required files are missing -- aborting"
    fi
}

preflight_check_already_applied() {
    # Check all three configs for guest domain presence.
    # If all three are already configured, exit 2 (idempotent).
    local prosody_done=false
    local meet_done=false
    local jicofo_done=false

    if grep -q "VirtualHost \"${GUEST_DOMAIN}\"" "${PROSODY_CFG}" 2>/dev/null; then
        prosody_done=true
        log_info "Prosody: guest VirtualHost already present"
    fi

    if grep -q "anonymousdomain" "${MEET_CFG}" 2>/dev/null; then
        meet_done=true
        log_info "Jitsi Meet config.js: anonymousdomain already present"
    fi

    if grep -q "login-url" "${JICOFO_CFG}" 2>/dev/null; then
        jicofo_done=true
        log_info "Jicofo: authentication block already present"
    fi

    if [[ "${prosody_done}" == "true" ]] \
        && [[ "${meet_done}" == "true" ]] \
        && [[ "${jicofo_done}" == "true" ]]; then
        log_info "============================================"
        log_info "  Guest domain is ALREADY fully configured."
        log_info "  Nothing to do -- exiting with code 2."
        log_info "============================================"
        exit 2
    fi

    # Partial application -- warn but continue to fill in the gaps
    if [[ "${prosody_done}" == "true" ]] \
        || [[ "${meet_done}" == "true" ]] \
        || [[ "${jicofo_done}" == "true" ]]; then
        log_warn "Partial guest domain configuration detected -- will apply remaining changes"
    fi
}

preflight_backup_files() {
    mkdir -p "${LOG_DIR}"
    log_info "Backup directory: ${LOG_DIR}"

    local f basename backup
    for f in "${PROSODY_CFG}" "${MEET_CFG}" "${JICOFO_CFG}"; do
        basename="$(basename "${f}")"
        backup="${LOG_DIR}/${basename}.bak.${TIMESTAMP}"
        if [[ "${DRY_RUN}" == "1" ]]; then
            log_info "[DRY-RUN] Would back up ${f} -> ${backup}"
        else
            cp -a "${f}" "${backup}"
            if [[ ! -f "${backup}" ]]; then
                die "Backup failed for ${f} -- aborting"
            fi
            log_info "Backed up: ${f} -> ${backup}"
        fi
    done
}

run_preflight() {
    log_info "============================================"
    log_info "  Phase 1 -- Pre-flight checks"
    log_info "============================================"
    preflight_check_root
    preflight_check_dry_run
    preflight_check_files
    preflight_check_already_applied
    preflight_backup_files
    log_info "Pre-flight checks passed."
}

###############################################################################
# Phase 2 -- Apply guest domain config
###############################################################################
apply_prosody_guest_vhost() {
    log_info "Configuring Prosody guest VirtualHost..."

    if grep -q "VirtualHost \"${GUEST_DOMAIN}\"" "${PROSODY_CFG}" 2>/dev/null; then
        log_info "Prosody: guest VirtualHost already present -- skipping"
        return 0
    fi

    local block
    block="$(cat <<'LUABLOCK'

-- Guest domain for unauthenticated invite link participants
-- Added by Sprint 2 automation (theluckystrike)
VirtualHost "guest.jitsi-00.zitovoice.com"
    authentication = "anonymous"
    c2s_require_encryption = false
    modules_enabled = {
        "bosh";
        "ping";
    }
LUABLOCK
)"

    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Would append guest VirtualHost block to ${PROSODY_CFG}"
        log_info "[DRY-RUN] Block content:"
        printf '%s\n' "${block}" | while IFS= read -r line; do
            log_info "  ${line}"
        done
        return 0
    fi

    printf '%s\n' "${block}" >> "${PROSODY_CFG}"
    CHANGES_MADE=$((CHANGES_MADE + 1))

    # Verify it was written
    if grep -q "VirtualHost \"${GUEST_DOMAIN}\"" "${PROSODY_CFG}" 2>/dev/null; then
        log_pass "Prosody guest VirtualHost block appended successfully"
    else
        die "Failed to append guest VirtualHost block to ${PROSODY_CFG}"
    fi
}

apply_meet_anonymousdomain() {
    log_info "Configuring Jitsi Meet config.js anonymousdomain..."

    if grep -q "anonymousdomain" "${MEET_CFG}" 2>/dev/null; then
        log_info "Jitsi Meet: anonymousdomain already present -- skipping"
        return 0
    fi

    # Verify the domain line exists as our anchor
    if ! grep -q "domain: '${DOMAIN}'" "${MEET_CFG}" 2>/dev/null; then
        die "Cannot find \"domain: '${DOMAIN}'\" in ${MEET_CFG} -- cannot insert anonymousdomain"
    fi

    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Would add anonymousdomain: '${GUEST_DOMAIN}' after domain line in ${MEET_CFG}"
        return 0
    fi

    # Insert anonymousdomain line after the domain line, matching its indentation
    sed -i.sedtmp \
        "/domain: '${DOMAIN}'/a\\
        anonymousdomain: '${GUEST_DOMAIN}'," \
        "${MEET_CFG}"
    rm -f "${MEET_CFG}.sedtmp"
    CHANGES_MADE=$((CHANGES_MADE + 1))

    # Verify it was written
    if grep -q "anonymousdomain" "${MEET_CFG}" 2>/dev/null; then
        log_pass "anonymousdomain added to ${MEET_CFG}"
    else
        die "Failed to add anonymousdomain to ${MEET_CFG}"
    fi
}

apply_jicofo_authentication() {
    log_info "Configuring Jicofo authentication block..."

    if grep -q "login-url" "${JICOFO_CFG}" 2>/dev/null; then
        log_info "Jicofo: authentication block already present -- skipping"
        return 0
    fi

    # Verify the jicofo { block exists as our anchor
    if ! grep -q 'jicofo {' "${JICOFO_CFG}" 2>/dev/null; then
        die "Cannot find 'jicofo {' in ${JICOFO_CFG} -- cannot insert authentication block"
    fi

    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Would add authentication block inside jicofo {} in ${JICOFO_CFG}"
        return 0
    fi

    # Insert the authentication block after the first occurrence of 'jicofo {'
    sed -i.sedtmp \
        '0,/jicofo {/{ /jicofo {/a\
    authentication: {\
        enabled: true\
        type: XMPP\
        login-url: "jitsi-00.zitovoice.com"\
    }
}' \
        "${JICOFO_CFG}"
    rm -f "${JICOFO_CFG}.sedtmp"
    CHANGES_MADE=$((CHANGES_MADE + 1))

    # Verify it was written
    if grep -q "login-url" "${JICOFO_CFG}" 2>/dev/null; then
        log_pass "Authentication block added to ${JICOFO_CFG}"
    else
        die "Failed to add authentication block to ${JICOFO_CFG}"
    fi
}

run_apply() {
    log_info "============================================"
    log_info "  Phase 2 -- Apply guest domain config"
    log_info "============================================"
    apply_prosody_guest_vhost
    apply_meet_anonymousdomain
    apply_jicofo_authentication

    if [[ "${CHANGES_MADE}" -eq 0 ]]; then
        log_info "No changes were needed (all configs already in place)"
    else
        log_info "Applied ${CHANGES_MADE} configuration change(s)"
    fi
}

###############################################################################
# Phase 3 -- Restart and verify
###############################################################################
restart_service() {
    local service="$1"
    local wait_secs="$2"

    log_info "Restarting ${service}..."
    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Would restart ${service} and wait ${wait_secs}s"
        return 0
    fi

    systemctl restart "${service}"
    log_info "Restart issued for ${service}. Waiting ${wait_secs}s..."
    sleep "${wait_secs}"
}

verify_service_active() {
    local service="$1"

    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Would verify ${service} is active"
        return 0
    fi

    local attempt=0
    while [[ ${attempt} -lt ${MAX_SERVICE_CHECK_ATTEMPTS} ]]; do
        if systemctl is-active --quiet "${service}"; then
            log_pass "${service} is active"
            return 0
        fi
        attempt=$((attempt + 1))
        log_info "${service} not yet active, retrying (${attempt}/${MAX_SERVICE_CHECK_ATTEMPTS})..."
        sleep 2
    done

    log_fail "${service} is NOT active after ${MAX_SERVICE_CHECK_ATTEMPTS} attempts"
    systemctl status "${service}" --no-pager 2>&1 || true
    return 1
}

restart_all_services() {
    log_info "Restarting services in order..."

    if [[ "${CHANGES_MADE}" -eq 0 ]] && [[ "${DRY_RUN}" != "1" ]]; then
        log_info "No changes were made -- skipping service restarts"
        return 0
    fi

    restart_service "${PROSODY_SERVICE}" "${PROSODY_WAIT_SECS}"
    restart_service "${JICOFO_SERVICE}" "${JICOFO_WAIT_SECS}"
    restart_service "${JVB_SERVICE}" "${JVB_WAIT_SECS}"
}

verify_all_services() {
    log_info "Verifying all services are active..."
    local all_ok=true

    verify_service_active "${PROSODY_SERVICE}" || all_ok=false
    verify_service_active "${JICOFO_SERVICE}"  || all_ok=false
    verify_service_active "${JVB_SERVICE}"     || all_ok=false

    if [[ "${all_ok}" != "true" ]]; then
        log_fail "One or more services failed to start"
        return 1
    fi
    log_pass "All services are active"
    return 0
}

verify_prosody_guest_vhost() {
    log_info "Verifying Prosody loaded the guest VirtualHost..."
    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Would verify Prosody guest VirtualHost"
        return 0
    fi

    # Check prosodyctl status
    local status_output
    status_output="$(prosodyctl status 2>&1 || true)"
    log_info "prosodyctl status: ${status_output}"

    # Check Prosody log for the guest domain
    local log_file="/var/log/prosody/prosody.log"
    if [[ -f "${log_file}" ]]; then
        local guest_entries
        guest_entries="$(grep -i "${GUEST_DOMAIN}" "${log_file}" 2>/dev/null \
                         | tail -10 || true)"
        if [[ -n "${guest_entries}" ]]; then
            log_pass "Prosody log contains references to ${GUEST_DOMAIN}"
        else
            log_warn "No ${GUEST_DOMAIN} entries found in Prosody log (may appear later)"
        fi
    else
        log_warn "Prosody log not found at ${log_file}"
    fi

    # Verify the config file still has the block
    if grep -q "VirtualHost \"${GUEST_DOMAIN}\"" "${PROSODY_CFG}" 2>/dev/null; then
        log_pass "Prosody config contains guest VirtualHost declaration"
    else
        log_fail "Prosody config is missing guest VirtualHost declaration"
        return 1
    fi
    return 0
}

print_summary() {
    log_info "============================================"
    log_info "  Summary -- Guest Domain Configuration"
    log_info "============================================"

    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "DRY-RUN mode -- no actual changes were made"
        log_info "Review planned actions above, then run without DRY_RUN=1"
        log_info "============================================"
        return 0
    fi

    log_info "  Domain        : ${DOMAIN}"
    log_info "  Guest Domain  : ${GUEST_DOMAIN}"
    log_info "  Changes Made  : ${CHANGES_MADE}"
    log_info ""
    log_info "  Files modified:"

    if grep -q "VirtualHost \"${GUEST_DOMAIN}\"" "${PROSODY_CFG}" 2>/dev/null; then
        log_info "    [OK] ${PROSODY_CFG} -- guest VirtualHost appended"
    fi
    if grep -q "anonymousdomain" "${MEET_CFG}" 2>/dev/null; then
        log_info "    [OK] ${MEET_CFG} -- anonymousdomain added"
    fi
    if grep -q "login-url" "${JICOFO_CFG}" 2>/dev/null; then
        log_info "    [OK] ${JICOFO_CFG} -- authentication block added"
    fi

    log_info ""
    log_info "  Backups saved to: ${LOG_DIR}/"
    log_info ""
    log_info "  Invite links should now work for unauthenticated guests."
    log_info "============================================"
}

run_restart_and_verify() {
    log_info "============================================"
    log_info "  Phase 3 -- Restart and verify"
    log_info "============================================"

    restart_all_services

    local verify_ok=true
    verify_all_services     || verify_ok=false
    verify_prosody_guest_vhost || verify_ok=false

    print_summary

    if [[ "${verify_ok}" != "true" ]]; then
        return 1
    fi
    return 0
}

###############################################################################
# Main
###############################################################################
main() {
    log_info "============================================"
    log_info "  ${SCRIPT_NAME} -- Guest Domain Setup"
    log_info "  Target: ${DOMAIN}"
    log_info "  Guest : ${GUEST_DOMAIN}"
    log_info "  Timestamp: ${TIMESTAMP}"
    log_info "============================================"

    run_preflight
    run_apply

    local exit_code=0
    run_restart_and_verify || exit_code=$?

    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "DRY-RUN complete. Re-run without DRY_RUN=1 to apply changes."
        exit 0
    fi

    exit "${exit_code}"
}

main "$@"
