# Hungarian brand names criminals impersonate in From display-names/subjects.
# Regexp map for HU_BRAND_NAME (multimap.conf). Case-insensitive.
# Managed by hand — extend as campaigns appear (source: 2026-08-22 OTP/
# MagyarPosta phishing wave from a compromised univ-pau.fr account).
/\bOTP\s*(BANK|HUNGARY)?\b/i
/\bMagyar\s*Posta\b/i
/\bMagyarPosta\b/i
/\bK&H\b/i
/\bErste\b/i
/\bRaiffeisen\b/i
/\bRevolut\b/i
/\bFoxpost\b/i
/\bGLS\b/i
/\bDPD\b/i
/\bMÁV\b/i
#
# NAV is deliberately ABSENT from this map. This multimap matches the
# From-domain at eTLD+1 (filter = email:domain:tld) and gov.hu is not a
# public suffix, so every *.gov.hu sender collapses to "gov.hu": listing
# gov.hu as NAV's real domain whitelisted the whole public sector, and
# listing nav.gov.hu instead can never match, which scored genuine NAV
# mail +5.0. NAV is covered by brand_definitions.json, whose Lua rule
# compares the full From-domain and can tell the two apart.
