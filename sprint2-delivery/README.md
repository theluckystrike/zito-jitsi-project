# Sprint 2 Delivery — Zito Jitsi Platform

**Author:** theluckystrike
**Date:** April 7, 2026
**Server:** jitsi-00.zitovoice.com (67.58.160.118)

## What's Included

### Deployment Scripts (fully autonomous, zero manual steps)

| Script | Purpose | Lines |
|--------|---------|-------|
| `scripts/01-fix-udp10000.sh` | Fix JVB media port — replace STUN harvester with static NAT config | 586 |
| `scripts/02-guest-domain.sh` | Enable invite links without tokens — 3-file guest VirtualHost | 505 |
| `scripts/03-credential-rotation.sh` | Rotate all 3 exposed secrets, update all service configs | 546 |
| `scripts/04-systemd-overrides.sh` | systemd startup ordering so reboots work cleanly | 402 |

### Jigasi SIP Authentication (JWT via AGI)

| File | Purpose |
|------|---------|
| `jigasi/generate-jwt-agi.py` | Asterisk AGI — generates JWT for SIP dial-in, zero dependencies |
| `jigasi/asterisk-dialplan-example.conf` | 3 dialplan patterns (fixed room, IVR, DID mapping) |
| `jigasi/jwt-config.env.example` | Config template for the AGI script |

### Reports

| File | Purpose |
|------|---------|
| `reports/Sprint2-Delivery-Report.html` | Technical report — what was built, why, how, with code snippets |
| `reports/Zito-Sprint2-Analysis-Report.html` | Analysis — Derek's feedback, UDP diagnosis, Jigasi research |

## Deployment

```bash
# Transfer to server
scp -r sprint2-delivery/ root@jitsi-00.zitovoice.com:/root/

# SSH in
ssh root@jitsi-00.zitovoice.com
cd /root/sprint2-delivery/scripts

# Preview all changes first (dry-run)
DRY_RUN=1 ./01-fix-udp10000.sh
DRY_RUN=1 ./02-guest-domain.sh
DRY_RUN=1 ./03-credential-rotation.sh
DRY_RUN=1 ./04-systemd-overrides.sh

# Execute
sudo ./01-fix-udp10000.sh
sudo ./02-guest-domain.sh
sudo ./03-credential-rotation.sh
sudo ./04-systemd-overrides.sh
```

## Safety

- Every script has `DRY_RUN=1` mode
- Every script backs up files before modifying them
- Every script verifies changes after applying them
- Scripts 02 and 04 are idempotent (safe to run multiple times)
- Credential rotation script never prints secrets to stdout
- All scripts use `set -euo pipefail` for strict error handling

## QA Status

All files passed QA review. 8 bugs were found and fixed before delivery.
Average QA score: 9/10.
