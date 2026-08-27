#!/usr/bin/env bash
# 40-rspamd — rspamd as the sole mail filter, with ClamAV called through it.
#
# Replaces the MailScanner + SpamAssassin + MailWatch pipeline. rspamd runs as a
# milter alongside opendkim/opendmarc and both scores and rejects; ClamAV is no
# longer invoked by a separate scanner.
source "$MD_ROOT/lib/common.sh"
load_secrets   # RSPAMD_CTRL_PW if an earlier run already generated one
# REPAIR, BEFORE THE GUARD -- so an EXISTING host gets it too. deploy.sh used
# to default the tag with `: "${SPAM_SUBJECT_TAG:={Spam?}}"`, where the
# parameter expansion ends at the FIRST closing brace: that assigned "{Spam?"
# and left the "}" as literal text outside it. Answers-file installs passed a
# quoted value and were unaffected, so only WIZARD-built hosts carry the
# truncated tag -- and they would keep carrying it forever, because this
# module's marker is already set and the template is never re-rendered.
#
# Narrow on purpose: it only rewrites the exact truncated form, so an operator
# who deliberately chose their own tag is left alone.
if [ "$DRY_RUN" != 1 ] && [ -f /etc/rspamd/local.d/actions.conf ] \
   && grep -q '^subject = "{Spam? %s";' /etc/rspamd/local.d/actions.conf; then
  sed -i 's/^subject = "{Spam? %s";/subject = "{Spam?} %s";/' /etc/rspamd/local.d/actions.conf
  log_info "repaired truncated spam subject tag in actions.conf ({Spam? -> {Spam?})"
  if rspamadm configtest >/dev/null 2>&1; then
    systemctl reload rspamd >/dev/null 2>&1 || true
  else
    log_warn "actions.conf repaired but rspamadm configtest failed — not reloading"
  fi
fi

step_guard 40-rspamd || exit 0

# ---- repo + packages -------------------------------------------------------
# rspamd is not in EPEL for EL9, and Ubuntu's own universe package lags well
# behind (3.8.1 on noble vs 4.1.5 upstream, confirmed on a real 24.04 host
# 2026-08-15); use rspamd.com's own repo on both platforms.
if [ "$PKG_MGR" = apt ]; then
  if [ "$DRY_RUN" != 1 ] && [ ! -f /etc/apt/sources.list.d/rspamd.list ]; then
    mkdir -p /etc/apt/keyrings
    curl -sSfL https://rspamd.com/apt-stable/gpg.key | gpg --dearmor -o /etc/apt/keyrings/rspamd.gpg
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    write_file /etc/apt/sources.list.d/rspamd.list 0644 root:root <<EOF
deb [signed-by=/etc/apt/keyrings/rspamd.gpg] https://rspamd.com/apt-stable/ ${codename} main
EOF
    # -o DPkg::Lock::Timeout: unattended-upgrades holds the lock on fresh
    # Ubuntu boxes; see pkg_try() in lib/common.sh.
    apt-get -o DPkg::Lock::Timeout="${APT_LOCK_WAIT:-600}" update -qq
  fi
else
  if [ "$DRY_RUN" != 1 ] && [ ! -f /etc/yum.repos.d/rspamd.repo ]; then
    write_file /etc/yum.repos.d/rspamd.repo 0644 root:root <<EOF
[rspamd]
name=rspamd stable
baseurl=https://rspamd.com/rpm-stable/centos-\$releasever/\$basearch/
enabled=1
gpgcheck=1
gpgkey=https://rspamd.com/rpm-stable/gpg.key
EOF
  fi
fi
pkg_install rspamd "${REDIS_PKG:-redis}"

# rspamd keeps Bayes, fuzzy and ratelimits in redis; without it learning silently
# does nothing. (Package/service name is redis on EL9, valkey on EL10 -- a
# drop-in Redis-protocol-compatible fork, which is why rspamd's own config
# below still says backend = "redis" regardless of which one is running.)
svc_enable "${REDIS_SVC:-redis}"
svc_enable rspamd

# clamd's socket is group-readable by the MTA group, so rspamd must be in it.
if [ "$DRY_RUN" != 1 ]; then
  id -nG _rspamd 2>/dev/null | grep -qw "$MTA_GROUP" || {
    usermod -a -G "$MTA_GROUP" _rspamd && log_info "_rspamd added to $MTA_GROUP"
  }
fi

# ---- configuration ---------------------------------------------------------
# A generated controller password. rspamd stores it hashed; localhost is trusted
# via secure_ip anyway, so this only guards the web UI over a tunnel.
if [ "$DRY_RUN" != 1 ]; then
  if [ -z "${RSPAMD_CTRL_PW:-}" ]; then
    RSPAMD_CTRL_PW="$(gen_pw 24)"
    save_secret RSPAMD_CTRL_PW "$RSPAMD_CTRL_PW"
    record_cred "rspamd controller" "(no user)" "$RSPAMD_CTRL_PW"
  fi
  RSPAMD_CTRL_PW_HASH="$(rspamadm pw --encrypt -p "$RSPAMD_CTRL_PW" 2>/dev/null)" \
    || RSPAMD_CTRL_PW_HASH="$RSPAMD_CTRL_PW"
else
  RSPAMD_CTRL_PW_HASH="<generated>"
fi

export MD_VAR_SPAM_ADD_HEADER="$SPAM_ADD_HEADER"
export MD_VAR_SPAM_REWRITE_SUBJECT="$SPAM_REWRITE_SUBJECT"
export MD_VAR_SPAM_REJECT="$SPAM_REJECT"
export MD_VAR_SPAM_SUBJECT_TAG="$SPAM_SUBJECT_TAG"
export MD_VAR_CLAMD_SOCKET="$CLAMD_SOCKET"
export MD_VAR_MTA_GROUP="$MTA_GROUP"
export MD_VAR_RSPAMD_CTRL="$RSPAMD_CTRL"
export MD_VAR_RSPAMD_CTRL_PW_HASH="$RSPAMD_CTRL_PW_HASH"
export MD_VAR_ILEXA_LIST_DIR="$ILEXA_LIST_DIR"

LOCALD=/etc/rspamd/local.d
[ "$DRY_RUN" = 1 ] || mkdir -p "$LOCALD/maps.d"

render "$MD_TEMPLATES/rspamd/actions.conf.tmpl"           "$LOCALD/actions.conf"
render "$MD_TEMPLATES/rspamd/settings.conf.tmpl"          "$LOCALD/settings.conf"
render "$MD_TEMPLATES/rspamd/antivirus.conf.tmpl"         "$LOCALD/antivirus.conf"
render "$MD_TEMPLATES/rspamd/force_actions.conf.tmpl"     "$LOCALD/force_actions.conf"
render "$MD_TEMPLATES/rspamd/worker-controller.inc.tmpl"  "$LOCALD/worker-controller.inc"

