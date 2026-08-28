#!/usr/bin/env bash
# lib/progress.sh — one whiptail gauge for the whole package-install phase.
#
# Raw apt/dnf output used to stream straight to the terminal for the entire
# ~10 minute install, interleaved with the wizard's own screens -- reported as
# wanting the TUI to name the component and show a percentage instead, with
# ClamAV specifically flagged as the step that can look stuck (its signature
# download dominates the whole run -- see modules/35-clamav.sh).
#
# Scope: the interactive wizard only (_tui_ok), matching every other TUI
# feature in this codebase. An --answers run has no competing screen, so its
# package output is left exactly as it always was -- an operator piping or
# logging that run still sees everything live.
#
# Granularity is PER MODULE, not per package. The gauge is driven from
# run_modules() in the PARENT deploy.sh process, once per module, and the fifo
# it writes to never has to cross into a module's own `bash "$m"` subprocess.
# A module only needs to know NOT to print its package manager's chatter over
# the gauge -- it does that by checking MD_PROGRESS_ACTIVE (exported below)
# and redirecting to $MD_LOG instead, in pkg_try (lib/common.sh). log_info/
# log_warn do the same via _log, so nothing else can scribble on the gauge
# while it owns the screen.

MD_PROGRESS_FIFO=""
MD_PROGRESS_PID=""
MD_PROGRESS_ACTIVE=0
MD_PROGRESS_LAST_PCT=0
MD_PROGRESS_LAST_LABEL=""
export MD_PROGRESS_ACTIVE MD_PROGRESS_LAST_PCT MD_PROGRESS_LAST_LABEL
# All three exported: a module subprocess needs MD_PROGRESS_ACTIVE to know
# whether to redirect its own package output, and the last pct/label so a
# transient message (e.g. "waiting for the system's own updates") can be
# shown and then restored without the module having to invent new text.
#
# EXPORTING A VARIABLE DOES NOT EXPORT A FUNCTION. pkg_try (lib/common.sh) is
# sourced by every module, runs as its own `bash "$m"` process, and calls
# progress_note/progress_update when MD_PROGRESS_ACTIVE=1 -- but modules never
# source THIS file, only common.sh. Without export -f those two names simply
# do not exist in that process: "progress_note: command not found", live on a
# real install, the exact env var/function inheritance mistake this session
# already made once with a file descriptor. `export -f` is what actually
# carries a function definition across fork/exec via the environment.

progress_start() { # title
  _tui_ok || return 0
  [ "${DRY_RUN:-0}" = 1 ] && return 0
  local title="${1:-Installing}"
  MD_PROGRESS_FIFO=$(mktemp -u "${TMPDIR:-/tmp}/ilexa-progress.XXXXXX")
  mkfifo -m 600 "$MD_PROGRESS_FIFO" 2>/dev/null || { MD_PROGRESS_FIFO=""; return 0; }
  # Open read-write on our OWN fd before whiptail attaches, so this process
  # (the writer) never blocks on a reader that has not started yet -- a plain
  # `>fifo` redirect would hang until whiptail's `<fifo` open completes.
  exec 8<>"$MD_PROGRESS_FIFO"
  # `8<&-` AFTER `<&8`: dup fd 8 onto stdin first, then close whiptail's OWN
  # copy of fd 8. Without that second close, the background job inherits fd 8
  # itself (not just stdin) across the fork -- so when progress_stop later
  # closes OUR fd 8, the fifo's write end is still open in the child via its
  # OWN fd 8, EOF never reaches whiptail's read, and `wait` on it hangs
  # forever. Found by driving this through a real pty end to end, not by
  # reasoning about it -- the first version hung indefinitely on progress_stop.
  whiptail --backtitle "$MD_TUI_BACKTITLE" --title "$title" \
    --gauge "Preparing..." 10 74 0 <&8 8<&- &
  MD_PROGRESS_PID=$!
  MD_PROGRESS_ACTIVE=1
  # No EXIT trap existed on this process before. If the wizard dies mid-module
  # (die(), Ctrl+C, a dropped ssh session) the gauge must not survive to hide
  # whatever error message follows it.
  trap 'progress_stop' EXIT
}

progress_update() { # percent label
  [ "$MD_PROGRESS_ACTIVE" = 1 ] || return 0
  local pct="$1" label="$2"
  { printf 'XXX\n%s\n%s\nXXX\n' "$pct" "$label" >&8; } 2>/dev/null \
    || { MD_PROGRESS_ACTIVE=0; return 0; }
  MD_PROGRESS_LAST_PCT="$pct"; MD_PROGRESS_LAST_LABEL="$label"
}

# progress_note "text" -- reuses the LAST percent, only the label changes.
# For a transient status (a lock wait, a slow sub-step) that should not move
# the bar, just explain what it is currently sitting on.
progress_note() {
  [ "$MD_PROGRESS_ACTIVE" = 1 ] || return 0
  progress_update "$MD_PROGRESS_LAST_PCT" "$1"
}

