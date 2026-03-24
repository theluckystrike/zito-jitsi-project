plugin_paths = { "/usr/share/jitsi-meet/prosody-plugins/" }

-- domain mapper options, must at least have domain base set to use the mapper
muc_mapper_domain_base = "jitsi-00.zitovoice.com";

external_service_secret = "RGTiWndnTHGdJixoSYQWJc4QsKnEf9ze4MIwhTNjA4nTjfY2nANMqf95gHJq1TQy";
external_services = {
     { type = "stun", host = "turn-jitsi-00.zitovoice.com", port = 443 },
     { type = "turn", host = "turn-jitsi-00.zitovoice.com", port = 443, transport = "udp", secret = true, ttl = 86400, algorithm = "turn" },
     { type = "turns", host = "turn-jitsi-00.zitovoice.com", port = 5349, transport = "tcp", secret = true, ttl = 86400, algorithm = "turn" }
};

cross_domain_bosh = false;
consider_bosh_secure = true;
https_ports = { }; -- Fix bind error

-- by default prosody 0.12 sends cors headers, if you want to disable it uncomment the following (the config is available on 0.12.1)
--http_cors_override = {
--    bosh = {
--        enabled = false;
--    };
--    websocket = {
--        enabled = false;
--    };
--}

-- https://ssl-config.mozilla.org/#server=haproxy&version=2.1&config=intermediate&openssl=1.1.0g&guideline=5.4
ssl = {
    protocol = "tlsv1_2+";
    ciphers = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384"
}

unlimited_jids = {
    "focus@auth.jitsi-00.zitovoice.com",
    "jvb@auth.jitsi-00.zitovoice.com"
}

VirtualHost "jitsi-00.zitovoice.com"
    authentication = "jitsi-anonymous" -- do not delete me
    -- Properties below are modified by jitsi-meet-tokens package config
    -- and authentication above is switched to "token"
    --app_id="example_app_id"
    --app_secret="example_app_secret"
    -- Assign this host a certificate for TLS, otherwise it would use the one
    -- set in the global section (if any).
    -- Note that old-style SSL on port 5223 only supports one certificate, and will always
    -- use the global one.
    ssl = {
        key = "/etc/prosody/certs/jitsi-00.zitovoice.com.key";
        certificate = "/etc/prosody/certs/jitsi-00.zitovoice.com.crt";
    }
    av_moderation_component = "avmoderation.jitsi-00.zitovoice.com"
    speakerstats_component = "speakerstats.jitsi-00.zitovoice.com"
    conference_duration_component = "conferenceduration.jitsi-00.zitovoice.com"
    end_conference_component = "endconference.jitsi-00.zitovoice.com"
    -- we need bosh
    modules_enabled = {
        "bosh";
        "pubsub";
        "ping"; -- Enable mod_ping
        "speakerstats";
        "external_services";
        "conference_duration";
        "end_conference";
        "muc_lobby_rooms";
        "muc_breakout_rooms";
        "av_moderation";
        "room_metadata";
    }
    c2s_require_encryption = false
    lobby_muc = "lobby.jitsi-00.zitovoice.com"
    breakout_rooms_muc = "breakout.jitsi-00.zitovoice.com"
    room_metadata_component = "metadata.jitsi-00.zitovoice.com"
    main_muc = "conference.jitsi-00.zitovoice.com"
    -- muc_lobby_whitelist = { "recorder.jitsi-00.zitovoice.com" } -- Here we can whitelist jibri to enter lobby enabled rooms

Component "conference.jitsi-00.zitovoice.com" "muc"
    restrict_room_creation = true
    storage = "memory"
    modules_enabled = {
        "muc_meeting_id";
        "muc_domain_mapper";
        "polls";
        --"token_verification";
        "muc_rate_limit";
    }
    admins = { "focus@auth.jitsi-00.zitovoice.com" }
    muc_room_locking = false
    muc_room_default_public_jids = true

Component "breakout.jitsi-00.zitovoice.com" "muc"
    restrict_room_creation = true
    storage = "memory"
    modules_enabled = {
        "muc_meeting_id";
        "muc_domain_mapper";
        --"token_verification";
        "muc_rate_limit";
    }
    admins = { "focus@auth.jitsi-00.zitovoice.com" }
    muc_room_locking = false
    muc_room_default_public_jids = true

-- internal muc component
Component "internal.auth.jitsi-00.zitovoice.com" "muc"
    storage = "memory"
    modules_enabled = {
        "ping";
    }
    admins = { "focus@auth.jitsi-00.zitovoice.com", "jvb@auth.jitsi-00.zitovoice.com" }
    muc_room_locking = false
    muc_room_default_public_jids = true

VirtualHost "auth.jitsi-00.zitovoice.com"
    ssl = {
        key = "/etc/prosody/certs/auth.jitsi-00.zitovoice.com.key";
        certificate = "/etc/prosody/certs/auth.jitsi-00.zitovoice.com.crt";
    }
    modules_enabled = {
        "limits_exception";
    }
    authentication = "internal_hashed"

-- Proxy to jicofo's user JID, so that it doesn't have to register as a component.
Component "focus.jitsi-00.zitovoice.com" "client_proxy"
    target_address = "focus@auth.jitsi-00.zitovoice.com"

Component "speakerstats.jitsi-00.zitovoice.com" "speakerstats_component"
    muc_component = "conference.jitsi-00.zitovoice.com"

Component "conferenceduration.jitsi-00.zitovoice.com" "conference_duration_component"
    muc_component = "conference.jitsi-00.zitovoice.com"

Component "endconference.jitsi-00.zitovoice.com" "end_conference"
    muc_component = "conference.jitsi-00.zitovoice.com"

Component "avmoderation.jitsi-00.zitovoice.com" "av_moderation_component"
    muc_component = "conference.jitsi-00.zitovoice.com"

Component "lobby.jitsi-00.zitovoice.com" "muc"
    storage = "memory"
    restrict_room_creation = true
    muc_room_locking = false
    muc_room_default_public_jids = true
    modules_enabled = {
        "muc_rate_limit";
        "polls";
    }

Component "metadata.jitsi-00.zitovoice.com" "room_metadata_component"
    muc_component = "conference.jitsi-00.zitovoice.com"
    breakout_rooms_component = "breakout.jitsi-00.zitovoice.com"
