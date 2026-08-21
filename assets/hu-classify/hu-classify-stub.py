#!/usr/bin/env python3
"""Language classifier service, Phase 1 (language detection + naturalness),
Hungarian and English.

{HU,EN}_LANGUAGE: fastText lid.176 loaded once at startup, run per-request
against subject+body. rspamd's own built-in part:get_language() was tested
against this host's real Hungarian mail patterns and missed 4 of 5 realistic
cases (short messages, diacritic-free Hungarian) -- see
/root/.claude/plans/still-drifting-nagy.md and the 2026-08-18 check-2 notes.
English reuses the exact same fastText model (lid.176 already covers en) --
no separate dependency.

{HU,EN}_NATURALNESS: character-trigram log-probability against a reference
distribution built offline from a Wikipedia chunk in that language (a
Webcorpus 2.0 subcorpus for hu) -- see build_naturalness_model.py, run
manually, never in this live path. Needs no spam label at all, unlike
HU_SPAM. Calibration testing 2026-08-18 (Hungarian table) showed this does
NOT discriminate Hungarian from other real languages (short function-word
trigrams overlap too much across European languages) -- it discriminates
coherent language text from gibberish/obfuscated garbage, which clustered
clearly lower. Treat each one as an obfuscation-detector signal for ITS
language's own text, not a language-identity signal. EN_NATURALNESS was
built 2026-08-18 from a 756M-char enwiki chunk the same way.

ALL FOUR SIGNALS CARRY WEIGHT 0.0, and that is a measured result rather
than caution. Against the reference host's own mail (13 days; 77 genuinely
distinct spam / ~700 distinct ham after content-hash deduplication):
HU_LANGUAGE AUC 0.418, HU_NATURALNESS 0.368, EN_LANGUAGE 0.519,
EN_NATURALNESS 0.473 -- where 0.50 is literally no information. See
measure_signal_value.py, which recomputes this on demand.

Two structural reasons none of these is a spam score, worth knowing before
anyone "fixes" them by training harder:
  - the *_LANGUAGE symbols are language IDENTITY. On a Hungarian mail
    server "this is Hungarian" is if anything ham-associated, which is what
    the sub-0.5 AUC reflects. Their real use is as conditioning inputs that
    gate language-specific rules, not as scores.
  - *_NATURALNESS only reacts to mangled/obfuscated text, and most spam is
    ordinary readable prose. Corpus size cannot change this, and neither
    can recalibration (monotonic transform; AUC is rank-based).

What DID move the numbers was preprocessing -- see strip_non_prose() below.
Feeding the scorer human-readable prose instead of raw extracted mail,
re-measured against this deployed service, took EN_NATURALNESS from 0.473
to 0.644 (noise -> real signal) and HU_NATURALNESS from 0.368 to 0.344.
The *_LANGUAGE symbols were unaffected (0.418 / 0.513), since fastText runs
on the unstripped text. Both naturalness signals are now calibrated against
real-mail distributions rather than tidy sample sentences.

They still ship at weight 0.0: n=77 distinct spam is thin, and post-cleaning
EN_NATURALNESS substantially proxies "reads as fluent English", which would
punish legitimate English correspondence -- a false-positive risk the AUC
figure alone does not expose. Any weight must come from a per-host
measurement, not from these reference numbers.

HU_SPAM: now a REAL model where one has been trained, still weight 0.0.

History, because the numbers are easy to misread. A first attempt scored
95.95% held-out -- pure duplicate leakage: 258 of 316 "spam" were
near-identical resends of 16 campaigns landing on both sides of the split.
Deduplicated, only 77 genuinely distinct spam existed, and honest retraining
gave 42.3% -- WORSE than the 90.9% always-ham baseline. That was a data
wall, not a code bug.

The retired MailScanner archive supplied the missing data (~3-4k distinct
spam with full bodies). Retrained balanced on 1194+1194 deduplicated
messages: held-out accuracy 81.4% against a 50% baseline, precision 90.3%,
recall 70.3%. Real signal this time.

It is STILL weight 0.0, and that is the important part. Projected onto this
host's actual 9%-spam traffic, that WORD model reached only ~57% best
production precision, mis-flagging ~46 legitimate messages per 1000. A
balanced accuracy figure flatters any classifier facing a skewed base rate;
judge it by the projection, not the headline.

2026-08-19: the full retired-MailScanner archive (25,090 raw spam rows) was
extracted properly (mw_train_spam_router2.py), 3.5x the training data
(4138+4138 deduplicated, near-duplicate clusters kept out of both sides of
the split so the honest number cannot leak). Result: production precision
DID NOT MOVE (still ~57%) -- more data was not the binding constraint.

mw_tokenizer_experiment.py then tested WHY: Hungarian is agglutinative, so
`szamla`/`szamlat`/`szamlajanak` are three unrelated features to a
whole-word tokenizer, splintering the evidence for one concept. Character
3-5-grams (the cheap, dependency-free proxy for real subword tokenization)
were tested as a paired, same-corpus, same-splits comparison against the
word model and won: +5.7 points production precision, +6.1 points at a
matched 50%-recall operating point, beating word features on 8/10 splits.

mw_build_ngram_router.py (2026-08-19) trained and saved that model on the
same honest grouped split: production precision 91% (n=10 mean, range
69-100%), 93% on the single canonical split actually saved. THIS is the
model now loaded below -- a real, if still modest, improvement over both
prior word-based attempts, still weight 0.0 for the same base-rate reason
(useful as a contributing/router feature, never as a standalone rule).

Naive-Bayes over ~1800 n-gram features per document (vs ~110 words) sums an
order of magnitude larger log-odds total -- HU_SPAM_TEMPERATURE was refit
for this model specifically (980.6, not the word model's 36) using the same
p05/p95-real-sample methodology; the old constant saturated 66% of scores.

The trained table is NOT shipped with the installer -- it is learned from
one host's own mail and its vocabulary is meaningless elsewhere. A host
without a model file falls back to the fixed placeholder.

No English equivalent attempted -- no reason to think the label situation is
any better there.

HU_PHISHING, HU_SCAM are still fixed placeholders, not built yet.

Debug query params still work for fail-open testing, unchanged from Phase 0:
  POST /classify?delay_ms=3000   -> sleeps before replying (timeout test)
  POST /classify?malformed=1     -> replies 200 with invalid JSON
  POST /classify?http_error=1    -> replies with HTTP 500

Bound to 127.0.0.1 only.
"""

