#!/usr/bin/env python3
"""Does a SUBWORD representation beat whole-word features on Hungarian spam?

Motivated by a measured result, not a hunch: mw_train_spam_router2.py showed
that tripling the training corpus (1194 -> 4138) bought ZERO production
precision. So the binding constraint is the model family / representation, not
the label count. Hungarian is agglutinative -- `szamla`, `szamlat`,
`szamlajanak` are three unrelated features to a whole-word tokenizer, which
splinters the evidence for the same concept. Character n-grams are the cheap,
dependency-free proxy for the subword tokenization deepspam2 gets from
SentencePiece.

DESIGN: PAIRED COMPARISON. The corpus is collected ONCE and both tokenizers are
evaluated under the SAME 10 grouped splits, clustered on the SAME word-set
similarity. Only the feature extraction differs. Anything else would confound
the one variable under test.

Everything else -- Bernoulli NB, Laplace smoothing, the base-rate projection,
grouped splitting -- is unchanged from router2, so the numbers are directly
comparable to the 84.5% / 49.7% / 78.3% baseline.

MEMORY: char 3-5 grams over 8k documents would blow up to millions of distinct
features. Bounded by a two-stage vocabulary: stage A counts document frequency
on a sample to propose candidates, stage B counts only those across the full
corpus, and the top VOCAB_CAP by DF survive. A feature useful for
classification will appear in a 1000-document sample; one that does not is
noise we could not fit anyway.

Persists NOTHING but aggregates. Does not touch the live model or service.
"""
import email
import hashlib
import math
import os
import random
import re
import subprocess
import sys
from array import array
from collections import Counter, defaultdict

ARCHIVE = "/var/spool/MailScanner/archive"
WORD_RE = re.compile(r"[a-záéíóöőúüűA-ZÁÉÍÓÖŐÚÜŰ]{2,}")
WHITESPACE_RE = re.compile(r"\s+")
HTML_TAG_RE = re.compile(r"<[^>]+>")
MAX_CHARS = 4000
JACCARD = 0.7
SPAM_BASE = 0.09
SQL_SEED = 20260819
REPEATS = 10

NGRAM_MIN, NGRAM_MAX = 3, 5
SAMPLE_DOCS = 1000       # stage A: docs sampled to propose candidate n-grams
CANDIDATE_CAP = 300000   # stage A: candidates carried into stage B
VOCAB_CAP = 60000        # stage B: final feature count
MIN_DF = 8               # a feature must appear in at least this many documents


def rss_mb():
    try:
        with open("/proc/self/statm") as f:
            return int(f.read().split()[1]) * os.sysconf("SC_PAGE_SIZE") // (1024 * 1024)
    except Exception:
        return -1


def log(msg):
    print(f"[{rss_mb():>5}MB] {msg}", file=sys.stderr, flush=True)


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
    """Returns the TEXTS. Both tokenizers must run on identical input, so the
    text is held (in memory only) rather than reduced to features here."""
    limit = f"LIMIT {pool}" if pool else ""
    order = f"ORDER BY RAND({SQL_SEED}) " if pool else ""
    rows = run_mysql(
        f"SELECT id, DATE_FORMAT(timestamp,'%Y%m%d') FROM mailscanner.maillog "
        f"WHERE isspam={is_spam} AND isfp=0 AND timestamp>='2026-01-01' "
        f"{order}{limit};")
    log(f"{label}: {len(rows)} candidate rows")
    seen, texts = set(), []
    for n, (mid, d) in enumerate(rows, 1):
        if want and len(texts) >= want:
            break
        t = read_body(f"{ARCHIVE}/{d}/{mid}")
        if len(t) < 20:
            continue
        t = t[:MAX_CHARS].lower()
        h = hashlib.sha256(WHITESPACE_RE.sub(" ", t).encode()).hexdigest()
        if h in seen:
            continue
        seen.add(h)
        texts.append(t)
        if len(texts) % 1000 == 0:
            log(f"  {label}: {len(texts)} distinct (row {n}/{len(rows)})")
    log(f"{label}: {len(texts)} exact-distinct from {len(rows)} rows")
    return texts


