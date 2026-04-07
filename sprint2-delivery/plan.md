# Zito Jitsi Platform — Sprint 2 Execution Plan

**Owner:** theluckystrike
**Date:** April 7, 2026
**Client:** Derek Anthony, Zito Media
**Repo:** https://github.com/theluckystrike/zito-jitsi-project
**Server:** jitsi-00.zitovoice.com (67.58.160.118) — Incus LXC on Debian 12

---

## Status: SCRIPTS BUILT — READY FOR DEPLOYMENT

All automation scripts are complete in `sprint2-delivery/`. The following chunks now require SSH access to jitsi-00 to execute.

### Delivery artifacts:
- `sprint2-delivery/scripts/01-fix-udp10000.sh` (586 lines) — READY
- `sprint2-delivery/scripts/02-guest-domain.sh` (505 lines) — READY
- `sprint2-delivery/scripts/03-credential-rotation.sh` (546 lines) — READY
- `sprint2-delivery/scripts/04-systemd-overrides.sh` (402 lines) — READY
- `sprint2-delivery/jigasi/generate-jwt-agi.py` (194 lines) — READY
- `sprint2-delivery/jigasi/asterisk-dialplan-example.conf` (165 lines) — READY
- `sprint2-delivery/jigasi/jwt-config.env.example` (6 lines) — READY
- `sprint2-delivery/Sprint2-Delivery-Report.html` — READY
- `Zito-Sprint2-Analysis-Report.html` — READY

---

## Remaining — Server-Side Execution

### Chunk 1.1+1.2 — UDP 10000 Diagnostics + Fix (AUTOMATED)

**Script:** `01-fix-udp10000.sh`
**Objective:** Confirm the root cause and fix JVB UDP 10000 non-responsiveness.
**Execution:** `DRY_RUN=1 sudo ./01-fix-udp10000.sh` then `sudo ./01-fix-udp10000.sh`

**Steps:**
1. SSH into jitsi-00
2. Run: `ss -ulnp | grep 10000` — identify exactly what process holds the port
3. Run: `cat /proc/sys/net/ipv6/bindv6only` — check if IPv6-only binding
4. Run: `ip addr show` and `ip route show` — document container interfaces
5. Run: `grep -iE "harvester|candidate|mapping|public.address|NAT_HARVESTER" /var/log/jitsi/jvb.log | tail -80` — check what IP JVB discovered
6. Run: `cat /etc/jitsi/videobridge/sip-communicator.properties` — confirm current NAT config
7. On Incus host: `incus config device show jitsi-00` — check proxy device for nat=true
8. Capture all output and compare JVB's discovered IP vs 67.58.160.118

**Acceptance criteria:**
- Root cause identified with log/config evidence
- Fix path documented before any changes are made
- Output captured for audit trail

**Estimated effort:** 15 minutes

---

### Chunk 1.2 — UDP 10000 Fix

**Objective:** JVB responds to UDP 10000 packets. Media flows directly without TURN relay.

**Files to modify:**
- `/etc/jitsi/videobridge/sip-communicator.properties`
- Possibly: Incus proxy device config (on host)

**Steps:**
1. Comment out STUN_MAPPING_HARVESTER_ADDRESSES
2. Add NAT_HARVESTER_LOCAL_ADDRESS=<container-internal-IP from diagnostics>
3. Add NAT_HARVESTER_PUBLIC_ADDRESS=67.58.160.118
4. Add DISABLE_AWS_HARVESTER=true
5. If Incus proxy device lacks nat=true, coordinate with Derek to add it
6. Restart JVB: `systemctl restart jitsi-videobridge2`
7. Verify: `grep -i "harvester" /var/log/jitsi/jvb.log | tail -20` — should show 67.58.160.118
8. Test: Start a call, check chrome://webrtc-internals/ for ICE candidate 67.58.160.118:10000
9. Verify: nftables counter for UDP 10000 shows non-zero inbound AND response packets

