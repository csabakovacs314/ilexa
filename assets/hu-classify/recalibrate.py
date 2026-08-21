#!/usr/bin/env python3
"""Recalibration + preprocessing experiment for the NATURALNESS signals.

TWO SEPARATE QUESTIONS, deliberately not conflated:

1. CALIBRATION (midpoint/scale). Fixes only what the numbers MEAN. The
   sigmoid is monotonic, so AUC is mathematically invariant under any
   choice of midpoint/scale -- recalibrating cannot and will not improve
   spam/ham discrimination by even 0.001. It is worth doing anyway because
   the shipped constants were fit against clean prose (0.87-0.92) while
   real mail sits far lower (ham median 0.54), so the published meaning of
   a score is currently wrong.

2. PREPROCESSING. This CAN change AUC, because it changes the underlying
   measurement rather than the transform applied to it. Real mail is not
   prose: it carries URLs, HTML remnants, base64 blobs, quoted-printable
   artifacts, hex ids and signatures. Character trigrams over that soup
   measure artifact density as much as they measure "is the human-written
   text coherent", which is what the signal claims to detect. Each variant
   below strips progressively more non-prose before scoring.

Reports raw avg_logprob percentiles per class (the input to calibration)
and AUC per variant (the only thing that can justify a weight).

PRIVACY: identical to measure_signal_value.py -- text is fetched, scored
in memory, discarded. Only aggregates are printed. Nothing hits disk.

Usage: /opt/hu-classify/venv/bin/python3 recalibrate.py [ham_sample]
"""

import hashlib
import importlib.util
import math
import re
import subprocess
import sys

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

_spec = importlib.util.spec_from_file_location(
    "hu_classify_stub", "/usr/local/sbin/hu-classify-stub.py")
_stub = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_stub)

MAX_CHARS = 4000

# --- preprocessing variants -------------------------------------------------
URL_RE = re.compile(r"https?://\S+|www\.\S+")
EMAIL_RE = re.compile(r"\S+@\S+\.\S+")
LONGTOKEN_RE = re.compile(r"\S{25,}")          # base64 blobs, tracking ids, hashes
NONLETTER_RUN_RE = re.compile(r"[^\w\sáéíóöőúüűÁÉÍÓÖŐÚÜŰ]{2,}")
DIGITS_RE = re.compile(r"\d+")


def prep_raw(text):
    return text


def prep_strip_urls(text):
    text = URL_RE.sub(" ", text)
    text = EMAIL_RE.sub(" ", text)
    return text


def prep_strip_urls_tokens(text):
    text = prep_strip_urls(text)
    text = LONGTOKEN_RE.sub(" ", text)
    return text


def prep_prose_only(text):
    """Most aggressive: keep only what plausibly reads as human prose."""
    text = prep_strip_urls_tokens(text)
    text = NONLETTER_RUN_RE.sub(" ", text)
    text = DIGITS_RE.sub(" ", text)
    return text


VARIANTS = [
    ("raw (shipped)", prep_raw),
    ("strip urls/emails", prep_strip_urls),
    ("+ strip long tokens", prep_strip_urls_tokens),
    ("+ strip punct runs/digits", prep_prose_only),
]


def avg_logprob(text, lang):
    """Raw pre-sigmoid score -- the quantity calibration actually maps."""
    table = _stub._naturalness_tables[lang]
    combined = text.lower().replace("\n", " ").strip()[:MAX_CHARS]
    padded = f"  {combined}  "
    tg = [padded[i:i + 3] for i in range(len(padded) - 2)]
    tg = [t for t in tg if t.strip()]
    if not tg:
        return None
    return sum(table["logprob"].get(t, table["floor"]) for t in tg) / len(tg)


def run_mysql(q):
    r = subprocess.run(["mysql", "-N", "-e", q], capture_output=True, text=True, check=True)
    return [l.split("\t") for l in r.stdout.splitlines() if l]


def fetch_text(uid):
    r = subprocess.run([DOVEADM, "fetch-text", ARCHIVE_USER, "INBOX", str(uid)],
                       capture_output=True, timeout=15)
    return r.stdout.decode("utf-8", errors="replace") if r.returncode == 0 else ""


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
        cs = part.get_content_charset() or "utf-8"
        try:
            txt = payload.decode(cs, errors="replace")
        except LookupError:
            txt = payload.decode("utf-8", errors="replace")
        (plain if ct == "text/plain" else html).append(txt)
    if plain:
        text = "\n".join(plain)
    elif html:
        import html as _h
        text = _h.unescape(HTML_TAG_RE.sub(" ", "\n".join(html)))
    else:
        return ""
    return WHITESPACE_RE.sub(" ", text).strip()


