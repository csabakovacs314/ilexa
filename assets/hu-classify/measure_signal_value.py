#!/usr/bin/env python3
"""Retrospective measurement: do the four live shadow-mode signals actually
separate spam from ham on THIS host's real mail?

Answers the question the 2-week forward observation window was meant to
answer, but against mail that ALREADY has labels -- rspamd's own is_spam
verdict on every archived message. No waiting required.

PRIVACY: strictly less invasive than the earlier HU_SPAM corpus extraction.
Message text is fetched, scored in memory, and DISCARDED immediately --
nothing is ever written to disk except the aggregate statistics printed at
the end. There is no corpus directory to clean up afterwards.

DEDUPLICATION: mandatory, and applied BEFORE any statistic is computed.
2026-08-18's HU_SPAM attempt was inflated to a fake 95.95% accuracy because
82% of "spam" was 16 near-identical resent campaigns. The same trap would
skew a correlation measurement: 40 copies of one obfuscated campaign would
look like a strong signal from a sample size of one. Dedup key is a sha256
of whitespace-normalized text, same as build_spam_router.py.

WHAT "USEFUL" MEANS HERE: a signal earns a weight only if its distribution
differs materially between spam and ham. Reported per signal:
  - mean/median per class
  - AUC (probability a random spam scores higher than a random ham).
    0.50 = no information whatsoever. <0.55 is noise for this purpose.
  - the practical question for NATURALNESS specifically: how many spam
    messages actually score LOW (obfuscated), since that is the only case
    where it can contribute anything.

Usage: /opt/hu-classify/venv/bin/python3 measure_signal_value.py [ham_sample]
"""

import hashlib
import json
import re
import subprocess
import sys

sys.path.insert(0, "/usr/local/sbin")

DOVEADM = "/usr/local/sbin/qa-doveadm.sh"
def _archive_user():
    """Derive the archive mailbox from the doveadm gateway rather than
    hardcoding it. qa-doveadm.sh is rendered per host by the installer and
    is already a hard dependency of these tools, so it is the one place
    guaranteed to hold the right value -- a hardcoded address silently
    fetches nothing on every host but the one it was written on."""
    try:
        with open(DOVEADM) as f:
            m = re.search(r'^ARCHIVE_USER="([^"]+)"', f.read(), re.M)
        if m:
            return m.group(1)
    except OSError:
        pass
    sys.exit(f"could not read ARCHIVE_USER from {DOVEADM} -- is the console installed?")


ARCHIVE_USER = _archive_user()
WHITESPACE_RE = re.compile(r"\s+")
HTML_TAG_RE = re.compile(r"<[^>]+>")

# Import the LIVE scoring code rather than reimplementing it -- a
# reimplementation that drifts from the deployed service would measure
# something the running system does not actually compute.
import importlib.util

_spec = importlib.util.spec_from_file_location(
    "hu_classify_stub", "/usr/local/sbin/hu-classify-stub.py"
)
_stub = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_stub)


def run_mysql(query):
    r = subprocess.run(["mysql", "-N", "-e", query], capture_output=True, text=True, check=True)
    return [line.split("\t") for line in r.stdout.splitlines() if line]


def fetch_text(uid):
    r = subprocess.run(
        [DOVEADM, "fetch-text", ARCHIVE_USER, "INBOX", str(uid)],
        capture_output=True, timeout=15,
    )
    if r.returncode != 0:
        return ""
    return r.stdout.decode("utf-8", errors="replace")


def clean(raw):
    import email as _email
    lines = raw.splitlines()
    if lines and lines[0].strip() == "text:":
        lines = lines[1:]
    msg = _email.message_from_string("\n".join(lines))
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
        charset = part.get_content_charset() or "utf-8"
        try:
            txt = payload.decode(charset, errors="replace")
        except LookupError:
            txt = payload.decode("utf-8", errors="replace")
        (plain if ct == "text/plain" else html).append(txt)
    if plain:
        text = "\n".join(plain)
    elif html:
        import html as _html
        text = _html.unescape(HTML_TAG_RE.sub(" ", "\n".join(html)))
    else:
        return "", ""
    subject = msg.get("Subject", "") or ""
    return subject, WHITESPACE_RE.sub(" ", text).strip()


