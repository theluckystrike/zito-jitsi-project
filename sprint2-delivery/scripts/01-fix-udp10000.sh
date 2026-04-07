#!/usr/bin/env bash
###############################################################################
# 01-fix-udp10000.sh
#
# Purpose : Fix JVB UDP 10000 binding issue on jitsi-00.zitovoice.com
#           (Incus LXC container, Debian 12, public IP 67.58.160.118).
#           Switches JVB from STUN-based harvesting to explicit NAT harvester
#           configuration so that UDP 10000 binds correctly and media flows.
#
# Host    : jitsi-00.zitovoice.com
# Platform: Debian 12 (Incus LXC container)
# Public  : 67.58.160.118
#
# Usage   : sudo ./01-fix-udp10000.sh
#           DRY_RUN=1 sudo ./01-fix-udp10000.sh   # preview changes only
#
# Author  : theluckystrike
# Date    : 2026-04-07
# License : Internal — ZitoVoice Sprint 2
###############################################################################
set -euo pipefail

###############################################################################
# Constants
###############################################################################
readonly SCRIPT_NAME="01-fix-udp10000"
readonly PUBLIC_IP="67.58.160.118"
readonly SIP_PROPS="/etc/jitsi/videobridge/sip-communicator.properties"
readonly JVB_LOG="/var/log/jitsi/jvb.log"
readonly JVB_SERVICE="jitsi-videobridge2"
readonly LOG_BASE="/var/log/zito-sprint2"
readonly SYSCTL_CONF="/etc/sysctl.conf"
readonly BINDV6ONLY_PROC="/proc/sys/net/ipv6/bindv6only"
readonly DRY_RUN="${DRY_RUN:-0}"
readonly RESTART_WAIT_SECS=5
readonly MAX_LOG_GREP_LINES=80
readonly MAX_VERIFY_ATTEMPTS=6
readonly TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
readonly LOG_DIR="${LOG_BASE}/${TIMESTAMP}"

# Counters for summary
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

