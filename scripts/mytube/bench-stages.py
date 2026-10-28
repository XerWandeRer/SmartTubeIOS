#!/usr/bin/env python3
"""Summarises PlaybackProbe stage records from one `log stream --style compact` file.

usage: bench-stages.py <log> <videoId> [label]

Prints one TSV row: label, video, then the time since `PROBE event=start` (log timestamps,
ms) at which each startup step finished, plus the step's own duration where it is logged.
Steps that did not happen print "-". Proxy records carry no video ID, so only those after
this video's start record count.
"""
import re
import sys
from datetime import datetime

COLUMNS = [
    # (column, stage, value): value "at" = ms since start, "dur" = the step's own duration
    ("potoken", "potoken", "dur"),
    ("cache", "cache", "at"),
    ("seed", "visitor_seed", "dur"),
    ("player", "player", "dur"),
    ("player_at", "player", "at"),
    ("master", "master_parse", "dur"),
    ("item_at", "item", "at"),
    ("pxy_master", "proxy_master", "at"),
    ("pxy_playlist", "proxy_playlist", "at"),
    ("pxy_seg1", "proxy_segment", "at"),
    ("ready", "ready", "at"),
]
HEADER = ["label", "video", "result", "source", "path"] + [c for c, _, _ in COLUMNS] + ["n_master", "n_playlist"]

STAMP = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)")


def parse(path, video):
    start = None
    stages = {}
    counts = {"proxy_master": 0, "proxy_playlist": 0}
    result, source, item_path = "timeout", "-", "-"
    with open(path, errors="replace") as fh:
        for line in fh:
            if "PROBE event=" not in line:
                continue
            m = STAMP.match(line)
            if not m:
                continue
            t = datetime.strptime(m.group(1)[:26], "%Y-%m-%d %H:%M:%S.%f")
            rec = dict(re.findall(r"(\w+)=(\S+)", line.split("PROBE ", 1)[1]))
            vid = rec.get("video")
            if rec.get("event") == "start" and vid == video:
                start, stages = t, {}
                counts = {k: 0 for k in counts}
                continue
            if start is None or vid not in (video, "-"):
                continue
            at = int((t - start).total_seconds() * 1000)
            event = rec.get("event")
            if event == "stage":
                name = rec.get("stage", "?")
                if name in counts:
                    counts[name] += 1
                if name in stages:  # first occurrence wins
                    continue
                stages[name] = {"at": at, "dur": rec.get("dur", "-")}
                if name == "player":
                    source = rec.get("source", "-")
                if name == "item":
                    item_path = rec.get("path", "-")
            elif event in ("ready", "error") and "ready" not in stages:
                result = event
                stages["ready"] = {"at": int(rec.get("ms", at)), "dur": "-"}
    row = [result, source, item_path]
    for _, stage, value in COLUMNS:
        row.append(str(stages[stage][value]) if stage in stages else "-")
    row += [str(counts["proxy_master"]), str(counts["proxy_playlist"])]
    return row


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--header":
        print("\t".join(HEADER))
        return
    path, video = sys.argv[1], sys.argv[2]
    label = sys.argv[3] if len(sys.argv) > 3 else "-"
    print("\t".join([label, video] + parse(path, video)))


if __name__ == "__main__":
    main()
