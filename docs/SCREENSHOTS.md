# Screenshots

Every image on this page was produced against **entirely synthetic data**. The
console screens come from a sandboxed copy of the application with its own
database and stub system helpers, and the installer screens were rendered by
loading the wizard's dialog library alone — no install was run. Domains use the
reserved `.example` namespace and addresses come from the documentation ranges,
so nothing here corresponds to a real host, mailbox or person.

## The ilexa console

### Overview

Archived volume, rspamd scan totals and Bayes training, host health, and a 24-hour spam/ham histogram.

![Overview](screenshots/console/01-overview.png)

### Reported spam

What users flagged, per mailbox — bulk release and delete, with sender-domain and connecting-IP reputation per row.

![Reported spam](screenshots/console/02-reported-spam.png)

### Archive

Every message in and out, kept 30 days, filterable, each one teachable back to rspamd as spam or ham.

![Archive](screenshots/console/03-archive.png)

### Blocklist

SMTP-level rejection by address, domain, wildcard pattern or IP, each rule stamped with who added it.

![Blocklist](screenshots/console/04-blocklist.png)

### Allowlist

The mirror of the blocklist: senders that must never be scored as spam.

![Allowlist](screenshots/console/05-allowlist.png)

### Indicators

Indicators from quarantined mail, campaigns and bulk import, scored across the enabled reputation services.

![Indicators](screenshots/console/06-ioc.png)

### Campaigns

Clusters of similar-subject mail from one sender domain, promotable to a blocking indicator in one click.

![Campaigns](screenshots/console/07-campaigns.png)

### Admin

Interface language, the data-protection policy governing who may read message content, sign-in alerts, SIEM export.

![Admin](screenshots/console/08-admin.png)

### System

Updates, rspamd modules and Bayes, feed sources, live DNSBLs, ClamAV, Postfix and full-text indexes.

![System](screenshots/console/09-system.png)

### Audit log

Spam actions and sign-in history with CSV export.

![Audit log](screenshots/console/10-audit.png)

## The installer wizard

### Start screen

States what will be built and what will be overwritten. Nothing has changed at this point.

![Start screen](screenshots/installer/01-welcome.png)

### Host check

OS, memory, disk, hostname and IP of the box you are actually on, before anything is touched.

![Host check](screenshots/installer/02-hostcheck.png)

### Mail FQDN

The MX target and TLS common name. Placeholder and dotless values are refused.

![Mail FQDN](screenshots/installer/03-fqdn.png)

### Timezone

Drives the clock, mail-log timestamps and every time the console displays.

![Timezone](screenshots/installer/04-timezone.png)

### TLS mode

Let's Encrypt, your own certificate, or a self-signed lab cert.

![TLS mode](screenshots/installer/05-tls.png)

### Archive briefing

The one decision with a legal dimension gets a full screen before the question is asked.

![Archive briefing](screenshots/installer/06-archive.png)

### Password expiry

Single-choice list with the default pre-selected.

![Password expiry](screenshots/installer/07-pwexpiry.png)

### Optional extras

Multi-select. Items that cannot be delivered on the detected platform are not offered.

![Optional extras](screenshots/installer/08-extras.png)

### Review

Every answer on one screen before a single file is written. Abort here is a clean exit.

![Review](screenshots/installer/09-review.png)

### Install progress

One gauge for the whole package phase, labelled per module rather than per package.

![Install progress](screenshots/installer/10-gauge.png)

### Command line

The same install runs unattended from an answers file; --dry-run changes nothing.

![Command line](screenshots/installer/11-usage.png)