**Acceptance criteria:**
- JVB log shows correct public IP 67.58.160.118 in harvester output
- At least one test call completes with direct media (not relayed through TURN)
- ICE candidates in webrtc-internals include 67.58.160.118:10000

**Rollback:** Restore original sip-communicator.properties, restart JVB

**Estimated effort:** 20 minutes

---

### Chunk 1.3 — Guest Domain Implementation

**Objective:** Invite links work without tokens. Guests join existing rooms. Guests cannot create rooms.

**Files to modify:**
- `/etc/prosody/conf.avail/jitsi-00.zitovoice.com.cfg.lua` — add guest VirtualHost
- `/etc/jitsi/meet/jitsi-00.zitovoice.com-config.js` — add anonymousdomain
- `/etc/jitsi/jicofo/jicofo.conf` — enable authentication gating

**Steps:**
1. Back up all 3 files: `cp <file> <file>.bak.$(date +%Y%m%d)`
2. Add to Prosody config (after main VirtualHost block):
   ```lua
   VirtualHost "guest.jitsi-00.zitovoice.com"
       authentication = "anonymous"
       c2s_require_encryption = false
       modules_enabled = {
           "bosh";
           "ping";
       }
   ```
3. Add to Jitsi Meet config.js hosts block:
   ```javascript
   anonymousdomain: 'guest.jitsi-00.zitovoice.com',
   ```
4. Add to jicofo.conf:
   ```hocon
   jicofo {
       authentication: {
           enabled: true
           type: XMPP
           login-url: "jitsi-00.zitovoice.com"
       }
   }
   ```
5. Restart services in order:
   ```bash
   systemctl restart prosody && sleep 5
   systemctl restart jicofo && sleep 5
   systemctl restart jitsi-videobridge2 && sleep 3
   ```
6. Test — moderator flow:
   - Open token-authenticated URL → room should be created
   - Copy invite link from the room
7. Test — guest flow:
   - Open invite link in incognito browser (no token)
   - Guest should join the room without any login prompt
8. Test — security gate:
   - Open invite link when no moderator is present
   - Should NOT be able to create a room or join an empty one

**Acceptance criteria:**
- Moderator creates room with token URL — works as before
- Guest joins via invite link without credentials
- Guest cannot create rooms independently
- Guest cannot join empty rooms (no moderator present)
- No DNS changes required (guest domain is Prosody-internal)

**Rollback:** Restore .bak files, restart services

**Estimated effort:** 30 minutes

---

## Batch 2 — Security Hardening (P0)

Starts after Batch 1 is complete and verified.

### Chunk 2.1 — Credential Rotation

**Objective:** All 3 exposed secrets are invalidated and replaced with new random credentials.

**Files to modify:**
- `/etc/jitsi/jicofo/jicofo.conf` — new focus password
- `/etc/jitsi/videobridge/sip-communicator.properties` — new JVB password
- `/etc/prosody/conf.avail/jitsi-00.zitovoice.com.cfg.lua` — new TURN secret
- `/etc/turnserver.conf` — new TURN secret (must match Prosody)

**Steps:**
1. Generate new secrets:
   ```bash
   JICOFO_PASS=$(openssl rand -hex 16)
   JVB_PASS=$(openssl rand -hex 32)
   TURN_SECRET=$(openssl rand -hex 32)
   ```
2. Update Prosody user registrations:
   ```bash
   prosodyctl register focus auth.jitsi-00.zitovoice.com "$JICOFO_PASS"
   prosodyctl register jvb auth.jitsi-00.zitovoice.com "$JVB_PASS"
   ```
3. Update jicofo.conf with $JICOFO_PASS
4. Update sip-communicator.properties with $JVB_PASS
5. Update Prosody external_services TURN secret with $TURN_SECRET
6. Update /etc/turnserver.conf static-auth-secret with $TURN_SECRET
7. Restart services in order:
   ```bash
   systemctl restart prosody && sleep 5
   systemctl restart jicofo && sleep 5
   systemctl restart jitsi-videobridge2 && sleep 3
   systemctl restart coturn
   ```
