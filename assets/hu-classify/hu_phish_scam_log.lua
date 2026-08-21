-- Prospective ground-truth logging for a future HU_PHISHING/HU_SCAM model.
--
-- WHY THIS EXISTS: the historical MailScanner archive HU_SPAM was trained
-- from (see hu-classify-stub.py's docstring) has no phishing/scam-specific
-- label at all -- checked directly 2026-08-21 against mailscanner.maillog
-- (no isphish/isscam column, only generic isspam) and its own SpamAssassin
-- report text (zero of 25,106 archived spam rows mention any PHISH/SCAM/
-- 419/ADVANCE_FEE-named rule). Unlike HU_SPAM's original data wall, there
-- is no rescue path via more extraction: the source system never captured
-- that distinction, at any volume. The only way forward is PROSPECTIVE --
-- log which messages rspamd's OWN phishing/scam-indicative symbols fire on
-- from here forward, and correlate that against the existing 30-day mail
-- archive (BCC to archive@linuxforum.hu) once enough real examples
-- accumulate, likely weeks to months out. This module is that logging
-- step, nothing more -- no training happens here, no symbol score changes.
--
-- WHAT COUNTS AS A HIT: a case-insensitive substring match for "phish" or
-- "scam" against every symbol name that actually fired (task:get_symbols_all()),
-- plus a short explicit list for symbols that don't spell it out (e.g.
-- PH_SURBL_MULTI). Deliberately pattern-based rather than an enumerated
-- symbol list: the community-rules feed (martinschaible/rspamd-rules,
-- synced daily) adds/renames individual phishing/scam maps on its own
-- schedule -- hundreds of them today (body.en.phishing.banking,
-- subject.de.scam.donation, PHISHING_EN, ...) -- and every one embeds
-- "phishing"/"scam" literally in its symbol name by the feed's own
-- convention. A hardcoded list would silently rot as that feed evolves;
-- this doesn't need updating when it does.
--
-- CORRELATION KEY: the message's own Message-ID header, not a Dovecot IMAP
-- UID or any quarantine-admin database key. The archive is a raw BCC of
-- the same message, so it carries the identical Message-ID -- a future
-- training script can doveadm-fetch the archive mailbox and match headers
-- directly, with zero coupling to that app's own archive_index schema.
--
-- NEGATIVES ARE NOT LOGGED HERE, DELIBERATELY: only messages with at least
-- one phish/scam-pattern hit get a line. This is not "ham doesn't matter"
-- -- every archived message NOT in this log is already an implicit
-- negative, recoverable the same way mw_train_spam_router2.py's collect()
-- already samples ham for HU_SPAM: by absence, from the existing archive
-- population. Logging every message here would just duplicate what the
-- archive's own is_spam/timestamp index already answers, for no benefit
-- and a larger footprint.
--
-- WHAT GETS LOGGED: timestamp, Message-ID, phish/scam booleans, and the
-- actual matched symbol names (to spot-check the pattern match later, not
-- for training). Never the message body/subject -- that stays in the
-- existing archive, which already has its own retention/access controls;
-- duplicating it here would be a second, less-controlled copy of the same
-- sensitive content for no benefit.
--
-- FAILS OPEN: wrapped in pcall. Any error here must never affect scoring
-- or delivery -- no symbol score is registered, and a logging failure is
-- caught and logged to rspamd's own error log, never surfaced as a scan
-- failure or a missing symbol.
--
-- ROTATION: covered automatically by the existing /etc/logrotate.d/rspamd
-- glob (/var/log/rspamd/*log) -- no separate config needed.

local rspamd_logger = require "rspamd_logger"

local LOG_PATH = "/var/log/rspamd/hu-phish-scam-labels.log"

local EXPLICIT_PHISH_SYMBOLS = {
  PH_SURBL_MULTI = true,
}

-- HU_PHISHING/HU_SCAM are this project's OWN always-present placeholder
-- symbols (inserted unconditionally at weight 0.0 by hu_classify.lua on
-- every message, real signal or not) -- their names contain "phish"/"scam"
-- literally, so without this exclusion every single message would match
-- itself and "only log messages with a hit" would silently become "log
-- every message". Caught by testing before shipping, not by inspection.
local SELF_SYMBOLS = {
  HU_PHISHING = true,
  HU_SCAM = true,
}

local function contains_ci(haystack, needle)
  return haystack:lower():find(needle, 1, true) ~= nil
end

local function json_string_array(t)
  local q = {}
  for _, v in ipairs(t) do
    table.insert(q, string.format('%q', v))
  end
  return '[' .. table.concat(q, ',') .. ']'
end

local function classify_symbols(task)
  local phish_hits, scam_hits = {}, {}
  local all = task:get_symbols_all()
  if not all then
    return phish_hits, scam_hits
  end
  for _, s in ipairs(all) do
    local name = s.name or ''
    if not SELF_SYMBOLS[name] then
      if contains_ci(name, 'phish') or EXPLICIT_PHISH_SYMBOLS[name] then
        table.insert(phish_hits, name)
      end
      if contains_ci(name, 'scam') then
        table.insert(scam_hits, name)
      end
    end
  end
  return phish_hits, scam_hits
end

local function hu_phish_scam_log_cb(task)
  local ok, err = pcall(function()
    local phish_hits, scam_hits = classify_symbols(task)
    if #phish_hits == 0 and #scam_hits == 0 then
      return
    end
    local mid = task:get_message_id()
    if not mid or mid == '' then
      return -- unusable without a correlation key
    end
    local line = string.format(
      '{"ts":%d,"message_id":%s,"phish":%s,"scam":%s,"phish_symbols":%s,"scam_symbols":%s}\n',
      os.time(),
      string.format('%q', mid),
      #phish_hits > 0 and 'true' or 'false',
      #scam_hits > 0 and 'true' or 'false',
      json_string_array(phish_hits),
      json_string_array(scam_hits)
    )
    local f = io.open(LOG_PATH, 'a')
    if f then
      f:write(line)
      f:close()
    end
  end)
  if not ok then
    rspamd_logger.errx(task, 'hu_phish_scam_log: %s', err)
  end
end

rspamd_config:register_symbol({
  name = 'HU_PHISH_SCAM_LOG',
  type = 'postfilter',
  callback = hu_phish_scam_log_cb,
  description = 'Prospective ground-truth logging for a future HU_PHISHING/HU_SCAM model -- no score, logging only',
})