def ngrams(text, lo=NGRAM_MIN, hi=NGRAM_MAX):
    out = set()
    L = len(text)
    for n in range(lo, hi + 1):
        for i in range(L - n + 1):
            out.add(text[i:i + n])
    return out


def build_ngram_vocab(texts, rng):
    """Two-stage, memory-bounded. Stage A proposes on a sample, stage B counts
    only those across everything."""
    sample = rng.sample(texts, min(SAMPLE_DOCS, len(texts)))
    log(f"ngram stage A: proposing candidates from {len(sample)} sampled docs")
    df = Counter()
    for t in sample:
        df.update(ngrams(t))
    log(f"ngram stage A: {len(df):,} distinct n-grams in sample")
    cands = {g for g, _ in df.most_common(CANDIDATE_CAP)}
    del df
    log(f"ngram stage A: kept {len(cands):,} candidates")

    df2 = Counter()
    for i, t in enumerate(texts, 1):
        df2.update(ngrams(t) & cands)
        if i % 2000 == 0:
            log(f"  ngram stage B: {i}/{len(texts)} docs")
    n = len(texts)
    # Drop the ubiquitous (no discriminative power) and the too-rare (unfittable).
    keep = [(g, c) for g, c in df2.items() if MIN_DF <= c <= 0.95 * n]
    keep.sort(key=lambda x: -x[1])
    # ngram -> integer id. Per-document features are then stored as int arrays
    # rather than sets of strings: at ~1800 features across 8276 documents a
    # set-of-str costs ~1.8GB (measured -- it left this box with 136MB free,
    # and this host has previously OOM-killed clamd during a comparable job),
    # while array('i') costs ~4 bytes per feature, roughly 60MB.
    vocab = {g: i for i, (g, _) in enumerate(keep[:VOCAB_CAP])}
    log(f"ngram vocab: {len(vocab):,} features (from {len(df2):,} counted)")
    return vocab


def featurize(texts, mode, vocab=None):
    if mode == "word":
        return [frozenset(WORD_RE.findall(t)) for t in texts]
    out = []
    for t in texts:
        ids = array("i", sorted({vocab[g] for g in ngrams(t) if g in vocab}))
        out.append(ids)
    return out


def cluster(docs, threshold=JACCARD):
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
    groups = defaultdict(list)
    for i in range(n):
        groups[find(i)].append(i)
    return list(groups.values())


def grouped_split_idx(n, clusters, rng, test_frac=0.2):
    cl = sorted(clusters, key=len, reverse=True)
    rng.shuffle(cl)
    target = int(n * test_frac)
    te, tr = [], []
    for c in cl:
        if len(te) + len(c) <= target:
            te.extend(c)
        else:
            tr.extend(c)
    return tr, te


def train(spam, ham):
    vocab = {}
    for docs, key in ((spam, "spam"), (ham, "ham")):
        for words in docs:
            for w in words:
                vocab.setdefault(w, {"spam": 0, "ham": 0})[key] += 1
    n_s, n_h, alpha = len(spam), len(ham), 1.0
    lo = {}
    for w, c in vocab.items():
        if c["spam"] + c["ham"] < 3:
            continue
        p_s = (c["spam"] + alpha) / (n_s + 2 * alpha)
        p_h = (c["ham"] + alpha) / (n_h + 2 * alpha)
        v = math.log(p_s / p_h)
        if abs(v) > 0.05:
            lo[w] = v
    return lo, (math.log(n_s / n_h) if n_h else 0.0)