# Must cross into a module's own `bash "$m"` process (see the comment on
# MD_PROGRESS_ACTIVE above) -- a plain function definition does not, only
# `export -f` does.
export -f progress_update progress_note

progress_stop() {
  [ "$MD_PROGRESS_ACTIVE" = 1 ] || return 0
  MD_PROGRESS_ACTIVE=0
  # NOT "close our fd and wait for whiptail to see EOF and exit on its own".
  # The fifo was opened O_RDWR (`exec 8<>`) so it can carry writer AND reader
  # in this one process; whiptail inherits that fd across fork with the same
  # write-capable open file description, and newt internally dups it onto its
  # own fd -- so the kernel's writer refcount on the fifo never reaches zero
  # after WE close our copy, EOF never arrives, and `wait` hangs forever.
  # Found by driving this through a real pty end to end and inspecting
  # /proc/<pid>/fd while it was stuck, not by reasoning about it.
  #
  # Killing it directly sidesteps the whole question: whiptail/newt handles
  # SIGTERM by restoring the terminal before exiting, which is all that is
  # needed here -- there is no partially-drawn state worth preserving.
  [ -n "$MD_PROGRESS_PID" ] && kill "$MD_PROGRESS_PID" 2>/dev/null
  # NOT `exec 8>&- 2>/dev/null` -- `exec` with only redirects and no command
  # applies EVERY listed redirect PERMANENTLY to the current shell, not just to
  # this one statement. That accidentally sent this shell's OWN stderr to
  # /dev/null for the rest of the run: found by tracing /proc/$$/fd/2 across a
  # real pty session and watching it flip from the pts device to /dev/null the
  # instant this line ran. A later log_warn (e.g. the failure path in
  # run_modules) would then vanish from the screen with no explanation. Closing
  # an fd that is known open cannot meaningfully fail, so no error redirect is
  # needed at all.
  exec 8>&-
  [ -n "$MD_PROGRESS_PID" ] && wait "$MD_PROGRESS_PID" 2>/dev/null
  [ -n "$MD_PROGRESS_FIFO" ] && rm -f "$MD_PROGRESS_FIFO" 2>/dev/null
  MD_PROGRESS_PID=""; MD_PROGRESS_FIFO=""
  # newt draws in the terminal's ALTERNATE screen buffer, and a killed process
  # gets no chance to leave it -- caught by inspecting the raw bytes of a real
  # pty session after a kill-based teardown: the enter sequence (\x1b[?1049h)
  # was there, the matching exit never was. Left alone, the operator's screen
  # would stay showing the frozen gauge, with the failure message that follows
  # written invisibly into a buffer nothing is displaying any more -- worse
  # than the raw apt/dnf noise this feature exists to replace. Force the
  # terminal back explicitly rather than trust the killed process to have.
  if [ -t 1 ]; then tput rmcup 2>/dev/null; tput cnorm 2>/dev/null; fi
}

# module basename -> human label, shown while that module's step runs.
# ClamAV names its own known-slow step explicitly, per the report; everything
# else gets a short, honest description rather than the filename.
progress_label_for() { # module_basename
  case "$1" in
    00-preflight)    echo "Checking the host" ;;
    05-base)         echo "Base packages and OS hardening" ;;
    10-mariadb)      echo "MariaDB (mail database)" ;;
    20-postfix)      echo "Postfix (mail transfer agent)" ;;
    21-greylist)     echo "Greylisting (postgrey)" ;;
    25-dovecot)      echo "Dovecot (IMAP/POP3)" ;;
    26-sieve)        echo "Sieve mail filters" ;;
    27-quota)        echo "Mailbox quotas" ;;
    30-auth)         echo "Authentication and admin accounts" ;;
    35-clamav)       echo "ClamAV (downloading virus signatures -- this step can take several minutes)" ;;
    40-rspamd)       echo "rspamd (spam filtering engine)" ;;
    41-hu-classify)  echo "Language-aware spam classifier" ;;
    50-web)          echo "Web server and PHP" ;;
    55-ilexa)        echo "ilexa console" ;;
    57-archive)      echo "Central mail archive" ;;
    58-report-learn) echo "Spam/ham report addresses" ;;
    60-firewalld)    echo "Firewall" ;;
    65-fail2ban)     echo "Fail2Ban (brute-force protection)" ;;
    66-siem-export)  echo "SIEM export" ;;
    70-otx)          echo "AlienVault OTX threat intelligence" ;;
    72-feeds)        echo "Reputation and block-list feeds" ;;
    75-tls-dns)      echo "TLS certificate" ;;
    76-mta-sts)      echo "MTA-STS policy" ;;
    78-autoconfig)   echo "Mail client autoconfiguration" ;;
    80-unattended)   echo "Unattended security updates" ;;
    82-metrics)      echo "System metrics" ;;
    85-hardening)    echo "Security hardening" ;;
    90-enable)       echo "Starting services" ;;
    95-sources)      echo "Community threat-intel sources" ;;
    99-verify)       echo "Final verification" ;;
    *)               echo "$1" ;;
  esac
}
