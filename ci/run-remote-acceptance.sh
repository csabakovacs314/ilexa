#!/usr/bin/env bash
# run-remote-acceptance.sh — drive ci/run-acceptance.sh on a remote disposable
# host, from a machine that cannot run a VM itself.
#
# WHY THIS EXISTS. The acceptance suite has to run against a real, fully
# installed host: most of what it checks (are the helpers on disk, do the cron
# paths resolve, does sudoers parse, does the console actually answer) is
# invisible to any static check and cannot be faked. But the authoring machine
# here has no virtualisation at all -- no vmx flags, no container runtime -- so
# `vagrant up` is not an option. The disposable Ubuntu box is, over SSH.
#
# It is therefore SEMI-automated by design: one command, but pointed at a
# machine you keep around rather than one it creates. The remote host is
# treated as expendable -- run-acceptance.sh executes deploy.sh for real.
#
#   ci/run-remote-acceptance.sh <user@host> [ssh-key] [answers-file-on-remote]
#
# Example:
#   ci/run-remote-acceptance.sh root@test-vm.example.com ~/.ssh/test_vm_key /root/answers.test.conf
set -uo pipefail

TARGET="${1:?usage: run-remote-acceptance.sh <user@host> [ssh-key] [remote-answers-file]}"
KEY="${2:-}"
REMOTE_ANS="${3:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)
RSYNC_E="ssh -o BatchMode=yes -o ConnectTimeout=10"
if [ -n "$KEY" ]; then
  SSH+=(-i "$KEY")
  RSYNC_E="$RSYNC_E -i $KEY"
fi

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "1/4  reachability"
"${SSH[@]}" "$TARGET" 'echo "  connected: $(hostname -f) — $(. /etc/os-release; echo "$PRETTY_NAME")"' \
  || { echo "cannot reach $TARGET"; exit 2; }

# Refuse to point this at the authoring host by accident. run-acceptance.sh has
# its own safety check, but by the time that runs the tree has already been
# overwritten -- catching it here costs nothing.
if "${SSH[@]}" "$TARGET" 'test -f /etc/ilexa/secrets/otx_api_key' 2>/dev/null; then
  echo "REFUSING: $TARGET has an OTX API key, so it does not look disposable." >&2
  exit 2
fi

say "2/4  syncing the installer (and the app bundle)"
# --delete so a file removed here is removed there: a stale module left behind
# would be run by deploy.sh and could mask exactly the drift this is testing.
rsync -az --delete -e "$RSYNC_E" --exclude='.git' "$ROOT/" "$TARGET:/root/ilexa-installer/" \
  || { echo "sync failed"; exit 2; }
echo "  synced $(find "$ROOT" -type f -not -path '*/.git/*' | wc -l) files"

say "3/4  running acceptance on the remote host"
# Not -t: this must work unattended from cron or a script, and a TTY would
# change how the remote output is buffered.
if [ -n "$REMOTE_ANS" ]; then
  "${SSH[@]}" "$TARGET" "bash /root/ilexa-installer/ci/run-acceptance.sh '$REMOTE_ANS'"
else
  "${SSH[@]}" "$TARGET" "bash /root/ilexa-installer/ci/run-acceptance.sh"
fi
rc=$?

say "4/4  result"
if [ "$rc" = 0 ]; then
  echo "  ACCEPTANCE PASSED on $TARGET"
else
  echo "  ACCEPTANCE FAILED on $TARGET (exit $rc) — see the FAIL lines above"
fi
exit "$rc"
