#!/usr/bin/env python3
"""Survey the retired MailWatch/MailScanner archive: how much GENUINELY
DISTINCT labelled spam is actually in there?

Context: every previous attempt at a trained HU_SPAM signal died on a
data-volume wall -- the live archive holds only 77 genuinely distinct spam
messages once near-identical resent campaigns are collapsed. The retired
MailScanner archive (/var/spool/MailScanner/archive, 44GB, ~97k Postfix
queue files) joins 1:1 to mailscanner.maillog, which carries an isspam
label per message. That is potentially 25,106 labelled spam instead of 77.

The number that matters is NOT 25,106. It is how many remain after
deduplication, because 82% of the live archive's "spam" turned out to be
16 resent campaigns, and duplicates on both sides of a train/test split
are exactly what inflated the first HU_SPAM result to a fake 95.95%.
This script answers that question on a sample before anyone commits to a
full extraction.

PRIVACY: reads real mail (both spam and ham) but persists NOTHING except
the aggregate counts printed at the end. No corpus directory is created.

Usage: mw_survey.py [n_spam] [n_ham]
"""

import email
import hashlib
import re
import subprocess
import sys
from collections import Counter

ARCHIVE = "/var/spool/MailScanner/archive"
WHITESPACE_RE = re.compile(r"\s+")
HTML_TAG_RE = re.compile(r"<[^>]+>")


def run_mysql(q):
    r = subprocess.run(["mysql", "-N", "-e", q], capture_output=True, text=True, check=True)
    return [l.split("\t") for l in r.stdout.splitlines() if l]


def read_message(path):
    """postcat renders a Postfix queue file; the RFC822 message follows the
    envelope/header record dump, so take everything from the first blank
    line after the *MESSAGE CONTENTS* marker."""
    r = subprocess.run(["postcat", path], capture_output=True, timeout=20)
    if r.returncode != 0:
        return ""
    out = r.stdout.decode("utf-8", errors="replace")
    marker = "*** MESSAGE CONTENTS"
    i = out.find(marker)
    if i == -1:
        return ""
    j = out.find("\n", i)
    body = out[j + 1:]
    end = body.find("*** HEADER EXTRACTED")
    if end != -1:
        body = body[:end]
    return body


def clean(raw):
    msg = email.message_from_string(raw)
    plain, html = [], []
    for part in msg.walk():
        if part.is_multipart():
            continue
        ct = part.get_content_type()
        if ct not in ("text/plain", "text/html"):
            continue
        payload = part.get_payload(decode=True)
        if payload is None:
            continue
        cs = part.get_content_charset() or "utf-8"
        try:
            txt = payload.decode(cs, errors="replace")
        except (LookupError, UnicodeDecodeError):
            txt = payload.decode("utf-8", errors="replace")
        (plain if ct == "text/plain" else html).append(txt)
    if plain:
        text = "\n".join(plain)
    elif html:
        import html as _h
        text = _h.unescape(HTML_TAG_RE.sub(" ", "\n".join(html)))
    else:
        return "", ""
    subj = str(msg.get("Subject", "") or "")
    return subj, WHITESPACE_RE.sub(" ", text).strip()


def survey(label, is_spam, n):
    rows = run_mysql(
        f"SELECT id, DATE_FORMAT(timestamp,'%Y%m%d') FROM mailscanner.maillog "
        f"WHERE isspam={is_spam} AND isfp=0 AND timestamp>='2026-01-01' "
        f"ORDER BY RAND() LIMIT {n};")
    seen = set()
    n_read = n_empty = n_dup = 0
    subj_hashes = Counter()
    for mid, d in rows:
        path = f"{ARCHIVE}/{d}/{mid}"
        try:
            subj, text = clean(read_message(path))
        except Exception:
            continue
        if len(text) < 20:
            n_empty += 1
            continue
        n_read += 1
        h = hashlib.sha256(WHITESPACE_RE.sub(" ", text.lower()).encode()).hexdigest()
        if h in seen:
            n_dup += 1
        else:
            seen.add(h)
        subj_hashes[hashlib.sha256(subj.lower().encode()).hexdigest()] += 1

    distinct = len(seen)
    rate = distinct / n_read if n_read else 0
    print(f"\n=== {label} ===")
    print(f"  sampled            : {len(rows)}")
    print(f"  usable text        : {n_read}   (too short/unparsable: {n_empty})")
    print(f"  DISTINCT after dedup: {distinct}   ({100*rate:.1f}% of usable)")
    print(f"  exact-dup copies   : {n_dup}")
    print(f"  distinct subjects  : {len(subj_hashes)}")
    top = subj_hashes.most_common(3)
    if top and top[0][1] > 1:
        print(f"  largest subject cluster: {top[0][1]} messages")
    return rate


def main():
    n_spam = int(sys.argv[1]) if len(sys.argv) > 1 else 600
    n_ham = int(sys.argv[2]) if len(sys.argv) > 2 else 400

    tot = run_mysql("SELECT SUM(isspam=1), SUM(isspam=0) FROM mailscanner.maillog "
                    "WHERE isfp=0 AND timestamp>='2026-01-01';")[0]
    total_spam, total_ham = int(tot[0]), int(tot[1])
    print(f"population in archive range: {total_spam} spam / {total_ham} ham")

    sr = survey("SPAM", 1, n_spam)
    hr = survey("HAM", 0, n_ham)

    print(f"\n=== EXTRAPOLATION (the number that decides whether this is worth it) ===")
    print(f"  est. distinct spam available: {int(total_spam * sr):,}"
          f"   (vs 77 in the live archive)")
    print(f"  est. distinct ham available : {int(total_ham * hr):,}")
    print("\nNote: extrapolating a dedup rate from a random sample UNDERSTATES")
    print("duplication -- a random 600 of 25k rarely catches both copies of a")
    print("pair, so the true distinct count is lower than this estimate.")


if __name__ == "__main__":
    main()
