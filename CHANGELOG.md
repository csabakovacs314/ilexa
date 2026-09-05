# Changelog

Console releases, newest first. Generated from `RELEASES.json` by
`tools/gen-changelog.py` -- edit the notes there, not here.

## 1.0.24 (Duna) — 2026-09-05
`fix`

Housekeeping release: the app bundle no longer carries internal development scratch, which was half its file count and was unpacked on every host. No credentials were ever exposed. Includes 1.0.23s English-default fix.

## 1.0.23 (Duna) — 2026-09-05
`fix`

A console that has never had a language chosen now starts in English instead of Hungarian; hosts with an explicit choice already on disk are unaffected. This release also carries the installer work behind AlmaLinux 10 support — 12 fixes, and a wizard that now completes end-to-end on EL10.

## 1.0.22 (Duna) — 2026-09-01
`feature`

The explanation header on the Archive, Reported spam, Blocklist and Allowlist pages is now collapsible and closed by default, matching the other pages. On an English console, 49 strings that still rendered in Hungarian are fixed -- including the column headers shown on narrow screens, the audit CSV export header, and the sign-in risk reasons, which had no English at all.

## 1.0.21 (Duna) — 2026-09-01
`feature`

The long explanation at the top of the IOC and Campaigns pages is now collapsible and closed by default, matching the sections on the System and Admin pages. Both pages now open on their actual content, with the explanation still one click away.

## 1.0.20 (Duna) — 2026-09-01
`feature`

The Admin page cards are now collapsible, matching the System page: everything is closed on a fresh visit, and saving a setting reopens the card you were working in instead of dumping you at the top.

## 1.0.19 (Duna) — 2026-08-31
`fix`

Fixes the DNSBL count on the "Blocked mail" card: warn-only (warn_if_reject) events were counted as blocks, substantially inflating the 7-day DNSBL figure. The per-list DNSBL breakdown is removed -- the log names whichever list replied first, not which ones actually matched.

## 1.0.18 (Duna) — 2026-08-27
`security` · **requires a full installer run**

Email exposure: multi-provider (XposedOrNot+LeakCheck+HudsonRock) hourly mailbox sweep on a shared on-disk API budget; spam@/ham@ now require an authenticated sender that is a real mailbox (Bayes-poisoning path closed); switchable postgrey greylisting; dashboard per-source markers. The report gate, postgrey and the hourly cron need the installer (--only 20-postfix 21-greylist 58-report-learn). Enable the sweep providers on the System tab.

## 1.0.14 (Duna) — 2026-08-27
`fix`

A security release now also sends an email notice, not just a red tile.

## 1.0.13 (Duna) — 2026-08-26
`fix`

The release tarball source can be overridden for testing.

## 1.0.12 (Duna) — 2026-08-26
`fix`

The Blocked mail card now counts virus rejections again.

## 1.0.11 (Duna) — 2026-08-26
`feature`

The Blocked mail and Data-breach cards are now collapsed by default.

## 1.0.10 (Duna) — 2026-08-26
`fix`

The version row now acts in place: check/install no longer jump to the System page, and checking no longer blanks the version state.

## 1.0.9 (Duna) — 2026-08-26
`feature`

The ilexa version row is now clickable — check and install from it; the separate update card is gone.

## 1.0.8 (Duna) — 2026-08-26
`feature`

The installed ilexa version now appears in the System-info panel, colour-coded.

## 1.0.7 (Duna) — 2026-08-25
`fix`

More reliable updates: the sqlite snapshot waits out concurrent writes, and the version tile is correct immediately after an update.

## 1.0.6 (Duna) — 2026-08-25
`fix`

Automatically retry transient CDN failures when fetching and verifying the release manifest.

## 1.0.5 (Duna) — 2026-08-25
`fix`

Fix the version tile going blank after an update; failed attempts no longer report a rollback that never happened.

## 1.0.4 (Duna) — 2026-08-25
`fix`

Fix the version status tile going blank right after a successful update.

## 1.0.3 (Duna) — 2026-08-25
`fix`

Fix audit-log duplication when applying an update (update-run.json ownership).

## 1.0.2 (Duna) — 2026-08-25
`fix`

Fix: three bugs found in the update-apply pipeline's own first rehearsal, resolved.

## 1.0.1 (Duna) — 2026-08-25
`fix`

Fix: check-views.php now catches diagnostics from bootstrap.php's own top-level code too.

## 1.0.0 (Duna) — 2026-08-25
`feature`

Baseline release: version display, update checking, database migration framework.

<!-- generated-from-releases-json: do not edit above this line -->

# Installer changes

The installer is not separately versioned — it ships with whatever console
release it carries — so notable changes are dated here. Hand-written; the
generator never touches anything below the marker above.

## 2026-09-05 — AlmaLinux 10 support

First real EL10 install (AlmaLinux 10.1). Eight fixes; the platform is now
real-host-verified, with one caveat that needs an operator decision.

- **rspamd cannot be GPG-verified on EL10.** Upstream's key self-signs with
  SHA-1, `rpm-sequoia` rejects it, and EL10 ships no `SHA1.pmod`. The installer
  now fails with that explanation instead of a bare dnf error; the new
  `RSPAMD_ALLOW_UNSIGNED=yes` answer opts in, disabling `gpgcheck` for the
  rspamd repo only and reporting it in the review summary.
- **Postfix lookup tables follow the platform.** `postfix_map_type()` asks
  `postconf -m`, so EL10 gets `lmdb:` where EL9 gets `hash:`. Berkeley DB is
  gone from EL10 and no `postfix-hash` package exists.
- **`opendkim-genkey` moved to `opendkim-tools`** — installed by capability
  check. Without it no DKIM keys were generated at all.
- **DKIM tables get explicit ownership and mode.** EL10's root umask of 027
  made them unreadable by the opendkim user; EL9's 022 had made them work by
  accident.
- **`php-imap` is optional now** (`pkg_install_optional()`). It does not exist
  on EL10 and one missing name failed the whole transaction.
- **PostfixAdmin 4.0.1 → 4.0.5.** Composer 2.10 blocks packages carrying
  security advisories; 4.0.1 pinned `spomky-labs/otphp ^10.0`, all of which are
  flagged, so `vendor/` was never built and everything downstream of it failed.
  Not EL10-specific — any platform hits this once Composer ≥2.10 arrives.
- **fail2ban's `recidive` jail** reads a log that does not exist on a fresh
  host; it is now pre-created, since fail2ban refuses to start without it.
- **`50-web` logs composer and `upgrade.php` failures** instead of discarding
  them.

## 2026-09-04 — wizard by default

- `install.sh` with no `--fqdn` now hands over to the interactive wizard
  instead of installing unattended from a generated answers file. `--fqdn`
  keeps the old behaviour exactly; `--wizard` forces the interactive path.
- `save_answers()` quotes values. An unquoted `GEOBLOCK_COUNTRIES="ru cn br kr"`
  came back as `ru` on re-read and executed the rest as a command.
- `deploy.sh --help` no longer prints two lines of the script's own source.
- 21 screenshots added under `docs/screenshots/`, indexed in
  `docs/SCREENSHOTS.md`.
