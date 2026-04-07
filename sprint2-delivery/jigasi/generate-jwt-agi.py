#!/usr/bin/env python3
"""
generate-jwt-agi.py — Asterisk AGI script for Jigasi JWT authentication.

Generates an HS256-signed JWT token for SIP dial-in callers and sets it
as an Asterisk channel variable. Called from the dialplan before forwarding
the call to Jigasi.

Usage in Asterisk dialplan:
    same => n,AGI(generate-jwt-agi.py,${CALLERID(num)},${JITSI_ROOM})

Arguments:
    arg1 — CallerID number (e.g. 15551234567)
    arg2 — Target Jitsi room name (e.g. standup-daily)

Environment / Config:
    Reads APP_ID, APP_SECRET, DOMAIN from either:
      - Environment variables, or
      - /etc/jitsi/jigasi/jwt-config.env

Author: theluckystrike
License: MIT
"""

import sys
import os
import json
import hmac
import hashlib
import base64
import time

CONFIG_PATH = "/etc/jitsi/jigasi/jwt-config.env"


def base64url_encode(data):
    """Encode bytes to base64url (no padding) per RFC 7515."""
    if isinstance(data, str):
        data = data.encode("utf-8")
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def load_config():
    """Load APP_ID, APP_SECRET, DOMAIN from env vars or config file.

    Environment variables take precedence over the config file.
    Returns a dict with keys: app_id, app_secret, domain.
    Raises RuntimeError if required values are missing.
    """
    config = {
        "app_id": os.environ.get("APP_ID", ""),
        "app_secret": os.environ.get("APP_SECRET", ""),
        "domain": os.environ.get("DOMAIN", ""),
    }

    # Fall back to config file for any missing values
    if not all(config.values()) and os.path.isfile(CONFIG_PATH):
        file_vars = _parse_env_file(CONFIG_PATH)
        for key in ("app_id", "app_secret", "domain"):
            if not config[key]:
                config[key] = file_vars.get(key.upper(), "")

    missing = [k for k, v in config.items() if not v]
    if missing:
        raise RuntimeError("Missing config values: {}".format(", ".join(missing)))

    return config


def _parse_env_file(path):
    """Parse a KEY=VALUE env file, ignoring comments and blank lines."""
    result = {}
    with open(path, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            result[key.strip()] = value.strip()
    return result


def generate_jwt(app_id, app_secret, domain, room, caller_id):
    """Build and sign an HS256 JWT for Jigasi authentication.

    Returns the compact JWT string (header.payload.signature).
    """
    now = int(time.time())

    header = {"alg": "HS256", "typ": "JWT"}

    payload = {
        "iss": app_id,
        "sub": domain,
        "aud": "jitsi",
        "room": room,
        "iat": now,
        "exp": now + 3600,
        "context": {
            "user": {
                "name": "Phone: {}".format(caller_id),
                "affiliation": "member",
            }
        },
    }

    segments = [
        base64url_encode(json.dumps(header, separators=(",", ":"))),
        base64url_encode(json.dumps(payload, separators=(",", ":"))),
    ]

    signing_input = ".".join(segments).encode("ascii")
    signature = hmac.new(
        app_secret.encode("utf-8"), signing_input, hashlib.sha256
    ).digest()
    segments.append(base64url_encode(signature))

    return ".".join(segments)


def read_agi_env():
    """Read the AGI environment block from stdin.

    Asterisk sends key: value lines terminated by a blank line.
    Returns a dict of AGI variables.
    """
    max_lines = 100
    env = {}
    for _ in range(max_lines):
        line = sys.stdin.readline().strip()
        if not line:
            break
        if ":" in line:
            key, _, value = line.partition(":")
            env[key.strip()] = value.strip()
    return env


def agi_set_variable(name, value):
    """Set an Asterisk channel variable via AGI protocol."""
    safe_value = str(value).replace('"', "")
    cmd = 'SET VARIABLE {} "{}"\n'.format(name, safe_value)
    sys.stdout.write(cmd)
    sys.stdout.flush()
    # Read the AGI result line
    return sys.stdin.readline().strip()


def agi_verbose(message, level=1):
    """Send a VERBOSE message via AGI protocol."""
    cmd = 'VERBOSE "{}" {}\n'.format(message, level)
    sys.stdout.write(cmd)
    sys.stdout.flush()
    return sys.stdin.readline().strip()


def main():
    """Entry point: read AGI env, generate JWT, set channel variables."""
    # Read AGI environment (required by AGI protocol)
    agi_env = read_agi_env()

    # Extract arguments: arg1=callerid, arg2=room
    caller_id = agi_env.get("agi_arg_1", "unknown")
    room = agi_env.get("agi_arg_2", "*")

    if not caller_id or caller_id == "unknown":
        # Fallback: try callerid from AGI env
        caller_id = agi_env.get("agi_callerid", "unknown")

    try:
        config = load_config()
        token = generate_jwt(
            app_id=config["app_id"],
            app_secret=config["app_secret"],
            domain=config["domain"],
            room=room,
            caller_id=caller_id,
        )

        agi_set_variable("JWT_TOKEN", token)
        agi_set_variable("JITSI_ROOM", room)
        agi_set_variable("JWT_STATUS", "OK")
        agi_verbose("JWT generated for caller {} room {}".format(caller_id, room))

    except Exception as exc:
        agi_set_variable("JWT_STATUS", "FAIL")
        agi_set_variable("JWT_ERROR", str(exc))
        agi_verbose("JWT generation failed: {}".format(exc), level=1)

    return 0


if __name__ == "__main__":
    sys.exit(main())
