#!/usr/bin/env bash
# 82-metrics — optional Prometheus node_exporter. Bound to localhost by default
# (scrape over an SSH tunnel); if METRICS_SCRAPE_CIDR is set, it binds all
# interfaces and firewalld opens 9100 ONLY to that CIDR.
source "$MD_ROOT/lib/common.sh"
step_guard 82-metrics || exit 0

if [ "$ENABLE_METRICS" != yes ]; then
  log_info "metrics disabled — skipping"; mark_done 82-metrics; exit 0
fi

# Package AND unit/binary name all differ on Debian -- confirmed by checking
# the real .deb's shipped file list, not assumed from the package name alone:
# apt's prometheus-node-exporter ships /lib/systemd/system/
# prometheus-node-exporter.service and /usr/bin/prometheus-node-exporter,
# neither of which is called "node_exporter" the way EPEL's package is.
if [ "$PKG_MGR" = apt ]; then
  pkg_try prometheus-node-exporter || {
    log_warn "node_exporter package not found — skipping metrics"; mark_done 82-metrics; exit 0; }
  ne_svc=prometheus-node-exporter
  ne_bin=/usr/bin/prometheus-node-exporter
else
  # EPEL package name; fall back gracefully if unavailable.
  pkg_try golang-github-prometheus-node-exporter || pkg_try node_exporter || {
    log_warn "node_exporter package not found — skipping metrics"; mark_done 82-metrics; exit 0; }
  ne_svc=node_exporter
  ne_bin=/usr/bin/node_exporter
fi

if [ -n "$METRICS_SCRAPE_CIDR" ]; then bind=0.0.0.0; else bind=127.0.0.1; fi
write_file "/etc/systemd/system/${ne_svc}.service.d/mail-deploy.conf" 644 <<EOF
[Service]
ExecStart=
ExecStart=${ne_bin} --web.listen-address=${bind}:9100
EOF

if [ "$DRY_RUN" != 1 ]; then
  systemctl daemon-reload
  # open 9100 only to the scrape source (default zone blocks it otherwise)
  if [ -n "$METRICS_SCRAPE_CIDR" ]; then
    firewall-cmd --permanent --zone=public \
      --add-rich-rule="rule family=ipv4 source address=${METRICS_SCRAPE_CIDR} port port=9100 protocol=tcp accept" >/dev/null 2>&1 \
      && firewall-cmd --reload >/dev/null 2>&1 || log_warn "could not add firewalld rule for 9100"
    log_info "node_exporter on ${bind}:9100, scrape allowed from $METRICS_SCRAPE_CIDR"
  else
    log_info "node_exporter on 127.0.0.1:9100 (scrape via SSH tunnel)"
  fi
fi
svc_try "$ne_svc" 2>/dev/null || log_warn "$ne_svc unit not started (check package)"

mark_done 82-metrics
log_info "prometheus node_exporter configured"
