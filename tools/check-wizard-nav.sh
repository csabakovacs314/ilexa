#!/usr/bin/env bash
#
# check-wizard-nav.sh — drive the interactive wizard with a scripted whiptail.
#
# THE BUG CLASS THIS EXISTS FOR. The wizard's navigation (Exit on step 1, Back
# after it, Esc quits anywhere, Change... from the review) is a state machine
# spread over ~20 step functions, each with its own prefill and branch logic.
# None of it can be seen without a person at a terminal, and every earlier
# wizard bug was found exactly that way: by an operator, on a live install.
# This walks the real step functions through scripted sessions and pins:
#   - which dialog appears, in what order, titled "Step n of N: ..." with the
#     right N (conditional steps counted only where they are shown);
#   - the cancel button's label (Exit on step 1, Back after it) and that Esc
#     quits on the spot;
#   - that a revisited step is prefilled with the earlier answer, and that a
#     derived default follows its source when the earlier answer WAS the default;
#   - the variables the wizard leaves behind, including keys of a branch that
#     was taken and then undone (they must end as if never asked);
#   - that no password/API key is ever passed on whiptail's command line, and
#   - that the answer memory holding them is gone once the wizard ends;
#   - that an answer starting with "-" can be revisited (whiptail would read it
#     as an option -- the fake below rejects it exactly as popt does);
#   - the review and Change... values are what apply_defaults will APPLY (a
#     blank geoblock shows "ru cn br kr"), compared against a real
#     apply_defaults run on the same answers;
#   - a Change... carries on to answers that were just the derived default;
#   - the review text: human labels, nothing wider than the 78-column box;
#   - the no-terminal fallback runs straight through once, never loops;
#   - a step-state variable inherited from the environment cannot stop a
#     non-wizard screen's Exit button from exiting.
# Every session runs twice: under deploy.sh's own shell options (pipefail
# only) and under `set -euo pipefail`. Be clear what the second pass proves:
# collect_interactive runs the engine as `tui_wizard ... || rc=$?`, and bash
# suspends errexit for everything called on the left of `||` -- so it is the
# -u (no unset variable read anywhere in the wizard, the review's
# apply_defaults pass included) and pipefail half that is exercised, not -e.
#
# Runs against a COPY of deploy.sh with only its final `main "$@"` line
# removed -- no test seam is added to the shipped file -- and with a fake
# `whiptail` first on PATH that answers from a script, one line per dialog:
#   "0 <value>"   OK with that value ("0 =" = accept what is prefilled)
#   "1"           the cancel button (Exit/Back)      "255"  Esc
# Nothing is installed, no host state is read beyond `command -v`, and the
# rspamd key probe, timedatectl and tput are stubbed.
#
#   tools/check-wizard-nav.sh [--quiet]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

T=$(mktemp -d "${TMPDIR:-/tmp}/check-wizard-nav.XXXXXX") || exit 2
cleanup() { [ -n "${T:-}" ] && [ -d "$T" ] && rm -rf -- "$T"; }
trap cleanup EXIT

# ---- the copy of deploy.sh ---------------------------------------------------
last=$(tail -n 1 "$HERE/deploy.sh")
# shellcheck disable=SC2016  # the literal line, not an expansion
[ "$last" = 'main "$@"' ] || { echo "check-wizard-nav: deploy.sh no longer ends in 'main \"\$@\"' -- update this harness" >&2; exit 2; }
sed '$d' "$HERE/deploy.sh" > "$T/deploy.sh"
ln -s "$HERE/lib" "$T/lib"
printf 'cert\n' > "$T/cert.pem"; printf 'key\n' > "$T/key.pem"