###############################################################################
# Utility functions
###############################################################################
log_info() {
    printf "[%s] [INFO]  %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

log_warn() {
    printf "[%s] [WARN]  %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
}

log_error() {
    printf "[%s] [ERROR] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

log_pass() {
    printf "[%s] [PASS]  %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

log_fail() {
    printf "[%s] [FAIL]  %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

die() {
    log_error "$1"
    exit 1
}

run_cmd() {
    # Execute a command, or print it in dry-run mode.
    # Usage: run_cmd "description" command [args...]
    local desc="$1"; shift
    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Would execute: $*  ($desc)"
        return 0
    fi
    log_info "Executing: $desc"
    "$@"
}

save_artifact() {
    # Save diagnostic output to a file in the log directory.
    local filename="$1"
    local content="$2"
    printf '%s\n' "$content" > "${LOG_DIR}/${filename}"
    log_info "Saved artifact: ${LOG_DIR}/${filename}"
}

###############################################################################
# Pre-flight checks
###############################################################################
preflight_checks() {
    log_info "=== Pre-flight checks ==="

    # Must be root
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This script must be run as root. Use: sudo $0"
    fi
    log_info "Running as root: OK"

    # Dry-run banner
    if [[ "${DRY_RUN}" == "1" ]]; then
        log_warn "========================================="
        log_warn "  DRY-RUN MODE — no changes will be made"
        log_warn "========================================="
    fi

    # Verify critical paths exist
    if [[ ! -f "${SIP_PROPS}" ]]; then
        die "sip-communicator.properties not found at ${SIP_PROPS}"
    fi
    log_info "sip-communicator.properties exists: OK"

    # Verify JVB service exists
    if ! systemctl list-unit-files "${JVB_SERVICE}.service" 2>/dev/null \
         | grep -q "${JVB_SERVICE}"; then
        die "Service ${JVB_SERVICE} not found"
    fi
    log_info "Service ${JVB_SERVICE} found: OK"

    log_info "Pre-flight checks passed."
}

###############################################################################
# Phase 1 — Diagnostics
###############################################################################
phase1_create_log_dir() {
    log_info "Creating log directory: ${LOG_DIR}"
    # Created in both normal and dry-run modes so diagnostic artifacts can be saved
    mkdir -p "${LOG_DIR}"
}

phase1_capture_udp_binding() {
    log_info "Capturing UDP 10000 binding status..."
    local output
    output="$(ss -ulnp 2>/dev/null | grep 10000 || true)"
    if [[ -z "${output}" ]]; then
        output="(no UDP listener on port 10000 found)"
        log_warn "No process currently bound to UDP 10000"
    else
        log_info "UDP 10000 binding found"
    fi
    save_artifact "01-ss-udp10000-before.txt" "${output}"
}

phase1_capture_bindv6only() {
    log_info "Capturing bindv6only setting..."
    local val="unknown"
    if [[ -f "${BINDV6ONLY_PROC}" ]]; then
        val="$(cat "${BINDV6ONLY_PROC}")"
    else
        log_warn "${BINDV6ONLY_PROC} not found (may be normal in LXC)"
    fi
    save_artifact "02-bindv6only.txt" "net.ipv6.bindv6only = ${val}"
    log_info "bindv6only = ${val}"
}

phase1_capture_network() {
    log_info "Capturing network configuration..."
    local addr_output route_output
    addr_output="$(ip addr show 2>&1)"
    route_output="$(ip route show 2>&1)"
    save_artifact "03-ip-addr.txt" "${addr_output}"
    save_artifact "04-ip-route.txt" "${route_output}"
}

phase1_capture_sip_props() {
    log_info "Capturing current sip-communicator.properties..."
    local content
    content="$(cat "${SIP_PROPS}" 2>&1)"
    save_artifact "05-sip-communicator-before.txt" "${content}"
}

phase1_capture_jvb_harvester_log() {
    log_info "Capturing JVB harvester log entries..."
    local output="(no JVB log found)"
    if [[ -f "${JVB_LOG}" ]]; then
        output="$(grep -iE 'harvester|candidate|mapping|public.address|NAT_HARVESTER|STUN' \
                  "${JVB_LOG}" 2>/dev/null | tail -"${MAX_LOG_GREP_LINES}" || true)"
        if [[ -z "${output}" ]]; then
            output="(no harvester-related entries found in JVB log)"
        fi
    else
        log_warn "JVB log not found at ${JVB_LOG}"
    fi
    save_artifact "06-jvb-harvester-log.txt" "${output}"
}

phase1_capture_jvb_status() {
    log_info "Capturing JVB service status..."
    local output
    output="$(systemctl status "${JVB_SERVICE}" 2>&1 || true)"
    save_artifact "07-jvb-status-before.txt" "${output}"
}

phase1_print_summary() {
    log_info "=== Phase 1 — Diagnostic Summary ==="

    # UDP 10000 status
    if ss -ulnp 2>/dev/null | grep -q 10000; then
        log_info "  UDP 10000: BOUND"
    else
        log_warn "  UDP 10000: NOT BOUND"
    fi

    # bindv6only
    if [[ -f "${BINDV6ONLY_PROC}" ]]; then
        local bv6
        bv6="$(cat "${BINDV6ONLY_PROC}")"
        if [[ "${bv6}" == "1" ]]; then
            log_warn "  bindv6only: 1 (PROBLEMATIC — will fix)"
        else
            log_info "  bindv6only: 0 (OK)"
        fi
    else
        log_info "  bindv6only: N/A (proc entry not present)"
    fi

    # STUN vs NAT harvester in current config
    if grep -q 'STUN_MAPPING_HARVESTER_ADDRESSES' "${SIP_PROPS}" 2>/dev/null; then
        log_warn "  STUN harvester: CONFIGURED (will be commented out)"
    fi
    if grep -q 'NAT_HARVESTER_LOCAL_ADDRESS' "${SIP_PROPS}" 2>/dev/null; then
        log_info "  NAT harvester local: already present"
    else
        log_info "  NAT harvester local: MISSING (will add)"
    fi
    if grep -q 'NAT_HARVESTER_PUBLIC_ADDRESS' "${SIP_PROPS}" 2>/dev/null; then
        log_info "  NAT harvester public: already present"
    else
        log_info "  NAT harvester public: MISSING (will add)"
    fi

    log_info "  Artifacts saved to: ${LOG_DIR}"
    log_info "=== End Phase 1 ==="
}

run_phase1() {
    log_info "============================================"
    log_info "  Phase 1 — Diagnostics"
    log_info "============================================"
    phase1_create_log_dir
    phase1_capture_udp_binding
    phase1_capture_bindv6only
    phase1_capture_network
    phase1_capture_sip_props
    phase1_capture_jvb_harvester_log
    phase1_capture_jvb_status
    phase1_print_summary
}

###############################################################################
# Phase 2 — Fix
###############################################################################
phase2_backup_sip_props() {
    local backup="${SIP_PROPS}.bak.${TIMESTAMP}"
    log_info "Backing up sip-communicator.properties to ${backup}"
    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Would copy ${SIP_PROPS} -> ${backup}"
    else
        cp -a "${SIP_PROPS}" "${backup}"
        if [[ ! -f "${backup}" ]]; then
            die "Backup failed — aborting"
        fi
        log_info "Backup created: ${backup}"
    fi
}

phase2_detect_internal_ip() {
    # NOTE: All log output in this function goes to stderr (>&2) because
    # stdout is used to return the detected IP via echo.
    log_info "Auto-detecting container internal IP..." >&2
    local iface ip_addr

    # Get the interface for the default route
    iface="$(ip route show default 2>/dev/null \
             | head -1 \
             | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
    if [[ -z "${iface}" ]]; then
        die "Could not determine default route interface"
    fi
    log_info "Default route interface: ${iface}" >&2

    # Extract the first IPv4 address on that interface
    ip_addr="$(ip -4 addr show dev "${iface}" 2>/dev/null \
               | awk '/inet / {print $2}' \
               | head -1 \
               | cut -d/ -f1)"
    if [[ -z "${ip_addr}" ]]; then
        die "Could not determine IPv4 address on interface ${iface}"
    fi

    # Basic IPv4 validation
    if ! [[ "${ip_addr}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Detected IP '${ip_addr}' does not look like a valid IPv4 address"
    fi

    log_info "Detected internal IP: ${ip_addr}" >&2
    echo "${ip_addr}"
}

phase2_patch_sip_props() {
    local internal_ip="$1"
    log_info "Patching sip-communicator.properties..."

    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Would comment out STUN_MAPPING_HARVESTER_ADDRESSES"
        log_info "[DRY-RUN] Would set NAT_HARVESTER_LOCAL_ADDRESS=${internal_ip}"
        log_info "[DRY-RUN] Would set NAT_HARVESTER_PUBLIC_ADDRESS=${PUBLIC_IP}"
        log_info "[DRY-RUN] Would set DISABLE_AWS_HARVESTER=true"
        return 0
    fi

    # 1. Comment out any active STUN_MAPPING_HARVESTER_ADDRESSES lines
    if grep -qE '^[^#]*STUN_MAPPING_HARVESTER_ADDRESSES' "${SIP_PROPS}" 2>/dev/null; then
        sed -i.sedtmp \
            's/^\([^#]*STUN_MAPPING_HARVESTER_ADDRESSES\)/# \1/' \
            "${SIP_PROPS}"
        rm -f "${SIP_PROPS}.sedtmp"
        log_info "Commented out STUN_MAPPING_HARVESTER_ADDRESSES"
    else
        log_info "No active STUN_MAPPING_HARVESTER_ADDRESSES to comment out"
    fi

    # 2. Set NAT_HARVESTER_LOCAL_ADDRESS
    phase2_set_property \
        "org.ice4j.ice.harvest.NAT_HARVESTER_LOCAL_ADDRESS" \
        "${internal_ip}"

    # 3. Set NAT_HARVESTER_PUBLIC_ADDRESS
    phase2_set_property \
        "org.ice4j.ice.harvest.NAT_HARVESTER_PUBLIC_ADDRESS" \
        "${PUBLIC_IP}"

    # 4. Set DISABLE_AWS_HARVESTER
    phase2_set_property \
        "org.ice4j.ice.harvest.DISABLE_AWS_HARVESTER" \
        "true"

    log_info "sip-communicator.properties patched successfully"
}

phase2_set_property() {
    # Set a property in sip-communicator.properties.
    # If the property already exists (commented or not), replace the line.
    # Otherwise append it.
    local key="$1"
    local value="$2"
    local escaped_key
    escaped_key="$(printf '%s' "${key}" | sed 's/[.[\*^$/]/\\&/g')"

    if grep -qE "^#?\\s*${escaped_key}" "${SIP_PROPS}" 2>/dev/null; then
        sed -i.sedtmp \
            "s|^#*\s*${escaped_key}=.*|${key}=${value}|" \
            "${SIP_PROPS}"
        rm -f "${SIP_PROPS}.sedtmp"
        log_info "Updated: ${key}=${value}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${SIP_PROPS}"
        log_info "Appended: ${key}=${value}"
    fi
}

phase2_fix_bindv6only() {
    log_info "Checking bindv6only..."
    if [[ ! -f "${BINDV6ONLY_PROC}" ]]; then
        log_info "bindv6only proc entry not present — skipping"
        return 0
    fi

    local current
    current="$(cat "${BINDV6ONLY_PROC}")"
    if [[ "${current}" == "0" ]]; then
        log_info "bindv6only already 0 — no change needed"
        return 0
    fi

    log_info "bindv6only is ${current} — fixing to 0"
    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Would set bindv6only=0 in proc and sysctl.conf"
        return 0
    fi

    # Set immediately
    echo 0 > "${BINDV6ONLY_PROC}"
    log_info "Set ${BINDV6ONLY_PROC} = 0"

    # Persist in sysctl.conf
    if grep -q 'net.ipv6.bindv6only' "${SYSCTL_CONF}" 2>/dev/null; then
        sed -i.sedtmp \
            's/^.*net\.ipv6\.bindv6only.*/net.ipv6.bindv6only = 0/' \
            "${SYSCTL_CONF}"
        rm -f "${SYSCTL_CONF}.sedtmp"
        log_info "Updated net.ipv6.bindv6only in ${SYSCTL_CONF}"
    else
        printf '\n# Fix bindv6only for JVB dual-stack binding\nnet.ipv6.bindv6only = 0\n' \
            >> "${SYSCTL_CONF}"
        log_info "Appended net.ipv6.bindv6only=0 to ${SYSCTL_CONF}"
    fi
}

phase2_restart_jvb() {
    log_info "Restarting ${JVB_SERVICE}..."
    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Would restart ${JVB_SERVICE} and wait ${RESTART_WAIT_SECS}s"
        return 0
    fi

    systemctl restart "${JVB_SERVICE}"
    log_info "Restart command issued. Waiting ${RESTART_WAIT_SECS} seconds..."
    sleep "${RESTART_WAIT_SECS}"

    if systemctl is-active --quiet "${JVB_SERVICE}"; then
        log_info "${JVB_SERVICE} is active after restart"
    else
        log_error "${JVB_SERVICE} failed to start after restart"
        systemctl status "${JVB_SERVICE}" --no-pager || true
        die "JVB restart failed — check logs at ${JVB_LOG}"
    fi
}

run_phase2() {
    log_info "============================================"
    log_info "  Phase 2 — Fix"
    log_info "============================================"

    phase2_backup_sip_props

    local internal_ip
    internal_ip="$(phase2_detect_internal_ip)"
    if [[ -z "${internal_ip}" ]]; then
        die "Internal IP detection returned empty — aborting"
    fi

    phase2_patch_sip_props "${internal_ip}"
    phase2_fix_bindv6only
    phase2_restart_jvb

    # Save the updated config as artifact
    if [[ -f "${SIP_PROPS}" ]]; then
        save_artifact "08-sip-communicator-after.txt" "$(cat "${SIP_PROPS}")"
    fi
}

###############################################################################
# Phase 3 — Verification
###############################################################################
phase3_verify_udp_binding() {
    log_info "Verifying UDP 10000 binding..."
    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Would verify UDP 10000 binding"
        return 0
    fi

    local attempt=0
    local bound=false
    while [[ ${attempt} -lt ${MAX_VERIFY_ATTEMPTS} ]]; do
        if ss -ulnp 2>/dev/null | grep -q 10000; then
            bound=true
            break
        fi
        attempt=$((attempt + 1))
        log_info "UDP 10000 not yet bound, retrying (${attempt}/${MAX_VERIFY_ATTEMPTS})..."
        sleep 2
    done

    local output
    output="$(ss -ulnp 2>/dev/null | grep 10000 || true)"
    save_artifact "09-ss-udp10000-after.txt" "${output}"

    if [[ "${bound}" == "true" ]]; then
        log_pass "UDP 10000 is bound: ${output}"
    else
        log_fail "UDP 10000 is NOT bound after ${MAX_VERIFY_ATTEMPTS} attempts"
    fi
}

phase3_verify_nat_harvester_log() {
    log_info "Verifying NAT harvester entries in JVB log..."
    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Would verify NAT harvester log entries"
        return 0
    fi

    if [[ ! -f "${JVB_LOG}" ]]; then
        log_fail "JVB log not found at ${JVB_LOG}"
        return 0
    fi

    local output
    output="$(grep -iE 'NAT_HARVESTER|harvester.*public|harvester.*67\.58\.160\.118' \
              "${JVB_LOG}" 2>/dev/null \
              | tail -20 || true)"
    save_artifact "10-jvb-nat-harvester-after.txt" "${output}"

    if echo "${output}" | grep -qF "${PUBLIC_IP}"; then
        log_pass "JVB log shows NAT harvester with public IP ${PUBLIC_IP}"
    else
        # The log entry may take a moment; check for harvester init at minimum
        local harvester_init
        harvester_init="$(grep -i 'location.*location' "${JVB_LOG}" 2>/dev/null \
                          | tail -5 || true)"
        if [[ -n "${harvester_init}" ]]; then
            log_warn "Public IP not yet in log, but harvester initialized"
            save_artifact "10b-jvb-harvester-init.txt" "${harvester_init}"
        else
            log_fail "JVB log does not show NAT harvester with ${PUBLIC_IP}"
        fi
    fi
}

phase3_print_summary() {
    log_info "============================================"
    log_info "  Phase 3 — Verification Summary"
    log_info "============================================"

    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "DRY-RUN mode — no actual changes were made"
        log_info "Review planned actions above, then run without DRY_RUN=1"
        log_info "============================================"
        return 0
    fi

    log_info "  PASS : ${PASS_COUNT}"
    log_info "  FAIL : ${FAIL_COUNT}"
    log_info "  WARN : ${WARN_COUNT}"
    log_info "  Artifacts: ${LOG_DIR}/"
    log_info ""

    if [[ "${FAIL_COUNT}" -gt 0 ]]; then
        log_error "One or more checks FAILED. Review artifacts in ${LOG_DIR}/"
        log_info "============================================"
        return 1
    fi

    log_info "All checks PASSED."
    log_info "============================================"
    return 0
}

run_phase3() {
    log_info "============================================"
    log_info "  Phase 3 — Verification"
    log_info "============================================"
    phase3_verify_udp_binding
    phase3_verify_nat_harvester_log
    phase3_print_summary
}

###############################################################################
# Main
###############################################################################
main() {
    log_info "============================================"
    log_info "  ${SCRIPT_NAME} — JVB UDP 10000 Fix"
    log_info "  Target: jitsi-00.zitovoice.com"
    log_info "  Public IP: ${PUBLIC_IP}"
    log_info "  Timestamp: ${TIMESTAMP}"
    log_info "============================================"

    preflight_checks
    run_phase1
    run_phase2

    local exit_code=0
    run_phase3 || exit_code=$?

    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "DRY-RUN complete. Re-run without DRY_RUN=1 to apply changes."
        exit 0
    fi

    exit "${exit_code}"
}

main "$@"
