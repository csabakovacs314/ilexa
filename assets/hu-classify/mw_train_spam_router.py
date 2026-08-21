#!/usr/bin/env python3
"""Retrain the HU_SPAM router from the MailScanner archive.

The 2026-08-18 HU_SPAM attempt died on data volume: the live archive holds
only 77 genuinely distinct spam messages, and the honest held-out accuracy
(42.3%) was WORSE than always guessing ham (90.9%). The retired MailScanner
archive ([[mailwatch_archive_corpus]]) has ~3-4k distinct spam with full
bodies, which is the one thing that was missing.

METHOD, unchanged from build_spam_router.py because the method was never
the problem:
  - word-presence (Bernoulli) Naive-Bayes log-odds, Laplace-smoothed, an
    inspectable table rather than a black box;
  - deduplicate by content hash BEFORE the train/test split -- the original
    95.95% was pure duplicate leakage across the split;
  - report held-out accuracy against the trivial always-majority baseline,
    and treat "cannot beat the baseline" as a result to report, not to
    massage.

WHAT CHANGED: the corpus is streamed from Postfix queue files instead of a
corpus directory, so per the operator's standing instruction NOTHING is
persisted except the final aggregate model. There is no corpus dir to
delete afterwards.

BALANCE: trains on equal numbers of spam and ham. The trivial baseline is
then 50%, so any accuracy above ~50% is real signal rather than an artefact
of class imbalance -- the previous run's 90.9% "baseline" made the result
hard to read at a glance.

Usage: mw_train_spam_router.py [n_each]
"""

import email
import hashlib
import json
import math
import random
import re
import subprocess
import sys

ARCHIVE = "/var/spool/MailScanner/archive"
OUT_PATH = "/opt/hu-classify/models/hu_spam_router.json"
WORD_RE = re.compile(r"[a-záéíóöőúüűA-ZÁÉÍÓÖŐÚÜŰ]{2,}")
WHITESPACE_RE = re.compile(r"\s+")
HTML_TAG_RE = re.compile(r"<[^>]+>")
MAX_CHARS = 4000


def run_mysql(q):
    r = subprocess.run(["mysql", "-N", "-e", q], capture_output=True, text=True, check=True)
    return [l.split("\t") for l in r.stdout.splitlines() if l]


def read_body(path):
    try:
        r = subprocess.run(["postcat", path], capture_output=True, timeout=20)
    except subprocess.TimeoutExpired:
        return ""
    if r.returncode != 0:
        return ""
    out = r.stdout.decode("utf-8", errors="replace")
    i = out.find("*** MESSAGE CONTENTS")
    if i == -1:
        return ""
    body = out[out.find("\n", i) + 1:]
    end = body.find("*** HEADER EXTRACTED")
    if end != -1:
        body = body[:end]

    try:
        msg = email.message_from_string(body)
    except Exception:
        return ""
    plain, html = [], []
    for part in msg.walk():
        if part.is_multipart():
            continue
        ct = part.get_content_type()
        if ct not in ("text/plain", "text/html"):
            continue
        try:
            payload = part.get_payload(decode=True)
        except Exception:
            continue
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
        return ""
    subj = str(msg.get("Subject", "") or "")
    return WHITESPACE_RE.sub(" ", subj + " " + text).strip()


def collect(is_spam, want, label):
    """Stream, dedup, and reduce each message to its word SET immediately --
    the text itself never leaves this loop."""
    pool = int(want * (3.0 if is_spam else 1.3)) + 500
    rows = run_mysql(
        f"SELECT id, DATE_FORMAT(timestamp,'%Y%m%d') FROM mailscanner.maillog "
        f"WHERE isspam={is_spam} AND isfp=0 AND timestamp>='2026-01-01' "
        f"ORDER BY RAND() LIMIT {pool};")
    seen, docs = set(), []
    for n, (mid, d) in enumerate(rows, 1):
        if len(docs) >= want:
            break
        text = read_body(f"{ARCHIVE}/{d}/{mid}")
        if len(text) < 20:
            continue
        text = text[:MAX_CHARS].lower()
        h = hashlib.sha256(WHITESPACE_RE.sub(" ", text).encode()).hexdigest()
        if h in seen:
            continue
        seen.add(h)
        words = set(WORD_RE.findall(text))
        if words:
            docs.append(words)
        if len(docs) % 250 == 0:
            print(f"  {label}: {len(docs)} distinct (from {n} read)", file=sys.stderr, flush=True)
    print(f"  {label}: {len(docs)} distinct from {len(rows)} candidates",
          file=sys.stderr, flush=True)
    return docs


def train(spam, ham):
    vocab = {}
    for docs, key in ((spam, "spam"), (ham, "ham")):
        for words in docs:
            for w in words:
                vocab.setdefault(w, {"spam": 0, "ham": 0})[key] += 1
    n_s, n_h, alpha = len(spam), len(ham), 1.0
    log_odds = {}
    for w, c in vocab.items():
        if c["spam"] + c["ham"] < 3:
            continue
        p_s = (c["spam"] + alpha) / (n_s + 2 * alpha)
        p_h = (c["ham"] + alpha) / (n_h + 2 * alpha)
        lo = math.log(p_s / p_h)
        if abs(lo) > 0.05:
            log_odds[w] = round(lo, 4)
    prior = math.log(n_s / n_h) if n_h else 0.0
    return log_odds, prior


