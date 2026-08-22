# mail-deploy — Complete Guide

A detailed reference for the interactive EL9/EL10 + Ubuntu LTS mail-server deployer: what it builds,
how it works internally, every option, prerequisites, recommendations, and the
post-install steps you must complete yourself.

- [1. What it builds](#1-what-it-builds)
- [2. Prerequisites](#2-prerequisites)
- [3. Running the deployer](#3-running-the-deployer)
- [4. The start screen & how to exit](#4-the-start-screen--how-to-exit)
- [5. Every option (answer keys)](#5-every-option-answer-keys)
- [6. How the script works](#6-how-the-script-works)
- [7. Module-by-module](#7-module-by-module)
- [8. Recommendations](#8-recommendations)
- [9. After the run — DNS & testing](#9-after-the-run--dns--testing)
- [10. Verification & acceptance](#10-verification--acceptance)
- [11. Troubleshooting](#11-troubleshooting)
- [12. Security & secrets handling](#12-security--secrets-handling)
- [13. Extended features](#13-extended-features)

---

## 1. What it builds

A complete virtual-domain mail server, reproducing a production-grade reference
stack from parameterized templates:

| Layer          | Software                                             |
|----------------|------------------------------------------------------|
| MTA            | Postfix (MySQL virtual domains, postscreen DNSBLs)   |
| IMAP/POP3      | Dovecot (SQL auth, Maildir, optional fts_xapian)     |
| Content filter | rspamd + ClamAV                                      |
| Authentication | OpenDKIM, OpenDMARC, policyd-spf                      |
| Databases      | MariaDB (postfix, roundcube)                          |
| Admin UIs      | PostfixAdmin, ilexa console                          |
| Webmail        | **Roundcube** (the only webmail — no AfterLogic)     |
| Brute-force    | Fail2Ban                                             |
| Firewall       | firewalld geoblock + OTX IP block ipsets             |
| Threat-intel   | AlienVault OTX (IP block + URI→rspamd + rbldnsd DNSBL) |
| User filtering | Sieve + ManageSieve (server-side rules, editable from webmail) |
| Quotas         | PostfixAdmin per-mailbox quotas, enforced at SMTP time |
| Inbound TLS    | MTA-STS + TLS-RPT + DANE/TLSA record generation      |
| Client setup   | Thunderbird autoconfig + Outlook autodiscover        |
| Observability  | SIEM export (rsyslog forward, opt-in), Prometheus node_exporter (opt-in) |
| Maintenance    | dnf-automatic security updates, backups, auto-reboot |

**Design principle:** *template, never copy live config.* Nothing from the
reference box's secrets or domains is baked in; every site value comes from your
answers, and strong DB passwords are generated per run.

---

## 2. Prerequisites

### Host / OS
- **AlmaLinux 9/10 or Rocky 9/10**, or **Ubuntu 22.04/24.04/26.04 LTS**. The
  deployer refuses to run on anything else.
- **No packages to install by hand.** The interactive wizard needs `whiptail`
  (shipped in `newt` on EL, `whiptail` on Debian/Ubuntu); if it is missing the
  deployer installs it itself before drawing the first dialog, so a bare
  minimal image is fine. `--answers` mode does not need it at all. The one
  exception is `--dry-run` on a host without it: dry-run must not install
  packages, so install it yourself first or use `--answers`.
- **Root access** (run with `sudo`).
- A **fresh host.** Modules overwrite `/etc/postfix`, `/etc/dovecot`, MariaDB
  databases, firewalld zones, etc. with templated defaults. Do **not** run this
  on a server that already carries mail you care about.

### Hardware (minimums / recommended)
- **RAM:** 2 GB minimum; **4 GB+ recommended.** rspamd + ClamAV + fts_xapian
  are memory-hungry. If under ~2 GB total (RAM+swap) the deployer adds a 2 GB
  swapfile automatically.
- **Disk:** enough for the mail store (`/data/mail` by default) plus DBs and logs.
  Put the mail store on its own volume for real deployments.
- **CPU:** any modern 1–2 vCPU is fine for a small/medium community server.

### Network / ports
The host must be able to **receive** on 25/465/587/143/993/110/995 and 80/443,
and **make outbound** connections (package repos, Let's Encrypt, OTX API,
ipdeny.com, Cloudflare/Google range feeds). Port 25 outbound must not be blocked
by your provider or you cannot send mail.

### DNS worth creating *before* the run (optional, saves a second pass)
Everything under "DNS you must control" below is set **after** the run, because
the tool prints the exact records once it knows them. Two names are the
exception, and creating them **first** is worth it:

```
autoconfig.<domain>     IN CNAME <your FQDN>.     # if ENABLE_AUTOCONFIG=yes
autodiscover.<domain>   IN CNAME <your FQDN>.     # if ENABLE_AUTOCONFIG=yes
mta-sts.<domain>        IN CNAME <your FQDN>.     # if ENABLE_MTA_STS=yes
```

Both features are served over **HTTPS from those names**, so the TLS
certificate has to cover them. Let's Encrypt only issues for names that already
resolve, and a single unresolvable name fails the **whole** certificate order —
so the installer omits any that are missing rather than losing the certificate
entirely. The result is a feature that is installed but quietly broken until
you create the records and re-issue.

Create them beforehand and the certificate covers everything in one pass.
Skip them and nothing blocks: preflight lists exactly which are missing at the
**start** of the run, the summary repeats it at the **end**, an ACTION REQUIRED
block is written into `/root/mail-deploy-dns-extra.txt`, and you finish with:

```bash
./deploy.sh --only 75-tls-dns --answers <your answers file>
```

### DNS you must control (set *after* the run — the tool prints exact records)
- **A** record for the FQDN → the server's public IP
- **MX** record for each mail domain → the FQDN
- **PTR / rDNS** for the public IP → the FQDN (set at your hosting provider; this
  is the single biggest deliverability factor and the tool cannot set it for you)
- **SPF**, **DKIM** (generated per domain, written to
  `/root/mail-deploy-dkim-dns.txt`), and **DMARC** TXT records

### Optional
- An **AlienVault OTX API key** (free at otx.alienvault.com) if you enable the OTX
  suite. You can supply it during the run or drop it into `/etc/ilexa/secrets/otx_api_key`
  (mode 0600) afterwards.
- An **SSH public key** if you enable SSH key-only hardening (required, or that
  step self-skips to avoid lockout).

---

## 3. Running the deployer

```bash
git clone <this repo> mail-deploy && cd mail-deploy

# Interactive whiptail wizard (recommended for a first run):
sudo ./deploy.sh

# Unattended / repeatable — copy and edit the answer file first:
cp answers.example.conf answers.conf
$EDITOR answers.conf
sudo ./deploy.sh --answers answers.conf

# See exactly what WOULD happen, changing nothing:
sudo ./deploy.sh --dry-run --answers answers.conf

# Re-run a single stage (idempotent; repeatable):
sudo ./deploy.sh --only 20-postfix --answers answers.conf
```

| Flag              | Effect                                                        |
|-------------------|---------------------------------------------------------------|
| *(none)*          | Interactive whiptail wizard                                    |
| `--answers FILE`  | Read all values from FILE (no prompts)                        |
| `--dry-run`       | Log intended actions; make **no** changes                     |
| `--only NAME`     | Run only matching module(s), e.g. `--only 25-dovecot` (repeatable) |
| `--help`, `-h`    | Usage                                                         |

Everything is logged to `/var/log/ilexa-install.log`. Generated DB passwords and
the Roundcube `des_key` go to `/root/ilexa-install-credentials.txt` (0600).

---

## 4. The start screen & how to exit

When run interactively, the deployer opens with a **purpose screen** describing
what it will build and warning that it targets a fresh host. From there:

- **ENTER** — begin the questionnaire.
- **Ctrl+X** — exit immediately, making no changes (handled by a raw single-key
  read, so it works reliably; whiptail cannot bind Ctrl+X itself).

During the questionnaire every dialog has an **Exit** button (and **Esc** works
too). Choosing Exit/Esc aborts cleanly with no changes. The final **review
screen** lists every setting; its **Abort** button stops before anything is
touched. Nothing on disk changes until you pass that review.

---

## 5. Every option (answer keys)

These are the keys in `answers.example.conf` (and the questions the wizard asks).

### Identity
| Key | Meaning | Default |
|-----|---------|---------|
| `MAIL_FQDN` | Public FQDN (MX target, TLS common name) | `mail.example.com` |
| `MAIL_HOSTNAME` | Short hostname | derived from FQDN |
| `PRIMARY_DOMAIN` | Primary virtual mail domain | derived from FQDN |
| `EXTRA_DOMAINS` | Space-separated additional domains | empty |
| `TIMEZONE` | System + PHP timezone | `Europe/Budapest` |

### Admin
| Key | Meaning | Default |
|-----|---------|---------|
| `ADMIN_EMAIL` | PostfixAdmin superadmin login + alert destination | `postmaster@…` |
| `ADMIN_PASSWORD` | Superadmin password (blank ⇒ auto-generated) | auto |
| `PFA_ADMIN_PASSWORD` | `postfixadmin@<fqdn>` mailbox password (blank ⇒ auto-generated) | auto |

### Storage / TLS
| Key | Meaning | Default |
|-----|---------|---------|
| `MAIL_STORE` | Maildir root (`<store>/<domain>/<user@domain>/`) | `/data/mail` |
| `TLS_MODE` | `letsencrypt`, `custom` or `selfsigned` | `letsencrypt` |
| `CERTBOT_METHOD` | `standalone` or `webroot` | `webroot` |
| `TLS_CUSTOM_CERT` / `TLS_CUSTOM_KEY` | your own cert + key (`custom` mode only) | — |

### Scanner (rspamd)
| Key | Meaning | Default |
|-----|---------|---------|
| `SPAM_ADD_HEADER` | Score at which mail gets `X-Spam` headers | `4` |
| `SPAM_REWRITE_SUBJECT` | Score at which the subject gets tagged | `6` |
| `SPAM_REJECT` | Safety-net reject threshold; also arms the ClamAV virus reject | `15` |
| `SPAM_SUBJECT_TAG` | Subject prefix applied at the rewrite threshold | `{Spam?}` |
| `ENABLE_MX_CHECK` | Probe the envelope-from domain's MX (rspamd `mx_check`; uses the module's own built-in symbol scores, fails open if outbound :25 is blocked) | `yes` |
| `ENABLE_KNOWN_SENDERS` | Per-sender reputation for freemail domains, where domain reputation is meaningless; needs accumulated history before its symbols fire | `yes` |
| `ENABLE_HU_BRAND_GUARD` | Brand-impersonation guard, two layers. Exact: a From display-name claiming a known Hungarian brand from a foreign domain scores +5 (`HU_BRAND_SPOOF`). Fuzzy: a Lua rule (`HU_BRAND_DN_SPOOF`, +2.5) additionally catches lookalikes — `0TP`, Cyrillic `ОТР`, accent tricks — via transliteration, homoglyph folding and edit-distance 1; when both fire, the `HU_BRAND_STRONG` composite merges them into a single +5.5. Brands, name variants and real domains live in `local.d/brand_definitions.json` (seeded with 16 Hungarian + 30 international brands: PayPal, Amazon, Microsoft, DHL, Booking.com, …; dictionary-word brand names like Visa/Apple/Meta use `=`-prefixed whole-name-only variants to avoid false positives) — standing config seeded once and then managed from the console (Rendszer → Márkavédelem) or `qa-brand-guard.sh`; the toggle only affects the first seed (`"enabled"` in the JSON is the live switch). The universal `PHISH_ON_TRUSTED` composite (phishing via whitelisted infra loses its whitelist bonuses) installs regardless | `yes` |

Content filtering is **rspamd only** — this replaces the old `SA_THRESHOLD`; there
is no separate SpamAssassin-style single score, just the three thresholds above.
ClamAV hits (`CLAM_VIRUS`) are rejected outright regardless of score.

### Filtering / firewall
| Key | Meaning | Default |
|-----|---------|---------|
| `GEOBLOCK_COUNTRIES` | firewalld geoblock country codes (one-time seed for `/etc/ilexa/geoblock.conf`; later changes go through the ilexa console) | `ru cn br kr` |
| `SSH_PORT` | SSH port opened in firewalld | `22` |
| `WEBMIN_PORT` | Webmin port opened (if Webmin present) | `10000` |

### ilexa console
| Key | Meaning | Default |
|-----|---------|---------|
| `ENABLE_ILEXA` | Install the ilexa mail-security console | `yes` |
| `ILEXA_ADMIN_USER` | First console admin (Basic auth) | `admin` |
| `ILEXA_ADMIN_PASSWORD` | Console admin password (blank ⇒ auto-generated) | auto |
| `ILEXA_URL_PREFIX` | Apache `Alias` + cookie path | `/ilexa/` |
| `ILEXA_LANG` | Console UI language (`en`/`hu`), seeded once; the console's Admin → language owns it afterwards | `en` |
| `QUARANTINE_FOLDERS` | Dovecot folders the console treats as quarantine | `Junk Quarantine Spam` |

### Mail archive (opt-in) — the deployment-type choice

This is the one option that changes what kind of system you end up with, so it
is asked as a deployment type rather than a feature toggle. **Filtering is
identical either way.** What the archive adds is recovery, retrospective search
and training signal.

**Why copy every message at all?** Because of how mail actually leaves this
server:

- **POP3 clients delete mail from the server after download.** Once a user has
  collected their mail there is no server-side copy left — a message that was
  mis-filed can never be examined, recovered, or learned from. IMAP users who
  empty folders leave the same hole.
- **Users do not reliably report spam.** Webmail's mark-as-junk buttons and
  the `spam@`/`ham@` report addresses (`ENABLE_REPORT_ADDRESSES`, see §13)
  only work for people who bother to use them, so without an archive the
  filter's training corpus is whatever a handful of users happened to report.
- **There is no quarantine in this design.** Suspect mail is tagged and
  *delivered* — deliberately — so the archive is the only place a false
  positive can be retrieved from. That includes mail scored down for a
  dangerous attachment, which is delivered precisely so it stays recoverable.
- **The Archive tab, its search, the spam/ham training buttons and the weekly
  digest all read from it.** Without it, those features have no data.

**Without the archive** you get a filtering-only mail server: spam is still
scored, tagged and rejected exactly the same. You lose recovery, history and
most of the training signal.

#### GDPR / privacy

Enabling this copies the **content** of everyone's mail — inbound and outbound,
personal and business — into one mailbox administrators can read. In most
jurisdictions that is personal-data processing, which needs:

- a **lawful basis** (legitimate interest in mail security is the usual one, and
  usually requires a balancing assessment you should record),
- a **defined retention period** — `ARCHIVE_RETENTION_DAYS`, enforced by a daily
  purge job, not left to manual cleanup,
- **users informed in advance**, typically in an acceptable-use or privacy
  notice naming what is retained, for how long, and who can read it.

Two things reduce exposure and are worth knowing before you decide:

- the console's **content-viewing policy** (Rendszer → adatvédelem) gates whether
  message bodies can be read at all — `none` / `spam only` / `all` — and
  **defaults to deny**, so enabling the archive does not by itself grant anyone
  read access;
- every view, release and resend is written to the **audit log** with the
  operator's account name.

| Key | Meaning | Default |
|-----|---------|---------|
| `ENABLE_ARCHIVE` | Central always-bcc archive of every message — see the GDPR notes above | `no` |
| `ARCHIVE_USER` | Mailbox every message is archived into | `archive@<primary domain>` |
| `ARCHIVE_RETENTION_DAYS` | Days before archived mail is purged | `30` |

### Feed sources & breach check (opt-in)
| Key | Meaning | Default |
|-----|---------|---------|
| `ENABLE_FEEDS` | Reputation-feed layer (URLhaus, Spamhaus DROP, ThreatFox/Feodo, disposable domains) | `no` |
| `OTX_API_KEY` | AlienVault OTX key — shared with the `ENABLE_OTX` suite above | empty |
| `ABUSECH_API_KEY` | abuse.ch key (URLhaus/ThreatFox/Feodo) | empty |
| `ABUSEIPDB_API_KEY` | AbuseIPDB key | empty |
| `ENABLE_BREACH_CHECK` | XposedOrNot breach lookups in the console | `no` |
| `ABUSIX_API_KEY` | Abusix Mail Intelligence datafeed key (postscreen/rspamd DNSBL zones; console-editable later) | empty |
| `SPAMHAUS_DQS_KEY` | Spamhaus DQS key (zen/DBL/ZRD zones; console-editable later) | empty |

Any source whose key is left blank is skipped rather than failing the install.

### OTX threat-intel
| Key | Meaning | Default |
|-----|---------|---------|
| `ENABLE_OTX` | Install the OTX suite | `yes` |
| `OTX_API_KEY` | Your OTX key (blank ⇒ set later in `/etc/ilexa/secrets/otx_api_key`) | empty |
| `OTX_TRUSTED_CIDRS` | Extra never-block CIDRs (CF/Google already covered) | empty |
| `ENABLE_OTX_URI` | OTX URI feed → rspamd url multimap (symbol `FEED_OTX_URI`) | `no` |

### Optional extras
| Key | Meaning | Default |
|-----|---------|---------|
| `ENABLE_LAST_LOGIN` | Dovecot last-login tracking | `yes` |
| `ENABLE_FTS_XAPIAN` | Full-text search (compiled; RAM-heavy) | `yes` |
| `ENABLE_UNATTENDED` | dnf-automatic security updates | `yes` |
| `ENABLE_FTS_OPTIMIZE` | Weekly RAM-capped compaction of the fts_xapian indexes (skips indexes too large to compact safely; console-switchable afterwards) | `yes` |
| `ENABLE_UNOFFICIAL_SIGS` | Third-party ClamAV signatures + YARA rules (`clamav-unofficial-sigs`); required by the console's signature/YARA panel. EL only | `yes` |
| `ENABLE_SIEM_EXPORT` | Seed the rsyslog SIEM-forward config (Fail2Ban / Apache-SSL errors / console audit → local2-4). The console's Rendszer → SIEM card owns it afterwards; actual forwarding stays off until a collector is configured there | `no` |
| `HU_CLASSIFY_REPORT_EMAIL` | Destination for the fortnightly `41-hu-classify` auto-review report | empty |
| `ENABLE_REPORT_ADDRESSES` | spam@/ham@ report addresses in every mail domain — forward a mis-classified message as an attachment to train the filter (see §13) | `yes` |

### Hardening (secure-by-default)
| Key | Meaning | Default |
|-----|---------|---------|
| `HARDEN_SSH_KEYONLY` | Key-only SSH + sudo admin user | `yes` |
| `ADMIN_SSH_PUBKEY` | Public key seeded into `mailadmin` (**required** for the above) | empty |
| `HARDEN_SELINUX` | `no` ⇒ documented TODO; `yes` ⇒ permissive burn-in | `no` |
| `HARDEN_WEBMIN` | Webmin source-IP allowlist | `yes` |
| `WEBMIN_ALLOW_IPS` | Allowlist (add your admin IP) | `127.0.0.1` |
| `HARDEN_KERNEL_AUTOREBOOT` | Scheduled maintenance-window reboot | `yes` |
| `HARDEN_SMTP_TUNING` | `message_size_limit` 50 MB + `smtpd_delay_reject=yes` | `yes` |
| `MESSAGE_SIZE_LIMIT` | Max message size in bytes | `52428800` (50 MiB) |
| `SENDER_LOGIN_POLICY` | May an authenticated user put someone else's address in MAIL FROM? `warn` logs violations, `enforce` rejects, `off` disables. Start with `warn`, review the log, then enforce. Legitimise a *role alias* by adding the sender to its goto (that is what the alias exists to do); for everything else — senders in *unhosted* domains, or send-as delegation between two *real mailboxes* (where touching goto would also forward the target's incoming mail) — add a `<sender> <sasl-user>` line to `/etc/postfix/sender_login_exceptions` and `postmap` it | `warn` |
| `BACKUP_TARGET` | Backup destination (empty ⇒ module inert) | empty |
| `BACKUP_PASSPHRASE` | If set, DB dumps are gpg-encrypted at rest (they contain password hashes) | empty |

---

## 5b. Where things are installed

Every file this installer places on a host lands in one of the locations below.
The paths are declared once in `lib/common.sh` (`ILEXA_SBIN`, `ILEXA_STATE`,
`ILEXA_SECRETS`, `ILEXA_GEOIP`) and read from there, so they are changed in one
place rather than in the two dozen files that reference them.

| Location | Mode | Contents |
|---|---|---|
| `/usr/local/sbin/` | 0755 root:root | Everything an admin or cron runs: the `load-*.sh` feed loaders, `qa-*` console helpers, `update-*.sh` refreshers. |
| `/usr/bin/` | 0755 root:root | The OTX suite's own wrappers (`update-otx*.sh`, `otx-rbldnsd-sync.sh`, `cron-alert.sh`, `firewall-report.sh`). |
| `/etc/ilexa/` | 0755 root:root | Console configuration the sudo helpers rewrite: `feeds.conf`, `geoblock.conf`, `ioc_lookup.conf`. |
| `/etc/ilexa/secrets/` | **0700** root:root | API keys, each 0600: `otx_api_key`, `abuse_api_key`, `abuseipdb_key`, `vt_api_key`. |
| `/var/lib/ilexa/` | 0755 root:root | State the loaders build and read back: `otx-whitelist.txt`, `otx-whitelist-auto.txt`, `otx-uri-whitelist.txt`. |
| `/var/lib/ilexa/geoip/` | 0755 root:root | Downloaded ipdeny country zone files (`ru.zone`, `cn.zone`, …). |
| `/var/lib/ilexa-install/state/` | 0755 root:root | Per-module `.done` markers and `secrets.env` (0600) for cross-module values. |
| `/var/lib/ilexa-install/backups/` | 0755 root:root | Every file the installer overwrote, named after its full original path. Backups are **not** left beside the original, so directories that are read wholesale (`/etc/cron.d`, `/etc/rspamd/local.d`) stay free of stray files. |
| `/var/log/ilexa-install.log` | 0644 root:root | The install log. **World-readable — never write a credential here.** |
| `/root/` | 0600 / 0644 | Operator output only: `ilexa-install-credentials.txt` (0600) and the generated `mail-deploy-dkim-dns.txt` / `mail-deploy-dns-extra.txt`. |

Two deliberate choices worth knowing:

**`/etc/ilexa/secrets/` is 0700 rather than 0600 files inside `/etc/ilexa/`.**
`/etc/ilexa` itself is 0755 and holds config the console reads, so "the web user
can never read an API key" is made a property of the directory instead of
something every individual file has to get right.

**State lives in `/var/lib`, not `/var/cache`.** `/var/cache` implies safely
deletable; `firewall-report.sh` genuinely reads the geoip zone files back, so
deleting them would break it.

Earlier versions of this installer put the loaders, the zone files and the API
keys directly in `/root`. A run of `05-base` on such a host relocates them
automatically and reports how many files it moved; nothing needs doing by hand.
If cron entries on that host were written by an older installer, re-running the
owning module rewrites them.

## 6. How the script works

### Execution flow (`deploy.sh`)
1. **parse args** → interactive vs `--answers`, dry-run, module filter.
2. **drain in-progress system updates** — a freshly booted image starts its
   own unattended update within minutes (Ubuntu: apt-daily/unattended-upgrade;
   EL: dnf-makecache) and holds the package lock; the installer waits for it
   *visibly*, naming the holder and counting elapsed time (cap 30 min,
   `PKG_LOCK_WAIT_MAX=` to override) instead of silently sitting on the lock
   and looking hung. Every later apt call additionally carries
   `DPkg::Lock::Timeout` in case an updater re-triggers mid-run.
3. **welcome screen** (interactive) → purpose + Ctrl+X exit.
3. **collect answers** → whiptail wizard *or* source the answer file.
4. **apply defaults + derive values** → e.g. TLS cert paths from `TLS_MODE`,
   the postscreen DNSBL list (adds `otx.rbl*2` only if OTX is on),
   `smtpd_delay_reject` from the SMTP-tuning toggle.
5. **validate** → required keys present, FQDN looks like an FQDN, warn if SSH
   key-only is requested without a key.
6. **export config** → all answers exported so module subprocesses inherit them.
7. **review screen** (interactive) → confirm, or abort with no changes.
8. **preflight gate** → root + a supported OS (EL 9/10 or Ubuntu 22.04/24.04/26.04 LTS).
9. **run modules** → each `modules/NN-*.sh` executed **as a subprocess** in
   numeric order. A module failure stops the run.

Modules run as isolated subprocesses (not sourced) so one module crashing cannot
corrupt the driver, and each can be run standalone with `--only`.

### Templating — `render()`
Configs live in `templates/` as `*.tmpl` with `@@PLACEHOLDER@@` markers.
`render()` substitutes them with **`sed`**, *not* `envsubst`, precisely so that
native `$postfix` / `$dovecot` variables (`$myhostname`, `$mydomain`, `$user`,
the `$queue_directory`-prefixed postfix-files path, …) are preserved untouched.
`render()` **hard-fails if a template references a placeholder you didn't set** —
so a missing value is caught immediately, not silently shipped.

### Idempotency & safety
- Each module writes a marker to `/var/lib/ilexa-install/state/NN.done` and
  **skips** if already done — so re-running is safe and resumes where it stopped.
- Every file is **backed up** (`*.mdbak-<timestamp>`) before overwrite.
- `--dry-run` sets `DRY_RUN=1`; all mutating helpers (`pkg_install`, `write_file`,
  `render`, DB helpers, `svc_*`) log their intent and change nothing.

### Secrets
- DB passwords are generated with `gen_pw` (alphanumeric only, so they are safe
  inside DSNs and shell), recorded to `/root/ilexa-install-credentials.txt`, and
  shared between modules via `save_secret`/`load_secrets` (a 0600 env file under
  the state dir). No credential is ever written into the repo.

---

## 7. Module-by-module

| Module | What it does |
|--------|--------------|
| `00-preflight` | OS gate (EL9/EL10, Ubuntu LTS) + root check; warns on unresolved FQDN, low RAM, busy ports, disk. |
| `05-base` | EPEL, PHP module stream (EL9 only — EL10 ships PHP unmodularized), `mtagroup`, swapfile if short, sysctl tuning, crypto-policy DEFAULT. |
| `10-mariadb` | Install + localhost bind + 512 MB pool; creates `postfix`/`roundcube` DBs with generated passwords, plus the ungranted read-only `postfix_maps` user (grants come from `50-web` once the schema exists). |
| `20-postfix` | Renders `main.cf`/`master.cf`; writes the 9 MySQL maps with the read-only `postfix_maps` user (column-scoped — cannot read `mailbox.password`); postscreen DNSBLs. |
| `25-dovecot` | SQL auth, Maildir, TLS, gz storage, the LMTP delivery socket Postfix delivers through (sieve/quota/zlib run at delivery), quarantine-folder auto-create; optional `last_login` and `fts_xapian` (built from source on EL, packaged on Ubuntu; only enabled if the `.so` verifies). |
| `26-sieve` | Sieve server-side filtering + ManageSieve on 4190 (dovecot-pigeonhole; Roundcube `managesieve` plugin wired in `50-web`). |
| `27-quota` | PostfixAdmin per-mailbox quotas: RCPT-time rejection via Dovecot's `quota-status` policy (refuse before accepting responsibility), enforced again at LMTP delivery; IMAP QUOTA reporting on. |
| `30-auth` | OpenDKIM per-domain 2048-bit keys (+ DNS records), OpenDMARC, policyd-spf. |
| `35-clamav` | Enables freshclam (auto-updating defs) + clamd, called through rspamd. |
| `40-rspamd` | rspamd as the sole mail filter (`add_header 4 / rewrite_subject 6 / reject 15`); ClamAV wired in as `CLAM_VIRUS`; `_rspamd` added to `mtagroup` so it can reach the clamd socket. |
| `41-hu-classify` | Opt-in (`ENABLE_HU_CLASSIFY`, default `no`), experimental. Language, text-coherence and (where a host has trained one) spam-router signals, computed by a small local Python service. **All symbols are weight 0.0** — see §13 for what each one actually measures and why none is a rule. Installs inert; the console's Rendszer page is the on/off switch. |
| `50-web` | Apache + PHP, security headers, PostfixAdmin (+ its schema, then the `postfix_maps` column-level SELECT grants), Roundcube + password plugin. |
| `55-ilexa` | Deploys the ilexa console from the bundle built by `tools/bundle-ilexa.sh`; Apache alias + Basic auth, root helpers, sudoers, DB read-only user, map seeding, crons. Runs after `50-web` and `40-rspamd`. |
| `57-archive` | Opt-in central mail archive (always-bcc into one admin-readable mailbox); off by default because of its legal/GDPR weight. |
| `58-report-learn` | spam@/ham@ report addresses in every mail domain: dedicated `rspamreport` user, hardened python3 handler (attachment-extract → strip scanner headers → rspamd Bayes learn + local fuzzy add/del, spam copies saved to the reporter's Spam folder via a one-command sudoers rule), master.cf pipe services + transport routing + alias rows. Never clobbers an existing spam@/ham@. |
| `60-firewalld` | Public zone, geoblock + OTX ipsets, drop rules (port 25 never dropped). |
| `65-fail2ban` | sshd / postfix-sasl / dovecot / apache jails, 1 h ban + escalation. |
| `66-siem-export` | Seeds the rsyslog SIEM-forward config once via `qa-siem-config.sh`; the console's Rendszer → SIEM card is the sole owner afterwards. Forwarding stays off until a collector is configured there. |
| `70-otx` | The OTX suite: IP block, URI→rspamd, rbldnsd port-25 DNSBL, soft-fail cron. |
| `72-feeds` | Opt-in reputation/blocklist feeds (URLhaus, Spamhaus DROP, ThreatFox/Feodo, disposable domains); every updater is installed, only key-bearing sources are enabled. |
| `75-tls-dns` | certbot (self-signed fallback) + unbound as local resolver. |
| `76-mta-sts` | MTA-STS policy served over HTTPS, TLS-RPT, DANE/TLSA generation; all DNS records written to `/root/mail-deploy-dns-extra.txt`. Runs after web (50) + TLS (75). |
| `78-autoconfig` | Thunderbird autoconfig + Outlook autodiscover from `autoconfig.`/`autodiscover.<domain>` (cert SANs handled in `75-tls-dns`). |
| `80-unattended` | dnf-automatic security-only, **excludes `dovecot*`** (fts ABI safety). |
| `82-metrics` | Optional Prometheus `node_exporter`: localhost-bound by default; `METRICS_SCRAPE_CIDR` opens 9100 to exactly that CIDR. |
| `85-hardening` | SSH key-only (+ admin user), SELinux opt-in, Webmin allowlist, auto-reboot, backups. |
| `90-enable` | Enables + starts all services in order. |
| `95-sources` | Initial fetch for every enabled reputation source — without it a fresh install's feeds sit empty until their first 03:00-ish cron (geoblock: Monday). Soft-fails per source rather than failing the install. |
| `99-verify` | Non-destructive self-check + prints the DNS records you must set. |

---

## 8. Recommendations

- **Deliverability first.** Set **PTR/rDNS** and a correct **SPF/DKIM/DMARC** set
  before announcing the server. Without rDNS matching the FQDN, major providers
  will reject or spam-folder your mail regardless of everything else here.
- **RAM & swap.** Prefer **4 GB+**. On a tight box, keep `process_limit=2` for the
  fts indexer (already set) and let the auto-swapfile stand.
- **fts_xapian is powerful but fragile.** It is compiled out-of-tree and RAM-heavy;
  the first bulk index of a very large flat mailbox is slow by nature. If you don't
  need server-side full-text search, set `ENABLE_FTS_XAPIAN=no`. It is
  deliberately **excluded from unattended updates** — after any manual Dovecot
  upgrade, rebuild it (`/usr/local/src/fts-xapian`).
- **rspamd actions.** `SPAM_ADD_HEADER=4 / SPAM_REWRITE_SUBJECT=6 / SPAM_REJECT=15`
  is the reference box's validated "Light" posture; ClamAV hits (`CLAM_VIRUS`) are
  rejected outright regardless of score. Leave the defaults unless you have data
  suggesting otherwise.
- **SELinux.** Off by default to match the reference box and avoid first-run
  breakage. If you opt in, it starts **permissive**; review
  `ausearch -m avc | audit2allow` before switching to enforcing.
- **Backups.** The backup module is installed but **inert** until you set
  `BACKUP_TARGET` (in the answer file or `/etc/mail-backup.conf`). Point it at
  off-host storage (restic/borg/rsync/S3) and confirm the nightly restore-test
  logs `OK`.
- **SSH hardening.** Supply `ADMIN_SSH_PUBKEY`. The step creates a key-seeded
  `mailadmin` sudo user first and validates `sshd -t` before reload, so a bad
  config self-reverts — but always keep your current session open and test a new
  key login before closing it.
- **TLS.** Three modes:
  - `letsencrypt` (default) — certbot runs during the install, arms
    `certbot.timer`, and installs a deploy hook that reloads postfix, dovecot
    and the web server on every renewal. `webroot` is the default method;
    `standalone` needs port 80 free at issuance time, which it is not once the
    web server is up.
  - `custom` — install a certificate you already hold (commercial, wildcard, or
    from an internal CA) via `TLS_CUSTOM_CERT` / `TLS_CUSTOM_KEY`. Validated
    before anything is written: the key must match the certificate, it must not
    be expired, and it must cover `MAIL_FQDN`. A failure aborts the run instead
    of falling back. **Renewal is yours to handle in this mode**, and the key
    must not be passphrase-protected — services start unattended.
  - `selfsigned` — labs only, and the automatic fallback when Let's Encrypt
    cannot issue. No browser or mail client accepts it.

- **Extra certificate names need DNS first.** With `ENABLE_AUTOCONFIG` or
  `ENABLE_MTA_STS` on, the certificate should also cover
  `autoconfig.<domain>`, `autodiscover.<domain>` and `mta-sts.<domain>`. On a
  first install those records do not exist yet — this run prints them at the
  end — so any name that does not already resolve to this host is **skipped**
  from the request, with a warning naming it. That is deliberate: including an
  unresolvable name fails the entire certificate order, at renewal as well as
  at install. Create the CNAMEs, then re-run:

  ```bash
  ./deploy.sh --only 75-tls-dns --answers <file>
  ```

  You do not have to remember this. When the certificate is missing names that
  an enabled feature needs, the final verification says so and writes an
  **ACTION REQUIRED** block into `/root/mail-deploy-dns-extra.txt`, right next
  to the CNAME records you need to create — listing what the certificate does
  and does not cover, and the exact re-run command. It does not count as a
  failed check: nothing on the host is broken, the missing piece is DNS.

---

## 9. After the run — DNS & testing

The `99-verify` summary prints the exact records. In general, per mail domain:

```
A     mail            <public IP>
MX    @        10     mail.<domain>
TXT   @               "v=spf1 a mx ~all"
TXT   _dmarc          "v=DMARC1; p=quarantine; rua=mailto:<admin>"
TXT   default._domainkey   (see /root/mail-deploy-dkim-dns.txt)
PTR   <public IP> ->  mail.<domain>   (at your hosting provider)
```

Then:
1. Create a domain + mailbox in **PostfixAdmin** (`https://<fqdn>/postfixadmin`).
2. Log in to **Roundcube** (`https://<fqdn>/roundcube`) as that mailbox.
3. Send a test message in and confirm it lands in the Maildir and carries an
   `X-Spamd-Result` header (proof the milter scanned it — `BAYES_*` symbols
   only appear once Bayes has been trained past its minimum); change the
   password in Roundcube and confirm it still logs in.
4. Verify SPF/DKIM/DMARC with an external checker (e.g. mail-tester.com).

---

## 10. Verification & acceptance

The toolkit ships **static-verified**: `shellcheck` clean; every template renders
with zero leftover placeholders and passes its native linter (`postconf`,
`php -l`); a full `--dry-run` runs all modules with no errors.

**Full end-to-end acceptance must run on a throwaway VM or disposable host**
(never an existing mail server). Two runners exist:

- `ci/run-remote-acceptance.sh <user@host>` — copies the tree to a disposable
  remote box, deploys with an answers file and runs `ci/run-acceptance.sh`
  there. This is the path that has actually been exercised.
- `cd ci && vagrant up` (or `CI_BOX=almalinux/10 vagrant up`) — the local-VM
  variant, for hosts with a hypervisor.

The acceptance run asserts, end to end:

1. `postfix check`, `doveconf -n`, `rspamadm configtest`, and `postmap -q
   <primary-domain>` (queried against the rendered virtual-domains map) all pass.
2. Provision a test domain + mailbox in PostfixAdmin; confirm the mailbox's
   `maildir` is full-form (`domain/user@domain/`, i.e. `domain_in_mailbox=YES`).
3. Send a GTUBE message → rejected; send an EICAR attachment → ClamAV blocks it;
   send a clean message → delivered and tagged per the rspamd actions table.
4. `sudo -u apache /usr/local/sbin/qa-doveadm.sh users` lists users (**not**
   direct `doveadm` — the web user has no direct doveadm sudo rights).
5. The ilexa console: unauthenticated request → `401`; authenticated → every tab
   returns `200` with no PHP notices.
6. `qa-weekly-digest.php --dry-run` and `qa-blocked-stats.sh` produce sane JSON.
7. **Idempotency:** re-run the whole installer; every module reports "already
   done" and nothing is rewritten.
8. `DRY_RUN=1 /usr/local/sbin/load-otx.sh` builds a non-trivial ipset; `dig
   2.0.0.127.otx.rbl @127.0.0.1 -p 530` answers `127.0.0.2` (rbldnsd live).

How far each OS has actually been through this: **Ubuntu 24.04** has completed
the full remote acceptance run on a real disposable host (every module executed,
real mail sent and scanned); **EL9** is verified against a live production
deployment; **EL10** is repoquery-verified (real AlmaLinux 10 repo metadata)
but has never executed end-to-end; **Ubuntu 22.04/26.04** share the 24.04 code
path and are extrapolated. The README's verification-tier table is the summary
of the same facts.

---

## 11. Troubleshooting

- **"unsupported OS … supported: RHEL/AlmaLinux/Rocky 9 or 10, Ubuntu
  22.04/24.04/26.04 LTS"** — you're not on a supported OS/version (EL8 and
  Debian-proper profiles are not written).
- **"system updates in progress … waiting"** — normal on a freshly booted
  image: the distro's own first-boot update run holds the package lock, and
  the installer waits for it rather than corrupting it. If it exceeds the cap
  the message names the exact `systemctl stop …` command to reclaim the lock.
- **A module failed** — read `/var/log/ilexa-install.log`, fix the cause, then
  re-run `sudo ./deploy.sh --only <module> --answers answers.conf`. Completed
  modules skip themselves; to force a redo, delete
  `/var/lib/ilexa-install/state/<module>.done`.
- **Roundcube/PostfixAdmin download failed** — the module warns and
  continues; the app was skipped. Re-run that module once connectivity is back.
- **Mail delivered but invisible in webmail** — a mailbox `maildir` in the short
  form `domain/user/` instead of `domain/user@domain/`. `domain_in_mailbox=YES`
  prevents new ones; see the reference-box notes.
- **fts_xapian build failed** — the module warns and continues without full-text
  search; deploy proceeds. Install `dovecot-devel`/`xapian-core-devel` and re-run.
- **postscreen can't resolve `otx.rbl`** — ensure unbound is running and
  `127.0.0.1` is first in `/etc/resolv.conf` (module `75-tls-dns` sets this).

---

## 12. Security & secrets handling

- **No secret is ever written into the repo.** Configs that need credentials are
  rendered at deploy time from templates; the templates contain only
  `@@PLACEHOLDERS@@`.
- **Generated, per-run passwords.** Each DB user gets a fresh random password,
  recorded only to the root-only `/root/ilexa-install-credentials.txt`.
- **OTX key** is stored at `/etc/ilexa/secrets/otx_api_key` (0600) and read from there by the
  loader scripts — never embedded.
- **A repo-external secret checker** (`/root/mail-deploy-secretcheck.sh`, kept
  outside the repo on purpose) scans the working tree for live domains, IPs, the
  OTX key, and any DB password harvested from the live config, and must report
  CLEAN before every commit. Public releases add a second gate:
  `tools/export-public.sh` builds the published tree and deletes its own output
  if any audited pattern (key shapes, private-key blocks, internal material)
  appears in the result.
- **Least privilege:** MariaDB binds to localhost only; each app has its own DB
  user scoped to its own database; the Postfix SQL maps use a separate
  read-only user with column-level grants (it cannot read password hashes, and
  a leak of the group-readable map files grants no write access); Webmin can
  be source-IP allowlisted; port 25 is open to the world (it must be) but
  everything else can be geo/OTX-dropped.

---

## 13. Extended features

These are optional capability layers on top of the core stack. All are toggled
by answer keys and static-verified; each is one module (or a small extension of
an existing one).

| Feature | Answer keys | Default | Notes |
|---------|-------------|---------|-------|
| **MTA-STS / TLS-RPT / DANE** | `ENABLE_MTA_STS`, `MTA_STS_MODE`, `TLSRPT_RUA` | on / enforce | Publishes an MTA-STS policy on `mta-sts.<domain>` and generates every DNS record (policy TXT, TLS-RPT, `mta-sts` CNAME, and a DANE **TLSA `3 1 1`** for the MX) into `/root/mail-deploy-dns-extra.txt`. The cert requests `mta-sts.<domain>` as a SAN. |
| **IPv6** | `ENABLE_IPV6` | off | `inet_protocols=all` + `[::1]/128` in mynetworks; reminds you to set AAAA + IPv6 PTR. Note: the geoblock/OTX ipsets are IPv4-only, so v6 traffic bypasses them. |
| **Sieve + ManageSieve** | `ENABLE_SIEVE` | on | dovecot-pigeonhole, ManageSieve on **4190** (opened in firewalld), and the Roundcube `managesieve` plugin — users edit server-side filters from webmail, and they **execute at delivery** because delivery goes through Dovecot LMTP (with Postfix's own `virtual(8)` agent, sieve silently never ran — proven live and fixed 2026-08-21). |
| **Mailbox quotas** | `ENABLE_QUOTA` | on | Enforced at **SMTP time** (Postfix queries Dovecot's `quota-status` policy and rejects RCPT for over-quota mailboxes — pre-queue beats bouncing) and again at LMTP delivery. Limits come from the PostfixAdmin `quota` column; IMAP QUOTA reporting is on. |
| **fail2ban recidive** | (always on with fail2ban) | — | Week-long ban for IPs that repeatedly trip other jails. |
| **Prometheus metrics** | `ENABLE_METRICS`, `METRICS_SCRAPE_CIDR` | off | `node_exporter` bound to localhost (scrape via SSH tunnel) or, if a scrape CIDR is given, bound to `0.0.0.0:9100` with a firewalld rule opening 9100 **only** to that CIDR. |
| **Autoconfig / autodiscover** | `ENABLE_AUTOCONFIG` | on | Thunderbird autoconfig + Outlook autodiscover served from `autoconfig.<domain>` / `autodiscover.<domain>` (cert SANs added once the CNAMEs resolve — see §TLS) so mail clients self-configure. CNAMEs written to `mail-deploy-dns-extra.txt`. |
| **Spam/ham report addresses** | `ENABLE_REPORT_ADDRESSES` | on | Module `58-report-learn`. Users forward a mis-classified message **as an attachment** to `spam@`/`ham@` of their own domain. The handler (dedicated no-login `rspamreport` user) checks the sender is an internal domain, rate-limits, extracts the `message/rfc822` original, strips scanner-added headers, then: Bayes `learn_spam`/`learn_ham`, local-fuzzy add (spam) or del (ham), and — spam only — saves a copy into the reporter's own Spam folder (visible in the console's quarantine view) through a sudoers rule allowing exactly `doveadm save -u <user> -m Spam`. Reports never bounce; every outcome is syslogged. This is the main training path for POP3 users, whose clients delete server-side mail. An existing `spam@`/`ham@` mailbox or alias in a domain is left untouched (warned, not overwritten). The allowed-sender list (`/etc/rspamd-report/domains.txt`) is regenerated from the answers file on every run — add new domains there, not by hand. |
| **SIEM export** | `ENABLE_SIEM_EXPORT` | off | Module `66-siem-export` seeds the rsyslog forward config (Fail2Ban bans, Apache SSL-vhost errors i.e. console sign-in attempts, and the console's own audit trail → rsyslog local2-4). After install the console's **Rendszer → SIEM** card owns it entirely: collector host/port/protocol, optional TLS with a pasted CA certificate, and an automatic health check that alerts when forwarding wedges. Nothing leaves the server until a collector is configured there. |
| **Language signals (experimental)** | `ENABLE_HU_CLASSIFY`, `HU_CLASSIFY_REPORT_EMAIL` | off | Module `41-hu-classify`. The report email receives a fortnightly auto-review of the signals' measured performance. See the honest status below before enabling. |

#### Language signals — measured status (read this before enabling)

`41-hu-classify` adds four rspamd symbols — `HU_LANGUAGE`, `EN_LANGUAGE`
(fastText lid.176 language identification) and `HU_NATURALNESS`,
`EN_NATURALNESS` (character-trigram "is this coherent language or mangled
text" scores, one reference table per language, built offline from Wikipedia).
They are served by a small local Python service on `127.0.0.1:11336`.

**Every symbol carries score 0.0 and none of them is a candidate for a real
weight today.** That is a measured result, not caution. Against 13 days of
this project's own reference-host mail (77 genuinely distinct spam / 694
distinct ham, deduplicated by content hash before measuring):

| symbol | AUC | meaning |
|--------|-----|---------|
| `HU_LANGUAGE` | 0.418 | marginal, and *ham*-leaning |
| `HU_NATURALNESS` | 0.368 → 0.344 | real separation, still unusable as a standalone rule |
| `EN_LANGUAGE` | 0.519 | no information |
| `EN_NATURALNESS` | 0.473 → 0.644 | was noise as first shipped; the preprocessing fix below made it a real signal |

(Arrows show the effect of the preprocessing + recalibration fix described
below, re-measured against the deployed service.)

AUC 0.50 means "no information whatsoever"; distance from 0.50 in either
direction is what matters.

Two things worth understanding rather than re-deriving:

- **The language symbols are identity, not spam-ness.** On a Hungarian mail
  server "this message is Hungarian" is not evidence of spam — if anything the
  reverse, which is what the sub-0.5 AUC shows. Their plausible future is as
  *conditioning* inputs that gate language-specific rules, not as scores.
- **`*_NATURALNESS` only fires on obfuscated text**, and most spam is ordinary
  coherent prose. At a 0.3 threshold it flags 13% of spam but 17% of ham —
  actively anti-predictive; at 0.5 it is 68% of spam against 44% of ham. No
  threshold yields a usable rule.

The signals ship anyway because they are cheap (~30 MB RSS, sub-millisecond
inference, fail-open), because the measurement tooling to re-check them lives
alongside them, and because a documented negative result is worth more than an
untested idea. Re-check with
`assets/hu-classify/measure_signal_value.py` (imports the live scoring code,
deduplicates before computing anything, and persists only aggregates — message
text is scored in memory and discarded).

**Do not "fix" this by collecting a bigger Wikipedia corpus.** Corpus size was
never the constraint — the models measure coherence perfectly well; coherence
just does not predict spam here. Likewise, **recalibrating the sigmoid cannot
change any AUC**, because the sigmoid is monotonic and AUC is rank-based;
calibration only fixes what a score *means*.

##### What preprocessing changed (and what it didn't)

The one lever that *did* move discrimination was the text fed **in**. Raw
extracted mail is not prose — it is thick with URLs, tracking ids, base64
fragments and punctuation runs, so character trigrams over it partly measure
artifact density rather than "is the human-written text coherent". Stripping
that material before scoring (`strip_non_prose()` in the service) was measured
across two independent ham samples:

| variant | HU_NATURALNESS | EN_NATURALNESS |
|---------|---------------|----------------|
| raw | 0.421 | 0.535 |
| strip URLs/emails | **0.334** | 0.477 |
| + strip long tokens | 0.383 | 0.668 |
| + strip punct runs/digits (shipped) | 0.388 | **0.686** |

The shipped preprocessing is the last row for both languages — a single
consistent rule rather than a per-language variant tuned on 77 spam examples,
since the HU difference between rows is inside one standard error at that
sample size.

Calibration was then re-fit against the **real-mail** distribution after
stripping (HU `midpoint=-11.4/scale=1.3`, EN `-14.7/1.5`, replacing the
original `-14.0/2.3` fit against tidy sample sentences). Under the old
constants 44% of *legitimate* mail scored below 0.5; now ham centres near 0.5
in both languages, so a published score means what the docs say.

Re-measured against the **deployed** service afterwards (not just the
experiment harness), which is the number that counts:

| symbol | as first shipped | after preprocessing + recalibration |
|--------|-----------------|-------------------------------------|
| `HU_LANGUAGE` | 0.418 | 0.418 (unchanged — fastText path, not affected) |
| `HU_NATURALNESS` | 0.368 | **0.344** |
| `EN_LANGUAGE` | 0.519 | 0.513 (unchanged) |
| `EN_NATURALNESS` | 0.473 | **0.644** |

**They still ship at weight 0.0**, including EN_NATURALNESS at 0.644. Two
reasons that number should not be turned into a score without local
measurement: n=77 distinct spam is thin, and post-stripping EN_NATURALNESS
substantially proxies "reads as fluent English" — which on a Hungarian server
correlates with spam but would penalise legitimate English correspondence, a
false-positive risk AUC alone does not expose. The threshold table shows the
same thing directly: `HU_NATURALNESS < 0.3` now covers 55% of spam but still
32% of ham, so it remains a contributing feature at best, never a standalone
rule. `assets/hu-classify/recalibrate.py` reproduces the whole table on any host.

##### HU_SPAM — a trained model, still weight 0.0

`HU_SPAM` began as a fixed placeholder because the live archive held only 77
genuinely distinct spam messages after de-duplication, and honest retraining
on those scored 42.3% — worse than always guessing ham (90.9%).

The retired MailScanner archive supplied the missing data. Retrained balanced
on 1194 + 1194 de-duplicated messages: **held-out accuracy 81.4% against a
50% baseline** (precision 90.3%, recall 70.3%), and AUC ~0.88 on live scoring
— by far the strongest of these signals.

**It is still weight 0.0, deliberately.** Projected onto a realistic ~9%-spam
traffic mix, no threshold reaches even 60% precision: at best ~57%, which
would mis-flag roughly 46 legitimate messages per 1000. A balanced-set
accuracy figure always flatters a classifier facing a skewed base rate —
judge it by the projection, not the headline. It is a useful contributing
feature, never a standalone rule.

Two implementation notes worth keeping:

- **The trained table is NOT shipped.** It is learned from one host's own
  mail and its vocabulary is meaningless elsewhere; a host with no model file
  falls back to the fixed placeholder. Train one with
  `assets/hu-classify/mw_train_spam_router.py` (streams the corpus, persists
  nothing but the model).
- **Temperature scaling is required, not cosmetic.** Naive Bayes sums one
  log-odds term per word and is wildly overconfident: raw, 86% of real
  messages scored *exactly* 0.0 or 1.0. That destroys the shadow-mode
  measurement, since ties make AUC meaningless. Dividing the evidence by a
  temperature fitted to the observed spread (~287 log-odds units p05..p95)
  restores gradation to 95% of messages while changing no ranking. The
  emitted value is a ranking score in (0,1), **not** a calibrated probability.

**Not "extended":** the content filter (rspamd, module `40-rspamd`), the ilexa
console (`55-ilexa`), the opt-in mail archive (`57-archive`) and the opt-in
reputation-feed layer (`72-feeds`) are core parts of the stack, documented in
§5's "ilexa console", "Mail archive" and "Feed sources & breach check" tables —
not toggles in this extended-features list.

### CI / acceptance (`ci/`)

Because the toolkit is authoring-only against production, real end-to-end testing
runs in a throwaway VM. `cd ci && vagrant up` boots AlmaLinux 9 (or
`CI_BOX=almalinux/10 vagrant up` for AlmaLinux 10), deploys with
`ci/answers.ci.conf`, and runs `ci/run-acceptance.sh`: deploy → service/config
health → provision a domain+mailbox (full-form maildir) → GTUBE spam injection →
DKIM/credentials outputs → a second run to assert idempotency. See `ci/README.md`.