8. Verify: Check Prosody logs for successful XMPP auth — no "not-authorized" errors
9. Verify: Test a video call — full functionality confirmed with new credentials
10. Store new secrets securely (NOT in git)

**Acceptance criteria:**
- All 3 old secrets are invalidated
- Services running with new credentials
- No auth failures in any service log
- Video calls work end-to-end
- New secrets are NOT committed to any repo

**Rollback:** Re-register old passwords, restore old configs, restart

**Estimated effort:** 25 minutes

---

### Chunk 2.2 — GitHub Repo Cleanup

**Objective:** No production secrets accessible in any commit of the public repo.

**Files:** GitHub repo theluckystrike/zito-jitsi-project

**Steps:**
1. Clone the repo locally
2. Option A (preferred): Make the repo private via GitHub settings
3. Option B (if must stay public):
   - Remove raw-configs/ directory
   - Use BFG Repo Cleaner or git filter-repo to scrub secrets from history
   - Force push cleaned history
   - Update README to reference config file locations without actual secrets
4. Verify: Search all commits for the 3 old secret values — zero matches

**Acceptance criteria:**
- No production secrets in any commit (HEAD or history)
- README updated if raw-configs removed
- Repo state is clean

**Note:** Coordinate with Derek — he may want the repo to stay public for documentation purposes. If so, use Option B.

**Estimated effort:** 15 minutes

---

## Batch 3 — Operational Resilience (P1)

Starts after Batch 2 is complete.

### Chunk 3.1 — systemd Startup Ordering

**Objective:** System recovers cleanly from reboot. No manual restart sequence needed.

**Files to create:**
- `/etc/systemd/system/jicofo.service.d/override.conf`
- `/etc/systemd/system/jitsi-videobridge2.service.d/override.conf`

**Steps:**
1. Create override directories:
   ```bash
   mkdir -p /etc/systemd/system/jicofo.service.d
   mkdir -p /etc/systemd/system/jitsi-videobridge2.service.d
   ```
2. Create Jicofo override:
   ```ini
   [Unit]
   After=prosody.service
   Requires=prosody.service
   ```
3. Create JVB override:
   ```ini
   [Unit]
   After=jicofo.service
   Requires=prosody.service
   ```
4. Reload systemd: `systemctl daemon-reload`
5. Verify ordering: `systemctl show jicofo.service | grep -E "After|Requires"`
6. Test: Coordinate with Derek to reboot jitsi-00
7. After reboot: verify all services started automatically in correct order
8. Verify: Video call works without any manual intervention

**Acceptance criteria:**
- Reboot produces a working system automatically
- Prosody starts first, Jicofo second, JVB third
- No manual restart sequence needed
- Services show "active (running)" after reboot

**Estimated effort:** 15 minutes (excluding reboot coordination)

---

### Chunk 3.2 — Branding Pass

**Objective:** All Zito branding applied. Visual identity matches Logo Policy PDF.

**Files to modify:**
- `/usr/share/jitsi-meet/images/watermark.svg` — replace with Zito logo
- `/usr/share/jitsi-meet/images/favicon.ico` — replace with Zito favicon
- `/etc/jitsi/meet/jitsi-00.zitovoice.com-interface_config.js` — colors and branding
- Possibly: custom CSS override file

**Steps:**
1. Obtain Logo Policy PDF color codes and correct logo variants
2. Convert Zito logo to SVG if not already (the zito-logos package from playbook 21)
3. Replace watermark.svg with correct Zito logo variant
4. Replace favicon.ico with Zito favicon
5. Update interface_config.js:
   - TOOLBAR_BUTTONS colors
   - DEFAULT_BACKGROUND
   - BRAND_WATERMARK settings
6. Apply color palette from Logo Policy PDF:
   - Toolbar backgrounds
   - Button accents
   - Welcome page styling
