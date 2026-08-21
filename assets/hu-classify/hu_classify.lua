-- Language-based spam classifier — Phase 1 (Hungarian + English language
-- detection live).
--
-- Calls hu-classify-stub.service (127.0.0.1:11336) for every message with
-- text content, unconditionally — still no gate on the call itself (that's
-- fine, the call is cheap; each symbol's own value is what downstream logic
-- should gate on once anything downstream exists).
--
-- HU_LANGUAGE/EN_LANGUAGE are real: the service runs fastText lid.176 per
-- message. rspamd's own built-in part:get_language() was tested against
-- this host's real Hungarian mail 2026-08-18 and missed 4 of 5 realistic
-- cases (short messages, diacritic-free Hungarian) — see the plan's Phase 1
-- notes. HU_NATURALNESS/EN_NATURALNESS are also real (per-language
-- Wikipedia-trigram coherence scores). HU_SPAM is real too as of
-- 2026-08-19 — a character 3-5-gram Naive-Bayes router, honest grouped-
-- split production precision 91%, promoted after word-based attempts
-- plateaued at 57% (see the service's own docstring for the full history).
-- HU_PHISHING/HU_SCAM remain fixed placeholders, not built yet; no English
-- HU_SPAM equivalent attempted (see the service's own docstring for why).
--
-- Fails open by design: any HTTP error, timeout, non-200, or malformed JSON
-- means none of the symbols fire and this task is scored exactly as if
-- the module were absent. Every symbol carries score = 0.0 (shadow mode)
-- until its own measurement window justifies a weight — see
-- /root/.claude/plans/still-drifting-nagy.md. The real computed value is
-- still attached as an option string on each symbol so the shadow-mode
-- window has something to actually measure. The observation-window clock
-- itself (how long this has been switched on) is tracked by
-- qa-hu-classify.sh, not here.
--
-- Console on/off toggle (Rendszer page): reads STATE_FILE fresh on every
-- message rather than following rspamd's own module-enable convention
-- (local.d/<module>.conf's enabled key + reload) — a plain file read costs
-- microseconds and needs no reload at all, sidestepping the "reload doesn't
-- respawn every worker" gotcha found while building this module (see memory
-- rspamd_reload_testing_gotchas.md). Absent file = disabled: a fresh install
-- ships this module structurally present but inert until an admin explicitly
-- turns it on from the console.

local rspamd_http = require "rspamd_http"
local rspamd_logger = require "rspamd_logger"
local ucl = require "ucl"

local settings = {
  url = 'http://127.0.0.1:11336/classify',
  timeout = 2.0, -- generous vs. the <5ms server-side target; this bounds worst case, not the expected case
}

local STATE_FILE = '/etc/rspamd/local.d/hu_classify.state'
-- Per-symbol weights, read ONCE at config load because rspamd fixes a
-- symbol's score when it is registered -- unlike STATE_FILE, which is
-- re-read per message. Changing a weight therefore needs an rspamd restart,
-- which qa-hu-classify.sh performs.
--
-- A file this module owns outright, deliberately NOT an entry in
-- local.d/groups.conf: that file is shared with the RBL/feed weights, and a
-- script assuming exclusive ownership of a shared rspamd config file is
-- exactly what destroyed a live Abusix config for hours on 2026-08-16.
-- Nothing else writes here, so nothing else can be clobbered.
--
-- Absent or unparsable = every symbol stays 0.0, which is the shipped state.
local WEIGHTS_FILE = '/etc/rspamd/local.d/hu_classify.weights'

local function load_weights()
  local w = {}
  local f = io.open(WEIGHTS_FILE, 'r')
  if not f then
    return w
  end
  for line in f:lines() do
    local name, val = line:match('^%s*([A-Z_]+)%s*=%s*(-?[%d%.]+)%s*$')
    if name and val then
      w[name] = tonumber(val) or 0.0
    end
  end
  f:close()
  return w
end

local hu_weights = load_weights()

local function hu_classify_enabled()
  local f = io.open(STATE_FILE, 'r')
  if not f then
    return false
  end
  local content = f:read('*l')
  f:close()
  return content == 'enabled'
end

rspamd_logger.infox(rspamd_config, 'hu_classify: module file loaded (Phase 1: language detection live)')

local function hu_classify_check(task)
  if not hu_classify_enabled() then
    return
  end

  local parts = task:get_text_parts()
  if not parts or #parts == 0 then
    return
  end

  local text = ''
  for _, p in ipairs(parts) do
    local c = p:get_content()
    if c then
      text = text .. tostring(c)
    end
  end
  if text == '' then
    return
  end

  local req_body = ucl.to_format({
    subject = task:get_subject() or '',
    text = text,
  }, 'json-compact', true)

  local function http_callback(err, code, resp_body)
    if err then
      rspamd_logger.infox(task, 'hu_classify: request failed, skipping (fail-open): %s', err)
      return
    end
    if code ~= 200 then
      rspamd_logger.infox(task, 'hu_classify: non-200 reply (%s), skipping (fail-open)', code)
      return
    end

    local parser = ucl.parser()
    local ok, parse_err = parser:parse_string(resp_body)
    if not ok then
      rspamd_logger.warnx(task, 'hu_classify: malformed JSON reply, skipping (fail-open): %s', parse_err)
      return
    end

    local d = parser:get_object()
    if not d then
      return
    end

    -- Score stays 0.0 (shadow mode, see the symbol registration below), but
    -- the real computed value is passed as an option string so it's visible
    -- in rspamc/JSON output and in the mail log -- otherwise a 0.0-weighted
    -- symbol is completely unobservable, which defeats the measurement
    -- window this whole phase depends on before any weight is assigned.
    if d.hu_language then
      task:insert_result('HU_LANGUAGE', d.hu_language, tostring(d.hu_language))
    end
    if d.hu_naturalness then
      task:insert_result('HU_NATURALNESS', d.hu_naturalness, tostring(d.hu_naturalness))
    end
    if d.en_language then
      task:insert_result('EN_LANGUAGE', d.en_language, tostring(d.en_language))
    end
    if d.en_naturalness then
      task:insert_result('EN_NATURALNESS', d.en_naturalness, tostring(d.en_naturalness))
    end
    if d.hu_spam then
      task:insert_result('HU_SPAM', d.hu_spam, tostring(d.hu_spam))
    end
    if d.hu_phishing then
      task:insert_result('HU_PHISHING', d.hu_phishing, tostring(d.hu_phishing))
    end
    if d.hu_scam then
      task:insert_result('HU_SCAM', d.hu_scam, tostring(d.hu_scam))
    end
  end

  rspamd_http.request({
    task = task,
    url = settings.url,
    method = 'post',
    mime_type = 'application/json',
    body = req_body,
    timeout = settings.timeout,
    callback = http_callback,
    log_obj = task,
    -- The stub is Python's stdlib http.server, which defaults to HTTP/1.0
    -- and closes the connection after every response. keepalive=true here
    -- let rspamd reuse an already-closed socket after the first request,
    -- poisoning every subsequent request with a fast connection-reset
    -- "error" that looked exactly like a working fail-open path. No
    -- persistent connections at this request volume; revisit only if a real
    -- service with proper HTTP/1.1 keep-alive replaces the stub.
    keepalive = false,
  })
end

local parent_id = rspamd_config:register_symbol({
  name = 'HU_CLASSIFY_CHECK',
  type = 'postfilter',
  callback = hu_classify_check,
  description = 'Async call to the local Hungarian classifier service',
})

local hu_symbols = {
  { name = 'HU_LANGUAGE', desc = 'fastText lid.176 confidence this message is Hungarian (live)' },
  { name = 'HU_NATURALNESS', desc = 'coherent-language-vs-gibberish detector, Hungarian Wikipedia trigrams (live)' },
  { name = 'EN_LANGUAGE', desc = 'fastText lid.176 confidence this message is English (live)' },
  { name = 'EN_NATURALNESS', desc = 'coherent-language-vs-gibberish detector, English Wikipedia trigrams (live)' },
  { name = 'HU_SPAM', desc = 'char 3-5-gram Naive-Bayes router, honest grouped-split production precision 91% (n=10 mean); still weight 0.0, base-rate too low to gate delivery alone' },
  { name = 'HU_PHISHING', desc = 'placeholder, not built yet' },
  { name = 'HU_SCAM', desc = 'placeholder, not built yet' },
}
for _, sym in ipairs(hu_symbols) do
  -- 0.0 unless an operator has explicitly activated this symbol from the
  -- console, which only offers the option once a measurement justifies it.
  local score = hu_weights[sym.name] or 0.0
  if score ~= 0.0 then
    rspamd_logger.infox(rspamd_config, 'hu_classify: %s ACTIVE at weight %s', sym.name, score)
  end
  rspamd_config:register_symbol({
    name = sym.name,
    type = 'virtual',
    parent = parent_id,
    score = score,
    group = 'hu_classify',
    description = sym.desc,
  })
end