import json
import math
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

import fasttext

HOST = "127.0.0.1"
PORT = 11336
LANG_MODEL_PATH = "/opt/hu-classify/models/lid.176.ftz"
SPAM_ROUTER_MODEL_PATH = "/opt/hu-classify/models/hu_spam_router_ngram.json"

# Character-cap for anything fed to a model: keeps worst-case latency bounded
# by a constant, not by message size, and spam signal is front-loaded in a
# message body anyway. fastText inference is sub-millisecond regardless, but
# this cap matters more for the trigram scan below.
MAX_CHARS = 4000

PLACEHOLDER = {
    "hu_phishing": 0.0,
    "hu_scam": 0.0,
}

# HU_SPAM: a word-presence Naive-Bayes log-odds table, loaded only if a host
# has actually trained one (mw_train_spam_router.py). It is deliberately NOT
# shipped with the installer: the table is learned from ONE host's own mail
# and its vocabulary means nothing on another deployment. No model file ->
# fall back to the old fixed placeholder, which is what every fresh install
# gets.
#
# HU_SPAM_PLACEHOLDER is what the symbol reported before any model existed.
# Kept as the fallback so the symbol's shape never changes.
HU_SPAM_PLACEHOLDER = 0.1

# Naive Bayes is famously overconfident: it sums one log-odds term per
# feature and treats them as independent, so a message accumulates a large
# total. Fed straight into a sigmoid that pins to the rails -- the ORIGINAL
# (word-model) measurement on 157 real messages found 86% came out as EXACTLY
# 0.0 or EXACTLY 1.0, with only 14% carrying any gradation at all.
#
# That is fatal for a signal whose entire job is to be measured: messages
# tied at 0.0 make an AUC computation meaningless (ties score 0.5), and the
# logged value cannot distinguish "barely" from "definitely".
#
# So divide the evidence by a temperature before the sigmoid. T is fitted to
# the observed spread, not guessed: T = (p95-p05 of the raw sum over a real
# sample) / 8, which maps that span onto roughly +-4 sigmoid units -- enough
# range to avoid saturating without being so wide it flattens everything to
# the middle. Being a monotonic transform it changes NOTHING about ranking or
# AUC -- the same point as the naturalness recalibration -- it only restores
# resolution. MUST be refit per model: the n-gram model below sums ~1800
# features per document against the word model's ~110, so its raw total (and
# therefore its correctly-fitted T) is roughly an order of magnitude larger
# -- reusing the word model's T=36 here saturates 66% of scores, almost as
# badly as the original unfitted bug. Refit 2026-08-19 against a 400-message
# real sample (200 spam + 200 ham): span 7845, T = 980.6, saturation 2%.
#
# The emitted number is therefore a RANKING SCORE in (0,1), NOT a calibrated
# probability. Do not read hu_spam=0.4 as "40% likely to be spam". Applying a
# production prior was tried and rejected on the word model: at a 9% base
# rate it pushed both classes into the bottom of the range, which is
# nominally better calibrated and practically useless to look at.
HU_SPAM_TEMPERATURE = 980.6

