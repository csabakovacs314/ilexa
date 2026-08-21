#!/usr/bin/env python3
"""Teach rspamd Bayes from the retired MailScanner archive, measured.

WHY THIS EXISTS. rspamd's Bayes on this host was trained on 2040 spam /
2901 ham. The retired MailScanner archive holds ~25k labelled spam and
~69k labelled ham with FULL message bodies (Postfix queue files under
/var/spool/MailScanner/archive, joining 1:1 to mailscanner.maillog.id),
covering 2026-01-01..2026-08-05 -- a period that does NOT overlap the live
archive (2026-08-05 onward), so all of it is new to rspamd.

FOUR THINGS THIS DOES DELIBERATELY, each guarding a real failure mode:

1. DEDUPLICATES before teaching. ~50% of that spam is resent campaigns --
   one subject cluster appeared 32 times in a 600-message sample. Teaching
   32 copies does not teach a campaign 32 times better, it over-weights
   that campaign's tokens and skews the classifier. Dedup key is a sha256
   of whitespace-normalised body text.

2. TEACHES BALANCED. Bayes degrades when one class dominates. Spam and ham
   are taught in equal numbers, so the post-teach ratio stays sane rather
   than becoming ~12:1 spam.

3. EXCLUDES KNOWN FALSE POSITIVES (isfp=1). These are messages a human
   already flagged as wrongly-marked-spam; teaching them as spam actively
   trains in the mistake.

4. MEASURES ON A HELD-OUT SET the model never sees. A held-out slice of
   both classes is scanned BEFORE and AFTER teaching, and the two runs are
   compared. Without this there is no way to distinguish "Bayes improved"
   from "the counters went up", which is the whole point of the exercise.

PRIVACY: per the operator's explicit instruction, message text is NEVER
persisted. Every message is streamed (postcat -> parse -> use -> discard);
rspamc is fed on STDIN rather than via temp files. Nothing but ids, hashes
and aggregate counts exists outside of memory at any point.

Usage: mw_teach_bayes.py [n_each] [n_test] [--dry-run]
  n_each   distinct messages of EACH class to teach (default 5000)
  n_test   held-out messages of EACH class for measurement (default 250)
  --dry-run  select and measure baseline, but do not teach
"""

import email
import hashlib
import re
import subprocess
import sys

ARCHIVE = "/var/spool/MailScanner/archive"
WHITESPACE_RE = re.compile(r"\s+")
HTML_TAG_RE = re.compile(r"<[^>]+>")
ACTION_RE = re.compile(r"^Action: (.+)$", re.M)
SCORE_RE = re.compile(r"^Score: (-?[\d.]+) /", re.M)
SYMBOL_RE = re.compile(r"^Symbol: (BAYES_\w+)", re.M)


def run_mysql(q):
    r = subprocess.run(["mysql", "-N", "-e", q], capture_output=True, text=True, check=True)
    return [l.split("\t") for l in r.stdout.splitlines() if l]


SENDER_RE = re.compile(r"^sender: (.+)$", re.M)
RCPT_RE = re.compile(r"^recipient: (.+)$", re.M)
CLIENTIP_RE = re.compile(r"^named_attribute: client_address=(.+)$", re.M)
HELO_RE = re.compile(r"^named_attribute: helo_name=(.+)$", re.M)


def read_raw(path):
    """Extract the RFC822 message AND its original SMTP envelope from a
    Postfix queue file.

    The envelope is not a nicety. Scanning a bare message body means rspamd
    sees no client IP, no HELO and no envelope sender, so SPF cannot
    evaluate at all (every message comes back R_SPF_NA) and DMARC collapses
    to policy failures -- which silently inflated legitimate mail's score
    and made an early measurement run look like an 18% false-positive rate
    that does not exist in reality. Queue files carry the real connection
    metadata, so feed it back via rspamc --ip/--from/--rcpt/--helo and
    measure something close to how the message was actually judged on
    arrival.

    Returns (message_text, envelope_dict).
    """
    try:
        r = subprocess.run(["postcat", path], capture_output=True, timeout=20)
    except subprocess.TimeoutExpired:
        return "", {}
    if r.returncode != 0:
        return "", {}
    out = r.stdout.decode("utf-8", errors="replace")
    i = out.find("*** MESSAGE CONTENTS")
    if i == -1:
        return "", {}

    head = out[:i]
    env = {}
    for key, rx in (("from", SENDER_RE), ("rcpt", RCPT_RE),
                    ("ip", CLIENTIP_RE), ("helo", HELO_RE)):
        m = rx.search(head)
        if m and m.group(1).strip():
            env[key] = m.group(1).strip()

    j = out.find("\n", i)
    body = out[j + 1:]
    end = body.find("*** HEADER EXTRACTED")
    if end != -1:
        body = body[:end]
    return body.strip(), env