# ---- the fake whiptail -------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/whiptail" <<'STUB'
#!/usr/bin/env bash
# Logs "kind|title|cancel-label|prefill" per call, answers from $WT_SCRIPT.
# Arguments are parsed the way whiptail's popt parses them: options anywhere,
# "--" ends them, and any OTHER argument starting with "-" is an unknown
# option -- real whiptail then exits 1 (the Back code) without drawing
# anything, which is exactly what a prefilled "-foo" answer used to trigger.
kind="" title="" cancel="" def="" pos=() tags=() ons=() items=()
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; pos+=("$@"); break ;;
    --title)         title=$2; shift 2 ;;
    --cancel-button|--no-button) cancel=$2; shift 2 ;;   # the button that is not OK
    --default-item)  def=$2; shift 2 ;;
    --backtitle|--ok-button|--yes-button) shift 2 ;;
    --scrolltext|--defaultno|--separate-output|--nocancel|--fullbuttons) shift ;;
    --inputbox|--passwordbox|--menu|--checklist|--radiolist|--yesno|--msgbox) kind=${1#--}; shift ;;
    -*) echo "UNKNOWN-OPTION $1" >> "$WT_LOG"; printf '%s: unknown option\n' "$1" >&2; exit 1 ;;
    *)  pos+=("$1"); shift ;;
  esac
done
text=${pos[0]:-}
case "$kind" in
  inputbox|passwordbox) [ "${#pos[@]}" -gt 3 ] && def=${pos[3]} ;;
  menu)
    for ((i = 4; i + 1 < ${#pos[@]}; i += 2)); do tags+=("${pos[$i]}"); items+=("${pos[$i]}|${pos[$((i + 1))]}"); done ;;
  checklist|radiolist)
    for ((i = 4; i + 2 < ${#pos[@]}; i += 3)); do [ "${pos[$((i + 2))]}" = on ] && ons+=("${pos[$i]}"); done
    def="${ons[*]}" ;;
esac
n=$(( $(cat "$WT_POS") + 1 )); echo "$n" > "$WT_POS"
printf '%s|%s|%s|%s\n' "$kind" "$title" "$cancel" "$def" >> "$WT_LOG"
case "$title" in
  Review*)            printf '%s\n' "$text" > "$WT_REVIEW" ;;
  "Change an answer") printf '%s\n' "${items[@]}" > "$WT_PICK" ;;
esac
line=$(sed -n "${n}p" "$WT_SCRIPT")
if [ -z "$line" ] || [ "$n" -gt 400 ]; then echo "EXHAUSTED at call $n" >> "$WT_LOG"; exit 255; fi
read -r rc val <<<"$line"
if [ "${val:-}" = "=" ]; then
  case "$kind" in
    menu)      val=${def:-${tags[0]:-}} ;;
    checklist) val=""; for t in "${ons[@]}"; do val="$val\"$t\" "; done ;;
    *)         val=$def ;;
  esac
fi
printf '%s' "${val:-}" >&2
exit "$rc"
STUB
chmod +x "$T/bin/whiptail"

KEYS="MAIL_FQDN MAIL_HOSTNAME PRIMARY_DOMAIN EXTRA_DOMAINS ADMIN_EMAIL ALERT_EMAIL
ADMIN_PASSWORD MAIL_STORE TIMEZONE TLS_MODE TLS_CUSTOM_CERT TLS_CUSTOM_KEY SPAM_REJECT
GEOBLOCK_COUNTRIES SSH_PORT ENABLE_OTX OTX_API_KEY SPAMHAUS_DQS_KEY ENABLE_FEEDS
ABUSECH_API_KEY ABUSEIPDB_API_KEY RSPAMD_ALLOW_UNSIGNED ENABLE_ARCHIVE
ARCHIVE_RETENTION_DAYS ENABLE_GREYLISTING SYSTEM_LANG ILEXA_LANG PASSWORD_EXPIRY_DAYS
ENABLE_LAST_LOGIN ENABLE_FTS_XAPIAN ENABLE_UNATTENDED ENABLE_MX_CHECK
ENABLE_KNOWN_SENDERS ENABLE_UNOFFICIAL_SIGS HARDEN_SSH_KEYONLY HARDEN_WEBMIN
HARDEN_KERNEL_AUTOREBOOT HARDEN_SMTP_TUNING HARDEN_SELINUX"

