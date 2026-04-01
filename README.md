Zito Media — Jitsi Video Conferencing Platform

This repository contains the deployment artifacts, diagnostic evidence, and sprint reports
for the Jitsi video conferencing platform at jitsi-00.zitovoice.com.


Getting Started

The platform runs inside an Incus LXC container on Debian 12. All services are installed
from Debian packages. No Docker, no pip, no source builds.

To rebuild the container from scratch, SSH into lxchost-00.zitovoice.com on port 47011
and run the following as the ansible-controller user.

    sudo build_jitsi-00.zitovoice.com.sh

Then remove the old SSH key and accept the new one.

    ssh-keygen -f '/home/ansible-controller/.ssh/known_hosts' -R '[jitsi-00.zitovoice.com]:47011'
    ssh -p 47011 -o StrictHostKeyChecking=accept-new ansible@jitsi-00.zitovoice.com exit

Run the playbooks in this exact order.

    ansible-playbook -u ansible -i ~/inventory/hosts-production-jitsi --forks 1 --limit jitsi-00.zitovoice.com ~/playbooks/production/jitsi-00.zitovoice.com/10-enable-apt-proxy-debian.yaml
    ansible-playbook -u ansible -i ~/inventory/hosts-production-jitsi --forks 1 --limit jitsi-00.zitovoice.com ~/playbooks/production/jitsi-00.zitovoice.com/20-nftables_configuration.yaml
    ansible-playbook -u ansible -i ~/inventory/hosts-production-jitsi --forks 1 --limit jitsi-00.zitovoice.com ~/playbooks/production/jitsi-00.zitovoice.com/21-install_packages.yaml
    ansible-playbook -u ansible -i ~/inventory/hosts-production-jitsi --forks 1 --limit jitsi-00.zitovoice.com ~/playbooks/production/jitsi-00.zitovoice.com/22-fix-vim-default-settings.yaml
    ansible-playbook -u ansible -i ~/inventory/hosts-production-jitsi --forks 1 --limit jitsi-00.zitovoice.com ~/playbooks/production/jitsi-00.zitovoice.com/25-network_configuration.yaml
    ansible-playbook -u ansible -i ~/inventory/hosts-production-jitsi --forks 1 --limit jitsi-00.zitovoice.com ~/playbooks/production/jitsi-00.zitovoice.com/30-create-voice-admin-users.yaml
    ansible-playbook -u ansible -i ~/inventory/hosts-production-jitsi --forks 1 --limit jitsi-00.zitovoice.com ~/playbooks/generic/create-mlip-user.yaml
    ansible-playbook -u ansible -i ~/inventory/hosts-production-jitsi --forks 1 --limit jitsi-00.zitovoice.com ~/playbooks/production/jitsi-00.zitovoice.com/90-jitsi_configuration.yaml
    ansible-playbook -u ansible -i ~/inventory/hosts-production-jitsi --forks 1 --limit jitsi-00.zitovoice.com ~/playbooks/production/jitsi-00.zitovoice.com/94-install-existing-letsencrypt-certificate.yaml
    ansible-playbook -u ansible -i ~/inventory/hosts-production-jitsi --forks 1 --limit jitsi-00.zitovoice.com ~/playbooks/production/jitsi-00.zitovoice.com/95-letsencrypt_configuration.yaml


Service Restart Sequence

Always restart services in this order. Never start them simultaneously. Jicofo will not
recover if it starts before Prosody is fully initialized.

    systemctl restart prosody
    sleep 5
    systemctl restart jicofo
    sleep 5
    systemctl restart jitsi-videobridge2
    sleep 3
    systemctl restart coturn
    nginx -t && systemctl restart nginx


Token Generation

Generate a JWT token for authenticated room access.

    /usr/local/bin/generate-token.pl \
      --jitsi-server-url https://jitsi-00.zitovoice.com \
      --token-app-id jitsi00 \
      --token-email-address voiceops@zitomedia.com \
      --token-expiration-lifespan 86400 \
      --token-jitsi-domain jitsi-00.zitovoice.com \
      --token-jitsi-room my-meeting-room \
      --token-secret YOUR_APP_SECRET \
      --token-user-name "Your Name" \
      --token-claims-moderator

