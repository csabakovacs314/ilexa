-- brand_guard.lua — brand impersonation checks against a foreign From-domain:
--   BRAND_DN_SPOOF   (2.5) From display-name claims a protected brand
--                          (OTP, Magyar Posta, PayPal, ...), fuzzily
--   BRAND_ADDR_SPOOF (1.0) From localpart claims one (magyarposta@gmail.com)
--   BRAND_SUBJ_SPOOF (1.0) Subject names one plainly (weak: webshops
--                          legitimately write "GLS", accountants "NAV")
--   BRAND_SUBJ_OBFUS (3.0) Subject names one only after homoglyph/digit
--                          folding ("0TP", Cyrillic) — deliberate disguise
--   BRAND_LURE       (2.0) ON TOP of any of the above: the text also uses
--                          classic phishing lure language (any configured
--                          language). Never fires on its own — "please
--                          verify your account" is also what a genuine
--                          password reset says.
--
-- Language-neutral by construction: matching folds case, accents, homoglyphs
-- and lookalike digits, so the same code covers Hungarian and English (and
-- anything else added to the two data files). LANGUAGE lives in the data,
-- never here.
--
-- Data files (both standing config, seeded once by the installer and then
-- managed from the ilexa console — Rendszer → Márkavédelem — or by
-- qa-brand-guard.sh; edits survive re-runs):
--   /etc/rspamd/local.d/brand_definitions.json   brands, name variants, real domains
--   /etc/rspamd/local.d/brand_lures.json         lure phrases per language
--
-- A variant starting with "=" only matches the WHOLE display name (for brand
-- names that are also ordinary words, e.g. "wise", "visa", "apple"); such
-- variants take no part in Subject/localpart matching at all.
--
-- Failure behaviour: any problem with the definitions file logs one error
-- and leaves the symbols unregistered — mail flow is never affected. A
-- missing or broken lures file only disables BRAND_LURE.
--
-- NOTE: rspamd executes this once at worker START. A `systemctl reload` does
-- NOT re-run it; changing this file or either data file needs a restart
-- (which is what qa-brand-guard.sh apply does).

if confighelp then return end

local rspamd_util   = require "rspamd_util"
local rspamd_logger = require "rspamd_logger"
local ucl           = require "ucl"

local DEFS  = '/etc/rspamd/local.d/brand_definitions.json'
local LURES = '/etc/rspamd/local.d/brand_lures.json'

local function load_json(path)
  local f = io.open(path, 'r')
  if not f then return nil, 'missing' end
  local raw = f:read('*a'); f:close()
  if not raw or #raw == 0 then return nil, 'empty' end
  local parser = ucl.parser()
  local ok, err = parser:parse_string(raw)
  if not ok then return nil, err end
  return parser:get_object(), nil
end

-- Common visual digit/symbol substitutions criminals use in display names.
-- transliterate() already folds case, accents and most non-Latin scripts.
local subst = {
  ['0'] = 'o', ['1'] = 'l', ['3'] = 'e', ['4'] = 'a',
  ['5'] = 's', ['7'] = 't', ['@'] = 'a', ['$'] = 's',
}

-- Cyrillic/Greek homoglyphs mapped by GLYPH (what the reader sees), because
-- transliterate maps by SOUND: Cyrillic "ОТР" transliterates to "otr" while
-- the recipient reads "OTP". Applied before transliterate; leftovers still
-- fall through to it.
local homoglyphs = {
  ['а']='a', ['А']='a', ['в']='b', ['В']='b', ['е']='e', ['Е']='e',
  ['к']='k', ['К']='k', ['м']='m', ['М']='m', ['н']='h', ['Н']='h',
  ['о']='o', ['О']='o', ['р']='p', ['Р']='p', ['с']='c', ['С']='c',
  ['т']='t', ['Т']='t', ['у']='y', ['У']='y', ['х']='x', ['Х']='x',
  ['і']='i', ['І']='i', ['ѕ']='s', ['Ѕ']='s', ['ј']='j',
  ['α']='a', ['ε']='e', ['ι']='i', ['κ']='k', ['ο']='o', ['ρ']='p',
  ['τ']='t', ['υ']='u', ['χ']='x',
  ['Α']='a', ['Β']='b', ['Ε']='e', ['Η']='h', ['Ι']='i', ['Κ']='k',
  ['Μ']='m', ['Ν']='n', ['Ο']='o', ['Ρ']='p', ['Τ']='t', ['Υ']='y',
  ['Χ']='x',
}

