#!/usr/bin/env python3
"""HU_SPAM router, v2 -- honest baseline.

Sibling of mw_train_spam_router.py. Two changes, and DELIBERATELY NOTHING ELSE:

  1. MINE THE WHOLE CORPUS. v1's candidate pool was `want*3+500` = 5000 rows, so
     it trained on 1194 spam while 25,090 spam rows sit in mailscanner.maillog.
     That was a sampling cap being mistaken for a corpus ceiling -- the "data
     wall" that shaped a fortnight of decisions. v2 scans the full population.

  2. SPLIT BY NEAR-DUPLICATE CLUSTER, NOT RANDOMLY. v1 deduplicated by exact
     SHA-256 and then did random.shuffle + an 80/20 cut. Exact-hash dedup does
     not remove campaigns: measured on this corpus, only ~63% of exact-distinct
     spam is genuinely unique, with near-duplicate clusters of 90, 43, 26, 25
     and 19 messages. Random splitting scatters a campaign's variants across
     train and test, so the model is scored on paraphrases of what it memorized.
     v2 assigns whole clusters to one side.

The FEATURE EXTRACTION AND MODEL ARE UNCHANGED (word-presence Bernoulli
Naive-Bayes log-odds). That is the point: change one variable at a time, so the
delta is attributable. To separate the two effects, v2 reports the SAME trained
data under BOTH split strategies -- v1's random split and the grouped split --
so "more data" and "honest split" can be told apart rather than confounded.

Expect the grouped number to be WORSE than v1's 81.4%. That is the finding, not
a regression: it is what the model was always worth.

DOES NOT TOUCH THE LIVE MODEL. Writes to hu_spam_router_v2.json;
/usr/local/sbin/hu-classify-stub.py reads hu_spam_router.json and is unaffected.
Promoting v2 is a separate, deliberate step.

Per the operator's standing rule, nothing but aggregates and the final model is
persisted -- message text never leaves this process.
"""
import email
import hashlib
import json
import math
import random
import re
import subprocess
import sys
from collections import Counter, defaultdict

ARCHIVE = "/var/spool/MailScanner/archive"
OUT_PATH = "/opt/hu-classify/models/hu_spam_router_v2.json"
LIVE_PATH = "/opt/hu-classify/models/hu_spam_router.json"
WORD_RE = re.compile(r"[a-záéíóöőúüűA-ZÁÉÍÓÖŐÚÜŰ]{2,}")
WHITESPACE_RE = re.compile(r"\s+")
HTML_TAG_RE = re.compile(r"<[^>]+>")
MAX_CHARS = 4000
JACCARD = 0.7
SPAM_BASE = 0.09
SQL_SEED = 20260819
REPEATS = 10  # split repeats -- a single split is one draw, not a measurement


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


def collect(is_spam, label, want=None, pool=None):
    """Stream, exact-dedup, reduce to a word SET. Text never leaves this loop.

    want=None means 'take every distinct message in the population' -- the v2
    behaviour. pool caps how many candidate rows are read.
    """
    limit = f"LIMIT {pool}" if pool else ""
    # RAND() must be SEEDED. Unseeded, MySQL draws a different ham sample every
    # run while the Python seed controls only the splits -- so two "identical"
    # runs disagreed by 7 points of production precision and by 3pp on the
    # leakage estimate, which was invisible until the job was run twice. Spam
    # takes the full population and is deterministic regardless.
    order = f"ORDER BY RAND({SQL_SEED}) " if pool else ""
    rows = run_mysql(
        f"SELECT id, DATE_FORMAT(timestamp,'%Y%m%d') FROM mailscanner.maillog "
        f"WHERE isspam={is_spam} AND isfp=0 AND timestamp>='2026-01-01' "
        f"{order}{limit};")
    print(f"  {label}: {len(rows)} candidate rows", file=sys.stderr, flush=True)
    seen, docs, dates = set(), [], []
    pop_months = Counter(d[:6] for _, d in rows)
    for n, (mid, d) in enumerate(rows, 1):
        if want and len(docs) >= want:
            break
        text = read_body(f"{ARCHIVE}/{d}/{mid}")
        if len(text) < 20:
            continue
        text = text[:MAX_CHARS].lower()
        h = hashlib.sha256(WHITESPACE_RE.sub(" ", text).encode()).hexdigest()
        if h in seen:
            continue
        seen.add(h)
        ws = frozenset(WORD_RE.findall(text))
        if ws:
            docs.append(ws)
            dates.append(d)
        # NOTE: this sits after the `continue`s above, so it only fires when row
        # n is a multiple of 2000 AND that row survives dedup. With ~83% of spam
        # rows being duplicates most milestones are skipped -- 12 expected lines
        # came out as 2. Cosmetic only (logging, not results), inherited from
        # v1's loop shape. Left as-is rather than re-running a 10-minute job.
        if n % 2000 == 0:
            print(f"    {label}: read {n}/{len(rows)}, {len(docs)} distinct",
                  file=sys.stderr, flush=True)
    print(f"  {label}: {len(docs)} exact-distinct from {len(rows)} rows",
          file=sys.stderr, flush=True)
    return docs, dates, pop_months