_spam_router = None
_spam_router_ngram_range = None  # (min, max) char n-gram length, or None for word features
try:
    with open(SPAM_ROUTER_MODEL_PATH, "r", encoding="utf-8") as _f:
        _m = json.load(_f)
    if _m.get("log_odds"):
        _spam_router = _m["log_odds"]
        if "ngram_min" in _m and "ngram_max" in _m:
            _spam_router_ngram_range = (_m["ngram_min"], _m["ngram_max"])
except (OSError, ValueError):
    _spam_router = None

_SPAM_WORD_RE = re.compile(r"[a-záéíóöőúüűA-ZÁÉÍÓÖŐÚÜŰ]{2,}")


def _spam_char_ngrams(text: str, lo: int, hi: int) -> set:
    out = set()
    L = len(text)
    for n in range(lo, hi + 1):
        for i in range(L - n + 1):
            out.add(text[i:i + n])
    return out


def score_hu_spam(subject: str, text: str) -> float:
    """Distillation of the archive's own spam verdicts -- never an independent
    judgement, and permanently weight 0.0 in rspamd.

    Character 3-5-gram model (promoted 2026-08-19, see module docstring):
    honest grouped-split production precision 91% (n=10 mean), vs. 57% for
    both word-based attempts that preceded it. Still not a standalone rule --
    91% precision at a workable recall is good for a contributing feature,
    not good enough to gate delivery on alone. Revisit only with a fresh
    measurement, never by promoting a headline number on its own.
    """
    if _spam_router is None:
        return HU_SPAM_PLACEHOLDER
    combined = f"{subject} {text}"[:MAX_CHARS].lower()
    if _spam_router_ngram_range:
        feats = _spam_char_ngrams(combined, *_spam_router_ngram_range)
    else:
        feats = set(_SPAM_WORD_RE.findall(combined))
    if not feats:
        return HU_SPAM_PLACEHOLDER
    z = sum(_spam_router.get(f, 0.0) for f in feats) / HU_SPAM_TEMPERATURE
    # Overflow guard: the whole reason T needed refitting for this model is
    # that raw sums are an order of magnitude larger than the word model's --
    # a single outlier document is not worth risking OverflowError over.
    if z < -700:
        return 0.0
    if z > 700:
        return 1.0
    return round(1.0 / (1.0 + math.exp(-z)), 4)

fasttext.FastText.eprint = lambda *a, **k: None  # silence the load-time warning banner
_lang_model = fasttext.load_model(LANG_MODEL_PATH)

# Per-language naturalness reference tables + calibration. Calibration
# constants are fit per language against real sample text -- see each one's
# own comment for whether that check has actually been done, versus still
# carrying a starting-point value copied from another language's fit.
# Strip non-prose before scoring. This is NOT cosmetic: character trigrams
# over raw extracted mail measure ARTIFACT DENSITY (URLs, tracking ids,
# base64 fragments, punctuation runs) as much as they measure "is the
# human-written text coherent", which is the only thing these signals claim
# to detect. Measured against real mail on the reference host 2026-08-18,
# stripping this material moved EN_NATURALNESS from AUC 0.535 (indistinguishable
# from noise) to 0.686, and HU_NATURALNESS from 0.421 to 0.388 -- reproduced
# across two independent ham samples, so it is a real effect, not sampling
# noise. See recalibrate.py, which is what produced these numbers.
_URL_RE = re.compile(r"https?://\S+|www\.\S+")
_EMAIL_RE = re.compile(r"\S+@\S+\.\S+")
_LONGTOKEN_RE = re.compile(r"\S{25,}")   # base64 blobs, tracking ids, hashes
_NONLETTER_RUN_RE = re.compile(r"[^\w\sáéíóöőúüűÁÉÍÓÖŐÚÜŰ]{2,}")
_DIGITS_RE = re.compile(r"\d+")


def strip_non_prose(text: str) -> str:
    text = _URL_RE.sub(" ", text)
    text = _EMAIL_RE.sub(" ", text)
    text = _LONGTOKEN_RE.sub(" ", text)
    text = _NONLETTER_RUN_RE.sub(" ", text)
    text = _DIGITS_RE.sub(" ", text)
    return text