7. Verify: Load jitsi-00.zitovoice.com in browser — all branding correct
8. Verify: Check mobile viewport — branding scales correctly
9. Flag any ambiguous logo usage decisions for Derek's team

**Acceptance criteria:**
- Zito watermark SVG replaces default Jitsi logo
- Favicon shows Zito brand
- Color palette matches Logo Policy PDF
- No default Jitsi branding visible anywhere

**Estimated effort:** 30 minutes

---

### Chunk 3.3 — Ansible Consolidation

**Objective:** Running the full playbook chain produces a working system identical to the live instance.

**Files:** Ansible role templates on deployment controller

**Steps:**
1. SSH into deployment controller
2. Identify all template files in the systemli.jitsi_meet_dev role
3. Diff each template against the live config on jitsi-00
4. Update templates to match live state, including:
   - Fixed config.js (no syntax error)
   - Correct Prosody auth settings (token, not jitsi-anonymous)
   - Guest VirtualHost
   - JVB NAT harvester settings
   - coturn full configuration
   - NGINX correct routing (127.0.0.1, not FQDN)
   - systemd override files
   - Branding assets
   - New rotated credentials (templated, not hardcoded)
5. Parametrize secrets as Ansible vault variables
6. Test: Build a fresh container from the playbook chain
7. Verify: Fresh container matches live state — all services functional

**Acceptance criteria:**
- Full playbook run on a fresh container produces a working Jitsi instance
- All Sprint 1 fixes and Sprint 2 changes are in templates
- Secrets are Ansible vault variables, not plaintext
- No manual post-playbook steps required

**Estimated effort:** 60-90 minutes (largest chunk — includes testing)

---

### Chunk 3.4 — Jigasi Research Response

**Objective:** Derek has the information needed to make an architectural decision on SIP dial-in auth.

**Deliverable:** Written communication (not implementation)

**Content:**
1. Clear statement: Jigasi does not natively authenticate SIP callers
2. Present 4 options ranked by effort:
   - A: Lobby mode (zero code)
   - B: Room password via SIP header (low effort)
   - C: JWT via SIP header with AGI script (medium — recommended)
   - D: Full IVR + Conference Mapper (high — what he wants to avoid)
3. Include Asterisk dialplan example for Option C
4. Note that Option C reuses existing JWT infrastructure
5. Offer to scope implementation if Derek selects an option

**Acceptance criteria:**
- Derek has clear, actionable information
- No false promises about native capabilities
- Recommended path (Option C) is justified
- Derek can make an informed decision without guessing

**Estimated effort:** Already drafted in the Sprint 2 Analysis Report — needs review and personalization

---

## Execution Order Summary

```
Week 1 — Session start:
  [1.1] UDP Diagnostics → [1.2] UDP Fix → [1.3] Guest Domain
  ↓ verify all 3 → proceed

Week 1 — Same session:
  [2.1] Credential Rotation → [2.2] Repo Cleanup
  ↓ verify → proceed

Week 1 — Same session (if time permits) or next:
  [3.1] systemd Overrides → reboot test
  [3.4] Jigasi Response (can send immediately)

Week 2 (or continued):
  [3.2] Branding Pass
  [3.3] Ansible Consolidation
```

## Blocked Items (Cannot Execute Without Client Action)

| Item | Blocker | Who |
|------|---------|-----|
| Incus proxy device nat=true | Requires host-level access | Derek's team |
| Reboot test for systemd overrides | Requires coordination | Derek's team |
| Logo Policy PDF color codes | Need the PDF content | Derek to provide |
| Jigasi implementation | Architectural decision needed | Derek to decide |

## Notes

- All changes on the live server should be backed up before modification
- The ordered restart sequence (Prosody → Jicofo → JVB → coturn) must be followed for every change
- Do NOT run Ansible playbooks until Chunk 3.3 is complete
- Commit all Sprint 2 changes to the repo after Chunk 2.2 cleanup