# ---- one wizard session, in its own process ------------------------------------
cat > "$T/run.sh" <<'RUN'
#!/usr/bin/env bash
set -o pipefail                       # deploy.sh's own options
for k in $KEYS; do unset "$k"; done   # nothing from the caller's environment
export MD_LOG="$CASE/install.log" MD_STATE_DIR="$CASE/state" MD_CRED_FILE="$CASE/cred"
source "$T/deploy.sh"
PKG_MGR=$WZ_PKG_MGR
_tui_ok() { [ "$WZ_TTY" = 1 ]; }
rspamd_key_importable() { [ "$WZ_RSPAMD_OK" = 1 ]; }
timedatectl() { echo Europe/Budapest; }
tput() { case "$1" in cols) echo 80 ;; lines) echo 40 ;; esac; }
clear() { :; }
md_abort() { echo ABORTED >> "$CASE/events"; exit 0; }
dump() { for k in "$@"; do
  if [ -n "${!k+x}" ]; then printf '%s=%s\n' "$k" "${!k}"; else printf '%s<unset>\n' "$k"; fi
done; }
[ "$WZ_STRICT" = 1 ] && set -euo pipefail
if [ "$WZ_MODE" = hostcheck ]; then
  # A non-wizard screen (show_sysinfo's host check): Exit must still abort.
  tui_msg "HOST CHECK" "is this the right machine?"
  echo RETURNED >> "$CASE/events"; exit 0
fi
collect_interactive
echo COMPLETED >> "$CASE/events"
{ dump $KEYS
  for k in _WZ_MEM _WZ_VAL; do declare -p "$k" >/dev/null 2>&1 && echo "$k=still-set" || echo "$k<unset>"; done
} > "$CASE/vars"
# ...and what apply_defaults makes of those answers, as main() runs next.
gen_pw() { echo GENERATED; }
apply_defaults >/dev/null 2>&1
dump $KEYS TLSRPT_RUA > "$CASE/effective"
RUN