def score(words, lo, prior):
    return 1.0 / (1.0 + math.exp(-(prior + sum(lo.get(w, 0.0) for w in words))))


def evaluate(spam, ham, lo, prior, thr=0.5):
    tp = sum(1 for w in spam if score(w, lo, prior) >= thr)
    fn = len(spam) - tp
    fp = sum(1 for w in ham if score(w, lo, prior) >= thr)
    tn = len(ham) - fp
    tot = tp + fn + fp + tn
    return {
        "tp": tp, "fp": fp, "tn": tn, "fn": fn,
        "accuracy": (tp + tn) / tot if tot else 0.0,
        "precision": tp / (tp + fp) if (tp + fp) else 0.0,
        "recall": tp / (tp + fn) if (tp + fn) else 0.0,
    }


def main():
    n_each = int(sys.argv[1]) if len(sys.argv) > 1 else 1500
    random.seed(20260818)

    print(f"collecting up to {n_each} distinct of each class", file=sys.stderr, flush=True)
    spam = collect(1, n_each, "spam")
    ham = collect(0, n_each, "ham")

    # Balance so the trivial baseline is 50% and the numbers read honestly.
    k = min(len(spam), len(ham))
    spam, ham = spam[:k], ham[:k]
    print(f"\nbalanced to {k} spam / {k} ham (trivial baseline = 50.0%)")

    random.shuffle(spam)
    random.shuffle(ham)
    cut = int(k * 0.8)
    s_tr, s_te = spam[:cut], spam[cut:]
    h_tr, h_te = ham[:cut], ham[cut:]
    print(f"train {len(s_tr)}+{len(h_tr)}, held out {len(s_te)}+{len(h_te)}")

    lo, prior = train(s_tr, h_tr)
    print(f"vocabulary kept: {len(lo)} words")

    te = evaluate(s_te, h_te, lo, prior)
    tr = evaluate(s_tr, h_tr, lo, prior)
    print(f"\nTRAIN: acc {tr['accuracy']*100:.1f}%  prec {tr['precision']*100:.1f}%  rec {tr['recall']*100:.1f}%")
    print(f"HELD OUT (honest): acc {te['accuracy']*100:.1f}%  prec {te['precision']*100:.1f}%  "
          f"rec {te['recall']*100:.1f}%   tp={te['tp']} fp={te['fp']} tn={te['tn']} fn={te['fn']}")
    print(f"trivial always-one-class baseline: 50.0%")

    # Threshold sweep against the REAL traffic mix. Balanced-set accuracy is
    # the honest way to compare against a baseline, but it is NOT what the
    # signal would do in production: this host's mail is ~9% spam, so a
    # false-positive rate that looks small against 50% ham becomes dominant
    # against 91% ham. At threshold 0.5 the balanced set says 80% accuracy
    # while production precision would be ~45% -- i.e. most hits would be
    # legitimate mail. Report the threshold that is actually deployable.
    SPAM_BASE = 0.09
    print("\nthreshold sweep (projected onto ~9% spam / 91% ham real traffic):")
    print(f"  {'thr':>5s} {'recall':>7s} {'FPR':>7s} {'prod.precision':>15s}  per 1000 msgs")
    best = None
    for thr in (0.5, 0.7, 0.8, 0.9, 0.95, 0.98, 0.99):
        m = evaluate(s_te, h_te, lo, prior, thr)
        rec_ = m["tp"] / (m["tp"] + m["fn"]) if (m["tp"] + m["fn"]) else 0.0
        fpr_ = m["fp"] / (m["fp"] + m["tn"]) if (m["fp"] + m["tn"]) else 0.0
        TP, FP = 1000 * SPAM_BASE * rec_, 1000 * (1 - SPAM_BASE) * fpr_
        prec_ = TP / (TP + FP) if (TP + FP) else 0.0
        print(f"  {thr:5.2f} {rec_*100:6.1f}% {fpr_*100:6.1f}% {prec_*100:14.0f}%"
              f"  {TP:5.0f} spam / {FP:5.0f} ham wrongly flagged")
        if prec_ >= 0.90 and best is None:
            best = (thr, rec_, prec_)
    if best:
        print(f"  -> usable as a scored signal at threshold {best[0]:.2f}: "
              f"{best[1]*100:.0f}% of spam, {best[2]*100:.0f}% production precision")
    else:
        print("  -> NO threshold reaches 90% production precision; usable only as a "
              "low-weight contributing feature, never a standalone rule")

    verdict = ("USABLE — clearly beats the balanced baseline"
               if te['accuracy'] >= 0.75 else
               "MARGINAL — beats baseline but not by much"
               if te['accuracy'] >= 0.60 else
               "NOT USABLE — at or near the baseline")
    print(f"VERDICT: {verdict}")

    final_lo, final_prior = train(spam, ham)
    model = {
        "log_odds": final_lo,
        "prior_log_odds": round(final_prior, 4),
        "n_spam_train": len(spam),
        "n_ham_train": len(ham),
        "held_out_test_metrics": te,
        "held_out_baseline_accuracy": 0.5,
        "source": "mailscanner archive 2026-01-01..2026-08-05, deduplicated, balanced",
        "built": "2026-08-18",
    }
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump(model, f, ensure_ascii=False)
    print(f"\nwrote {OUT_PATH} ({len(final_lo)} words). NOT wired into the live "
          f"service -- that is a separate, deliberate step.")


if __name__ == "__main__":
    main()