def envelope_args(env):
    args = []
    for flag, key in (("--ip", "ip"), ("-F", "from"), ("-r", "rcpt"), ("--helo", "helo")):
        if env.get(key):
            args += [flag, env[key]]
    return args


def body_text(raw):
    """Decoded body text, used ONLY for the dedup hash."""
    try:
        msg = email.message_from_string(raw)
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
    return WHITESPACE_RE.sub(" ", text).strip()


def select_distinct(is_spam, want, label):
    """Stream candidates, keep the first message of each distinct body.
    Returns [(id, datedir)] -- ids only, never text."""
    # Over-fetch: roughly half of spam is duplicated, ham barely at all.
    pool = int(want * (2.6 if is_spam else 1.25)) + 500
    rows = run_mysql(
        f"SELECT id, DATE_FORMAT(timestamp,'%Y%m%d') FROM mailscanner.maillog "
        f"WHERE isspam={is_spam} AND isfp=0 AND timestamp>='2026-01-01' "
        f"ORDER BY RAND() LIMIT {pool};")
    seen, picked = set(), []
    for n, (mid, d) in enumerate(rows, 1):
        if len(picked) >= want:
            break
        raw, _env = read_raw(f"{ARCHIVE}/{d}/{mid}")
        if not raw:
            continue
        t = body_text(raw)
        if len(t) < 20:
            continue
        h = hashlib.sha256(t.lower().encode()).hexdigest()
        if h in seen:
            continue
        seen.add(h)
        picked.append((mid, d))
        if len(picked) % 500 == 0:
            print(f"  {label}: {len(picked)} distinct selected "
                  f"(from {n} read)", file=sys.stderr, flush=True)
    print(f"  {label}: {len(picked)} distinct selected from {len(rows)} candidates",
          file=sys.stderr, flush=True)
    return picked