pass=0; fail=0
CASE=""
ok()  { pass=$((pass + 1)); [ "$QUIET" = 1 ] || printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s: %s\n' "${CASE##*/}" "$1"; }

# run NAME PKG_MGR RSPAMD_OK TTY STRICT  (answers in $T/in, one per dialog)
# Not fed through a pipe: that would run this in a subshell, and CASE --
# which every expect_* reads -- would never reach the caller.
run() {
  CASE="$T/case-$1-$5"; mkdir -p "$CASE"
  cp "$T/in" "$CASE/script"; : > "$CASE/log"; echo 0 > "$CASE/pos"; : > "$CASE/events"
  [ "$QUIET" = 1 ] || printf '%s (%s)\n' "$1" "$([ "$5" = 1 ] && echo 'set -euo pipefail' || echo 'deploy.sh options')"
  env PATH="$T/bin:$PATH" T="$T" CASE="$CASE" KEYS="$KEYS" \
      WT_SCRIPT="$CASE/script" WT_LOG="$CASE/log" WT_POS="$CASE/pos" WT_REVIEW="$CASE/review" \
      WT_PICK="$CASE/pick" WZ_MODE="${WZ_MODE:-wizard}" \
      WZ_PKG_MGR="$2" WZ_RSPAMD_OK="$3" WZ_TTY="$4" WZ_STRICT="$5" \
      timeout 60 bash "$T/run.sh" > "$CASE/out" 2>&1
  local rc=$?
  [ "$rc" = 0 ] || bad "session exited $rc (timeout = 124): $(tail -n 3 "$CASE/out" | tr '\n' ' ')"
}
# expect_call N "kind|title|cancel|prefill" -- the Nth dialog shown
expect_call() {
  local got; got=$(sed -n "${1}p" "$CASE/log")
  if [ "$got" = "$2" ]; then ok "dialog $1: $2"; else bad "dialog $1: expected [$2] got [$got]"; fi
}
expect_calls() { # total number of dialogs shown
  local got; got=$(wc -l < "$CASE/log")
  if [ "$got" = "$1" ]; then ok "$1 dialogs shown"; else bad "expected $1 dialogs, got $got (last: $(tail -n 1 "$CASE/log"))"; fi
}
expect_end() { # COMPLETED | ABORTED
  local got; got=$(cat "$CASE/events")
  if [ "$got" = "$1" ]; then ok "ended: $1"; else bad "expected end [$1] got [$got]"; fi
}
expect_var() { # KEY value
  if grep -qxF "$1=$2" "$CASE/vars"; then ok "$1=$2"
  else bad "expected $1=$2, got $(grep -E "^$1(=|<)" "$CASE/vars")"; fi
}
expect_unset() { # KEY
  if grep -qxF "$1<unset>" "$CASE/vars"; then ok "$1 unset"
  else bad "expected $1 unset, got $(grep -E "^$1(=|<)" "$CASE/vars")"; fi
}
expect_titles() { # the step titles, in order, of every dialog that has one
  local got; got=$(cut -d'|' -f2 "$CASE/log" | sed -n 's/^\(Step [0-9]* of [0-9]*\): .*/\1/p' | tr '\n' ',')
  if [ "$got" = "$1" ]; then ok "step sequence $1"; else bad "step sequence: expected [$1] got [$got]"; fi
}
expect_eff() { # KEY value -- after apply_defaults
  if grep -qxF "$1=$2" "$CASE/effective"; then ok "applied: $1=$2"
  else bad "expected applied $1=$2, got $(grep -E "^$1(=|<)" "$CASE/effective")"; fi
}
expect_in() { # file fixed-string description
  if grep -qF -- "$2" "$CASE/$1"; then ok "$3"; else bad "$3: [$2] not in $1"; fi
}
accept() { local i; for ((i = 0; i < $1; i++)); do echo "0 ="; done; }
no_secret_argv() {
  if grep -E '^passwordbox\|[^|]*\|[^|]*\|.+' "$CASE/log" >/dev/null; then
    bad "a password/API key was passed on whiptail's command line"
  else ok "no secret prefilled on a command line"; fi
}

for strict in 0 1; do

# A. Straight through, every default, Apply. EL host, rspamd key importable:
#    21 steps; titles, cancel labels, derived defaults, final variables.
{ echo "0 mail.northgate.example"; accept 25; echo "0 apply"; } > "$T/in"; run straight dnf 1 1 "$strict"
expect_end COMPLETED
expect_calls 27
expect_call 1  "inputbox|Step 1 of 21: Mail server FQDN|Exit|"
expect_call 2  "inputbox|Step 2 of 21: Primary mail domain|Back|northgate.example"
expect_call 4  "inputbox|Step 4 of 21: Admin email|Back|postmaster@northgate.example"
expect_call 5  "inputbox|Step 5 of 21: Alert email|Back|postmaster@northgate.example"
expect_call 6  "passwordbox|Step 6 of 21: Admin password|Back|"
expect_call 8  "menu|Step 8 of 21: System timezone|Back|Europe/Budapest"
expect_call 9  "menu|Step 9 of 21: TLS certificate|Back|letsencrypt"
expect_call 19 "yesno|Step 16 of 21: DEPLOYMENT TYPE: the central mail archive|Back|"
expect_call 24 "radiolist|Step 19 of 21: Password expiry|Back|90"
expect_call 25 "checklist|Step 20 of 21: Optional extras|Back|last_login fts_xapian unattended mx_check known_senders unofficial_sigs"
expect_call 26 "checklist|Step 21 of 21: Hardening options (secure-by-default)|Back|ssh webmin reboot smtp"
expect_call 27 "menu|Review — apply these changes?|Abort|apply"
expect_titles "$(for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 13 14 15 15 15 16 16 16 17 18 19 20 21; do printf 'Step %s of 21,' "$i"; done)"
expect_var MAIL_FQDN mail.northgate.example
expect_var MAIL_HOSTNAME mail
expect_var PRIMARY_DOMAIN northgate.example
expect_var ALERT_EMAIL postmaster@northgate.example
expect_var TIMEZONE Europe/Budapest
expect_var TLS_MODE letsencrypt
expect_unset TLS_CUSTOM_CERT
expect_var ENABLE_ARCHIVE yes
expect_var ARCHIVE_RETENTION_DAYS 30
expect_var SYSTEM_LANG en
expect_var ILEXA_LANG en
expect_var ENABLE_UNOFFICIAL_SIGS yes
expect_var HARDEN_SELINUX no
expect_unset RSPAMD_ALLOW_UNSIGNED
no_secret_argv
expect_unset _WZ_MEM
expect_unset _WZ_VAL
expect_in out "checking whether this system accepts rspamd's package signing key" "the key probe says what it is doing"
# W3: the review speaks in the checklist's words, inside the 78-column box.
if grep -qF '[x] Dovecot last-login tracking' "$CASE/review" && grep -qF '[ ] SELinux enforcing (advanced)' "$CASE/review" \
   && ! grep -qE 'last_login=|fts_xapian=|ssh=' "$CASE/review"; then ok "review uses the checklist labels"
else bad "review text does not use the checklist labels: $(head -c 300 "$CASE/review")"; fi
if awk 'length($0) > 72 { exit 1 }' "$CASE/review"; then ok "review lines fit the 78-column box"
else bad "review line wider than 72: $(awk 'length($0) > 72' "$CASE/review" | head -n 2)"; fi

# B. The scripted walk from the change request: forward, Back, Back, forward,
#    then Change... -> a field -> review, Back out of a second change, Abort.
{
  echo "0 mail.a.example"     # 1  FQDN
  echo "0 ="                  # 2  domain (a.example, the derived default)
  echo "0 west.example"       # 3  extra domains
  echo "1"                    # 4  admin email: Back
  echo "1"                    # 5  extra domains again: Back
  echo "0 custom.example"     # 6  domain again: a different answer
  echo "0 ="                  # 7  extra domains: west.example kept
  accept 23                   # 8..30 admin email (re-derived) ... hardening
  echo "0 change"             # 31 review
  echo "0 2"                  # 32 Change...: Primary mail domain
  echo "0 other.example"      # 33 step 2 again, in change mode
  echo "0 change"             # 34 review
  echo "0 ="                  # 35 Change...: preselects the last pick
  echo "1"                    # 36 step 2: Back -> review, answer untouched
  echo "0 abort"              # 37 review: Abort
} > "$T/in"; run back-and-change dnf 1 1 "$strict"
expect_end ABORTED
expect_calls 37
expect_call 3  "inputbox|Step 3 of 21: Extra mail domains|Back|"
expect_call 5  "inputbox|Step 3 of 21: Extra mail domains|Back|west.example"
expect_call 6  "inputbox|Step 2 of 21: Primary mail domain|Back|a.example"
expect_call 7  "inputbox|Step 3 of 21: Extra mail domains|Back|west.example"
expect_call 8  "inputbox|Step 4 of 21: Admin email|Back|postmaster@custom.example"
expect_call 32 "menu|Change an answer|Back|1"
expect_call 33 "inputbox|Step 2 of 21: Primary mail domain|Back|custom.example"
expect_call 35 "menu|Change an answer|Back|2"
expect_call 36 "inputbox|Step 2 of 21: Primary mail domain|Back|other.example"
expect_call 37 "menu|Review — apply these changes?|Abort|apply"

# C. Change... that is applied: sub-dialog Back inside a step, a file check,
#    a secret kept without re-typing, a branch taken and then undone, an
#    FQDN re-validated after a change.
{
  echo "0 mail.c.example"     # 1  FQDN
  accept 4                    # 2-5 domain, extra, admin, alert
  echo "0 s3cret-pw"          # 6  admin password
  echo "0 ="                  # 7  mail store
  echo "0 __other__"          # 8  timezone: Other...
  echo "1"                    # 9  IANA name: Back -> timezone menu
  echo "0 UTC"                # 10 timezone menu
  echo "0 custom"             # 11 TLS: own certificate
  echo "0 /nonexistent/c.pem" # 12 cert path
  echo "0"                    # 13 "Certificate not found"
  echo "0 $T/cert.pem"        # 14 cert path again
  echo "1"                    # 15 key path: Back -> cert path
  echo "0 ="                  # 16 cert path (kept)
  echo "0 $T/key.pem"         # 17 key path
  echo "0 ="; echo "0 ="      # 18,19 spam reject, geoblock
  echo "0 2222"               # 20 SSH port
  echo "0 yes"                # 21 OTX
  echo "0 otx-key-1"          # 22 OTX key
  echo "1"                    # 23 DQS key: Back -> OTX
  echo "0 ="                  # 24 OTX (yes, prefilled)
  echo "0 ="                  # 25 OTX key: keep the one entered before
  echo "0 ="                  # 26 DQS key: blank
  echo "0 no"                 # 27 feeds
  echo "0"; echo "0 no"       # 28,29 archive explainer, archive: no
  echo "0 no"                 # 30 greylisting
  echo "0 hu"                 # 31 language
  echo "0 never"              # 32 password expiry
  echo '0 "last_login" "unattended"'   # 33 extras
  echo '0 "ssh"'              # 34 hardening
  echo "0 change"; echo "0 13"   # 35,36 review -> Change...: OTX
  echo "0 no"                 # 37 OTX: off now
  echo "0 change"; echo "0 1"    # 38,39 review -> Change...: FQDN
  echo "0 nodot"              # 40 FQDN (prefilled mail.c.example)
  echo "0"                    # 41 "Invalid FQDN"
  echo "0 mail.d.example"     # 42 FQDN
  echo "0 change"; echo "0 6"    # 43,44 review -> Change...: admin password
  echo "0 new"                # 45 keep / type a different one: new
  echo "1"                    # 46 password: Back -> the keep question
  echo "0 ="                  # 47 keep
  echo "0 apply"              # 48 review: Apply
} > "$T/in"; run change-and-apply dnf 1 1 "$strict"
expect_end COMPLETED
expect_calls 48
expect_call 9  "inputbox|Step 8 of 21: Timezone|Back|Europe/Budapest"
expect_call 10 "menu|Step 8 of 21: System timezone|Back|__other__"
expect_call 13 "yesno|Step 9 of 21: Certificate not found|Back|"
expect_call 14 "inputbox|Step 9 of 21: TLS certificate|Back|/nonexistent/c.pem"
expect_call 16 "inputbox|Step 9 of 21: TLS certificate|Back|$T/cert.pem"
expect_call 24 "menu|Step 13 of 21: AlienVault OTX|Back|yes"
expect_call 25 "menu|Step 13 of 21: AlienVault OTX|Back|keep"
expect_call 26 "passwordbox|Step 14 of 21: Spamhaus DQS|Back|"
expect_call 37 "menu|Step 13 of 21: AlienVault OTX|Back|yes"
expect_call 40 "inputbox|Step 1 of 21: Mail server FQDN|Back|mail.c.example"
expect_call 41 "yesno|Step 1 of 21: Invalid FQDN|Back|"
expect_call 42 "inputbox|Step 1 of 21: Mail server FQDN|Back|"
expect_call 45 "menu|Step 6 of 21: Admin password|Back|keep"
expect_call 47 "menu|Step 6 of 21: Admin password|Back|keep"
expect_var MAIL_FQDN mail.d.example
expect_var MAIL_HOSTNAME mail
# The domain, admin and alert addresses were all accepted as offered, so the
# FQDN change carries through all three.
expect_var PRIMARY_DOMAIN d.example
expect_var ADMIN_EMAIL postmaster@d.example
expect_var ALERT_EMAIL postmaster@d.example
expect_var ADMIN_PASSWORD s3cret-pw
expect_var TIMEZONE UTC
expect_var TLS_MODE custom
expect_var TLS_CUSTOM_CERT "$T/cert.pem"
expect_var TLS_CUSTOM_KEY "$T/key.pem"
expect_var SSH_PORT 2222
expect_var ENABLE_OTX no
expect_unset OTX_API_KEY
expect_var SPAMHAUS_DQS_KEY ""
expect_var ENABLE_FEEDS no
expect_unset ABUSECH_API_KEY
expect_var ENABLE_ARCHIVE no
expect_unset ARCHIVE_RETENTION_DAYS
expect_var ENABLE_GREYLISTING no
expect_var SYSTEM_LANG hu
expect_var ILEXA_LANG hu
expect_var PASSWORD_EXPIRY_DAYS never
expect_var ENABLE_LAST_LOGIN yes
expect_var ENABLE_FTS_XAPIAN no
expect_var ENABLE_UNATTENDED yes
expect_var ENABLE_UNOFFICIAL_SIGS no
expect_var HARDEN_SSH_KEYONLY yes
expect_var HARDEN_WEBMIN no
no_secret_argv

# H. Blank answers mean apply_defaults' defaults, and the review and the
#    Change... menu say so -- not "(none)" for a geoblock that will block four
#    countries. A blank primary domain or admin address is refused in its step.
{
  echo "0 mail.h.example"     # 1  FQDN
  echo "0"                    # 2  primary domain: blank
  echo "0"                    # 3  "Answer required"
  echo "0 ="                  # 4  primary domain again: h.example re-offered
  echo "0 ="                  # 5  extra domains
  echo "0"                    # 6  admin email: blank
  echo "0"                    # 7  "Answer required"
  echo "0 ="                  # 8  admin email again
  accept 2                    # 9,10 alert, password
  echo "0"                    # 11 mail store: blank
  accept 2                    # 12,13 timezone, TLS
  echo "0"; echo "0"; echo "0"   # 14-16 spam reject, geoblock, SSH port: blank
  accept 14                   # 17-30 OTX .. hardening
  echo "0 change"             # 31 review
  echo "1"                    # 32 Change...: Back
  echo "0 apply"              # 33 review
} > "$T/in"; run blank-means-default dnf 1 1 "$strict"
expect_end COMPLETED
expect_calls 33
expect_call 3  "yesno|Step 2 of 21: Answer required|Back|"
expect_call 4  "inputbox|Step 2 of 21: Primary mail domain|Back|h.example"
expect_call 8  "inputbox|Step 4 of 21: Admin email|Back|postmaster@h.example"
expect_var MAIL_STORE ""
expect_var GEOBLOCK_COUNTRIES ""
expect_eff MAIL_STORE /data/mail
expect_eff GEOBLOCK_COUNTRIES "ru cn br kr"
expect_eff SPAM_REJECT 15
expect_eff SSH_PORT 22
expect_in review "Mail store:       /data/mail" "review shows the mail store that will be applied"
expect_in review "Geoblock:         ru cn br kr" "review shows the geoblock that will be applied"
expect_in review "Spam tag/reject:  4 / 15" "review shows the reject threshold that will be applied"
expect_in review "SSH port:         22" "review shows the SSH port that will be applied"
expect_in pick "11|Geoblock               ru cn br kr" "Change... shows the applied geoblock"
expect_in pick "7|Mail store             /data/mail" "Change... shows the applied mail store"

# I. An answer starting with "-" can be revisited, by Back and by Change...
#    (without "--" whiptail rejects it as an option and exits 1 = Back).
{
  echo "0 mail.i.example"; echo "0 ="   # 1,2
  echo "0 -foo"               # 3  extra domains
  echo "1"                    # 4  admin email: Back
  echo "0 ="                  # 5  extra domains, prefilled "-foo"
  accept 23                   # 6-28 admin email .. hardening
  echo "0 change"; echo "0 3" # 29,30 review -> Change...: extra domains
  echo "0 -bar"               # 31 extra domains, prefilled "-foo"
  echo "0 apply"              # 32
} > "$T/in"; run dash-answer dnf 1 1 "$strict"
expect_end COMPLETED
expect_calls 32
expect_call 5  "inputbox|Step 3 of 21: Extra mail domains|Back|-foo"
expect_call 31 "inputbox|Step 3 of 21: Extra mail domains|Back|-foo"
expect_var EXTRA_DOMAINS -bar

# J. Change... carries on to answers that were the derived default, and only
#    to those: the admin address follows a new FQDN, a typed alert address
#    does not.
{
  echo "0 mail.j.example"     # 1
  accept 3                    # 2-4 domain, extra, admin (postmaster@j.example)
  echo "0 ops@elsewhere.example"   # 5 alert: typed
  accept 21                   # 6-26 password .. hardening
  echo "0 change"; echo "0 1" # 27,28 review -> Change...: FQDN
  echo "0 mail.k.example"     # 29
  echo "0 change"; echo "0 4" # 30,31 review -> Change...: admin email
  echo "0 ="                  # 32 admin email, prefilled with the followed value
  echo "0 apply"              # 33
} > "$T/in"; run change-rederives dnf 1 1 "$strict"
expect_end COMPLETED
expect_calls 33
expect_call 32 "inputbox|Step 4 of 21: Admin email|Back|postmaster@k.example"
expect_var PRIMARY_DOMAIN k.example
expect_var ADMIN_EMAIL postmaster@k.example
expect_var ALERT_EMAIL ops@elsewhere.example
expect_eff TLSRPT_RUA postmaster@k.example
expect_in review "Primary domain:   k.example" "review shows the followed domain"

# K. A step-state variable inherited from the environment is cleared when
#    lib/tui.sh is sourced: the host check's Exit button still exits.
echo "1" > "$T/in"
MD_TUI_STEP="Step 9 of 9" MD_TUI_CANCEL=Back WZ_MODE=hostcheck run inherited-step-state dnf 1 1 "$strict"
expect_end ABORTED
expect_call 1 "yesno|HOST CHECK|Exit|"

# D. Esc in the middle quits at once: no further dialog, no review.
{ echo "0 mail.x.example"; accept 3; echo "255"; } > "$T/in"; run esc-quits dnf 1 1 "$strict"
expect_end ABORTED
expect_calls 5

# D2. Esc inside a step opened from Change... quits too -- it does not fall
#     back to the review the way that step's Back button does.
{ echo "0 mail.x.example"; accept 25; echo "0 change"; echo "0 3"; echo "255"; } > "$T/in"; run esc-in-change dnf 1 1 "$strict"
expect_end ABORTED
expect_calls 29
expect_call 29 "inputbox|Step 3 of 21: Extra mail domains|Back|"

# D3. The review's Abort button aborts.
{ echo "0 mail.x.example"; accept 25; echo "1"; } > "$T/in"; run review-abort-button dnf 1 1 "$strict"
expect_end ABORTED
expect_calls 27

# E. Step 1's cancel button is Exit, and it exits.
echo "1" > "$T/in"; run exit-on-step-1 dnf 1 1 "$strict"
expect_end ABORTED
expect_calls 1

# F. Ubuntu, and a platform that refuses rspamd's key: the signature step is
#    counted (N = 22), the EL-only options are neither offered nor left on.
{ echo "0 mail.u.example"; accept 17; echo "0"; echo "0 ="; accept 8; echo "0 apply"; } > "$T/in"; run apt-unsigned apt 0 1 "$strict"
expect_end COMPLETED
expect_call 19 "yesno|Step 16 of 22: rspamd package signature|Back|"
expect_call 20 "menu|Step 16 of 22: rspamd signature|Back|yes"
expect_call 27 "checklist|Step 21 of 22: Optional extras|Back|last_login fts_xapian unattended mx_check known_senders"
expect_call 28 "checklist|Step 22 of 22: Hardening options (secure-by-default)|Back|ssh webmin reboot smtp"
expect_var RSPAMD_ALLOW_UNSIGNED yes
expect_var ENABLE_UNOFFICIAL_SIGS no
expect_var HARDEN_SELINUX no

# F2. ...and declining the unverified install stops, as it always did.
{ echo "0 mail.u.example"; accept 17; echo "0"; echo "0 no"; } > "$T/in"; run apt-unsigned-declined apt 0 1 "$strict"
expect_end ABORTED
expect_calls 20

# G. No terminal: every wrapper returns its default, the walk runs once, the
#    review is printed rather than drawn, and nothing loops.
: > "$T/in"; run no-tty dnf 1 0 "$strict"
expect_end COMPLETED
expect_calls 0
expect_var MAIL_FQDN mail.example.com
expect_var PRIMARY_DOMAIN example.com
expect_var ADMIN_EMAIL postmaster@example.com
expect_var TLS_MODE letsencrypt
expect_var ENABLE_OTX yes
expect_var ARCHIVE_RETENTION_DAYS 30
expect_var PASSWORD_EXPIRY_DAYS 90
expect_var ENABLE_FTS_XAPIAN yes
if grep -qF '[x] Dovecot last-login tracking' "$CASE/out"; then ok "review printed without a terminal"
else bad "review text missing from the no-terminal output"; fi

done

if [ "$fail" -gt 0 ]; then
  echo "check-wizard-nav: $fail of $((pass + fail)) checks FAILED" >&2
  exit 1
fi
echo "check-wizard-nav: $pass checks passed -- clean"
exit 0
