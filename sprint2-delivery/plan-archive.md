# Zito Jitsi Platform — Plan Archive

**Owner:** theluckystrike
**Repo:** https://github.com/theluckystrike/zito-jitsi-project

---

## Sprint 1 — Completed (March 22 – April 1, 2026)

### Chunk S1.1 — Environment Assessment
**Completed:** March 22-25
**What was done:** Full environment walkthrough of jitsi-00.zitovoice.com. SSH access established, container access verified. Identified Incus LXC on Debian 12 with Prosody 13.0.4, JVB, Jicofo, coturn, NGINX.
**Outcome:** Complete environment map documented. 6 independent root-cause issues identified.

### Chunk S1.2 — Fix config.js Syntax Error
**Completed:** March 27
**What was done:** Removed invalid `var config.jwt = {...}` declaration above main config block. Moved enableUserRolesBasedOnToken into main config object.
**Decision:** Inline fix rather than restructuring — minimal change to production file.
**Outcome:** Browser can parse config.js. BOSH URL, domain, and MUC address now available to Jitsi client.

### Chunk S1.3 — Fix JVB Authentication
**Completed:** March 27
**What was done:** Re-registered JVB user in Prosody with correct password matching sip-communicator.properties.
**Evidence:** 9 consecutive SASL "not-authorized" failures eliminated in jvb.log.
**Outcome:** JVB connects to Prosody XMPP successfully.

### Chunk S1.4 — Fix Jicofo Startup Race Condition
**Completed:** March 27
**What was done:** Implemented ordered restart sequence with sleep delays (prosody 5s → jicofo 5s → jvb 3s). Jicofo was trying to configure JvbBrewery MUC before Prosody MUC component initialized.
**Decision:** Manual restart sequence for now. systemd overrides deferred to Sprint 2.
**Outcome:** Jicofo successfully creates and configures brewery room.

### Chunk S1.5 — Enable Token Authentication in Prosody
**Completed:** March 27
**What was done:** Changed VirtualHost authentication from "jitsi-anonymous" to "token". Enabled app_id, app_secret, and token_verification module. Configured HS256 signing algorithm.
**Decision:** HS256 chosen over RS256 per client preference (confirmed March 30-31).
**Outcome:** JWT tokens are validated by Prosody. Unauthenticated users rejected.

### Chunk S1.6 — Configure coturn from Scratch
**Completed:** March 27
**What was done:** Wrote complete /etc/turnserver.conf from scratch. Configured use-auth-secret, static-auth-secret, realm, TLS certificates, external-ip mapping, listening ports (3478 STUN, 5349 TLS).
**Outcome:** TURN relay operational. NAT traversal works for users behind restrictive firewalls.

### Chunk S1.7 — Fix NGINX Routing and Prosody Module Errors
**Completed:** March 27
**What was done:** Changed turn_backend upstream from jitsi-00.zitovoice.com:5349 to 127.0.0.1:5349 (eliminated DNS routing loop). Removed invalid pubsub module from VirtualHost scope. Removed polls module reference (no file on disk).
**Outcome:** NGINX routes correctly. Prosody starts without module errors.

### Chunk S1.8 — Initial Branding
**Completed:** March 31
**What was done:** Set APP_NAME to "Zito Video Conferencing" and PROVIDER_NAME to "Zito Business" in interface_config.js. Set JITSI_WATERMARK_LINK to https://zitobusiness.com.
**Decision:** Manual install on jitsi-00 rather than playbook run (would overwrite live config changes).
**Outcome:** Basic text branding live. Logo/color branding deferred to Sprint 2.

### Chunk S1.9 — Documentation and Delivery
**Completed:** April 1
**What was done:** Produced comprehensive HTML report (Zito-Jitsi-Platform-Report.html) with: environment table, all 6 issues with root cause analysis and code evidence, cascading failure timeline, live proof screenshots, service health verification, prioritized roadmap. Committed everything to GitHub repo. Raw configs and logs preserved as evidence.
**Outcome:** Full sprint report delivered to client. All documentation committed.

---

## Key Decisions Made (Sprint 1)

| Decision | Rationale | Date |
|----------|-----------|------|
| HS256 over RS256 for JWT signing | Client preference — simpler key management | March 30-31 |
| Manual restart sequence over systemd overrides | Faster to deploy, overrides deferred to Sprint 2 | March 27 |
| Live config changes over Ansible template updates | Template updates would require full rebuild cycle — too risky for initial fix | March 27 |
| Manual branding install over playbook run | Playbook would overwrite live config changes | March 31 |
| Raw configs committed to repo as evidence | Documentation value outweighed security concern at the time — rotation planned for Sprint 2 | March 27 |

---

## Sprint 2 — In Progress (April 7, 2026 →)

See `plan.md` for current execution plan.
