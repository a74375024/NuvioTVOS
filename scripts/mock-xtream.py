#!/usr/bin/env python3
"""A fake Xtream Codes provider for the CI screenshot tour (simulator only).

Serves ~60,000 made-up live channels shaped like a big IPTV list (US
networks in several versions, local stations, PPV event slots, other
countries, 24/7 and FAST channels), a short XMLTV guide, and empty short
EPGs, on http://127.0.0.1:8765. Event slot names change on every channel
list request, like real event feeds do through the day, so the app's
"only event names changed" refresh path gets exercised.

No real channel data: every name is generated here.
"""
import gzip
import http.server
import json
import random
import socketserver
import sys
import threading
import time
import urllib.parse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
rng = random.Random(42)

CORE = [
    ("NEWS", ["CNN", "FOX NEWS", "MSNBC", "CNBC", "HLN", "BLOOMBERG", "NEWSMAX", "WEATHER CHANNEL", "C-SPAN", "FOX BUSINESS"]),
    ("SPORTS", ["ESPN", "ESPN 2", "ESPNU", "ESPNEWS", "FS1", "FS2", "NFL NETWORK", "NBA TV", "MLB NETWORK", "NHL NETWORK",
                "GOLF CHANNEL", "TENNIS CHANNEL", "CBS SPORTS NETWORK", "BIG TEN NETWORK", "SEC NETWORK", "ACC NETWORK"]),
    ("ENTERTAINMENT", ["USA NETWORK", "TNT", "TBS", "FX", "FXX", "AMC", "HGTV", "FOOD NETWORK", "DISCOVERY", "TLC",
                       "HISTORY", "A&E", "BRAVO", "E!", "SYFY", "COMEDY CENTRAL", "PARAMOUNT NETWORK", "LIFETIME",
                       "NATIONAL GEOGRAPHIC", "ANIMAL PLANET", "TRAVEL CHANNEL", "INVESTIGATION DISCOVERY", "OXYGEN", "FREEFORM"]),
    ("MOVIES", ["HBO", "HBO 2", "HBO FAMILY", "SHOWTIME", "STARZ", "CINEMAX", "MGM+", "TCM", "FX MOVIE CHANNEL", "HALLMARK MOVIES"]),
    ("KIDS", ["DISNEY CHANNEL", "DISNEY JUNIOR", "DISNEY XD", "NICKELODEON", "NICK JR", "CARTOON NETWORK", "BOOMERANG", "PBS KIDS"]),
    ("MUSIC", ["MTV", "MTV 2", "CMT", "VH1", "BET"]),
]
CITIES = ["NEW YORK", "LOS ANGELES", "CHICAGO", "PHILADELPHIA", "DALLAS", "SAN FRANCISCO", "ATLANTA", "HOUSTON", "BOSTON",
          "PHOENIX", "SEATTLE", "TAMPA", "DETROIT", "MINNEAPOLIS", "DENVER", "ORLANDO", "MIAMI", "CLEVELAND", "SACRAMENTO",
          "ST. LOUIS", "PORTLAND", "CHARLOTTE", "PITTSBURGH", "RALEIGH", "BALTIMORE", "NASHVILLE", "SAN DIEGO", "SALT LAKE CITY"]
NETWORKS = ["ABC", "CBS", "NBC", "FOX", "PBS", "CW"]
COUNTRIES = ["UK", "FR", "DE", "ES", "IT", "NL", "PT", "PL", "TR", "AR", "MX", "BR", "CA", "SE", "NO", "GR", "IN", "PH"]
TEAMS = ["Hawks", "Bears", "Lions", "Tigers", "Sharks", "Wolves", "Eagles", "Falcons", "Kings", "Jets", "Rams", "Bulls"]

categories = []          # (id, name)
streams = []             # dicts without event names
event_slots = []         # indexes into streams of event slots


def category(name):
    categories.append((str(len(categories) + 1), name))
    return categories[-1][0]


def add(name, cat, epg=""):
    streams.append({"name": name, "category_id": cat, "epg_channel_id": epg})
    return len(streams) - 1


