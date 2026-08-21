#!/usr/bin/env python3
# Read IP/CIDR lines on stdin; emit only PUBLIC ones (drop private/loopback/link-local/
# multicast/reserved/unspecified) so IP-reputation feeds never score internal or local mail.
import sys, ipaddress
# Explicit non-public supernets — an `overlaps` test catches broad blocks (e.g. 224.0.0.0/3,
# 100.64.0.0/10) that the per-category flags miss because they span multiple categories.
RESERVED = [ipaddress.ip_network(n) for n in (
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
    "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16",
    "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/3",
)]
for line in sys.stdin:
    s = line.strip()
    if not s:
        continue
    try:
        net = ipaddress.ip_network(s, strict=False)
    except ValueError:
        continue
    if net.version != 4:
        continue
    if any(net.overlaps(r) for r in RESERVED):
        continue
    print(str(net.network_address) if net.prefixlen == net.max_prefixlen else net.with_prefixlen)