def cluster(docs, threshold=JACCARD):
    """Union-find over near-duplicates. Candidate generation uses an inverted
    index on non-ubiquitous words, so this is not the O(n^2) pairwise scan --
    at 6k documents that would be 18M set intersections.

    NOTE: union-find chains transitively, so a returned cluster can span pairs
    that are not themselves above threshold. For LEAKAGE control that is the
    conservative direction: it over-merges, keeping related messages together.
    """
    n = len(docs)
    parent = list(range(n))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    df = Counter()
    for d in docs:
        df.update(d)
    # Drop only genuinely ubiquitous words from candidate generation. The bound
    # needs an ABSOLUTE floor, not a bare percentage: a campaign's core words are
    # shared by every member, so a percentage-only rule (5% was the first
    # attempt) discards exactly the words that identify the campaign whenever the
    # campaign is larger than the threshold. That silently returned all-singleton
    # clusters -- i.e. "no leakage found" -- which is the most dangerous possible
    # failure for this script. Caught by a synthetic-campaign unit check.
    cap = max(50, int(0.2 * n))
    common = {w for w, c in df.items() if c > cap}
    index = defaultdict(list)
    for i, d in enumerate(docs):
        for w in d:
            if w not in common:
                index[w].append(i)

    for i, di in enumerate(docs):
        li = len(di)
        cand = Counter()
        for w in di:
            if w in common:
                continue
            for j in index[w]:
                if j > i:
                    cand[j] += 1
        for j, shared in cand.items():
            if shared < 3:
                continue
            dj = docs[j]
            lj = len(dj)
            if min(li, lj) < threshold * max(li, lj):
                continue
            if find(i) == find(j):
                continue
            inter = len(di & dj)
            if inter and inter / (li + lj - inter) >= threshold:
                union(i, j)
        if (i + 1) % 2000 == 0:
            print(f"    clustered {i+1}/{n}", file=sys.stderr, flush=True)

    groups = defaultdict(list)
    for i in range(n):
        groups[find(i)].append(i)
    return list(groups.values())


def grouped_split(docs, clusters, test_frac=0.2, rng=None, label=""):
    """Assign whole clusters to train or test so no campaign straddles the split.

    Reports the composition of the test side. This matters: a single campaign of
    462 messages is 11% of the class, and if it lands in TEST then the recall
    figure is largely a statement about that one campaign rather than about spam
    in general. Concentration has to be visible, not assumed away.
    """
    cl = sorted(clusters, key=len, reverse=True)
    rng.shuffle(cl)
    target = int(len(docs) * test_frac)
    test_idx, train_idx = [], []
    test_sizes, big_dest = [], []
    for c in cl:
        if len(test_idx) + len(c) <= target:
            test_idx.extend(c)
            test_sizes.append(len(c))
        else:
            train_idx.extend(c)
        if len(c) >= 30:
            big_dest.append((len(c), "TEST" if c and c[0] in set(test_idx) else "train"))
    if label:
        ts = sorted(test_sizes, reverse=True)
        top = ts[0] if ts else 0
        print(f"  {label} test side: {len(test_idx)} msgs from {len(test_sizes)} clusters, "
              f"largest {ts[:5]}")
        print(f"  {label} test concentration: largest cluster = {100*top/max(len(test_idx),1):.0f}% "
              f"of held-out set")
        print(f"  {label} clusters >=30 msgs -> {[f'{n}:{d}' for n, d in sorted(big_dest, reverse=True)]}")
    return [docs[i] for i in train_idx], [docs[i] for i in test_idx]


def random_split(docs, test_frac=0.2, rng=None):
    d = list(docs)
    rng.shuffle(d)
    cut = int(len(d) * (1 - test_frac))
    return d[:cut], d[cut:]


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