# The block/allow maps belong to ilexa. Seed them here so rspamd starts cleanly
# even when the console is not installed yet; 55-ilexa takes ownership later.
if [ "$DRY_RUN" != 1 ] && [ "${ENABLE_ILEXA:-yes}" = yes ]; then
  mkdir -p "$ILEXA_LIST_DIR"
  for m in blocklist_from blocklist_ip whitelist_from whitelist_ip; do
    [ -e "$ILEXA_LIST_DIR/$m.map" ] || {
      printf '# Auto-generated by ilexa — DO NOT EDIT BY HAND.\n' > "$ILEXA_LIST_DIR/$m.map"
      chmod 644 "$ILEXA_LIST_DIR/$m.map"
    }
  done
  # The rendered multimap.conf glob-includes these two directories (see the
  # template's own footer for why). Create them so the includes are never
  # dangling, and so a later feature can drop a file in without needing to
  # know whether the directory exists. try=true makes an empty one harmless.
  for _d in community-rules.d multimap.d; do
    mkdir -p "$LOCALD/$_d"
    chown root:_rspamd "$LOCALD/$_d" 2>/dev/null || chown root:root "$LOCALD/$_d"
    chmod 0750 "$LOCALD/$_d"
  done
  render "$MD_TEMPLATES/rspamd/multimap.conf.tmpl" "$LOCALD/multimap.conf"

fi

# ---- brand-impersonation guard + phishing/whitelist composites -------------
#
# NOT gated on ENABLE_ILEXA. None of this needs the console: the maps, the Lua
# rule and the composites are pure rspamd configuration. Having it inside that
# gate meant a console-less install silently got no brand guard AND no
# PHISH_ON_TRUSTED -- the whitelist-stripping composite this block's own
# comment calls "universal logic, installed unconditionally" and GUIDE.md says
# "installs regardless". An operator who set ENABLE_ILEXA=no and
# ENABLE_HU_BRAND_GUARD=yes had their explicit yes ignored without a word.
if [ "$DRY_RUN" != 1 ]; then
  # ---- brand-impersonation guard + phishing/whitelist composites -----------
  # Born from a live incident (2026-08-22): a compromised university account
  # sent OTP-Bank/MagyarPosta phishing that every reputation layer voted ham
  # on -- the whitelists describe the SERVER, and a hijacked account weaponises
  # them. Three pieces:
  #   maps + multimap pair (multimap.d/, survives multimap.conf re-renders;
  #     zero-score alone) -- installed whenever the guard is on;
  #   HU_BRAND_SPOOF composite (+5): brand named in From, domain not the
  #     brand's own. HU-brand policy, hence the toggle;
  #   PHISH_ON_TRUSTED composite (+3, strips whitelist weights when rspamd's
  #     own PHISHING symbol fires through whitelisted infra) -- universal
  #     logic, installed unconditionally.
  # The MULTIMAP half needs multimap.conf, which is rendered only for console
  # installs (it also carries ilexa's block/allow maps and the glob includes),
  # so it is installed only when that directory really exists. The Lua half and
  # the composites below have no such dependency and always ship -- which is
  # the point of moving this section out of the ENABLE_ILEXA gate.
  _bg_multimap=0
  # These two maps ship with headers telling the operator to extend them by
  # hand, and the installer overwrites them on every run. `install` truncates
  # the target, so an added campaign regexp or a customer's legitimate domain
  # vanished with no copy kept anywhere -- the exact "never silently overwrite
  # configuration / preserve backups before destructive changes" rule this
  # toolkit sets for itself. Back up (and say so) whenever the file on disk
  # differs from what we are about to write.
  for _m in hu_brand_names.re hu_brand_domains.inc; do
    if [ -e "$LOCALD/maps.d/$_m" ] \
       && ! cmp -s "$MD_TEMPLATES/rspamd/$_m" "$LOCALD/maps.d/$_m"; then
      backup "$LOCALD/maps.d/$_m"
      log_warn "maps.d/$_m had local changes — backed up before being replaced from the template"
    fi
    install -m 644 "$MD_TEMPLATES/rspamd/$_m" "$LOCALD/maps.d/$_m"
  done
  if [ -d "$LOCALD/multimap.d" ]; then
    if [ "${ENABLE_HU_BRAND_GUARD:-yes}" = yes ]; then
      install -m 644 "$MD_TEMPLATES/rspamd/hu-brand-guard-multimap.conf" "$LOCALD/multimap.d/hu-brand-guard.conf"
      _bg_multimap=1
    else
      rm -f "$LOCALD/multimap.d/hu-brand-guard.conf"
    fi
  elif [ "${ENABLE_HU_BRAND_GUARD:-yes}" = yes ]; then
    log_info "no multimap.d (console not installed) — brand guard runs as the Lua rule only"
  fi

  # ---- Lua brand guard (BRAND_* symbols) -----------------------------------
  # The fuzzy companion of the multimap pair: catches "0TP", Cyrillic "ОТР",
  # accent tricks via transliteration + homoglyph fold + levenshtein <= 1, and
  # additionally scores brand claims in the Subject and the From localpart,
  # plus lure language (any configured language) alongside them.
  #
  # lua.local.d/ is rspamd's OWN auto-loaded custom-rule directory (stock
  # rules/rspamd.lua globs it) and already holds this project's hu_classify /
  # hu_phish_scam_log rules -- the rule goes there rather than into a
  # bespoke loader. First ship used an invented rspamd.local.lua + lua.d/
  # pair; those are removed below so an upgraded host does not load the rule
  # twice under two names.
  #
  # Both JSON data files are STANDING CONFIG (console: Rendszer ->
  # Márkavédelem, helper: qa-brand-guard.sh): seeded once, never re-rendered,
  # so operator edits survive re-runs. The rule file IS re-rendered.
  install -d -m 755 /etc/rspamd/lua.local.d
  install -m 644 "$MD_TEMPLATES/rspamd/brand_guard.lua" /etc/rspamd/lua.local.d/brand_guard.lua
  # Clean up the first ship's invented loader -- CAREFULLY. rspamd.local.lua is
  # rspamd's OWN documented operator hook (rules/rspamd.lua dofiles it if
  # present), so it is only ours to delete when it actually is ours: the file
  # we wrote referenced lua.d/. Anything else is an administrator's own rules,
  # and it is backed up and left in place rather than removed.
  #
  # An earlier version of this block deleted it on existence alone, with no
  # backup and no content check -- destroying hand-written Lua on the
  # add-to-an-existing-server path while logging only "removed the superseded
  # loader". That contradicted this toolkit's own rules ("never silently
  # overwrite configuration", "preserve backups before destructive changes").
  if [ -f /etc/rspamd/lua.d/brand_guard.lua ]; then
    rm -f /etc/rspamd/lua.d/brand_guard.lua
    rmdir /etc/rspamd/lua.d 2>/dev/null || true
    log_info "removed the superseded lua.d/ brand-guard rule"
  fi
  if [ -f /etc/rspamd/rspamd.local.lua ]; then
    if grep -q 'lua\.d' /etc/rspamd/rspamd.local.lua; then
      backup /etc/rspamd/rspamd.local.lua
      rm -f /etc/rspamd/rspamd.local.lua
      log_info "removed the superseded rspamd.local.lua loader (backed up)"
    else
      backup /etc/rspamd/rspamd.local.lua
      log_warn "/etc/rspamd/rspamd.local.lua is not ours (no lua.d reference) — backed up and LEFT IN PLACE"
    fi
  fi
  _bg_seeded=0
  for _bf in brand_definitions.json brand_lures.json; do
    if [ ! -s "$LOCALD/$_bf" ]; then
      install -m 644 "$MD_TEMPLATES/rspamd/$_bf" "$LOCALD/$_bf"
      [ "$_bf" = brand_definitions.json ] && _bg_seeded=1
    fi
  done
  # ONE-TIME SECURITY MIGRATION on an existing file.
  #
  # brand_definitions.json is standing config, so a defect in the seed data we
  # shipped never reaches hosts that already have it -- and this particular
  # entry is a hole, not a preference: bare "gov.hu" is not a public suffix, so
  # rspamd resolves EVERY *.gov.hu sender to it and the whole Hungarian public
  # sector was exempt from all five BRAND_* checks. Removing exactly that one
  # string, with a backup, is narrower than leaving installed hosts unprotected.
  # nav.gov.hu (kept) covers NAV, and the Lua rule compares the full domain.
  # python3 is NOT guaranteed at this point in the run (58-report-learn installs
  # it eighteen modules later), so the migration must announce itself rather
  # than fail into silence on a minimal image.
  if [ -s "$LOCALD/brand_definitions.json" ] \
     && grep -q '"gov\.hu"' "$LOCALD/brand_definitions.json" \
     && ! command -v python3 >/dev/null 2>&1; then
    log_warn "brand_definitions.json still contains the bare gov.hu whitelist entry and python3 is not installed"
    log_warn "  it exempts EVERY *.gov.hu sender from the brand checks — remove that one line by hand"
  fi
  if [ -s "$LOCALD/brand_definitions.json" ] \
     && command -v python3 >/dev/null 2>&1 \
     && grep -q '"gov\.hu"' "$LOCALD/brand_definitions.json"; then
    backup "$LOCALD/brand_definitions.json"
    if python3 - <<'PYMIG'
