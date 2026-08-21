# Attachment extensions treated as dangerous, one per line, no leading dot.
# Matched by the DANGEROUS_ATTACHMENT_EXT multimap rule against ATTACHMENT
# FILENAMES ONLY -- it cannot see inside an archive. Filenames within archives
# are covered separately by ClamAV + Sanesecurity's foxhole_filename database
# (verified: a bare invoice.exe scans clean, the same file zipped is caught).
#
# This rule SCORES, it does not reject: a hit lands the message well above the
# tag threshold so it is marked and delivered, and it is archived and therefore
# recoverable. Only a hit combined with further spam signal reaches the reject
# threshold. Chosen deliberately over a hard block so that a legitimate .jar or
# .msi from a known correspondent is not destroyed with no way to retrieve it.
#
# Executables and installers
exe
com
scr
pif
bat
cmd
cpl
msi
msp
mst
hta
jar
# Windows Script Host / scripting
vbs
vbe
js
jse
wsf
wsh
wsc
sct
shs
shb
scf
# Shortcuts, registry, config
lnk
reg
ins
isp
its
inf
job
xnk
prf
prg
cnf
# PowerShell
ps1
ps1xml
ps2
ps2xml
psc1
psc2
# Help and certificate formats abused as droppers
chm
hlp
crt
der
# Office/Access macro-bearing and legacy formats
mda
mde
mdz
mad
maf
mag
mam
maq
mar
mas
mat
mav
maw
vsmacros
vbp
# Misc historically abused
gadget
ceo
mau