def build():
    # US networks: several versions each, as big lists have.
    for group, names in CORE:
        cat = category(f"US| {group}")
        alt = category(f"US| {group} VIP")
        for name in names:
            epg = name.replace(" ", "").replace("+", "plus").replace("&", "and").lower() + ".us"
            add(f"US: {name} HD", cat, epg)
            add(f"US: {name} FHD", cat, epg)
            add(f"US: {name} (Backup)", alt)
            add(f"TV: {name}", alt, epg)
    # Local stations in many cities.
    loc = category("US| LOCALS")
    loc2 = category("US| LOCALS & REGIONAL")
    letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    for city in CITIES:
        for network in NETWORKS:
            sign = rng.choice("KW") + "".join(rng.choice(letters) for _ in range(3))
            number = rng.randint(2, 50)
            add(f"US: {network} {number} ({sign}) {city} HD", loc)
            add(f"TV: {city} {sign} {network} {number}", loc2)
    # PPV / event slots: numbered families, mostly empty.
    for family, count in [("ESPN+", 600), ("PEACOCK", 150), ("NFL", 40), ("NBA", 30), ("NHL", 30), ("MLB", 30),
                          ("UFC", 20), ("DAZN", 200), ("SOCCER", 300), ("FLO SPORTS", 400)]:
        cat = category(f"US| {family} PPV")
        for number in range(1, count + 1):
            event_slots.append(add(f"{family} {number:03d}", cat))
    # Other countries: lots of regular channels.
    for country in COUNTRIES:
        for group in ["GENERAL", "SPORTS", "NEWS", "MOVIES", "KIDS", "DOCUMENTARY", "MUSIC", "REGIONAL"]:
            cat = category(f"{country}| {group}")
            for number in range(1, 330):
                add(f"{country}: {group.title()} {number} HD", cat)
        cat = category(f"{country}| SOCCER PPV")
        for number in range(1, 120):
            event_slots.append(add(f"{country} SOCCER {number:03d}", cat))
    # 24/7 and FAST.
    cat = category("US| 24/7")
    for number in range(1, 900):
        add(f"24/7: Classic Show {number}", cat)
    cat = category("US| PLUTO TV")
    for number in range(1, 700):
        add(f"PLUTO: Channel {number}", cat)
    # Headings some providers put in their lists.
    cat = category("US| ####")
    for number in range(1, 40):
        add(f"#### SECTION {number} ####", cat)


build()
version = {"n": 0}
lock = threading.Lock()


def event_name(slot_index, n):
    base = streams[slot_index]["name"]
    r = random.Random(slot_index * 7919 + n)
    if r.random() < 0.7:
        return f"{base}: NO EVENT STREAMING"
    a, b = r.sample(TEAMS, 2)
    hour = r.randint(12, 22)
    return f"{base}: {a} vs {b} | Fri 23 Oct {hour}:00 EDT (US)"


def live_streams():
    with lock:
        version["n"] += 1
        n = version["n"]
    names = {i: event_name(i, n) for i in event_slots}
    out = []
    for index, stream in enumerate(streams):
        out.append({
            "num": index + 1, "name": names.get(index, stream["name"]), "stream_type": "live",
            "stream_id": 100000 + index, "stream_icon": "", "epg_channel_id": stream["epg_channel_id"],
            "added": "1700000000", "category_id": stream["category_id"], "custom_sid": "",
            "tv_archive": 0, "direct_source": "", "tv_archive_duration": 0,
        })
    return out


def xmltv():
    now = int(time.time()) // 1800 * 1800
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', "<tv>"]
    ids = sorted({s["epg_channel_id"] for s in streams if s["epg_channel_id"]})
    for cid in ids:
        lines.append(f'<channel id="{cid}"><display-name>{cid}</display-name></channel>')
    for cid in ids:
        sports = "espn" in cid or "fs1" in cid or "nfl" in cid or "nba" in cid
        news = "cnn" in cid or "news" in cid or "msnbc" in cid
        for slot in range(-2, 16):
            start = now + slot * 1800
            stamp = lambda t: time.strftime("%Y%m%d%H%M%S +0000", time.gmtime(t))
            title = "Live Game" if sports else ("Evening Report" if news else f"Program {slot}")
            cat = "Sports event" if sports else ("News" if news else "Series")
            lines.append(f'<programme start="{stamp(start)}" stop="{stamp(start + 1800)}" channel="{cid}">'
                         f"<title>{title}</title><category>{cat}</category></programme>")
    lines.append("</tv>")
    return "\n".join(lines).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, body, kind="application/json"):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        if url.path.endswith("player_api.php"):
            action = query.get("action")
            if action is None:
                body = {"user_info": {"auth": 1, "status": "Active", "exp_date": "1900000000", "max_connections": "1",
                                      "active_cons": "0", "allowed_output_formats": ["m3u8", "ts"]},
                        "server_info": {"url": "127.0.0.1", "port": str(PORT)}}
            elif action == "get_live_categories":
                body = [{"category_id": cid, "category_name": name, "parent_id": 0} for cid, name in categories]
            elif action == "get_live_streams":
                body = live_streams()
            elif action == "get_short_epg":
                body = {"epg_listings": []}
            else:
                body = []
            self.send(json.dumps(body).encode())
        elif url.path.endswith("xmltv.php"):
            self.send(xmltv(), "application/xml")
        else:
            self.send_response(404)
            self.end_headers()


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    print(f"mock xtream: {len(streams)} channels, {len(categories)} categories, {len(event_slots)} event slots on :{PORT}",
          flush=True)
    Server(("127.0.0.1", PORT), Handler).serve_forever()