import json
p = '/etc/rspamd/local.d/brand_definitions.json'
d = json.load(open(p))
hit = False
for b in d.get('brands', []):
    if isinstance(b, dict) and isinstance(b.get('domains'), list) and 'gov.hu' in b['domains']:
        b['domains'] = [x for x in b['domains'] if x != 'gov.hu']; hit = True
if hit:
    json.dump(d, open(p, 'w'), ensure_ascii=False, indent=2)
PYMIG
    then
      log_info "brand_definitions.json: removed the bare gov.hu whitelist entry (it exempted every *.gov.hu sender)"
    else
      log_warn "could not remove the gov.hu entry from brand_definitions.json — do it by hand, it exempts every *.gov.hu sender"
    fi
  fi

  # The toggle now works on EVERY run, and needs no python3.
  #
  # Two bugs are fixed here. It used to apply only when the JSON was freshly
  # seeded, so re-running with ENABLE_HU_BRAND_GUARD=no on an existing host
  # removed the multimap and the composites while the Lua layer kept scoring --
  # the operator asked for the guard off and got a silently re-weighted one.
  # And the disable itself shelled out to python3, which NO earlier module
  # installs (58-report-learn is eighteen modules later), so on a minimal image
  # it failed into a warning and left the guard fully enabled.
  #
  # Asymmetric ON PURPOSE. An explicit "no" is a decision, so it is enforced on
  # every run. "yes" is merely the default, so it is applied only at seed time
  # -- otherwise a re-run would silently re-enable a guard the operator had
  # turned off in the console, which is the standing-config rule this toolkit
  # follows everywhere else.
  if [ "${ENABLE_HU_BRAND_GUARD:-yes}" != yes ] && [ -s "$LOCALD/brand_definitions.json" ]; then
    if grep -qE '"enabled"[[:space:]]*:[[:space:]]*true' "$LOCALD/brand_definitions.json"; then
      backup "$LOCALD/brand_definitions.json"
      sed -i -E 's/"enabled"[[:space:]]*:[[:space:]]*true/"enabled": false/' \
        "$LOCALD/brand_definitions.json"
      if grep -qE '"enabled"[[:space:]]*:[[:space:]]*false' "$LOCALD/brand_definitions.json"; then
        log_info "brand guard disabled in brand_definitions.json (ENABLE_HU_BRAND_GUARD=no)"
      else
        log_warn "could not disable the brand guard in brand_definitions.json — set \"enabled\": false by hand"
      fi
    fi
  fi
  {
    echo "# Written by 40-rspamd — re-rendered on every run, so anything added"
    echo "# here is lost on the next one. Put local composites in"
    echo "#   /etc/rspamd/local.d/composites.d/<name>.conf"
    echo "# which the glob include at the end of this file picks up and this"
    echo "# module never touches. (That directory is the fix for the previous"
    echo "# version of this comment, which said local additions belong in a"
    echo "# separate file without providing one to use.)"
    echo "PHISH_ON_TRUSTED {"
    echo "  expression = \"-PHISHING & (RWL_AMI | DWL_DNSWL_MED | RCVD_IN_DNSWL_LOW | RWL_MAILSPIKE_VERYGOOD | RWL_MAILSPIKE_EXCELLENT | RWL_MAILSPIKE_GOOD)\";"
    echo "  score = 3.0;"
    echo "  description = \"Phishing content sent through whitelisted infrastructure\";"
    echo "}"
    # HU_BRAND_SPOOF/STRONG name HU_BRAND_NAME and HU_BRAND_FROMDOM, which only
    # the multimap defines -- writing them without it would leave composites
    # referencing symbols that do not exist.
    if [ "${ENABLE_HU_BRAND_GUARD:-yes}" = yes ] && [ "${_bg_multimap:-0}" = 1 ]; then
      echo "HU_BRAND_SPOOF {"
      echo "  expression = \"HU_BRAND_NAME & !HU_BRAND_FROMDOM\";"
      echo "  score = 5.0;"
      echo "  description = \"From claims a Hungarian brand from a foreign domain\";"
      echo "  policy = \"leave\";"
      echo "}"
      echo "# The Lua brand guard (HU_BRAND_DN_SPOOF) is a superset of"
      echo "# HU_BRAND_SPOOF: when both fire it is the SAME evidence twice, so"
      echo "# this composite replaces their 5.0+2.5 stack with a single 5.5."
      echo "HU_BRAND_STRONG {"
      echo "  expression = \"HU_BRAND_SPOOF & BRAND_DN_SPOOF\";"
      echo "  score = 5.5;"
      echo "  description = \"Brand display-name spoof confirmed by both the exact and the fuzzy matcher\";"
      echo "}"
    fi
    echo ""
    echo "# Operator-owned composites, never rewritten by the installer."
    echo ".include(glob=true,try=true,priority=1,duplicate=merge) \"\$LOCAL_CONFDIR/local.d/composites.d/*.conf\""
  } | write_file "$LOCALD/composites.conf" 644
  install -d -m 0750 "$LOCALD/composites.d"
  chown root:_rspamd "$LOCALD/composites.d" 2>/dev/null || chown root:root "$LOCALD/composites.d"