def raw_score(feats, lo, prior):
    """Return the LOG-ODDS, not a probability.

    The sigmoid was the bug. n-gram docs carry ~1800 features against ~110
    words, so the log-odds sum is an order of magnitude larger and
    math.exp(-z) overflows outright (OverflowError at z < -709). Even where it
    does not overflow it SATURATES: essentially every document lands on exactly
    0.0 or 1.0, so a sweep over fixed probability thresholds (0.5..0.99)
    collapses to a single operating point and cannot find a trade-off at all.
    This is the same Naive-Bayes overconfidence that forced
    HU_SPAM_TEMPERATURE=36 on the word model, an order of magnitude worse.

    Working in log-odds and sweeping thresholds drawn from the observed
    distribution is immune to both, and is representation-neutral -- which is
    exactly what a paired comparison of two feature sets requires.
    """
    return prior + sum(lo.get(f, 0.0) for f in feats)


def metrics(s_te, h_te, lo, prior):
    s_z = [raw_score(f, lo, prior) for f in s_te]
    h_z = [raw_score(f, lo, prior) for f in h_te]
    ns, nh = len(s_z) or 1, len(h_z) or 1

    # Accuracy at the natural decision boundary (log-odds 0 == p 0.5).
    acc = (sum(1 for x in s_z if x >= 0) + sum(1 for x in h_z if x < 0)) / (ns + nh)

    # Sweep thresholds taken from the observed score distribution rather than
    # from fixed probabilities, so both arms get the same chance to find their
    # best operating point regardless of how their scores are scaled.
    allz = sorted(set(s_z + h_z))
    if len(allz) > 400:
        step = len(allz) / 400.0
        allz = [allz[int(i * step)] for i in range(400)]
    best_prec, rec_at_best = 0.0, 0.0
    s_sorted, h_sorted = sorted(s_z), sorted(h_z)
    import bisect

    def prec_at(thr):
        tp = ns - bisect.bisect_left(s_sorted, thr)
        fp = nh - bisect.bisect_left(h_sorted, thr)
        rec, fpr = tp / ns, fp / nh
        TP, FP = 1000 * SPAM_BASE * rec, 1000 * (1 - SPAM_BASE) * fpr
        return (TP / (TP + FP) if (TP + FP) else 0.0), rec

    for thr in allz:
        prec, rec = prec_at(thr)
        if rec < 0.30:          # an operating point nobody would deploy
            continue
        if prec > best_prec:
            best_prec, rec_at_best = prec, rec

    # MATCHED-RECALL comparison -- the number that actually decides anything.
    # "Best production precision" is chosen by scanning thresholds ON THE TEST
    # SET, which is optimistically biased AND free to wander to a high-precision
    # / low-recall corner. It did exactly that: it settled near 39% recall while
    # the router2 baseline operates near 78%. Precision at a FIXED recall pins
    # both arms to the same operating point, so the tokenizers are compared
    # doing the same job rather than at whichever corner each happens to like.
    at = {}
    for target in (0.50, 0.70):
        thr = s_sorted[max(0, int((1.0 - target) * ns) - 1)]  # threshold giving ~target recall
        p, r = prec_at(thr)
        at[target] = (p, r)
    return acc, best_prec, rec_at_best, at[0.50][0], at[0.70][0]


def evaluate_mode(s_feats, h_feats, s_cl, h_cl):
    accs, precs, recs, p50s, p70s = [], [], [], [], []
    for i in range(REPEATS):
        r = random.Random(1000 + i)
        s_tr_i, s_te_i = grouped_split_idx(len(s_feats), s_cl, r)
        h_tr_i, h_te_i = grouped_split_idx(len(h_feats), h_cl, r)
        lo, prior = train([s_feats[j] for j in s_tr_i], [h_feats[j] for j in h_tr_i])
        a, p, rc, p50, p70 = metrics([s_feats[j] for j in s_te_i], [h_feats[j] for j in h_te_i], lo, prior)
        accs.append(a); precs.append(p); recs.append(rc); p50s.append(p50); p70s.append(p70)
    return accs, precs, recs, p50s, p70s


