#!/usr/bin/env python3
"""Apply Pterodactyl environment variables to murmur.ini and Bragi configuration.ini.

Passwords are written to the config files only and are never printed.
"""
from __future__ import annotations

import os
import re
import sys
from configparser import ConfigParser
from pathlib import Path

CONTAINER = Path("/home/container")
MURMUR_INI = CONTAINER / "murmur.ini"
BRAGI_INI = CONTAINER / "configuration.ini"
TEMPLATE_MURMUR = Path("/opt/aerohost/murmur.ini.template")
COOKIE_FILE = CONTAINER / "youtube-cookies.txt"


def env(name: str, default: str = "") -> str:
    val = os.environ.get(name)
    if val is None:
        return default
    return val.strip()


def valid_port(value: str) -> str:
    try:
        n = int(str(value).strip())
    except (TypeError, ValueError):
        return ""
    if 1 <= n <= 65535:
        return str(n)
    return ""


def murmur_ini_port() -> str:
    """Read a pre-existing port from murmur.ini (Wings egg parser writes it)."""
    if not MURMUR_INI.exists():
        return ""
    for line in MURMUR_INI.read_text(encoding="utf-8", errors="replace").splitlines():
        s = line.strip()
        if s.startswith(";") or s.startswith("#"):
            continue
        m = re.match(r"^port\s*=\s*(\d+)\s*$", s, re.I)
        if m:
            return valid_port(m.group(1))
    return ""


def resolve_port() -> str:
    """Always prefer Wings SERVER_PORT. Never silently default to 64738 if
    murmur.ini already has the allocation port from the egg config parser."""
    from_env = valid_port(env("SERVER_PORT", ""))
    if from_env:
        return from_env
    from_ini = murmur_ini_port()
    if from_ini:
        return from_ini
    return "64738"


def resolve_users() -> str:
    raw = env("MAX_USERS", "40")
    try:
        n = int(float(raw))
    except ValueError:
        n = 40
    # Leave room for the bot plus at least a couple of listeners.
    if n < 5:
        n = 5
    return str(n)


def ini_quote(value: str) -> str:
    s = "" if value is None else str(value)
    if any(ch in s for ch in ' \t#;"\'=,\\'):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return s


def volume_from_env() -> str:
    raw = env("BOT_VOLUME", "80")
    try:
        num = float(raw)
    except ValueError:
        num = 80.0
    if num > 1.0:
        num = num / 100.0
    num = max(0.0, min(1.0, num))
    return f"{num:.2f}"


def ensure_murmur_template() -> None:
    if MURMUR_INI.exists():
        return
    if TEMPLATE_MURMUR.exists():
        MURMUR_INI.write_text(TEMPLATE_MURMUR.read_text(encoding="utf-8"), encoding="utf-8")
        return
    MURMUR_INI.write_text(
        "database=/home/container/murmur.sqlite\n"
        "logfile=/home/container/murmur.log\n"
        "pidfile=/home/container/murmur.pid\n"
        "port=64738\nhost=0.0.0.0\nserverpassword=\n"
        "bandwidth=558000\nusers=40\nopusthreshold=0\n",
        encoding="utf-8",
    )


def upsert_murmur(mapping: dict[str, str]) -> None:
    ensure_murmur_template()
    text = MURMUR_INI.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    seen: set[str] = set()
    out: list[str] = []
    lower_keys = {k.lower(): k for k in mapping}
    in_section = False
    pending_inserted = False

    def insert_missing() -> None:
        nonlocal pending_inserted
        if pending_inserted:
            return
        missing = [k for k in mapping if k not in seen]
        if missing:
            for key in missing:
                out.append(f"{key}={mapping[key]}")
                seen.add(key)
        pending_inserted = True

    for line in lines:
        section = re.match(r"^\[([^\]]+)\]\s*$", line.strip())
        if section:
            if not in_section:
                insert_missing()
            in_section = True
            out.append(line)
            continue
        if not in_section:
            km = re.match(r"^;?\s*([A-Za-z0-9_]+)\s*=", line)
            if km and km.group(1).lower() in lower_keys:
                key = lower_keys[km.group(1).lower()]
                out.append(f"{key}={mapping[key]}")
                seen.add(key)
                continue
        out.append(line)

    if not pending_inserted:
        insert_missing()

    MURMUR_INI.write_text("\n".join(out) + "\n", encoding="utf-8")


