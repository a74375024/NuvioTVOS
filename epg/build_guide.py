#!/usr/bin/env python3
"""Builds the compact outside-guide shards for the Live TV tab.

Downloads every free XMLTV source in sources.json, keeps the next ~48 hours,
merges the same channel across sources (by call sign for local stations,
otherwise by normalized name), fills one source's gaps from the others, and
writes one raw-deflate JSON file per shard to out/:

  {"v": 1, "generated": <unix>, "shard": "us-locals",
   "channels": [{"n": [names], "c": [call signs],
                 "p": [[start_minute, minutes, title, subtitle, desc, flags], ...]}]}

flags: 1 movie, 2 sports, 4 news, 8 kids, 16 live, 32 new.
The app matches its server's channels against these names and call signs.
"""
import bisect
import gzip
import json
import os
import re
import sys
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET
import zlib
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.getcwd(), "out")
NOW = int(time.time())
LOW = NOW - 3 * 3600
HIGH = NOW + 36 * 3600
# Descriptions only for what's on soon: they're most of the size, and the
# guide only shows the focused program's.
DESC_UNTIL = NOW + 8 * 3600
DESC_LIMIT = 200

# ---------------------------------------------------------------- matching keys

CALL_RE = re.compile(r"(?<![A-Z0-9])([KW][A-Z]{2,3})(?:[- ]?(DT|TV|LD|LP|CD|CA|HD)(\d)?)?(?![A-Z])")
CALL_STOP = {"WWE", "WNBA", "WEST", "WILD", "KIDS", "WORK", "WIRE", "WAVE", "WARS", "WOW", "KICK", "WINE", "WORD", "WEEK"}
DROP = {"hd", "fhd", "uhd", "sd", "4k", "hevc", "h265", "h264", "1080p", "720p", "1080", "720",
        "50fps", "60fps", "backup", "alt", "vip", "raw", "feed", "usa", "us", "ca", "uk", "tv",
        "east", "west", "pacific"}


def callsigns(texts, strong_context):
    """Call signs ("WNBC", "KABC-2" for a sub-channel). A bare four-letter
    word only counts in a locals source, in parentheses, or with a -DT style
    suffix, so "WILD" or "KIDS" in a network name don't."""
    found = []
    for text in texts:
        upper = text.upper()
        for match in CALL_RE.finditer(upper):
            sign, suffix, digit = match.group(1), match.group(2), match.group(3)
            if sign in CALL_STOP:
                continue
            in_parens = re.search(r"\(\s*" + re.escape(match.group(0)), upper) is not None
            if not (strong_context or suffix or in_parens):
                continue
            key = sign if not digit or digit == "1" else f"{sign}-{digit}"
            if key not in found:
                found.append(key)
    return found


def normalize(name):
    """Comparable form of a channel name. East is the default feed, so it's
    dropped; West / Pacific feeds keep a marker so they never merge with East."""
    s = name.lower().replace("&", " and ").replace("+", " plus ")
    west = re.search(r"\b(west|pacific)\b", s) is not None
    s = re.sub(r"[\[\(][^\]\)]*[\]\)]", " ", s)
    s = re.sub(r"^\s*[^:|]{1,24}[:|]\s*", "", s)
    tokens = [t for t in re.split(r"[^a-z0-9]+", s) if t and t not in DROP]
    key = "".join(tokens)
    return key + "~west" if key and west else key

# ---------------------------------------------------------------- parsing


def parse_time(raw):
    raw = (raw or "").strip()
    if not raw:
        return None
    parts = raw.split()
    stamp = parts[0][:14].ljust(14, "0")
    try:
        dt = datetime.strptime(stamp, "%Y%m%d%H%M%S")
    except ValueError:
        return None
    offset = 0
    if len(parts) > 1 and re.fullmatch(r"[+-]\d{4}", parts[1]):
        sign = 1 if parts[1][0] == "+" else -1
        offset = sign * (int(parts[1][1:3]) * 3600 + int(parts[1][3:5]) * 60)
    return int(dt.replace(tzinfo=timezone.utc).timestamp()) - offset


def flags_for(categories, element):
    text = " ".join(categories).lower()
    flags = 0
    if "movie" in text or "film" in text:
        flags |= 1
    if "sport" in text:
        flags |= 2
    if "news" in text:
        flags |= 4
    if "kids" in text or "children" in text or "animation" in text:
        flags |= 8
    if element.find("live") is not None:
        flags |= 16
    if element.find("new") is not None or element.find("premiere") is not None:
        flags |= 32
    return flags


def download(url):
    request = urllib.request.Request(url, headers={"User-Agent": "NuvioTV-guide-builder/1.0"})
    handle, path = tempfile.mkstemp(suffix=".xmltv")
    with urllib.request.urlopen(request, timeout=300) as response, os.fdopen(handle, "wb") as out:
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
    return path


def open_xml(path):
    with open(path, "rb") as probe:
        magic = probe.read(2)
    return gzip.open(path, "rb") if magic == b"\x1f\x8b" else open(path, "rb")


