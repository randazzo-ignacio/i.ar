# node-exporter role

Installs Prometheus `node_exporter` as a systemd service on each host.
Exports hardware/OS metrics (CPU, memory, disk, network) on the host's
WireGuard IP. Prometheus on daftpunk scrapes these endpoints over the
mesh — no public exposure.

## Deployment

Runs on all hosts via `site.yml`. The `wg_ip` variable (defined in each
host's `host_vars`) determines the listen address.

## Architecture

```
Prometheus (daftpunk:9090)
    │
    ├── scrape → 10.66.0.1:9100 (rammstein)
    ├── scrape → 10.66.0.2:9100 (greenday)
    ├── scrape → 10.66.0.3:9100 (daftpunk)
    ├── scrape → 10.66.0.4:9100 (yoga)
    └── scrape → 10.66.0.5:9100 (sophon)
```

## Hardening

The systemd service runs with:
- `NoNewPrivileges=true`
- `ProtectSystem=strict`
- `ProtectHome=true`
- `PrivateTmp=true`
- `PrivateDevices=true`
- `ProtectKernelModules=true`
- `ProtectKernelTunables=true`