fi

# Bayes needs somewhere to persist; autolearn keeps it useful without an operator.
#
# redis.conf is NOT optional alongside it. classifier-bayes says backend
# "redis", but rspamd has no default server address, so without this file every
# statistics call died inside its Lua with
#   rspamd_redis_process_tokens: call to redis failed: attempt to call a nil value
# Nothing surfaced that: teaching a message returned a misleading
# "has been already learned as spam, ignore it" (the dedup cache check fails the
# same way and is read as a positive), Bayes never trained -- "Messages learned:
# 0" with an empty redis -- and classification silently degraded to "the ham
# class needs more training samples". Confirmed on the Ubuntu test host, where
# redis itself was up and answering PING with dbsize 0.
#
# Same address the reference host uses. EL10 substitutes Valkey, which serves
# the identical protocol on this port, so no per-platform branch is needed.
# X-Spamd-Result carries the score and symbol breakdown, and rspamd does NOT
# emit it by default. Without this file no message gets the header, so
# archive-indexer.php's parser finds nothing, every archive_index row keeps
# rspamd_score = NULL, and the Archivum "Pont" column shows "-" for every
# message. Confirmed on the Ubuntu test host: 20 rows indexed, 0 with a score,
# and the messages carried only X-Spam-Flag. The reference host has this file;
# the installer never grew one.
write_file "$LOCALD/milter_headers.conf" 0644 root:root <<'EOF'
# Add X-Spamd-Result (score + full symbol breakdown) to every message. The
# ilexa archive indexer parses this header to populate archive_index.rspamd_score,
# which is what the Archivum score column and its spam/ham sorting read.
extended_spam_headers = true;
EOF

# ---- dangerous attachment extensions -------------------------------------
# SCORES, does not reject. The weight lands a hit well above the tag threshold
# (4) but below reject (15), so the message is marked, delivered and ARCHIVED
# -- recoverable. Only a hit plus further spam signal reaches a rejection.
#
# Chosen over a hard block deliberately: .jar, .msi, .reg and .crt all have
# legitimate uses, a reject leaves NO archive copy and therefore no way to
# retrieve a false positive, and a passthrough reject action outranks the
# admin allowlist -- an allowlisted correspondent could not send a .msi.
#
# Scope, and its limit: this matches ATTACHMENT FILENAMES only and cannot see
# inside an archive. Archives are covered by ClamAV plus Sanesecurity's
# foxhole_filename database, which does read filenames within them -- measured
# 2026-08-17, a bare invoice.exe scans clean while the same file zipped is
# caught as Win.Trojan.Suspect-21. The two are complementary; neither replaces
# the other.
#
# Lives in multimap.d/, not multimap.conf, so a re-render of that template
# cannot silently delete it -- the fuse that killed the Blocklist.de feed.
if [ "$DRY_RUN" != 1 ]; then
  mkdir -p "$LOCALD/maps.d"
  install -m 0644 -o root -g root "$MD_ASSETS/rspamd/dangerous_extensions.inc" \
    "$LOCALD/maps.d/dangerous_extensions.inc"
  write_file "$LOCALD/multimap.d/45-dangerous-attachment-ext.conf" 0644 root:root <<'EOF'
# Dangerous attachment extensions -- scores, does not reject. See the map file
# for the reasoning and for what this rule cannot see (inside archives).
# Managed by ilexa-installer; the extension list is maps.d/dangerous_extensions.inc
# and is hot-reloaded by rspamd on change (no restart needed to edit the list).
dangerous_attachment_ext {
  type = "filename";
  filter = "extension";
  map = "$LOCAL_CONFDIR/local.d/maps.d/dangerous_extensions.inc";
  symbol = "DANGEROUS_ATTACHMENT_EXT";
  description = "Attachment carries an executable/script file extension";
}
EOF
  touch "$LOCALD/groups.conf"
  if ! grep -q '"DANGEROUS_ATTACHMENT_EXT"' "$LOCALD/groups.conf"; then
    cat >> "$LOCALD/groups.conf" <<'EOF'

group "attachments" {
  symbols {
    "DANGEROUS_ATTACHMENT_EXT" {
      weight = 10.0;
      description = "Attachment carries an executable/script file extension";
    }
  }
}
EOF
    log_info "appended DANGEROUS_ATTACHMENT_EXT weight to $LOCALD/groups.conf"
  fi
fi

# ---- neural network + local fuzzy storage ---------------------------------
# Both have run on the reference host since 2026-08-07 and neither was ever
# taught to the installer, so installed hosts lacked two working layers the
# host they were modelled on has.
#
# neural: a small ANN that learns the PATTERN of all other symbols rather than
# any single one, so it catches mail that is individually unremarkable but
# collectively looks like the spam this server actually receives. It emits
# nothing until it has trained.
#
# CORRECTION 2026-08-22: this comment used to read "930 ham / 493 spam of 1000
# after ten days, i.e. genuinely working and simply not mature yet". That was
# wrong. Two weeks later the reference host had 1001 ham (capped) / 568 spam
# and had still never trained a single ANN, because rspamd's default balanced
# mode requires BOTH classes at max_trains -- and spam vectors arrive far
# slower than ham. Worse, the training-vector redis key embeds a digest of the
# symbol list, so every symbol added to the config silently reset the counts
# to zero. Fixed below with classes_bias (tolerate real-world class imbalance)
# and a lower max_trains (reachable between symbol-set changes). Details and
# the arithmetic are in the generated neural.conf header.
#
# local fuzzy: a private fuzzy_storage worker holding hashes of mail YOUR users
# and admins reported, so a near-duplicate of something already reported here
# is recognised even when no public list knows it. This is what makes the
# spam@/ham@ report addresses and the console's teach buttons do more than
# train Bayes. Deliberately IN ADDITION to rspamd.com's public fuzzy rather
# than instead of it -- the reference host disables the public feed
# (servers = ""), which is a defensible local choice but a poor default: a new
# install gets more signal by keeping both.
#
# NOT propagated: the reputation module, which is configured on the reference
# host but demonstrably inert there -- 0 symbols registered in the cache and 0
# redis keys after ten days of uptime. Shipping it would spread a no-op.
if [ "$DRY_RUN" != 1 ]; then
  write_file "$LOCALD/neural.conf" 0644 root:root <<'EOF'