-- Plain fold: what an honest writer could have typed (accents and case fold —
-- "MÁV" is a mention, not obfuscation). Also the fold used for lure phrases.
local function normalize_plain(s)
  -- transliterate returns an rspamd_text userdata (no :gsub) — force a string
  s = tostring(rspamd_util.transliterate(s) or '')
  s = s:lower()
  s = s:gsub('[^a-z0-9]+', ' ')
  s = s:gsub('^%s+', ''):gsub('%s+$', '')
  return s
end

-- Full fold: additionally undoes homoglyph and lookalike-digit disguises.
-- Text that names a brand only under this fold was deliberately disguised.
local function normalize(s)
  for k, v in pairs(homoglyphs) do s = s:gsub(k, v) end
  s = tostring(rspamd_util.transliterate(s) or '')
  s = s:lower()
  s = s:gsub('[013457@$]', subst)
  s = s:gsub('[^a-z0-9]+', ' ')
  s = s:gsub('^%s+', ''):gsub('%s+$', '')
  return s
end

-- Iterate a JSON array defensively.
--
-- Both data files are documented as hand-editable standing config, so
-- "variants": "otp" instead of ["otp"] is expected operator usage -- and in
-- Lua 5.1 (which rspamd runs) ipairs() on a scalar RAISES. rspamd loads
-- lua.local.d/*.lua with a bare dofile and no pcall, so that error does not
-- just skip this rule: it aborts the whole custom-rule load, taking
-- hu_classify.lua and hu_phish_scam_log.lua with it, and rspamd then fails
-- its own configtest. The header of this file promises the opposite ("mail
-- flow is never affected"), so make that true: a mistyped value is reported
-- and skipped, never thrown.
local function each_list(v, what, ctx)
  if type(v) == 'table' then return ipairs(v) end
  if v ~= nil then
    rspamd_logger.errx(rspamd_config,
      'brand_guard: %s for %s must be a list, got %s -- ignoring it',
      what, ctx, type(v))
  end
  return ipairs({})
end

local function lev_le1(a, b)
  if math.abs(#a - #b) > 1 then return false end
  return rspamd_util.levenshtein_distance(a, b) <= 1
end

local defs, derr = load_json(DEFS)
if not defs then
  if derr ~= 'missing' then
    rspamd_logger.errx(rspamd_config, 'brand_guard: cannot parse %s: %s', DEFS, derr)
  end
  return
end
if defs.enabled == false then return end

local brands = {}
local all_domains = {}   -- every protected brand's real domains: hard skip set
for _, b in each_list(defs.brands, 'brands', 'the definitions file') do
  local entry = { id = tostring(b.id or '?'), variants = {}, domains = {} }
  for _, v in each_list(b.variants, 'variants', tostring(b.id or '?')) do
    v = tostring(v)
    local exact = v:sub(1, 1) == '='
    local bare = exact and v:sub(2) or v
    local vn = normalize(bare)
    -- BOTH folds are kept. The aggressive fold (vn) is what text is matched
    -- against; the plain fold (vp) is what the SPOOF-vs-OBFUS test needs.
    -- Storing only vn meant a variant containing a digit ("office 365" ->
    -- "office e6s") could never be found in a digit-PRESERVING fold, so the
    -- discriminator answered "deliberate disguise" every time and ordinary
    -- Office 365 mail scored 3.0 instead of 1.0.
    local vp = normalize_plain(bare)
    -- 1-2 char variants match half the alphabet at distance 1; refuse them
    -- here rather than trusting every editor of the JSON.
    if #vn >= 3 then
      entry.variants[#entry.variants + 1] = { v = vn, vp = vp, exact = exact }
    end
  end
  for _, d in each_list(b.domains, 'domains', tostring(b.id or '?')) do
    d = tostring(d):lower()
    entry.domains[d] = true
    all_domains[d] = true
  end
  if #entry.variants > 0 then brands[#brands + 1] = entry end
end

if #brands == 0 then return end

-- Lure phrases: flat { normalized_phrase, lang } list. Optional feature.
local lures = {}
do
  local ldata, lerr = load_json(LURES)
  if not ldata then
    if lerr ~= 'missing' then
      rspamd_logger.errx(rspamd_config, 'brand_guard: cannot parse %s: %s', LURES, lerr)
    end
  elseif ldata.enabled ~= false then
    -- pairs() on a scalar raises exactly like ipairs(), so the container
    -- gets the same treatment as the lists inside it.
    local phrases = ldata.phrases
    if phrases ~= nil and type(phrases) ~= 'table' then
      rspamd_logger.errx(rspamd_config,
        'brand_guard: "phrases" must be an object, got %s -- ignoring the lure file',
        type(phrases))
      phrases = nil
    end
    for lang, list in pairs(phrases or {}) do
      for _, p in each_list(list, 'phrases', tostring(lang)) do
        local pn = normalize_plain(tostring(p))
        -- Short phrases match far too much prose to be evidence of anything.
        if #pn >= 8 then
          lures[#lures + 1] = { p = pn, lang = tostring(lang) }
        end
      end
    end
  end
end

-- Word-containment of a non-exact variant in normalized text.
-- Exact-only ("=") variants are dictionary words (visa, apple, meta...):
-- meaningful for a whole display name, meaningless inside a subject or a
-- localpart, so they are skipped here.
local function contains_variant(norm)
  local padded = ' ' .. norm .. ' '
  for _, b in ipairs(brands) do
    for _, vt in ipairs(b.variants) do
      if not vt.exact and padded:find(' ' .. vt.v .. ' ', 1, true) then
        return b, vt
      end
    end
  end
  return nil
end

local function check_display_name(dn_norm)
  local tokens = {}
  for t in dn_norm:gmatch('%S+') do
    tokens[#tokens + 1] = t
    if #tokens >= 12 then break end
  end
  local padded = ' ' .. dn_norm .. ' '
  for _, b in ipairs(brands) do
    for _, vt in ipairs(b.variants) do
      local v, hit = vt.v, false
      if vt.exact then
        -- EXACT means exact. These are ordinary words ("visa", "apple",
        -- "meta", "ups") marked '=' precisely so they cannot spread; allowing
        -- one edit spread them anyway -- ubs/ups, vista/visa, beta/meta are
        -- all distance 1, so genuine mail from UBS or a travel agency scored
        -- 2.5. Both this file's header and GUIDE.md already promised whole-
        -- name-only matching; this makes that true.
        hit = (dn_norm == v)
      else
        if padded:find(' ' .. v .. ' ', 1, true) then
          hit = true
        elseif #v >= 4 and lev_le1(dn_norm, v) then
          -- Fuzzy matching needs >= 4 characters, the same floor the token
          -- path below already used. At 3 characters an edit of distance 1
          -- reaches half the dictionary: max/mav, dvd/dpd, nap/nav, ubs/ups.
          -- Nothing real is lost, because the DISGUISES are caught by the
          -- folds, not by edit distance -- "0TP Bank" folds to "otp bank" and
          -- "Micr0soft" to "microsoft", both exact containment matches.
          hit = true
        elseif #v >= 4 and not v:find(' ', 1, true) then
          for _, t in ipairs(tokens) do
            if lev_le1(t, v) then hit = true; break end
          end
        end
      end
      if hit then return b, vt end
    end
  end
  return nil
end

-- Subject + the head of each text part, plainly folded. Bounded on purpose:
-- lure phrases live in the opening pitch, and scanning whole newsletters
-- would cost CPU for no additional signal.
local function lure_hit(task, subj)
  if #lures == 0 then return nil end
  local chunks = {}
  if subj then chunks[#chunks + 1] = subj end
  for _, part in ipairs(task:get_text_parts() or {}) do
    local c = part:get_content()
    if c then
      c = tostring(c)
      chunks[#chunks + 1] = (#c > 4000) and c:sub(1, 4000) or c
    end
    if #chunks >= 3 then break end
  end
  for _, chunk in ipairs(chunks) do
    local norm = normalize_plain(chunk)
    for _, l in ipairs(lures) do
      if norm:find(l.p, 1, true) then return l end
    end
  end
  return nil
end

local function brand_guard_cb(task)
  -- Authenticated submissions are our own users; the spoof economics only
  -- exist for inbound mail.
  if task:get_user() then return end

  local from = task:get_from('mime')
  if not from or not from[1] then return end
  local fdom = (from[1].domain or ''):lower()
  if fdom == '' then return end
  local tld = rspamd_util.get_tld(fdom) or fdom

  -- Genuine brand mail (and cross-brand mentions between genuine brand
  -- domains, e.g. a bank newsletter naming another bank) is never a spoof.
  if all_domains[fdom] or all_domains[tld] then return end

  local impersonation = false

  -- 1. Display name: fuzzy (containment + levenshtein), the strongest claim.
  local dn = from[1].name
  if dn and #dn >= 2 then
    local dn_norm = normalize(dn)
    if #dn_norm >= 3 and #dn_norm <= 120 then
      local b, vt = check_display_name(dn_norm)
      if b then
        impersonation = true
        task:insert_result('BRAND_DN_SPOOF', 1.0,
          string.format('%s:%s:%s', b.id, vt.v, tld))
      end
    end
  end

  -- 2. From-address localpart claiming a brand (magyarposta@gmail.com).
  local lp = from[1].user
  if lp and #lp >= 3 and #lp <= 100 then
    local b, vt = contains_variant(normalize(lp))
    if b then
      impersonation = true
      task:insert_result('BRAND_ADDR_SPOOF', 1.0,
        string.format('%s:%s:%s', b.id, vt.v, tld))
    end
  end

  -- 3. Subject naming a brand. A plain mention is weak evidence — webshops
  -- legitimately write "GLS", accountants write "NAV" — but a mention that
  -- only appears after homoglyph/digit folding ("0TP", Cyrillic МАV) is a
  -- deliberate disguise and scores accordingly.
  local subj = task:get_subject()
  if subj and #subj >= 3 then
    if #subj > 400 then subj = subj:sub(1, 400) end
    local full = normalize(subj)
    if #full >= 3 then
      local b, vt = contains_variant(full)
      if b then
        impersonation = true
        -- Compare like with like: the PLAIN fold of the subject against the
        -- PLAIN fold of the variant. Searching for the aggressively-folded
        -- variant here could never succeed for any variant containing a
        -- digit, so those were always reported as deliberate disguise.
        local plain = normalize_plain(subj)
        local sym = (' ' .. plain .. ' '):find(' ' .. vt.vp .. ' ', 1, true)
                    and 'BRAND_SUBJ_SPOOF' or 'BRAND_SUBJ_OBFUS'
        task:insert_result(sym, 1.0, string.format('%s:%s:%s', b.id, vt.v, tld))
      end
    end
  end

  -- 4. Lure language, ONLY alongside an impersonation hit above.
  if impersonation then
    local l = lure_hit(task, subj)
    if l then
      task:insert_result('BRAND_LURE', 1.0, string.format('%s:%s', l.lang, l.p))
    end
  end
end

local parent_id = rspamd_config:register_symbol({
  name = 'BRAND_GUARD',
  type = 'callback',
  callback = brand_guard_cb,
  score = 0.0,
  description = 'Brand impersonation checks (display name, From localpart, Subject, lure language)',
  -- Our OWN group, not rspamd's stock 'phishing'.
  --
  -- scores.d/phishing_group.conf caps that group at max_score = 10.0, and it
  -- already holds PHISHING (4.0), PHISHED_OPENPHISH and PHISHED_PHISHTANK
  -- (7.0 each). On a message that trips real phishing detection AND brand
  -- impersonation -- exactly the case this rule exists for -- the group total
  -- was clamped and the brand evidence could contribute nothing, silently.
  -- The sibling rule hu_classify.lua uses its own group for the same reason.
  -- No cap is set here: the five symbols top out around 8.5 together, well
  -- under the reject threshold, so they cannot run away on their own.
  group = 'brand_guard',
})

for _, sym in ipairs({
  { name = 'BRAND_DN_SPOOF', score = 2.5,
    description = 'From display-name resembles a protected brand but the From-domain is not that brand' },
  { name = 'BRAND_ADDR_SPOOF', score = 1.0,
    description = 'From-address localpart claims a protected brand from a foreign domain' },
  { name = 'BRAND_SUBJ_SPOOF', score = 1.0,
    description = 'Subject names a protected brand but the sender is a foreign domain' },
  { name = 'BRAND_SUBJ_OBFUS', score = 3.0,
    description = 'Subject names a protected brand in disguised form (homoglyph/digit tricks) from a foreign domain' },
  { name = 'BRAND_LURE', score = 2.0,
    description = 'Brand-impersonating message also uses classic phishing lure language' },
}) do
  rspamd_config:register_symbol({
    name = sym.name, type = 'virtual', parent = parent_id,
    score = sym.score, description = sym.description, group = 'brand_guard',
  })
end