# Calibration is fit against the distribution of REAL MAIL, per language,
# AFTER strip_non_prose() -- not against clean prose samples. The original
# shipped constants (-14.0/2.3 for both) were fit against tidy sample
# sentences that scored 0.87-0.92, but real mail sits far lower (reference
# host ham median was 0.54 under those constants, with 44% of LEGITIMATE
# mail below 0.5), so a published score did not mean what the docs claimed.
#
# Note what recalibration does and does not do: it fixes what the numbers
# MEAN. It cannot change any AUC, because the sigmoid is monotonic and AUC
# is rank-based -- only strip_non_prose() above can move discrimination.
NATURALNESS_MODELS = {
    "hu": {
        "path": "/opt/hu-classify/models/hu_naturalness.json",
        # Fit to reference-host mail after stripping: ham p50 -> 0.53,
        # spam p50 -> 0.32, ham p05/p95 -> 0.05/0.83.
        "calib_midpoint": -11.4,
        "calib_scale": 1.3,
    },
    "en": {
        "path": "/opt/hu-classify/models/en_naturalness.json",
        # Fit the same way: ham p50 -> 0.49, spam p50 -> 0.59, ham p05/p95
        # -> 0.26/0.97. Direction is inverted vs. Hungarian (higher = more
        # spam-like) because on a Hungarian mail server "reads as fluent
        # English" is itself weakly spam-associated -- which is also exactly
        # why this must not be given a weight without local measurement: it
        # would penalise legitimate English correspondence.
        "calib_midpoint": -14.7,
        "calib_scale": 1.5,
    },
}

_naturalness_tables = {}
for _lang, _cfg in NATURALNESS_MODELS.items():
    with open(_cfg["path"], "r", encoding="utf-8") as _f:
        _nat = json.load(_f)
    _naturalness_tables[_lang] = {
        "logprob": _nat["trigram_logprob"],
        "floor": _nat["trigram_floor_logprob"],
        "calib_midpoint": _cfg["calib_midpoint"],
        "calib_scale": _cfg["calib_scale"],
    }


def detect_language_score(subject: str, text: str, label: str) -> float:
    combined = f"{subject} {text}".replace("\n", " ").strip()[:MAX_CHARS]
    if not combined:
        return 0.0
    labels, probs = _lang_model.predict(combined, k=1)
    if labels and labels[0] == f"__label__{label}":
        return round(float(probs[0]), 4)
    return 0.0


def score_naturalness(subject: str, text: str, lang: str) -> float:
    table = _naturalness_tables[lang]
    combined = strip_non_prose(f"{subject} {text}").lower().replace("\n", " ").strip()[:MAX_CHARS]
    padded = f"  {combined}  "
    trigrams = [padded[i:i + 3] for i in range(len(padded) - 2)]
    trigrams = [tg for tg in trigrams if tg.strip()]
    if not trigrams:
        return 0.0

    total_logprob = sum(table["logprob"].get(tg, table["floor"]) for tg in trigrams)
    avg_logprob = total_logprob / len(trigrams)

    # sigmoid((avg_logprob - midpoint) / scale) -> bounded (0, 1)
    z = (avg_logprob - table["calib_midpoint"]) / table["calib_scale"]
    return round(1.0 / (1.0 + math.exp(-z)), 4)


class Handler(BaseHTTPRequestHandler):
    server_version = "hu-classify/0.2"

    def log_message(self, fmt, *args):
        pass  # systemd journal captures what matters via print(), keep HTTP noise out

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/classify":
            self.send_response(404)
            self.end_headers()
            return

        qs = parse_qs(parsed.query)
        length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(length) if length else b""

        delay_ms = int(qs.get("delay_ms", ["0"])[0])
        if delay_ms:
            time.sleep(delay_ms / 1000.0)

        if qs.get("http_error", ["0"])[0] == "1":
            self.send_response(500)
            self.end_headers()
            return

        if qs.get("malformed", ["0"])[0] == "1":
            payload = b"{not valid json"
        else:
            try:
                req = json.loads(body_bytes.decode("utf-8", errors="replace")) if body_bytes else {}
            except json.JSONDecodeError:
                req = {}
            subject, text = req.get("subject", ""), req.get("text", "")
            reply = {
                "hu_language": detect_language_score(subject, text, "hu"),
                "hu_naturalness": score_naturalness(subject, text, "hu"),
                "en_language": detect_language_score(subject, text, "en"),
                "en_naturalness": score_naturalness(subject, text, "en"),
                "hu_spam": score_hu_spam(subject, text),
                **PLACEHOLDER,
            }
            payload = json.dumps(reply).encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
