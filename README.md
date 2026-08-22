# ilexa-installer — interactive mail-server deployer for EL and Ubuntu

Stands up a hardened mail server (Postfix virtual domains, Dovecot, rspamd +
ClamAV, OpenDKIM/DMARC/SPF, PostfixAdmin, **Roundcube** webmail, the **ilexa**
mail-security console, Fail2Ban, firewalld geoblock, and an AlienVault OTX
threat-intel suite) on a fresh **AlmaLinux/Rocky/RHEL 9 or 10** or
**Ubuntu LTS** host — a guided run instead of weeks of hand-tuning. It
reproduces the feature set of a production-grade reference box from
**parameterized templates** (no live secrets are ever baked in).

The bundled **ilexa console** adds what a stock stack lacks: quarantine
management, a 30-day searchable mail archive, an IOC store with multi-service
reputation lookups (VirusTotal, URLhaus, OTX, ThreatFox, YARAify and more),
managed blocklist/reputation feeds with real enable/disable lifecycle,
role-based access, audit logging with failed-login tracking, and optional
SIEM export.

### Brand-impersonation guard

Deployments also get a **brand-impersonation guard** — an rspamd rule that
scores mail claiming a brand it does not send from. It exists because of a
failure mode reputation filtering handles poorly: phishing sent through a
*compromised legitimate account* passes SPF, DKIM, DMARC and IP reputation,
because those describe the server, not the human at the keyboard. A real
OTP-Bank/Magyar-Posta campaign arriving cleanly as ham from a hijacked
university mailbox is what prompted it.

The category is not new — commercial mail-security products all do brand
impersonation, and the matching techniques are public (see
[sublime-rules](https://github.com/sublime-security/sublime-rules), MIT). The
gap this fills is a self-hosted rspamd stack with an admin-editable brand
database, and Hungarian brands, which off-the-shelf brand lists omit
(MISP's `bank-website` warninglist, for instance, carries 2,226 bank domains
and not one `.hu`).

Five signals, all conditioned on the From-domain not being the brand's own:
display name (`BRAND_DN_SPOOF`), From localpart (`BRAND_ADDR_SPOOF`), Subject
(`BRAND_SUBJ_SPOOF`, or `BRAND_SUBJ_OBFUS` at three times the weight when the
brand is only readable after un-disguising it), and classic phishing wording
(`BRAND_LURE`) that scores **only** next to one of the others — "please verify
your account" is also what a genuine password reset says.

Matching folds case, accents, Cyrillic/Greek homoglyphs and lookalike digits
before allowing one edit of distance, so `0TP`, `ОТР`, `Micr0soft` and
`Magyar Pósta` all resolve to the brand they imitate — while ordinary-word
brand names (Visa, Apple, Booking) use whole-name-only variants so a travel
agency or a hotel confirmation stays clean.

Both halves are data, editable from the console (Rendszer → Márkavédelem) and
seeded here: 16 Hungarian + 30 international brands with their real sending
domains, and English + Hungarian lure phrases. **The rule is language-neutral
by construction — adding a language is a new key in `brand_lures.json`, not a
code change.** See `docs/GUIDE.md` (`ENABLE_HU_BRAND_GUARD`) for the details.

## Usage

```bash
sudo ./deploy.sh                      # interactive whiptail wizard
sudo ./deploy.sh --answers my.conf    # unattended (see answers.example.conf)
sudo ./deploy.sh --dry-run --answers my.conf   # log intended actions, change nothing
sudo ./deploy.sh --only 20-postfix    # run a single module (repeatable)
```

Copy `answers.example.conf`, edit it, and pass it with `--answers`. DB passwords
and the Roundcube `des_key` are auto-generated to `/root/ilexa-install-credentials.txt`
(0600); DKIM DNS records land in `/root/mail-deploy-dkim-dns.txt`.

**Greenfield only.** Do not run it against an existing mail server; the modules
overwrite `/etc/postfix`, `/etc/dovecot`, etc. with templated defaults.

## Layout

```
deploy.sh              entrypoint: preflight -> collect -> confirm -> run modules
lib/common.sh          logging, guards, idempotency markers, backup, render(), secrets
lib/tui.sh             whiptail wrappers (degrade gracefully when non-interactive)
lib/db.sh              MariaDB helpers (create/grant, import_schema, provision_app_db)
answers.example.conf   documented, secrets-free answer file
modules/NN-*.sh        idempotent stages, run in numeric order as subprocesses
templates/             *.tmpl with @@PLACEHOLDERS@@ (rendered by sed, NOT envsubst,
                       so native $postfix/$dovecot vars survive)
assets/ilexa-app.tar.gz  the ilexa mail-security console (PHP)
assets/ilexa/          root helpers + templates the ilexa console depends on
assets/otx/            the sanitized OTX threat-intel suite
assets/feeds/          reputation/blocklist feed loaders
ci/                    acceptance runner + answer files for disposable test VMs
```

## Design guarantees

- **Template, never copy live config.** Configs render from prompted values via
  `render()` (`@@KEY@@` -> `sed`); no site-specific values or secrets.
- **Idempotent & resumable.** Each module guards on a marker under
  `/var/lib/ilexa-install/state/` and backs up any file before overwrite.
- **Secure by default.** A hardening screen folds in security-review fixes
  (SSH key-only + sudo admin user, Webmin allowlist, kernel auto-reboot, SMTP
  tuning, parameterized backups). SELinux is off by default (documented TODO).
- **Lockout-safe SSH hardening.** Key-only is applied only when a public key is
  supplied and a key-seeded `mailadmin` sudo user exists first.

## Supported operating systems & verification tiers

| OS | Tier |
|---|---|
| AlmaLinux/Rocky/RHEL 9 | Verified against a live production host |
| Ubuntu 24.04 LTS | Real-host-verified: every module executed end-to-end on a live box, including real mail send/receive |
| AlmaLinux/Rocky/RHEL 10 | Repoquery-grade: validated against real AlmaLinux 10 repo metadata, never executed on an EL10 host |
| Ubuntu 22.04 / 26.04 LTS | Share the 24.04 code path (`os_profile_debian()`), extrapolated, not independently verified |

Every release is static-verified: `shellcheck` clean across all scripts, every
template renders with zero leftover placeholders, and rendered configs pass
their native linters (`postconf`, `php -l`). The end-to-end acceptance suite
(`ci/run-acceptance.sh`) executes a real deploy on a disposable VM and checks
real mail flow — see [docs/GUIDE.md §10](docs/GUIDE.md#10-verification--acceptance).

## Documentation

Full reference — prerequisites, every option, how it works internally,
module-by-module, recommendations, post-install DNS, troubleshooting, and the
acceptance checklist — is in **[docs/GUIDE.md](docs/GUIDE.md)**.

## Out of scope

Debian proper (only Ubuntu LTS derivatives); greenfield only (no data
migration); external DNS and PTR/rDNS are the operator's responsibility (the
tool prints the records to set).

## Security

This tool configures security-sensitive infrastructure. If you find a
vulnerability in the installer or the bundled console, please report it
privately to the maintainer (see commit email) rather than opening a public
issue.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE). The installer downloads and
configures third-party components (Postfix, Dovecot, rspamd, Roundcube,
PostfixAdmin, and others) which remain under their own licenses.