# Neural classifier. Dormant until it has trained, then scores based on the
# learned combination of every other symbol.
#
# Two settings below are deliberately NOT rspamd's defaults, both fixing a
# silent never-trains stall diagnosed on the reference host 2026-08-22, where
# the module had been enabled for two weeks with ZERO ANNs ever produced.
#
# 1. classes_bias = 0.5. In the default balanced mode (bias 0.0) training
#    needs BOTH classes at max_trains. Ham fills from ordinary mail; spam
#    vectors arrive much slower, so the ham set caps out and expires while
#    spam is still climbing. 0.5 tolerates up to a 2:1 imbalance, which is
#    what a real mail server actually produces.
#
# 2. max_trains = 200, not rspamd's 1000.
#
#    Two things force it down. First, the training-vector redis key embeds a
#    digest of the SYMBOL LIST (rn_<rule>_<set>_<digest8>_<ver>_*_set), so ANY
#    change to the enabled symbol set starts a brand-new, empty training set --
#    observed live: adding five symbols reset 1001 ham / 568 spam to zero. A
#    target that takes months is therefore never reached on a server that
#    gains symbols regularly.
#
#    Second, vectors DEDUPLICATE: redis stores them in a SET, so messages that
#    produce the same symbol combination count once. 341 archived spam messages
#    yielded 148 distinct vectors, because spam arrives in campaigns that all
#    score alike (verified by scanning one message twice -- the set grew by
#    one, not two). The effective corpus is DISTINCT VECTORS, not messages, and
#    no amount of replaying changes that.
#
#    200 was then chosen empirically. At 500/bias 0.5 the first ANN trained on
#    598 ham vs 148 spam and rspamd REJECTED it: "degenerate model: constant or
#    single-class output ... predicted spam=0 ham=746 of 746" -- the classic
#    collapse of a 4:1 imbalanced set with a small minority class. The ham set
#    was trimmed to bring the ratio to ~1.7:1, and the threshold follows the
#    class the corpus can actually fill.
#
#    NOTE the arithmetic rspamd applies, which is NOT "max_trains of each
#    class": lualib/plugins/neural.lua gates on the TOTAL --
#    `#ham_vec + #spam_vec < max_trains / 2` -> "insufficient training data".
#    classes_bias then governs how lopsided that total may be.
#
#    Churn resets only ACCUMULATING vectors. Once an ANN is trained it keeps
#    being loaded through later symbol drift (up to 30% distance, see
#    is_profile_compatible() in lualib/plugins/neural.lua), so the goal is to
#    get over the line once.
#
# Progress is snapshotted daily by qa-neural-snapshot.sh ->
# /var/log/qa-neural-snapshots.log, so a repeat stall is visible instead of
# silent.
enabled = true;
rules {
  "default" {
    train {
      max_trains = 200;
      max_usages = 20;
      max_iterations = 25;
      spam_score = 6;
      ham_score = -1;
      classes_bias = 0.5;
    }
    symbol_spam = "NEURAL_SPAM";
    symbol_ham  = "NEURAL_HAM";
    ann_expire  = 100d;
  }
}
EOF
  # Enables rspamd's fuzzy_storage worker; bind address and redis backend come
  # from rspamd's own defaults for that worker.
  write_file "$LOCALD/worker-fuzzy.inc" 0644 root:root <<'EOF'
# Local fuzzy hash storage, listening on 127.0.0.1:11335 (rspamd default).
# Populated by the console's teach buttons and the spam@/ham@ report addresses.
count = 1;
EOF
  write_file "$LOCALD/fuzzy_check.conf" 0644 root:root <<'EOF'
# Public rspamd.com fuzzy is left ENABLED (stock rule, not overridden here) and
# the local store is added alongside it.
timeout = 1s;
retransmits = 1;
rule "local" {
  algorithm = "mumhash";
  servers = "127.0.0.1:11335";
  symbol = "FUZZY_LOCAL";
  mime_types = ["*"];
  read_only = no;
  skip_unknown = yes;
  # min_bytes/min_length/short_text_direct_hash must match the stock text
  # shingle settings, or a hash added by the console is computed differently
  # from the one a scan looks up and nothing ever matches.
  min_bytes = 1024;
  min_length = 64;
  short_text_direct_hash = true;
  fuzzy_map = {
    FUZZY_LOCAL_DENIED { hits_limit = 1; flag = 11; }
    FUZZY_LOCAL_PROB   { hits_limit = 1; flag = 12; }
    FUZZY_LOCAL_WHITE  { hits_limit = 1; flag = 13; }
  }
}
EOF
  touch "$LOCALD/groups.conf"
  if ! grep -q '"FUZZY_LOCAL_DENIED"' "$LOCALD/groups.conf"; then
    cat >> "$LOCALD/groups.conf" <<'EOF'

group "fuzzy_local" {
  symbols {
    "FUZZY_LOCAL_DENIED" { weight =  9.0; description = "Near-duplicate of user/admin-reported spam (local fuzzy)"; }
    "FUZZY_LOCAL_PROB"   { weight =  4.0; description = "Probable near-duplicate of reported spam (local fuzzy)"; }
    "FUZZY_LOCAL_WHITE"  { weight = -3.0; description = "Near-duplicate of a locally-whitelisted message (local fuzzy)"; }
  }
}

group "neural" {
  symbols {
    "NEURAL_SPAM" { weight =  3.0; description = "Neural network classifies message as spam (learned)"; }
    "NEURAL_HAM"  { weight = -2.0; description = "Neural network classifies message as ham (learned)"; }
  }
}
EOF
    log_info "appended neural + local-fuzzy weights to $LOCALD/groups.conf"
  fi
fi

# Greylisting off, for real.
#
# actions.conf sets `greylist = null` and its comment states plainly that
# "greylist is off". That is not sufficient and the two had drifted: `greylist
# = null` only removes the greylist ACTION THRESHOLD, while the greylist MODULE
# keeps running with upstream defaults and issues its own passthrough soft
# reject. On a fresh Ubuntu 24.04 install a perfectly ordinary test message was
# answered "451 4.7.1 Try again later" and rspamd logged
# "greylist.lua:502: greylisted until ..." -- on a host whose own configuration
# said greylisting was disabled.
#
# The reference host does have local.d/greylist.conf with enabled = false, set
# by hand long ago; the installer never learned it. So every installed host
# greylisted while the reference host did not, and the config comment described
# the reference host rather than the product. Delivery latency on first contact
# from every new sender is exactly the cost the comment says was rejected.
write_file "$LOCALD/greylist.conf" 0644 root:root <<'EOF'
# Greylisting disabled. `greylist = null` in actions.conf only unsets the
# action threshold -- the module itself must be turned off here, or it still
# soft-rejects first-contact senders.
enabled = false;
EOF


write_file "$LOCALD/redis.conf" 0644 root:root <<'EOF'
# Local redis/valkey, used for bayes statistics, the learn cache and history.
# Localhost only, no password -- it is not reachable off-box.
servers = "127.0.0.1:6379";
EOF

