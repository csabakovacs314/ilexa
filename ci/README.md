# CI / acceptance harness

End-to-end validation for mail-deploy on a **disposable AlmaLinux 9 or 10 VM**.
This is the only place `deploy.sh` should actually execute — everything else in
this repo is authoring-only (the modules overwrite `/etc/postfix`, `/etc/dovecot`,
DBs, …).

## Run

```bash
cd ci
vagrant up                        # boots AlmaLinux 9 (default), deploys, runs the suite
CI_BOX=almalinux/10 vagrant up     # same, on AlmaLinux 10
vagrant destroy -f                 # tear down
```

Or, inside any throwaway EL9/EL10 VM you already have:

```bash
sudo bash /path/to/mail-deploy/ci/run-acceptance.sh
```

## What it checks (`run-acceptance.sh`)

1. **First deploy** completes (`deploy.sh --answers ci/answers.ci.conf`).
2. **Health** — core services active; `postfix check`; `doveconf -n`; ports
   25/465/587/143/993/4190 listening.
3. **Provisioning** — creates a domain + mailbox via `postfixadmin-cli` and
   asserts the maildir is full-form `domain/user@domain/`.
4. **Filtering** — injects a GTUBE message (spam) via swaks.
5. **Threat-intel** — `DRY_RUN=1 load-otx.sh` builds a set (if OTX configured).
6. **Outputs** — DKIM records generated; credentials file is `0600`.
7. **Idempotency** — a second run reports (nearly) all modules "already done"
   and changes nothing.

`answers.ci.conf` uses lab-safe settings (self-signed TLS; OTX / fts_xapian /
MTA-STS / autoconfig disabled since they need DNS or an API key). It refuses to
run if `/etc/ilexa/secrets/otx_api_key` exists (a guard against running on a real host).