def sweep(s_te, h_te, lo, prior, title, quiet=False):
    if not quiet:
        print(f"\n  {title} -- projected onto ~{SPAM_BASE*100:.0f}% spam real traffic:")
        print(f"    {'thr':>5s} {'recall':>7s} {'FPR':>7s} {'prod.prec':>10s}   per 1000 msgs")
    best = 0.0
    for thr in (0.5, 0.7, 0.8, 0.9, 0.95, 0.98, 0.99):
        m = evaluate(s_te, h_te, lo, prior, thr)
        rec = m["tp"] / (m["tp"] + m["fn"]) if (m["tp"] + m["fn"]) else 0.0
        fpr = m["fp"] / (m["fp"] + m["tn"]) if (m["fp"] + m["tn"]) else 0.0
        TP, FP = 1000 * SPAM_BASE * rec, 1000 * (1 - SPAM_BASE) * fpr
        prec = TP / (TP + FP) if (TP + FP) else 0.0
        best = max(best, prec)
        if not quiet:
            print(f"    {thr:5.2f} {rec*100:6.1f}% {fpr*100:6.1f}% {prec*100:9.0f}%"
                  f"   {TP:4.0f} spam / {FP:4.0f} ham wrongly flagged")
    return best


def repeat_eval(spam, ham, s_cl, h_cl, mode, k=REPEATS):
    """One split is a single draw, not a measurement.

    Running this job twice with the same Python seed produced grouped-split
    production precision of 54% and then 47% -- because ham was drawn with an
    UNSEEDED SQL RAND(). With that fixed, the remaining variance is the split
    itself, and the only honest way to quote a baseline is a distribution over
    repeated splits rather than whichever number one draw happened to give.
    """
    accs, precs, recs = [], [], []
    for i in range(k):
        r = random.Random(1000 + i)
        if mode == "grouped":
            s_tr, s_te = grouped_split(spam, s_cl, rng=r)
            h_tr, h_te = grouped_split(ham, h_cl, rng=r)
        else:
            s_tr, s_te = random_split(spam, rng=r)
            h_tr, h_te = random_split(ham, rng=r)
        lo, prior = train(s_tr, h_tr)
        m = evaluate(s_te, h_te, lo, prior)
        accs.append(m["accuracy"])
        recs.append(m["recall"])
        precs.append(sweep(s_te, h_te, lo, prior, "", quiet=True))
    return accs, precs, recs


def stat(name, xs):
    xs = sorted(xs)
    mean = sum(xs) / len(xs)
    return (f"  {name:<22} mean {mean*100:5.1f}%   range {xs[0]*100:5.1f}% - "
            f"{xs[-1]*100:5.1f}%   (n={len(xs)} splits)")


def report(name, s_tr, s_te, h_tr, h_te):
    lo, prior = train(s_tr, h_tr)
    te = evaluate(s_te, h_te, lo, prior)
    print(f"\n=== {name} ===")
    print(f"  train {len(s_tr)}+{len(h_tr)}, held out {len(s_te)}+{len(h_te)}, "
          f"vocab {len(lo)}")
    print(f"  HELD OUT: acc {te['accuracy']*100:.1f}%  prec {te['precision']*100:.1f}%  "
          f"rec {te['recall']*100:.1f}%   tp={te['tp']} fp={te['fp']} "
          f"tn={te['tn']} fn={te['fn']}")
    best = sweep(s_te, h_te, lo, prior, name)
    return lo, prior, te, best