The script now uses HS256 (aligned with Prosody's default verification algorithm).
Open the generated URL in a browser to join the conference as a moderator.


Invite Links (Guest Access)

The invite button in Jitsi copies the room URL without a token. Guests currently cannot
join because allow_empty_token is set to false. The fix for this is the guest domain
pattern, which is the next item to be implemented.

Once implemented, moderators will create rooms using token URLs and guests will join
using the plain invite link without needing a token. The room will only exist while
a token-authenticated moderator is present.


Architecture

    Browser --> NGINX (port 443, SNI multiplexer)
                  |
                  +--> jitsi-00.zitovoice.com --> NGINX HTTP (port 4444) --> Jitsi Meet frontend
                  |                                  |
                  |                                  +--> /http-bind --> Prosody (BOSH)
                  |                                  +--> /colibri-ws --> JVB (WebSocket)
                  |
                  +--> turn-jitsi-00.zitovoice.com --> coturn (port 5349, TLS)

    Prosody (XMPP signaling, JWT auth, external_services for TURN credentials)
       |
       +--> Jicofo (conference focus, bridge selection via JvbBrewery MUC)
       |
       +--> JVB (media routing, UDP 10000)
       |
       +--> coturn (TURN/STUN relay, UDP 3478, TLS 5349)


Configuration Files

    /etc/jitsi/meet/jitsi-00.zitovoice.com-config.js    Jitsi Meet frontend
    /etc/prosody/conf.avail/jitsi-00.zitovoice.com.cfg.lua   Prosody VirtualHost and MUC
    /etc/jitsi/videobridge/sip-communicator.properties    JVB XMPP and NAT harvester
    /etc/jitsi/videobridge/jvb.conf                      JVB REST API and WebSocket
    /etc/jitsi/jicofo/jicofo.conf                        Jicofo XMPP and bridge brewery
    /etc/turnserver.conf                                 coturn TURN/STUN relay
    /etc/nginx/sites-enabled/jitsi-00.zitovoice.com.conf NGINX reverse proxy
    /etc/nginx/modules-enabled/turn-meet-multiplex.conf  NGINX stream multiplexer
    /etc/nftables.conf                                   Firewall rules


Diagnostics

Check all services

    systemctl status prosody jicofo jitsi-videobridge2 coturn nginx

Tail logs

    journalctl -u prosody -f
    journalctl -u jicofo -f
    tail -f /var/log/jitsi/jvb.log

Query JVB stats

    curl -s http://localhost:8080/colibri/stats | python3 -m json.tool

Test TURN connectivity

    turnutils_uclient -T -W SHARED_SECRET -u testuser turn-jitsi-00.zitovoice.com

Verify TLS certificate

    echo | openssl s_client -connect jitsi-00.zitovoice.com:443 \
      -servername jitsi-00.zitovoice.com 2>/dev/null | \
      openssl x509 -noout -dates -subject -issuer

Test certbot renewal

    certbot renew --dry-run

Check firewall

    nft list ruleset
    nft list counters

Port reachability from external host

    nmap -Pn -p 80,443,5349 67.58.160.118
    nmap -Pn -sU -p 3478,10000 67.58.160.118


Repository Structure

    raw-configs/          Configuration file snapshots from the initial broken state
    report/               Sprint reports (HTML)
    screenshots/          Visual evidence of the platform running


Sprint 1 Summary (March 22 to March 27, 2026)

Six issues were identified and resolved in the initial sprint.

1. Fatal JavaScript syntax error in config.js that prevented the entire frontend
   from initializing. A var config.jwt block used invalid dot notation in a var
   declaration, causing a parse failure that left Jitsi Meet with no configuration.

2. JVB authentication failure caused by a password mismatch between
   sip-communicator.properties and Prosody's internal user database. Every XMPP
   connection from JVB was rejected with SCRAM-SHA-1 not-authorized.

3. Jicofo startup race condition where Jicofo attempted to configure the JvbBrewery
   MUC room before Prosody fully initialized. Jicofo does not retry after this
   failure and stayed stuck permanently.

4. Token authentication disabled in Prosody. The VirtualHost was set to
   jitsi-anonymous with app_id, app_secret, and token_verification all commented out.
   JWT tokens were generated but completely ignored.

5. coturn completely unconfigured. The turnserver.conf was the unmodified Debian
   default template with every directive commented out. No TURN relay was available
   for NAT traversal.

6. NGINX stream multiplexer routing loop where the turn_backend upstream pointed to
   the server's own public hostname instead of 127.0.0.1. Also removed invalid
   Prosody modules (pubsub in VirtualHost scope, polls with no file on disk).

The platform is now live at https://jitsi-00.zitovoice.com with JWT authentication,
Zito branding applied, and all five services running.


Contact

Michael Lip
github.com/theluckystrike