write_file "$LOCALD/classifier-bayes.conf" 0644 root:root <<'EOF'
backend = "redis";
autolearn = true;
EOF

# ---- Spamhaus DQS (optional) ------------------------------------------------
# Routes Spamhaus lookups through the paid/free-tier Data Query Service instead
# of the increasingly rate-limited free public zones, and adds Spamhaus ZRD
# (Zero Reputation Domains -- flags newly-registered domains, a phishing
# signal). Both score-only; nothing here is wired into force_actions.
#
# Presence of SPAMHAUS_DQS_KEY is the enable flag, same convention as
# OTX_API_KEY. No key -> nothing written, and rspamd still runs its other RBL
# checks (public Spamhaus zones included, from modules.d/rbl.conf) unaffected.
#
# rbl.conf is NOT owned by this feature. It is a shared wrapper whose rbls{}
# block glob-includes rbl.d/*.conf, and this feature owns exactly one slice:
# rbl.d/10-spamhaus-dqs.conf. Abusix Mail Intelligence, host-local overrides
# of stock rules, and any future keyed RBL each get their own slice.
#
# That layout exists because the previous one -- write_file'ing all of
# rbl.conf from here and from qa-spamhaus-dqs.sh, on the documented
# assumption that this feature owned the file outright -- silently destroyed
# a live Abusix config (3 rules, its own secret key) and re-enabled a
# deliberately-disabled URIBL_MULTI block on the reference host for ~4.5
# hours on 2026-08-16, undetected.
#
# 640 root:_rspamd on the slice, 0750 on rbl.d: the key is embedded directly
# in the DNS zone hostname rspamd queries, so the file itself, not a separate
# secrets file, is what needs restricting.
#
# This block only ever runs once, seeding the slice at install time (same
# convention as OTX_API_KEY: modules write secrets directly). After install,
# the key is changed or cleared from the ilexa console (Rendszer -> Spamhaus
# DQS), which shells out to /usr/local/sbin/qa-spamhaus-dqs.sh -- the app
# repo's install/qa-spamhaus-dqs.sh, bundled here as assets/ilexa/qa-
# spamhaus-dqs.sh. That script owns the slice from then on and must be kept
# byte-for-byte in sync with the heredoc below if this ever changes.
#
# NOTE: the slice carries no `rbls {` wrapper of its own -- it is included
# from inside rbl.conf's rbls{} block, so its rules sit at top level.
# Wrapping them again nests rbls{} inside rbls{} and they never register,
# while `rspamadm configtest` still reports "syntax OK" (the include uses
# try=true, so a slice that resolves to nothing is not an error either).
# Verify a change here with `rspamadm configdump rbl`, never configtest alone.
#
# groups.conf is different: multiple modules append to it (70-otx, 72-feeds,
# 35-clamav), so this follows their touch + grep-guard + reload pattern rather
# than write_file, and is scoped to symbols this block alone can produce.
# Both the Spamhaus DQS and the Abusix blocks below write a slice into rbl.d/,
# and BOTH need the wrapper to exist or their slice is never included and the
# feed is silently inert. This lived inside the DQS block, so a host configured
# with an Abusix key and no Spamhaus key got a slice nothing ever read.
# Seed-once, the same rule 72-feeds.sh's set_source follows: the answers file
# supplies a key at install time, the console owns it from then on.
#
# Without this, a re-run with a stale answers file silently reverts a key the
# admin rotated in the console -- and for a DNS datafeed that is worse than it
# sounds. A reverted (now-wrong) key does not error: every lookup just returns
# NXDOMAIN, so the feed goes quiet while the console still shows it configured
# and rspamd still reports "syntax OK". Nothing anywhere says the feed stopped
# working. That is the same shape as geoblock.conf and header_checks, both
# already seed-once for this reason.
#
# Known limitation, inherited from set_source: "never configured" and "the
# admin deliberately cleared the key" both look like an absent slice, so a
# re-run re-seeds the latter from the answers file. Telling those apart needs
# state nothing records today. The common case -- a rotated key being reverted
# by a stale answers file -- is covered.
_seed_once() { # slice-path human-name owning-helper
  [ -s "$1" ] || return 0
  log_info "$2 already configured -- leaving its key to the console ($3)"
  return 1
}

_ensure_rbl_wrapper() {
  mkdir -p "$LOCALD/rbl.d"
  chown root:_rspamd "$LOCALD/rbl.d" 2>/dev/null || chown root:root "$LOCALD/rbl.d"
  chmod 0750 "$LOCALD/rbl.d"

  # The wrapper is shared, so it is only created when absent. If an existing
  # host still carries the old monolithic rbl.conf (rules directly in its
  # rbls{} block, no include), replacing it with a bare wrapper would drop
  # every rule in it -- refuse and let a human migrate instead.
  if [ ! -s "$LOCALD/rbl.conf" ]; then
    write_file "$LOCALD/rbl.conf" 0640 root:_rspamd <<'EOF'
# Shared wrapper. Every rbls{} rule lives in its own file under rbl.d/, one
# per owner, so no feature can overwrite another's. Do not add rules here --
# add rbl.d/<NN>-<owner>.conf instead.
rbls {
  .include(glob=true,try=true,priority=1,duplicate=merge) "$LOCAL_CONFDIR/local.d/rbl.d/*.conf"
}
EOF
  elif ! grep -qF 'local.d/rbl.d/*.conf' "$LOCALD/rbl.conf"; then
    die "$LOCALD/rbl.conf exists but does not glob-include rbl.d/ -- this host has the old monolithic layout. Replacing it here would drop every rule it contains. Migrate by hand: move each rbls{} sub-block into its own $LOCALD/rbl.d/<NN>-<owner>.conf and leave rbl.conf holding only the include, then re-run."
  fi
}

if [ -n "${SPAMHAUS_DQS_KEY:-}" ] && [ "$DRY_RUN" != 1 ] \
   && _seed_once "$LOCALD/rbl.d/10-spamhaus-dqs.conf" "Spamhaus DQS" qa-spamhaus-dqs.sh; then
  _ensure_rbl_wrapper

  write_file "$LOCALD/rbl.d/10-spamhaus-dqs.conf" 0640 root:_rspamd <<EOF
# Spamhaus DQS (Data Query Service) -- account key embedded in the zone
# hostname below. local.d MERGES with modules.d/rbl.conf, so only the \`rbl\`
# zone is overridden here; existing symbol/check definitions still apply.
# CONTAINS A SECRET KEY -> kept at 0640 root:_rspamd.
# Managed by qa-spamhaus-dqs.sh after install -- do not hand-edit.
spamhaus {
  rbl = "${SPAMHAUS_DQS_KEY}.zen.dq.spamhaus.net";
}
DBL {
  rbl = "${SPAMHAUS_DQS_KEY}.dbl.dq.spamhaus.net";
}