def pct(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    return s[min(len(s) - 1, int(len(s) * p))]


def auc(pos, neg):
    if not pos or not neg:
        return None
    w = t = 0
    for a in pos:
        for b in neg:
            if a > b:
                w += 1
            elif a == b:
                t += 1
    return (w + 0.5 * t) / (len(pos) * len(neg))


def collect(label, uids):
    seen, out = set(), []
    for uid in uids:
        try:
            text = clean(fetch_text(uid))
        except Exception:
            continue
        if len(text) < 20:
            continue
        h = hashlib.sha256(WHITESPACE_RE.sub(" ", text.lower()).encode()).hexdigest()
        if h in seen:
            continue
        seen.add(h)
        rec = {}
        for vname, fn in VARIANTS:
            prepped = fn(text)
            rec[vname] = {lang: avg_logprob(prepped, lang) for lang in ("hu", "en")}
        out.append(rec)
        if len(out) % 100 == 0:
            print(f"  {label}: {len(out)}", file=sys.stderr)
    return out


def main():
    ham_n = int(sys.argv[1]) if len(sys.argv) > 1 else 800
    spam_uids = [r[0] for r in run_mysql(
        "SELECT uid FROM postfix.archive_index WHERE is_spam=1;")]
    ham_uids = [r[0] for r in run_mysql(
        f"SELECT uid FROM postfix.archive_index WHERE is_spam=0 ORDER BY RAND() LIMIT {ham_n};")]
    print(f"fetching {len(spam_uids)} spam / {len(ham_uids)} ham", file=sys.stderr)
    spam = collect("spam", spam_uids)
    ham = collect("ham", ham_uids)
    print(f"\n=== {len(spam)} distinct spam / {len(ham)} distinct ham ===")

    for lang in ("hu", "en"):
        print(f"\n########## {lang.upper()}_NATURALNESS ##########")
        print(f"\n{'variant':28s} {'AUC':>7s}   (0.50 = no information)")
        for vname, _ in VARIANTS:
            sv = [d[vname][lang] for d in spam if d[vname][lang] is not None]
            hv = [d[vname][lang] for d in ham if d[vname][lang] is not None]
            a = auc(sv, hv)
            print(f"{vname:28s} {a:7.3f}")

        # Distribution + suggested calibration for EVERY variant: calibration
        # must map whatever preprocessing actually ships, so the raw-variant
        # numbers are useless once a different variant is chosen.
        for vname, _ in VARIANTS:
            sv = [d[vname][lang] for d in spam if d[vname][lang] is not None]
            hv = [d[vname][lang] for d in ham if d[vname][lang] is not None]
            if not sv or not hv:
                continue
            print(f"\n--- avg_logprob distribution, variant '{vname}' ---")
            print(f"{'':10s} {'p05':>8s} {'p25':>8s} {'p50':>8s} {'p75':>8s} {'p95':>8s}")
            for nm, xs in (("spam", sv), ("ham", hv)):
                print(f"{nm:10s} " + " ".join(f"{pct(xs, p):8.2f}" for p in (.05, .25, .50, .75, .95)))

            allv = sv + hv
            mid = pct(allv, 0.50)
            span = (pct(allv, 0.95) - pct(allv, 0.05)) or 1.0
            scale = max(0.5, span / 4.4)   # +-2.2 sigma over the observed span
            sig = lambda x: 1 / (1 + math.exp(-(x - mid) / scale))
            print(f"suggested calibration: midpoint={mid:.1f}, scale={scale:.1f}"
                  f"   (shipped: -14.0 / 2.3)")
            print(f"  under it: ham p50 -> {sig(pct(hv,.50)):.2f}, "
                  f"spam p50 -> {sig(pct(sv,.50)):.2f}, "
                  f"ham p05 -> {sig(pct(hv,.05)):.2f}, ham p95 -> {sig(pct(hv,.95)):.2f}")


if __name__ == "__main__":
    main()