def main():
    rng = random.Random(20260819)
    print("collecting FULL spam population (v1 capped this at 5000 rows)",
          file=sys.stderr, flush=True)
    spam, s_dates, s_pop = collect(1, "spam")
    ham, h_dates, _ = collect(0, "ham", want=len(spam), pool=int(len(spam) * 1.4) + 500)

    k = min(len(spam), len(ham))
    spam, ham = spam[:k], ham[:k]
    s_dates = s_dates[:k]
    print(f"\nbalanced to {k} spam / {k} ham (trivial baseline = 50.0%)")
    print(f"v1 trained on 1194+1194 -- this is {k/1194:.1f}x the data")

    # Exact-dedup keeps the FIRST occurrence, and spam is read in id (i.e.
    # chronological) order, so the surviving representative of a months-long
    # campaign is its earliest copy. If that skews the kept set toward older
    # mail, the vocabulary is older than the traffic it will score -- a caveat
    # on the baseline, and a trap for anyone re-running with a different
    # ordering. Measured rather than assumed:
    kept = Counter(d[:6] for d in s_dates)
    print("\nspam month distribution -- KEPT vs FULL population:")
    for mth in sorted(s_pop):
        pk = 100 * kept.get(mth, 0) / max(k, 1)
        pp = 100 * s_pop[mth] / max(sum(s_pop.values()), 1)
        print(f"  {mth}  kept {kept.get(mth,0):>5} ({pk:4.1f}%)   "
              f"population {s_pop[mth]:>6} ({pp:4.1f}%)   skew {pk-pp:+5.1f}pp")

    print("\nclustering near-duplicates (Jaccard >= 0.7)...", file=sys.stderr, flush=True)
    s_cl, h_cl = cluster(spam), cluster(ham)
    s_single = sum(1 for c in s_cl if len(c) == 1)
    h_single = sum(1 for c in h_cl if len(c) == 1)
    print(f"  spam: {len(s_cl)} clusters over {k} msgs, {s_single} singletons "
          f"({100*s_single/k:.0f}% unique), largest {sorted((len(c) for c in s_cl), reverse=True)[:5]}")
    print(f"  ham : {len(h_cl)} clusters over {k} msgs, {h_single} singletons "
          f"({100*h_single/k:.0f}% unique), largest {sorted((len(c) for c in h_cl), reverse=True)[:5]}")

    # v1's method, on v2's larger data -- isolates the effect of MORE DATA.
    s_tr, s_te = random_split(spam, rng=rng)
    h_tr, h_te = random_split(ham, rng=rng)
    _, _, r_te, r_best = report("RANDOM split (v1 method, v2 data)", s_tr, s_te, h_tr, h_te)

    # The honest one -- isolates the effect of REMOVING LEAKAGE.
    s_tr, s_te = grouped_split(spam, s_cl, rng=rng, label="spam")
    h_tr, h_te = grouped_split(ham, h_cl, rng=rng, label="ham ")
    lo, prior, g_te, g_best = report("GROUPED split (honest baseline)", s_tr, s_te, h_tr, h_te)

    # --- the part that actually supports a quoted baseline ---
    print("\n" + "=" * 70)
    print(f"REPEATED SPLITS (n={REPEATS}) -- one split is a draw, not a measurement")
    print("=" * 70)
    r_acc, r_prec, r_rec = repeat_eval(spam, ham, s_cl, h_cl, "random")
    g_acc, g_prec, g_rec = repeat_eval(spam, ham, s_cl, h_cl, "grouped")
    print("RANDOM split (leaky):")
    print(stat("balanced accuracy", r_acc))
    print(stat("production precision", r_prec))
    print(stat("recall", r_rec))
    print("GROUPED split (honest):")
    print(stat("balanced accuracy", g_acc))
    print(stat("production precision", g_prec))
    print(stat("recall", g_rec))
    leak = sum(r_acc) / len(r_acc) - sum(g_acc) / len(g_acc)
    print(f"\n  mean leakage inflation: {leak*100:+.1f} accuracy points")

    print("\n" + "=" * 70)
    print("WHAT CHANGED, ATTRIBUTED")
    print("=" * 70)
    print(f"  v1 (1194+1194, random split) : acc 81.4%  best prod.precision 57%")
    print(f"     ^ historical reference only. Its FPR came from 239 held-out ham")
    print(f"       messages (12 of them), so its 95% CI on production precision")
    print(f"       is 44-70% -- it cannot support a comparison on its own.")
    print(f"  v2 ({k}+{k}, random split) : acc {r_te['accuracy']*100:.1f}%  "
          f"best prod.precision {r_best*100:.0f}%")
    print(f"     ^ v1's METHOD reproduced at scale -- NOT an isolated measurement")
    print(f"       of 'more data'. That would need v1's 1194 under a grouped")
    print(f"       split, which was never run. Both size and test-n differ here.")
    print(f"  v2 ({k}+{k}, grouped split): acc {g_te['accuracy']*100:.1f}%  "
          f"best prod.precision {g_best*100:.0f}%   <- THE HONEST BASELINE")
    print()
    print(f"  The ONLY clean contrast is v2-random vs v2-grouped: same corpus,")
    print(f"  same n, one variable. Leakage inflation = "
          f"{(r_te['accuracy']-g_te['accuracy'])*100:+.1f} accuracy points.")
    print(f"  The load-bearing conclusion needs no attribution table: production")
    print(f"  precision did not move across a 3.5x increase in training data.")
    print("\n  The GROUPED number is the honest baseline. Any future model --")
    print("  deepspam2 included -- must beat it on PRODUCTION PRECISION at")
    print("  comparable recall, measured the same way.")

    with open(OUT_PATH, "w") as f:
        json.dump({"prior": round(prior, 4), "log_odds": lo}, f)
    print(f"\nwrote {OUT_PATH} ({len(lo)} words).")
    print(f"LIVE model {LIVE_PATH} NOT touched -- promoting v2 is a separate step.")


if __name__ == "__main__":
    main()