def scan(raw, env):
    """Full rspamd scan of one message via stdin, with its real envelope."""
    try:
        r = subprocess.run(["rspamc"] + envelope_args(env) + ["symbols"],
                           input=raw.encode(), capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        return None
    out = r.stdout.decode("utf-8", errors="replace")
    a = ACTION_RE.search(out)
    s = SCORE_RE.search(out)
    if not a or not s:
        return None
    syms = set(SYMBOL_RE.findall(out))
    return a.group(1).strip(), float(s.group(1)), syms


def measure(items, label, expect_spam):
    """Scan a held-out set and report how rspamd currently judges it."""
    n = caught = b_spam = b_ham = 0
    total_score = 0.0
    for mid, d in items:
        raw, env = read_raw(f"{ARCHIVE}/{d}/{mid}")
        if not raw:
            continue
        res = scan(raw, env)
        if res is None:
            continue
        action, score, syms = res
        n += 1
        total_score += score
        is_flagged = action not in ("no action", "greylist")
        if is_flagged == expect_spam:
            caught += 1
        if "BAYES_SPAM" in syms:
            b_spam += 1
        if "BAYES_HAM" in syms:
            b_ham += 1
    if n == 0:
        return None
    return {"n": n, "correct": caught, "pct": 100.0 * caught / n,
            "avg_score": total_score / n, "bayes_spam": b_spam, "bayes_ham": b_ham}


def report(tag, spam_m, ham_m):
    print(f"\n--- {tag} ---")
    for nm, m in (("spam", spam_m), ("ham", ham_m)):
        if m is None:
            print(f"  {nm}: no data")
            continue
        word = "detected as spam" if nm == "spam" else "correctly NOT flagged"
        print(f"  {nm:5s} n={m['n']:4d}  {word}: {m['correct']:4d} "
              f"({m['pct']:5.1f}%)  avg score {m['avg_score']:6.2f}  "
              f"BAYES_SPAM {m['bayes_spam']}  BAYES_HAM {m['bayes_ham']}")


def teach(items, cmd, label):
    ok = fail = 0
    for i, (mid, d) in enumerate(items, 1):
        raw, _env = read_raw(f"{ARCHIVE}/{d}/{mid}")
        if not raw:
            fail += 1
            continue
        try:
            r = subprocess.run(["rspamc", cmd], input=raw.encode(),
                               capture_output=True, timeout=30)
        except subprocess.TimeoutExpired:
            fail += 1
            continue
        # "success = true" is NOT sufficient on its own -- rspamd returns it
        # even when its own guard declines the learn. The authoritative check
        # is the learned counter, verified once at the end.
        if r.returncode == 0 and b"success = true" in r.stdout:
            ok += 1
        else:
            fail += 1
        if i % 500 == 0:
            print(f"  {label}: {i}/{len(items)} taught", file=sys.stderr, flush=True)
    print(f"  {label}: {ok} taught, {fail} failed/skipped", file=sys.stderr, flush=True)
    return ok


def bayes_counts():
    r = subprocess.run(["rspamc", "stat"], capture_output=True, text=True)
    out = r.stdout
    sp = re.search(r"BAYES_SPAM.*?learned: (\d+)", out)
    hm = re.search(r"BAYES_HAM.*?learned: (\d+)", out)
    return (int(sp.group(1)) if sp else -1, int(hm.group(1)) if hm else -1)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    n_each = int(args[0]) if args else 5000
    n_test = int(args[1]) if len(args) > 1 else 250

    print(f"target: {n_each} distinct of each class to teach, "
          f"{n_test} of each held out for measurement"
          f"{' (DRY RUN)' if dry else ''}", file=sys.stderr, flush=True)

    sp0, hm0 = bayes_counts()
    print(f"Bayes before: {sp0} spam / {hm0} ham learned", file=sys.stderr, flush=True)

    print("selecting distinct spam...", file=sys.stderr, flush=True)
    spam = select_distinct(1, n_each + n_test, "spam")
    print("selecting distinct ham...", file=sys.stderr, flush=True)
    ham = select_distinct(0, n_each + n_test, "ham")

    # Held-out slice is taken FIRST and never taught.
    spam_test, spam_train = spam[:n_test], spam[n_test:]
    ham_test, ham_train = ham[:n_test], ham[n_test:]

    # Balance to whichever class actually yielded fewer DISTINCT messages.
    # Requesting n of each is not enough: spam deduplicates far harder than
    # ham (a first run asked for 4300 of each and got 1970 spam vs 4300 ham,
    # because ~83% of archived spam is resent campaigns). Teaching that
    # as-is would leave Bayes ham-heavy, biasing it toward calling real spam
    # ham -- the opposite skew to the one the balancing was meant to prevent,
    # but a skew all the same.
    k = min(len(spam_train), len(ham_train))
    if len(spam_train) != len(ham_train):
        print(f"  balancing: {len(spam_train)} spam / {len(ham_train)} ham "
              f"-> {k} each", file=sys.stderr, flush=True)
    spam_train, ham_train = spam_train[:k], ham_train[:k]

    print(f"train: {len(spam_train)} spam / {len(ham_train)} ham; "
          f"held out: {len(spam_test)} / {len(ham_test)}", file=sys.stderr, flush=True)

    print("measuring BEFORE...", file=sys.stderr, flush=True)
    before_s = measure(spam_test, "spam", True)
    before_h = measure(ham_test, "ham", False)
    report("BEFORE teaching", before_s, before_h)

    if dry:
        print("\ndry run -- nothing taught")
        return

    print("teaching...", file=sys.stderr, flush=True)
    teach(spam_train, "learn_spam", "spam")
    teach(ham_train, "learn_ham", "ham")

    sp1, hm1 = bayes_counts()
    print(f"\nBayes after: {sp1} spam / {hm1} ham learned "
          f"(+{sp1 - sp0} / +{hm1 - hm0})")

    print("measuring AFTER...", file=sys.stderr, flush=True)
    after_s = measure(spam_test, "spam", True)
    after_h = measure(ham_test, "ham", False)
    report("BEFORE teaching", before_s, before_h)
    report("AFTER teaching", after_s, after_h)

    if before_s and after_s:
        print(f"\nspam detection: {before_s['pct']:.1f}% -> {after_s['pct']:.1f}% "
              f"({after_s['pct'] - before_s['pct']:+.1f} pts)")
    if before_h and after_h:
        print(f"ham false-positive safety: {before_h['pct']:.1f}% -> {after_h['pct']:.1f}% "
              f"({after_h['pct'] - before_h['pct']:+.1f} pts)  "
              f"[higher is better: correctly NOT flagged]")


if __name__ == "__main__":
    main()
