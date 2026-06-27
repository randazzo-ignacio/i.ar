# monitoring role

Deploys Prometheus + Grafana monitoring stack via podman-compose on
daftpunk (i.ar, 10.66.0.3). All services bind to the WireGuard IP only
— no public exposure.

## Components

| Service | Port | Purpose |
|---------|------|---------|
| Prometheus | 10.66.0.3:9090 | Metrics storage + querying + alert evaluation |
| Grafana | 10.66.0.3:3000 | Dashboards + visualization |

## Files

| File | Purpose |
|------|---------|
| `templates/compose.yml.j2` | Podman-compose stack definition |
| `templates/prometheus.yml.j2` | Prometheus scrape config (all 5 hosts) |
| `templates/alert_rules.yml.j2` | Alert rules (host down, high CPU/mem/disk, container down, WireGuard down) |
| `tasks/main.yml` | Creates dirs, deploys configs, starts stack, enables on boot |

## Architecture

```
                    WireGuard mesh (10.66.0.x)
                    ┌──────────────────────────┐
  node_exporter     │  node_exporter           │   node_exporter
  10.66.0.1:9100 ───┤  10.66.0.2:9100         ├── 10.66.0.4:9100
  (rammstein)       │  (greenday)             │   (yoga)
                    │                          │
  cAdvisor          │  cAdvisor               │   node_exporter
  10.66.0.2:8081 ───┤  10.66.0.3:8081        ├── 10.66.0.5:9100
                    │  (daftpunk)              │   (sophon)
                    │                          │
                    │  Prometheus + Grafana   │   cAdvisor
                    │  10.66.0.3:9090/3000    │   10.66.0.5:8081
                    └──────────────────────────┘
```

## Alerting

Alert rules cover:
- **Host down** (>2 min unreachable)
- **High CPU** (>80% for >5 min)
- **High memory** (>90% for >5 min)
- **Low disk space** (>90% for >10 min)
- **Container down** (>2 min)
- **WireGuard interface down** (>2 min)
- **High scrape latency** (>2s for >5 min)

Alerts are evaluated by Prometheus. To receive notifications, add an
Alertmanager service to the compose stack and configure notification
channels (email, webhook, etc.).

## Access

Grafana is accessible at `http://10.66.0.3:3000` over WireGuard.
To expose publicly, add a Caddyfile block for `grafana.i.ar` proxying
to `10.66.0.3:3000` on rammstein.