# Spamhaus ZRD: domain first-seen (registered/reactivated) recently, a
# phishing signal. no_ip + domain-only checks; ignore_defaults so only the
# ZRD symbols fire. Return codes per Spamhaus: 127.0.2.2-4 = very fresh
# (last few hours); 127.0.2.5-24 = fresh (last 24h).
SPAMHAUS_ZRD {
  rbl = "${SPAMHAUS_DQS_KEY}.zrd.dq.spamhaus.net";
  no_ip = true;
  emails_domainonly = true;
  ignore_defaults = true;
  checks = ["urls", "content_urls", "emails", "dkim"];
  returncodes {
    SPAMHAUS_ZRD_VERY_FRESH_DOMAIN = ["127.0.2.2", "127.0.2.3", "127.0.2.4"];
    SPAMHAUS_ZRD_FRESH_DOMAIN = ["127.0.2.5", "127.0.2.6", "127.0.2.7", "127.0.2.8", "127.0.2.9", "127.0.2.10", "127.0.2.11", "127.0.2.12", "127.0.2.13", "127.0.2.14", "127.0.2.15", "127.0.2.16", "127.0.2.17", "127.0.2.18", "127.0.2.19", "127.0.2.20", "127.0.2.21", "127.0.2.22", "127.0.2.23", "127.0.2.24"];
  }
}
EOF
  log_info "Spamhaus DQS configured (zen + DBL + ZRD)"

  touch "$LOCALD/groups.conf"
  if ! grep -q '"SPAMHAUS_ZRD_VERY_FRESH_DOMAIN"' "$LOCALD/groups.conf"; then
    cat >> "$LOCALD/groups.conf" <<'EOF'

group "rbl" {
  symbols {
    "SPAMHAUS_ZRD_VERY_FRESH_DOMAIN" {
      weight = 3.0;
      description = "URL/email domain first seen in the last few hours (Spamhaus ZRD)";
    }
    "SPAMHAUS_ZRD_FRESH_DOMAIN" {
      weight = 1.5;
      description = "URL/email domain first seen in the last 24h (Spamhaus ZRD)";
    }
  }
}
EOF
    log_info "appended Spamhaus ZRD weights to $LOCALD/groups.conf"
  fi
elif [ "$DRY_RUN" = 1 ] && [ -n "${SPAMHAUS_DQS_KEY:-}" ]; then
  log_info "[dry-run] would configure Spamhaus DQS (zen + DBL + ZRD)"
fi

# ---- Abusix Mail Intelligence (optional) ------------------------------------
# Same shape as the Spamhaus DQS block above: presence of ABUSIX_API_KEY is the
# enable flag, and the key is embedded in the DNS zone hostnames so the slice
# itself is what needs restricting (0640 root:_rspamd).
#
# Writes ONLY rbl.d/20-abusix.conf. The wrapper and every other owner's slice
# are untouched -- which is the entire reason this feature could be built at
# all: against the old monolithic rbl.conf an Abusix writer would have wiped
# Spamhaus DQS exactly as DQS wiped Abusix on 2026-08-16.
#
# The key alone authorizes the query -- an earlier version of this comment
# claimed a per-host IP allowlist was also required, and that was wrong
# (verified 2026-08-17: the same key answers from two hosts with different
# public IPs, each on its own recursive resolver). What IS worth warning about
# at install time is that a key Abusix does not accept fails silently: every
# lookup just returns nothing, so the feed looks configured and does nothing.
if [ -n "${ABUSIX_API_KEY:-}" ] && [ "$DRY_RUN" != 1 ] \
   && _seed_once "$LOCALD/rbl.d/20-abusix.conf" "Abusix" qa-abusix.sh; then
  _ensure_rbl_wrapper

  write_file "$LOCALD/rbl.d/20-abusix.conf" 0640 root:_rspamd <<EOF
# Abusix Mail Intelligence -- DNS datafeed key embedded in the zone hostnames
# below. The key is what authorizes the query; there is no per-IP allowlist to
# configure. A key Abusix does not accept returns NXDOMAIN for every lookup and
# is silent, so verify with 'qa-abusix.sh test' rather than assuming.
# (Single quotes, not backticks: this heredoc is unquoted so the key
# interpolates, and backticks would execute instead of printing.)
# CONTAINS A SECRET KEY -> kept at 0640 root:_rspamd.
# Managed by qa-abusix.sh after install -- do not hand-edit.
#
# Return codes verified empirically against the live test points; the published
# docs/forum codes were WRONG. combined=127.0.0.x, dblack=127.0.1.x,
# white=127.0.2.x. combined and white use the default IP check; dblack is
# domain-only (no_ip).
ABUSIX_MAIL {
  rbl = "${ABUSIX_API_KEY}.combined.mail.abusix.zone";
  ipv6 = true;
  checks = ["from"];
  returncodes {
    RBL_AMI_BLACK = ["127.0.0.2", "127.0.0.3", "127.0.0.200"];
    RBL_AMI_EXPLOIT = ["127.0.0.4"];
    RBL_AMI_POLICY = ["127.0.0.11", "127.0.0.12"];
  }
}
URIBL_AMI {
  rbl = "${ABUSIX_API_KEY}.dblack.mail.abusix.zone";
  no_ip = true;
  emails_domainonly = true;
  ignore_defaults = true;
  checks = ["urls", "content_urls", "emails", "dkim"];
  returncodes {
    URIBL_AMI_BLACK = ["127.0.1.1", "127.0.1.2", "127.0.1.3"];
  }
}
RWL_AMI {
  rbl = "${ABUSIX_API_KEY}.white.mail.abusix.zone";
  is_whitelist = true;
  ipv6 = true;
  checks = ["from"];
  returncodes {
    RWL_AMI = ["127.0.2.1", "127.0.2.2", "127.0.2.3", "127.0.2.4", "127.0.2.5"];
  }
}
EOF
  log_info "Abusix Mail Intelligence configured (combined + dblack + white)"
  log_warn "Abusix fails silently if the key is not accepted -- every lookup just returns nothing. Verify with: qa-abusix.sh test"

  touch "$LOCALD/groups.conf"
  if ! grep -q '"RBL_AMI_BLACK"' "$LOCALD/groups.conf"; then
    cat >> "$LOCALD/groups.conf" <<'EOF'

group "rbl" {
  symbols {
    "RBL_AMI_BLACK" {
      weight = 4.0;
      description = "Sending IP in Abusix Mail Intelligence black (spam/abuse source)";
    }
    "RBL_AMI_EXPLOIT" {
      weight = 4.5;
      description = "Sending IP in Abusix Mail Intelligence exploit (compromised host / botnet)";
    }
    "RBL_AMI_POLICY" {
      weight = 1.5;
      description = "Sending IP in Abusix Mail Intelligence policy (dynamic/residential)";
    }
    "URIBL_AMI_BLACK" {
      weight = 4.0;
      description = "URL/email domain in Abusix Mail Intelligence dblack";
    }
    "RWL_AMI" {
      weight = -2.0;
      description = "Sending IP in Abusix Mail Intelligence allowlist";
    }
  }
}
EOF
    log_info "appended Abusix weights to $LOCALD/groups.conf"
  fi