def show(name, accs, precs, recs, p50s, p70s):
    def s(xs):
        xs = sorted(xs)
        return f"mean {sum(xs)/len(xs)*100:5.1f}%  range {xs[0]*100:5.1f}-{xs[-1]*100:5.1f}%"
    print(f"\n=== {name} ===")
    print(f"  balanced accuracy     {s(accs)}")
    print(f"  production precision  {s(precs)}")
    print(f"  recall (at best prec) {s(recs)}")
    print(f"  PRECISION @ 50% recall {s(p50s)}   <- matched operating point")
    print(f"  PRECISION @ 70% recall {s(p70s)}   <- matched operating point")
    return (sum(precs)/len(precs), sum(accs)/len(accs),
            sum(p50s)/len(p50s), sum(p70s)/len(p70s))


def main():
    rng = random.Random(SQL_SEED)
    spam_t = collect(1, "spam")
    ham_t = collect(0, "ham", want=len(spam_t), pool=int(len(spam_t) * 1.4) + 500)
    k = min(len(spam_t), len(ham_t))
    spam_t, ham_t = spam_t[:k], ham_t[:k]
    print(f"corpus: {k} spam / {k} ham (trivial baseline 50.0%)")

    log("featurizing WORD")
    s_w, h_w = featurize(spam_t, "word"), featurize(ham_t, "word")

    log("clustering on word sets (SAME splits for both tokenizers)")
    s_cl, h_cl = cluster(s_w), cluster(h_w)
    print(f"clusters: spam {len(s_cl)}, ham {len(h_cl)}")

    log("building n-gram vocabulary")
    vocab = build_ngram_vocab(spam_t + ham_t, rng)
    log("featurizing CHAR n-grams")
    s_n, h_n = featurize(spam_t, "ngram", vocab), featurize(ham_t, "ngram", vocab)
    del spam_t, ham_t
    log("features built")

    print(f"\nmean features/doc: word {sum(len(x) for x in s_w)//max(len(s_w),1)} (spam) "
          f"{sum(len(x) for x in h_w)//max(len(h_w),1)} (ham)")
    print(f"mean features/doc: ngram {sum(len(x) for x in s_n)//max(len(s_n),1)} (spam) "
          f"{sum(len(x) for x in h_n)//max(len(h_n),1)} (ham)")

    wa, wp, wr, w50, w70 = evaluate_mode(s_w, h_w, s_cl, h_cl)
    p_w, a_w, pw50, pw70 = show("WORD features", wa, wp, wr, w50, w70)
    na, np_, nr, n50, n70 = evaluate_mode(s_n, h_n, s_cl, h_cl)
    p_n, a_n, pn50, pn70 = show(f"CHAR {NGRAM_MIN}-{NGRAM_MAX} GRAM features", na, np_, nr, n50, n70)

    print("\n" + "=" * 66)
    print("PAIRED RESULT -- same corpus, same splits, only the tokenizer differs")
    print("=" * 66)
    print(f"  production precision:  word {p_w*100:.1f}%  ->  ngram {p_n*100:.1f}%   "
          f"({(p_n-p_w)*100:+.1f} points)")
    print(f"  balanced accuracy   :  word {a_w*100:.1f}%  ->  ngram {a_n*100:.1f}%   "
          f"({(a_n-a_w)*100:+.1f} points)")
    print(f"  MATCHED @50% recall :  word {pw50*100:.1f}%  ->  ngram {pn50*100:.1f}%   ({(pn50-pw50)*100:+.1f} points)")
    print(f"  MATCHED @70% recall :  word {pw70*100:.1f}%  ->  ngram {pn70*100:.1f}%   ({(pn70-pw70)*100:+.1f} points)")
    w70wins = sum(1 for x, y in zip(w70, n70) if y > x)
    print(f"  ngram beat word at 70% recall on {w70wins}/{REPEATS} splits")
    wins = sum(1 for x, y in zip(wp, np_) if y > x)
    print(f"  ngram beat word on {wins}/{REPEATS} individual splits")
    print("\n  Split-to-split spread on this corpus is ~25 points, so judge this on")
    print("  the MEAN and the per-split win count, never on one split.")


if __name__ == "__main__":
    main()
