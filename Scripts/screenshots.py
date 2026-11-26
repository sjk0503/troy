#!/usr/bin/env python3
"""Regenerates the screenshots in docs/images from the debug build.

The app is started on a temporary database holding the example project, each window is
opened with `--show`, captured with `screencapture`, and the app is quit again. Your own
database is never opened.

    swift build && python3 Scripts/screenshots.py

The terminal this runs in needs Screen Recording permission (System Settings, Privacy &
Security). Windows appear on screen for a few seconds while they are captured. For a check
that needs no permission and shows no window, use `TroyApp --render <scene> --out file.png`.
"""
import os
import re
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, ".build", "debug", "TroyApp")
CLI = os.path.join(ROOT, ".build", "debug", "troy")
OUT = os.path.join(ROOT, "docs", "images")

# The record the windows open on: the sync engine task of the example project.
SELECTED = "6"
# (window to show, file name, seconds to let it settle, record to select or None for none)
SHOTS = [
    ("main", "overview", 2.5, SELECTED),
    ("graph", "graph", 4.5, SELECTED),
    ("panel", "panel", 2.0, SELECTED),
    ("overview", "project-brief", 2.5, None),
    ("local-graph", "local-graph", 4.5, SELECTED),
]


def capture(database, language, show, name, settle, select):
    suffix = "" if language == "en" else "-" + language
    target = os.path.join(OUT, name + suffix + ".png")
    log = tempfile.NamedTemporaryFile("w+", suffix=".log", delete=False)
    app = subprocess.Popen(
        [APP, "--db", database, "--show", show] + (["--select", select] if select else [])
        + ["--lang", language],
        stdout=log, stderr=subprocess.STDOUT)
    try:
        window = None
        for _ in range(80):
            time.sleep(0.25)
            with open(log.name) as handle:
                found = re.search(r"WINDOW (\d+) ", handle.read())
            if found:
                window = found.group(1)
                break
        if window is None:
            print(f"{name}{suffix}: the app reported no window", file=sys.stderr)
            return False
        time.sleep(settle)
        done = subprocess.run(["screencapture", "-x", "-o", "-l", window, target], capture_output=True, text=True)
        if done.returncode != 0 or not os.path.exists(target):
            print(f"{name}{suffix}: screencapture failed: {done.stderr.strip()}", file=sys.stderr)
            return False
        print(os.path.relpath(target, ROOT))
        return True
    finally:
        app.terminate()
        try:
            app.wait(timeout=5)
        except subprocess.TimeoutExpired:
            app.kill()
        os.unlink(log.name)


def main():
    for binary in (APP, CLI):
        if not os.path.exists(binary):
            sys.exit(f"{os.path.relpath(binary, ROOT)} is missing; run `swift build` first.")
    os.makedirs(OUT, exist_ok=True)
    ok = True
    with tempfile.TemporaryDirectory(prefix="troy-screenshots-") as folder:
        for language in ("en", "ko"):
            database = os.path.join(folder, language + ".db")
            seed = [CLI, "--db", database, "demo"] + (["--korean"] if language == "ko" else [])
            subprocess.run(seed, check=True, stdout=subprocess.DEVNULL)
            for show, name, settle, select in SHOTS:
                ok = capture(database, language, show, name, settle, select) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