def write_bragi_ini() -> None:
    existing = ConfigParser(interpolation=None)
    existing.optionxform = str
    if BRAGI_INI.exists():
        existing.read(BRAGI_INI, encoding="utf-8")

    port = resolve_port()
    channel = env("BOT_CHANNEL", "")
    password = env("SERVER_PASSWORD", "")
    username = env("BOT_NAME", "AeroHost DJ") or "AeroHost DJ"
    cookie = str(COOKIE_FILE) if COOKIE_FILE.is_file() and COOKIE_FILE.stat().st_size > 0 else ""

    cfg = ConfigParser(interpolation=None)
    cfg.optionxform = str

    cfg["server"] = {
        "host": "127.0.0.1",
        "port": port,
        "password": password,
        "channel": channel,
        "certificate": "/home/container/bragi.pem",
        "tokens": "",
    }
    cfg["bot"] = {
        "username": username,
        "comment": (
            "AeroHost music bot. I reply in English. "
            "Use !yplay <search>, !ysearch <query>, or !url / !play <link> "
            "(YouTube, SoundCloud and other yt-dlp sites). "
            "Spotify links are not streamed natively — search the track with !yplay. "
            "Type !help for the full list."
        ),
        "avatar": "",
        "language": "en_US",
        "stereo": "True",
        "volume": volume_from_env(),
        "max_volume": "1.0",
        "restore_volume_on_stop": "False",
        "bandwidth": "200000",
        "music_folder": "/home/container/music/",
        "tmp_folder": "/home/container/tmp/",
        "tmp_folder_max_size": "512",
        "database_path": "/home/container/settings.db",
        "music_database_path": "/home/container/music.db",
        "logfile": "",
        "redirect_stderr": "False",
        "pip3_path": "/opt/bragi/venv/bin/pip",
        "download_attempts": "3",
        "announce_current_music": "True",
        "allow_other_channel_message": "False",
        "allow_private_message": "True",
        "playback_mode": "one-shot",
        "autoplay_length": "5",
        "clear_when_stop_in_oneshot": "False",
        "refresh_cache_on_startup": "False",
        "save_music_library": "True",
        "save_playlist": "True",
        "max_track_playlist": "40",
        "max_track_duration": "60",
        "ducking": "True",
        "ducking_volume": "0.05",
        "ducking_threshold": "3000",
        "when_nobody_in_channel": "nothing",
        "when_nobody_in_channel_ignore": "",
        "admin": "",
        "delete_allowed": "False",
        "ignored_folders": "tmp",
        "ignored_files": "Thumbs.db",
        "rebuild_workers": "1",
    }
    cfg["debug"] = {
        "ffmpeg": "False",
        "mumble_connection": "False",
        "youtube_dl": "False",
        "redirect_ffmpeg_log": "False",
    }
    cfg["youtube_dl"] = {
        "cookie_file": cookie,
        "source_address": "",
        "user_agent": "",
    }

    if existing.has_section("radio"):
        cfg["radio"] = {k: existing["radio"][k] for k in existing["radio"]}
    else:
        cfg["radio"] = {
            "jazz": 'http://jazz-wr04.ice.infomaniak.ch/jazz-wr04-128.mp3 "Jazz Yeah !"',
        }

    if existing.has_section("commands"):
        cfg["commands"] = {k: existing["commands"][k] for k in existing["commands"]}

    # Write atomically. Avoid echo of file contents.
    tmp = BRAGI_INI.with_suffix(".ini.tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        fh.write("# Generated on each start from panel variables.\n")
        fh.write("# Custom [radio] and [commands] sections are preserved.\n")
        fh.write("# Server connection, volume, name and channel come from the egg variables.\n\n")
        cfg.write(fh)
    tmp.replace(BRAGI_INI)


def main() -> int:
    CONTAINER.mkdir(parents=True, exist_ok=True)
    (CONTAINER / "music").mkdir(exist_ok=True)
    (CONTAINER / "tmp").mkdir(exist_ok=True)

    port = resolve_port()
    users = resolve_users()
    bandwidth = env("BANDWIDTH", "558000")
    server_password = env("SERVER_PASSWORD", "")

    try:
        bw = int(float(bandwidth))
    except ValueError:
        bw = 558000
    # Official Mumble maximum / current default.
    if bw <= 0 or bw > 558000:
        bw = 558000

    upsert_murmur(
        {
            "database": "/home/container/murmur.sqlite",
            "logfile": "/home/container/murmur.log",
            "pidfile": "/home/container/murmur.pid",
            "port": port,
            "host": "0.0.0.0",
            "users": users,
            "bandwidth": str(bw),
            "serverpassword": ini_quote(server_password),
            "opusthreshold": "0",
        }
    )
    write_bragi_ini()
    bot = env("BOT_NAME", "AeroHost DJ") or "AeroHost DJ"
    server_ip = env("SERVER_IP", "") or "unset"
    password_state = "set" if server_password else "empty"
    print("Applied Mumble Premium configuration for port " + port + ",", file=sys.stderr)
    print("users=" + users + ", bandwidth=" + str(bw) + ", bot=" + bot + ".", file=sys.stderr)
    print(
        "Bragi will connect to 127.0.0.1:" + port
        + " (SERVER_IP=" + server_ip + " is not used as the bot host; "
        + "SERVER_PASSWORD is " + password_state + ").",
        file=sys.stderr,
    )
    if COOKIE_FILE.is_file() and COOKIE_FILE.stat().st_size > 0:
        print("Using youtube-cookies.txt for yt-dlp.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
