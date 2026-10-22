#!/usr/bin/env python3
"""US/CA station directory (call sign → network, city, state, channel) from
Wikipedia's affiliate lists, so a channel named "NBC 5 Chicago" can be matched
to WMAQ even when its name has no call sign. Writes out/stations.json.z
(raw deflate): [{"c": "WMAQ", "net": "NBC", "city": "Chicago", "st": "Illinois", "ch": "5"}]
"""
import json
import os
import re
import sys
import urllib.parse
import urllib.request
import zlib

OUT = os.path.join(os.getcwd(), "out")
API = "https://en.wikipedia.org/w/api.php"

NETWORKS = [
    ("ABC", ["List of ABC television affiliates (by U.S. state)", "List of ABC television affiliates"]),
    ("CBS", ["List of CBS television affiliates (by U.S. state)", "List of CBS television affiliates"]),
    ("NBC", ["List of NBC television affiliates (by U.S. state)", "List of NBC television affiliates"]),
    ("FOX", ["List of Fox television affiliates (by U.S. state)", "List of Fox television affiliates"]),
    ("CW", ["List of The CW television affiliates (by U.S. state)", "List of The CW affiliates"]),
    ("MYNETWORKTV", ["List of MyNetworkTV affiliates"]),
    ("PBS", ["List of PBS member stations"]),
    ("TELEMUNDO", ["List of Telemundo affiliates (by U.S. state)", "List of Telemundo affiliates"]),
    ("UNIVISION", ["List of Univision affiliates", "List of Univision television affiliates"]),
    ("ION", ["List of Ion Television affiliates"]),
]

CALL = re.compile(r"\[\[\s*((?:[KW][A-Z]{2,3})(?:-(?:TV|DT|LD|CD|LP))?)\s*(?:\|[^\]]*)?\]\]")
LINK = re.compile(r"\[\[([^\]|#]+)(?:\|([^\]]+))?\]\]")


def wikitext(title):
    query = urllib.parse.urlencode({"action": "parse", "page": title, "prop": "wikitext",
                                    "format": "json", "redirects": 1})
    request = urllib.request.Request(f"{API}?{query}", headers={"User-Agent": "NuvioTV-guide-builder/1.0 (personal use)"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = json.load(response)
    if "error" in data:
        raise RuntimeError(data["error"].get("info", "parse error"))
    return data["parse"]["wikitext"]["*"]


def parse(text, network):
    stations = []
    state = ""
    city = ""
    heading_re = re.compile(r"^==+\s*([^=]+?)\s*==+\s*$", flags=re.M)
    for chunk in re.split(r"\n\|-", text):
        # A heading inside a chunk belongs to the rows after it.
        pieces = heading_re.split(chunk)
        blocks = [(pieces[0], None)] + [(pieces[i + 1], pieces[i]) for i in range(1, len(pieces) - 1, 2)]
        for block, new_state in blocks:
            if new_state is not None:
                state = re.sub(r"\[\[|\]\]", "", new_state).strip()
            row = parse_row(block, network, state, city)
            if row:
                city = row["city"]
                stations.append(row)
    return stations


def parse_row(block, network, state, city):
    if True:
        calls = list(CALL.finditer(block))
        if not calls:
            return None
        # The market / city is the first ordinary link before the call sign;
        # rowspans carry it over from the previous row when missing.
        before = block[: calls[0].start()]
        for target, label in LINK.findall(before):
            name = (label or target).strip()
            if CALL.fullmatch(f"[[{target}]]") or ":" in target:
                continue
            city = name.split(",")[0].strip()
            break
        sign = re.sub(r"-(TV|DT|LD|CD|LP)$", "", calls[0].group(1))
        after = re.sub(r"\[\[[^\]]*\]\]", " ", block[calls[0].end():])
        channel = re.search(r"\b(\d{1,2})(?:\.\d)?\b", after)
        return {"c": sign, "net": network, "city": city, "st": state,
                "ch": channel.group(1) if channel else ""}


def main():
    os.makedirs(OUT, exist_ok=True)
    seen = {}
    report = []
    for network, titles in NETWORKS:
        for title in titles:
            try:
                rows = parse(wikitext(title), network)
            except Exception as error:
                report.append(f"{network}: {title} failed ({str(error)[:60]})")
                continue
            for row in rows:
                seen.setdefault((row["c"], row["net"]), row)
            report.append(f"{network}: {len(rows)}")
            break
    stations = list(seen.values())
    payload = json.dumps(stations, ensure_ascii=False, separators=(",", ":")).encode()
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    with open(os.path.join(OUT, "stations.json.z"), "wb") as out:
        out.write(compressor.compress(payload) + compressor.flush())
    print("stations:", len(stations), "|", "; ".join(report))
    with open(os.path.join(OUT, "stations-report.txt"), "w") as out:
        out.write(f"{len(stations)} stations | " + "; ".join(report))
    if not stations:
        sys.exit("no stations parsed")


if __name__ == "__main__":
    main()
