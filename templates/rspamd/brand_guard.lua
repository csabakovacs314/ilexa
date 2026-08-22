-- brand_guard.lua — HU_BRAND_DN_SPOOF: the From display-name claims a
-- protected brand (OTP, Magyar Posta, ...) but the From-domain is not one of
-- that brand's real domains.
--
-- This is the fuzzy companion of the HU_BRAND_NAME/HU_BRAND_FROMDOM multimap
-- pair: where the multimap needs the literal brand string, this rule also
-- catches lookalikes — "0TP Bank", "Magyar  Pósta", Cyrillic "ОТР" — via
-- rspamd_util.transliterate + a digit-substitution fold + levenshtein <= 1.
-- Deliberately observational-grade scoring (2.5): the composite
-- HU_BRAND_STRONG in composites.conf merges it with the multimap verdict so
-- the same evidence is never double-counted.
--
-- Brand definitions: /etc/rspamd/local.d/brand_definitions.json, managed by
-- qa-brand-guard.sh (ilexa console, Rendszer → Márkavédelem card). Schema:
--   { "enabled": true,
--     "brands": [ { "id": "otp", "name": "OTP Bank",
--                   "variants": ["otp", "otp bank", "=wise-style-exact"],
--                   "domains":  ["otpbank.hu", ...] } ] }
-- A variant starting with "=" only matches the WHOLE display name (for brand
-- names that are also ordinary words, e.g. "wise"); all others also match as
-- a word inside the display name and at edit distance 1.
--
-- Failure behaviour: any problem with the definitions file logs one error
-- and leaves the symbol unregistered — mail flow is never affected.

if confighelp then return end

local rspamd_util   = require "rspamd_util"
local rspamd_logger = require "rspamd_logger"
local ucl           = require "ucl"

local DEFS = '/etc/rspamd/local.d/brand_definitions.json'

local function load_defs()
  local f = io.open(DEFS, 'r')
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

local function normalize(s)
  for k, v in pairs(homoglyphs) do s = s:gsub(k, v) end
  -- transliterate returns an rspamd_text userdata (no :gsub) — force a string
  s = tostring(rspamd_util.transliterate(s) or '')
  s = s:lower()
  s = s:gsub('[013457@$]', subst)
  s = s:gsub('[^a-z0-9]+', ' ')
  s = s:gsub('^%s+', ''):gsub('%s+$', '')
  return s
end

local function lev_le1(a, b)
  if math.abs(#a - #b) > 1 then return false end
  return rspamd_util.levenshtein_distance(a, b) <= 1
end

local defs, derr = load_defs()
if not defs then
  if derr ~= 'missing' then
    rspamd_logger.errx(rspamd_config, 'brand_guard: cannot parse %s: %s', DEFS, derr)
  end
  return
end
if defs.enabled == false then return end

local brands = {}
local all_domains = {}   -- every protected brand's real domains: hard skip set
for _, b in ipairs(defs.brands or {}) do
  local entry = { id = tostring(b.id or '?'), variants = {}, domains = {} }
  for _, v in ipairs(b.variants or {}) do
    v = tostring(v)
    local exact = v:sub(1, 1) == '='
    local vn = normalize(exact and v:sub(2) or v)
    -- 1-2 char variants match half the alphabet at distance 1; refuse them
    -- here rather than trusting every editor of the JSON.
    if #vn >= 3 then
      entry.variants[#entry.variants + 1] = { v = vn, exact = exact }
    end
  end
  for _, d in ipairs(b.domains or {}) do
    d = tostring(d):lower()
    entry.domains[d] = true
    all_domains[d] = true
  end
  if #entry.variants > 0 then brands[#brands + 1] = entry end
end

if #brands == 0 then return end

local function brand_guard_cb(task)
  -- Authenticated submissions are our own users; the spoof economics only
  -- exist for inbound mail.
  if task:get_user() then return false end

  local from = task:get_from('mime')
  if not from or not from[1] then return false end
  local dn = from[1].name
  if not dn or #dn < 2 then return false end
  local fdom = (from[1].domain or ''):lower()
  if fdom == '' then return false end
  local tld = rspamd_util.get_tld(fdom) or fdom

  -- Genuine brand mail (and cross-brand mentions between genuine brand
  -- domains, e.g. a bank newsletter naming another bank) is never a spoof.
  if all_domains[fdom] or all_domains[tld] then return false end

  local dn_norm = normalize(dn)
  if #dn_norm < 3 or #dn_norm > 120 then return false end
  local padded = ' ' .. dn_norm .. ' '
  local tokens = {}
  for t in dn_norm:gmatch('%S+') do
    tokens[#tokens + 1] = t
    if #tokens >= 12 then break end
  end

  for _, b in ipairs(brands) do
    for _, vt in ipairs(b.variants) do
      local v, hit = vt.v, false
      if vt.exact then
        hit = (dn_norm == v) or lev_le1(dn_norm, v)
      else
        if padded:find(' ' .. v .. ' ', 1, true) then
          hit = true
        elseif lev_le1(dn_norm, v) then
          hit = true
        elseif #v >= 4 and not v:find(' ', 1, true) then
          for _, t in ipairs(tokens) do
            if lev_le1(t, v) then hit = true; break end
          end
        end
      end
      if hit then
        return true, 1.0, string.format('%s:%s:%s', b.id, v, tld)
      end
    end
  end
  return false
end

rspamd_config:register_symbol({
  name = 'HU_BRAND_DN_SPOOF',
  type = 'normal',
  callback = brand_guard_cb,
  score = 2.5,
  description = 'From display-name resembles a protected brand but the From-domain is not that brand',
  group = 'phishing',
})