elif [ "$DRY_RUN" = 1 ] && [ -n "${ABUSIX_API_KEY:-}" ]; then
  log_info "[dry-run] would configure Abusix Mail Intelligence (combined + dblack + white)"
fi

# ---- rspamd extras: mx_check, known_senders --------------------------------
# Both use this build's own baked-in defaults (this rspamd.com repo release,
# not a distro package -- see the repo setup at the top of this file, same
# build on every supported OS). mx_check's ~26 symbols already carry
# per-symbol scores via set_metric_symbol (group "mx") in the module's own
# Lua source; known_senders' 4 symbols carry scores via register_symbol.
# Neither needs a groups.conf addition -- verified live on both the Ubuntu
# 24.04 reference box and hawking: a groups.conf override matching only 6 of
# mx_check's symbols silently downgraded every one of them versus the
# module's own defaults (worst case MX_BOGON_ONLY 8.0 -> 3.0). Do not add
# one without a specific reason.
if [ "${ENABLE_MX_CHECK:-yes}" = yes ] && [ "$DRY_RUN" != 1 ]; then
  write_file "$LOCALD/mx_check.conf" 0640 root:_rspamd <<'EOF'
# Validates that the sender's claimed domain actually has a working mail
# exchanger. Symbol scoring is NOT set here -- this build's mx_check.lua
# already ships its own per-symbol defaults (set_metric_symbol, group "mx"),
# correctly split between sender-fault outcomes (MX_NONE=4.0, MX_NULL=6.0,
# MX_BROKEN=4.0, MX_INVALID=3.0, MX_BOGON_ONLY=8.0, MX_LOCAL_ONLY=3.0) and
# our-side/ambiguous ones left at 0 (MX_DNS_FAIL, MX_ERROR, MX_INFLIGHT,
# MX_REDIS_ERROR, MX_SKIP) or a small nonzero value for signals judged real
# but weaker (MX_TIMEOUT_CONNECT=2.0, MX_REFUSED=3.0). Do not add a
# groups.conf/mx_group.conf override without a specific reason; the shipped
# defaults are the intended values for this deployment.
#
# check_mime_from/check_reply_to are explicitly forced false here (the stock
# module default is true for both) so only the envelope-from probe runs --
# one outbound TCP connection per message instead of three, while this
# signal is new. Revisit once the base signal proves useful.
#
# Greylist advice (the greylist_* flags in the stock config, all default
# true) only has any effect if the greylist module is itself enabled --
# mx_check just sets a mempool flag that module would consume. Nothing
# reads it while greylist stays off (rspamd's default posture here).
#
# Uses the shared redis{} config in local.d/redis.conf; no module-specific
# redis block required. Needs outbound TCP:25 to be useful -- if blocked at
# the network level, probes simply time out and contribute nothing (fails
# open, does not delay or block mail).
enabled = true;
check_mime_from = false;
check_reply_to = false;
EOF
  log_info "mx_check enabled (envelope-from probe only, module's own default scoring)"
elif [ "$DRY_RUN" = 1 ] && [ "${ENABLE_MX_CHECK:-yes}" = yes ]; then
  log_info "[dry-run] would enable mx_check"
fi

if [ "${ENABLE_KNOWN_SENDERS:-yes}" = yes ] && [ "$DRY_RUN" != 1 ]; then
  write_file "$LOCALD/known_senders.conf" 0640 root:_rspamd <<'EOF'
# Tracks per-sender history for freemail domains (gmail.com, outlook.com,
# etc.) where domain-level reputation is meaningless -- individual senders
# within those domains still build real history. KNOWN_SENDER/UNKNOWN_SENDER
# and both INC_MAIL_* symbols carry built-in scores from the module itself
# (-1.0 / +0.5 / -1.0 / -1.0) -- no groups.conf weight needed, unlike
# mx_check. Uses the shared redis{} config in local.d/redis.conf; no
# module-specific redis block required. Needs accumulated history to have
# any effect -- expect zero symbol hits for the first while after install.
enabled = true;
EOF
  log_info "known_senders enabled (module's own default scoring)"
elif [ "$DRY_RUN" = 1 ] && [ "${ENABLE_KNOWN_SENDERS:-yes}" = yes ]; then
  log_info "[dry-run] would enable known_senders"
fi

# ---- wire the milter into postfix -----------------------------------------
# Appended, not replaced: opendkim (8891) and opendmarc (8893) are already there.
if [ "$DRY_RUN" != 1 ]; then
  cur="$(postconf -h smtpd_milters 2>/dev/null || true)"
  case "$cur" in
    *"$RSPAMD_MILTER"*) log_info "rspamd milter already in smtpd_milters" ;;
    "") postconf -e "smtpd_milters = $RSPAMD_MILTER"
        postconf -e "non_smtpd_milters = \$smtpd_milters"
        postconf -e "milter_default_action = accept" ;;
    *)  postconf -e "smtpd_milters = ${cur},${RSPAMD_MILTER}"
        postconf -e "milter_default_action = accept" ;;
  esac
  # accept, not tempfail: if rspamd is down, mail flows unfiltered rather than
  # the server refusing everything.
fi

if [ "$DRY_RUN" != 1 ]; then
  # A FAILED configtest now ABORTS instead of warning, and it does so BEFORE
  # any service is touched.
  #
  # This block used to end in svc_reload, where a broken config was survivable:
  # SIGHUP makes rspamd log "cannot parse new config, revert to old one" and
  # keep the already-running workers. Moving to svc_restart (needed because Lua
  # rules only execute at worker start) quietly turned that into "rspamd stops
  # and does not come back" -- and with milter_default_action = accept set
  # above, every inbound message would then be delivered unfiltered, while the
  # run still printed "deploy complete" (no module uses set -e) and mark_done
  # below made the next run skip this module entirely.
  #
  # The operator's rspamd keeps running its last good config; the run stops so
  # the problem is seen. Note configtest is a syntax check, not a guarantee --
  # it is known to pass on some semantically broken states -- which is another
  # reason not to follow it with an unconditional restart.
  if ! rspamadm configtest >/dev/null 2>&1; then
    rspamadm configtest 2>&1 | tail -5 | while IFS= read -r _l; do log_error "  $_l"; done
    die "rspamadm configtest FAILED — refusing to restart rspamd (it keeps running its previous config). Fix $LOCALD and re-run."
  fi
  log_info "rspamadm configtest OK"
  # restart, not reload: the lua.local.d/ rules are executed once at worker
  # start; a reload demonstrably does not re-run them (verified on the
  # reference host — BRAND_DN_SPOOF only registered after a full restart).
  svc_restart rspamd
  svc_reload postfix
fi

mark_done 40-rspamd
log_info "40-rspamd done (tag='${SPAM_SUBJECT_TAG}' add_header=${SPAM_ADD_HEADER} reject=${SPAM_REJECT})"
