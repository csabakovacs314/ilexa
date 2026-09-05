#!/usr/bin/env python3
"""Regenerate CHANGELOG.md from RELEASES.json.

RELEASES.json is the signed, machine-readable record the update client already
consumes, so it is the single source of truth for what shipped when. Writing a
changelog by hand alongside it would just be a second copy free to drift.

The installer itself is not versioned -- it ships with whatever release it
carries -- so notable installer-side changes live in a hand-written section
below the generated one, delimited so regeneration never eats them.

  tools/gen-changelog.py [--check]     --check exits 1 if the file is stale
"""
import json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARK = "<!-- generated-from-releases-json: do not edit above this line -->"

def build() -> str:
    rel = json.load(open(os.path.join(ROOT, "RELEASES.json")))["releases"]
    out = ["# Changelog", "",
           "Console releases, newest first. Generated from `RELEASES.json` by",
           "`tools/gen-changelog.py` -- edit the notes there, not here.", ""]
    for r in rel:
        sev = {"security": "security", "fix": "fix", "feature": "feature"}.get(r.get("severity", ""), r.get("severity", ""))
        head = f"## {r['version']} ({r.get('codename','')}) — {r.get('released_at','')}"
        out.append(head.replace(" ()", ""))
        bits = [f"`{sev}`"]
        if r.get("requires_installer"):
            bits.append("**requires a full installer run**")
        out.append(" · ".join(bits))
        out.append("")
        note = (r.get("notes_en") or "").strip()
        out.append(note if note else "_No notes recorded._")
        out.append("")
    out.append(MARK)
    return "\n".join(out) + "\n"

def main() -> int:
    path = os.path.join(ROOT, "CHANGELOG.md")
    new = build()
    tail = ""
    if os.path.exists(path):
        old = open(path, encoding="utf-8").read()
        if MARK in old:
            # strip() both ends: build() already emits a newline after MARK, and
            # without normalising here that newline is absorbed into the tail on
            # every run, so the file grew by one blank line each time and --check
            # never agreed with itself.
            tail = old.split(MARK, 1)[1].strip("\n")
    combined = new + ("\n" + tail + "\n" if tail else "")
    if "--check" in sys.argv:
        cur = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        if cur != combined:
            print("gen-changelog: CHANGELOG.md is stale -- run tools/gen-changelog.py", file=sys.stderr)
            return 1
        print(f"gen-changelog: CHANGELOG.md current ({len(json.load(open(os.path.join(ROOT,'RELEASES.json')))['releases'])} releases)")
        return 0
    open(path, "w", encoding="utf-8").write(combined)
    print(f"gen-changelog: wrote CHANGELOG.md")
    return 0

if __name__ == "__main__":
    sys.exit(main())
