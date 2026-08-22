# The REAL sending domains of the brands in hu_brand_names.re: a message may
# NOTE: bare gov.hu was removed 2026-08-22. It is NOT a public suffix, so
# rspamd's eTLD+1 filter turns EVERY *.gov.hu sender into gov.hu, which
# whitelisted the entire Hungarian public-sector namespace against every
# brand check -- precisely the compromised-legitimate-account case this
# guard exists for. nav.gov.hu alone covers NAV.
# name a brand only if its From-domain is (a subdomain of) one of these.
otpbank.hu
otpbankdirekt.hu
posta.hu
kh.hu
khbank.hu
erstebank.hu
raiffeisen.hu
revolut.com
wise.com
foxpost.hu
gls-hungary.com
gls-group.eu
dpd.hu
mav.hu
mavcsoport.hu
gls.de
dpd.com
mav-start.hu