SIGNALS = ("hu_language", "hu_naturalness", "en_language", "en_naturalness")


def score_all(subject, text):
    return {
        "hu_language": _stub.detect_language_score(subject, text, "hu"),
        "hu_naturalness": _stub.score_naturalness(subject, text, "hu"),
        "en_language": _stub.detect_language_score(subject, text, "en"),
        "en_naturalness": _stub.score_naturalness(subject, text, "en"),
    }


def auc(pos, neg):
    """Probability a random positive outranks a random negative. Ties count
    half, which matters here: these signals produce exact 0.0 constantly."""
    if not pos or not neg:
        return None
    wins = ties = 0
    for p in pos:
        for n in neg:
            if p > n:
                wins += 1
            elif p == n:
                ties += 1
    return (wins + 0.5 * ties) / (len(pos) * len(neg))


def median(xs):
    if not xs:
        return None
    s = sorted(xs)
    m = len(s) // 2
    return s[m] if len(s) % 2 else (s[m - 1] + s[m]) / 2


def collect(label, uids):
    seen, out = set(), []
    for uid in uids:
        try:
            subject, text = clean(fetch_text(uid))
        except Exception as e:
            print(f"  {label} uid={uid}: parse error, skipped: {e}", file=sys.stderr)
            continue
        if len(text) < 20:
            continue
        h = hashlib.sha256(WHITESPACE_RE.sub(" ", text.lower()).encode()).hexdigest()
        if h in seen:
            continue
        seen.add(h)
        out.append(score_all(subject, text))
        # text goes out of scope here and is never persisted
        if len(out) % 100 == 0:
            print(f"  {label}: {len(out)} distinct scored", file=sys.stderr)
    return out


def main():
    ham_sample = int(sys.argv[1]) if len(sys.argv) > 1 else 800

    spam_uids = [r[0] for r in run_mysql(
        "SELECT uid FROM postfix.archive_index WHERE is_spam=1;")]
    ham_uids = [r[0] for r in run_mysql(
        f"SELECT uid FROM postfix.archive_index WHERE is_spam=0 "
        f"ORDER BY RAND() LIMIT {ham_sample};")]

    print(f"fetching {len(spam_uids)} spam / {len(ham_uids)} sampled ham "
          f"(text scored in memory, never written to disk)", file=sys.stderr)

    spam = collect("spam", spam_uids)
    ham = collect("ham", ham_uids)

    print(f"\n=== after dedup: {len(spam)} distinct spam / {len(ham)} distinct ham ===\n")

    print(f"{'signal':18s} {'spam mean':>10s} {'ham mean':>10s} "
          f"{'spam med':>9s} {'ham med':>9s} {'AUC':>7s}  verdict")
    for sig in SIGNALS:
        sv = [d[sig] for d in spam]
        hv = [d[sig] for d in ham]
        a = auc(sv, hv)
        sm = sum(sv) / len(sv) if sv else 0
        hm = sum(hv) / len(hv) if hv else 0
        if a is None:
            verdict = "no data"
        elif abs(a - 0.5) < 0.05:
            verdict = "NO SIGNAL — keep weight 0"
        elif abs(a - 0.5) < 0.10:
            verdict = "marginal, not worth a weight"
        else:
            verdict = f"real separation ({'spam' if a > 0.5 else 'ham'}-leaning)"
        print(f"{sig:18s} {sm:10.4f} {hm:10.4f} "
              f"{median(sv):9.4f} {median(hv):9.4f} {a:7.3f}  {verdict}")

    # The only case where NATURALNESS can contribute at all.
    print("\n=== obfuscation check: how much mail actually scores LOW? ===")
    for sig in ("hu_naturalness", "en_naturalness"):
        for thr in (0.3, 0.5):
            s_lo = sum(1 for d in spam if d[sig] < thr)
            h_lo = sum(1 for d in ham if d[sig] < thr)
            print(f"{sig:18s} < {thr}: {s_lo:4d}/{len(spam)} spam "
                  f"({100*s_lo/max(len(spam),1):5.1f}%)  "
                  f"{h_lo:4d}/{len(ham)} ham ({100*h_lo/max(len(ham),1):5.1f}%)")


if __name__ == "__main__":
    main()