def text_of(element, tag):
    child = element.find(tag)
    if child is None or child.text is None:
        return None
    value = child.text.strip()
    return value or None


def parse_source(path, locals_source):
    channels = {}   # xmltv id -> {"names": [...]}
    programs = {}   # xmltv id -> [(start, end, title, sub, desc, flags)]
    with open_xml(path) as stream:
        for _, element in ET.iterparse(stream, events=("end",)):
            if element.tag == "channel":
                cid = element.get("id") or ""
                names = [n.text.strip() for n in element.findall("display-name") if n.text and n.text.strip()]
                channels[cid] = {"names": names or [cid]}
                element.clear()
            elif element.tag == "programme":
                start = parse_time(element.get("start"))
                end = parse_time(element.get("stop"))
                if start is not None and end is not None and end > start and end > LOW and start < HIGH:
                    title = text_of(element, "title")
                    if title:
                        desc = text_of(element, "desc") if start < DESC_UNTIL else None
                        if desc and len(desc) > DESC_LIMIT:
                            desc = desc[: DESC_LIMIT - 1].rstrip() + "…"
                        categories = [c.text for c in element.findall("category") if c.text]
                        programs.setdefault(element.get("channel") or "", []).append(
                            (start, end, title, text_of(element, "sub-title"), desc, flags_for(categories, element))
                        )
                element.clear()
    result = []
    for cid, info in channels.items():
        listing = programs.get(cid)
        if not listing:
            continue
        names = info["names"]
        signs = callsigns(names + [cid], locals_source)
        if signs:
            key = "cs:" + signs[0]
        else:
            key = "n:" + (normalize(names[0]) or normalize(cid) or cid.lower())
        result.append({"key": key, "names": names, "signs": signs, "programs": sorted(listing)})
    return result

# ---------------------------------------------------------------- merging


def merge_programs(base, extra):
    """Adds extra programs that don't overlap base by more than 5 minutes."""
    if not base:
        return list(extra)
    merged = list(base)
    starts = [p[0] for p in merged]
    for program in extra:
        start, end = program[0], program[1]
        i = bisect.bisect_left(starts, start)
        clash = False
        for j in (i - 1, i, i + 1):
            if 0 <= j < len(merged):
                other = merged[j]
                overlap = min(end, other[1]) - max(start, other[0])
                if overlap > 300:
                    clash = True
                    break
        if not clash:
            merged.insert(i, program)
            starts.insert(i, start)
    return merged


def main():
    config = json.load(open(os.path.join(HERE, "sources.json")))
    os.makedirs(OUT, exist_ok=True)
    merged = {}       # key -> channel dict
    order = []
    report = []
    for source in config["sources"]:
        name, url, shard = source["name"], source["url"], source["shard"]
        started = time.time()
        try:
            path = download(url)
            channels = parse_source(path, bool(source.get("locals")))
            os.unlink(path)
        except Exception as error:  # a dead source shouldn't sink the rest
            report.append({"source": name, "ok": False, "error": str(error)[:200]})
            print(f"!! {name}: {error}", file=sys.stderr)
            continue
        added = filled = 0
        for channel in channels:
            existing = merged.get(channel["key"])
            if existing is None:
                merged[channel["key"]] = {
                    "shard": shard, "names": list(channel["names"]), "signs": list(channel["signs"]),
                    "programs": channel["programs"],
                }
                order.append(channel["key"])
                added += 1
            else:
                for n in channel["names"]:
                    if n not in existing["names"] and len(existing["names"]) < 10:
                        existing["names"].append(n)
                for s in channel["signs"]:
                    if s not in existing["signs"]:
                        existing["signs"].append(s)
                before = len(existing["programs"])
                existing["programs"] = merge_programs(existing["programs"], channel["programs"])
                if len(existing["programs"]) > before:
                    filled += 1
        report.append({
            "source": name, "ok": True, "channels": len(channels), "new": added,
            "gaps_filled": filled, "seconds": round(time.time() - started, 1),
        })
        print(f"== {name}: {len(channels)} channels, {added} new, {filled} gap-filled")

    shards = {}
    for key in order:
        channel = merged[key]
        shards.setdefault(channel["shard"], []).append({
            "n": channel["names"],
            "c": channel["signs"],
            "p": [[p[0] // 60, max(1, (p[1] - p[0]) // 60), p[2], p[3], p[4], p[5]] for p in channel["programs"]],
        })
    sizes = {}
    for shard, channels in shards.items():
        payload = json.dumps({"v": 1, "generated": NOW, "shard": shard, "channels": channels},
                             ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
        data = compressor.compress(payload) + compressor.flush()
        with open(os.path.join(OUT, f"{shard}.json.z"), "wb") as out:
            out.write(data)
        sizes[shard] = {"channels": len(channels), "bytes": len(data), "raw_bytes": len(payload)}
    summary = {"generated": NOW, "shards": sizes, "sources": report}
    with open(os.path.join(OUT, "summary.json"), "w") as out:
        json.dump(summary, out, indent=1)
    print(json.dumps(summary, indent=1))
    if not shards:
        sys.exit("No guide data from any source")


if __name__ == "__main__":
    main()
