# Architecture Overview

## Network Topology

```
                         ┌─────────────────────────────────────────────────┐
                         │              INTERNET                           │
                         │                                                 │
    ┌────────────────────┤                    │                            │
    │                    │                    │                            │
    │  randazzo.ar       │  0b.ar             │  i.ar                     │
    │  randazzo.com.ar   │                    │                            │
    │  (→redirect)       │                    │                            │
    │                    │                    │                            │
    ▼                    ▼                    ▼                            │
┌──────────────┐  ┌──────────────┐  ┌──────────────┐                     │
│  randazzo-ar  │  │    ob-ar     │  │    i-ar      │                     │
│  VPS 2c/4GB   │  │  VPS 16c/16G │  │ 16c/64GB     │                     │
│  Proxy Hub    │  │  AI Play     │  │ Ollama       │                     │
│  Caddy + TLS  │  │  Docker       │  │ Static page  │                     │
│  CF Tunnel    │  │  SSH for AI  │  │              │                     │
│  WG: 10.66.0.1│  │  WG:10.66.0.2│  │ WG:10.66.0.3│                     │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘                     │
       │                  │                  │                              │
       │   WireGuard      │   WireGuard      │   WireGuard                  │
       │   (hub)          │   (spoke→hub)    │   (spoke→hub)                │
       │                  │                  │                              │
       ▼                  ▼                  ▼                              │
   ════════════════════════════════════════════════════════════════        │
   ║          WIREGUARD MESH — 10.66.0.0/16                        ║        │
   ║          All peers route through hub (randazzo-ar)            ║        │
   ════════════════════════════════════════════════════════════════        │
       │                                              │                     │
       ▼                                              ▼                     │
┌──────────────┐                              ┌──────────────┐             │
│   laptop     │                              │  server-pc   │             │
│  Intel Ultra │                              │ 12c/96GB     │             │
│  NPU (future)│                              │ RTX 3080 10GB│             │
│  WG:10.66.0.4│                              │ Ollama GPU   │             │
└──────────────┘                              │ WG:10.66.0.5 │             │
                                               └──────────────┘             │
                                                                            │
                         ┌─────────────────────────────────────────────────┘
                         │
                    ┌────────┐
                    │Fallback│  randazzo.net.ar → Cloudflare Tunnel
                    │  VPN   │  (if WireGuard ports blocked)
                    └────────┘
```

## Server Roles

### 1. randazzo-ar — Proxy Hub (VPS 2c/4GB)
- **Domain:** randazzo.ar, randazzo.com.ar (redirect), i.ar, 0b.ar
- **Services:** Caddy reverse proxy with automatic TLS, Cloudflare Tunnel (fallback)
- **WireGuard:** Hub node — all traffic between peers routes through here
- **Public ports:** 80 (HTTP), 443 (HTTPS), 51820/udp (WireGuard)
- **Purpose:** The only server exposed to the internet. Everything else is behind it.

### 2. ob-ar — AI Playground (VPS 16c/16GB)
- **Domain:** 0b.ar (proxied through randazzo-ar)
- **Services:** Docker, SSH access for AI agent
- **WireGuard:** Spoke — connects to hub
- **Public ports:** 22 (SSH, key-only), 51820/udp (WireGuard)
- **Purpose:** Sandboxed environment where AI agents can run code, spin up containers, experiment. They get SSH access with docker privileges but nothing else.

### 3. i-ar — Ollama + Static Page (Dedicated 16c/64GB)
- **Domain:** i.ar (proxied through randazzo-ar)
- **Services:** Ollama (CPU-only, 64GB RAM for large models), static web page for the tool
- **WireGuard:** Spoke — connects to hub
- **Public ports:** 51820/udp (WireGuard only — Ollama not exposed)
- **Purpose:** Centralized AI inference. Ollama listens only on WireGuard IP (10.66.0.3:11434).

### 4. laptop — Personal Laptop (Intel Core Ultra, NPU)
- **No domain, no public exposure**
- **WireGuard:** Spoke — connects to hub
- **Future:** Continuous NPU agent
- **Purpose:** Mobile access point into the network

### 5. server-pc — Local GPU Server (12c/96GB, RTX 3080 10GB)
- **No domain, no public exposure**
- **Services:** Ollama with GPU offloading, Docker
- **WireGuard:** Spoke — connects to hub
- **Purpose:** Local high-performance inference. Can run fast small models entirely on GPU, or split large models across GPU+RAM.

## Security Model

1. **Single entry point:** Only randazzo-ar has public web ports (80/443). All other services are WireGuard-only.
2. **TLS everywhere:** Caddy handles Let's Encrypt automatically for all domains.
3. **No exposed Ollama:** Ollama binds to WireGuard IP only. Access requires VPN.
4. **Key-only SSH:** Password authentication disabled on all hosts. Fail2ban active.
5. **Firewalld:** Every host runs firewalld — default deny incoming, allow SSH + WireGuard only.
6. **AI agent isolation:** On ob-ar, the `ai-agent` user has docker access but limited sudo. Process limits prevent runaway.
7. **Cloudflare fallback:** If WireGuard UDP is blocked (restrictive networks), Cloudflare Tunnel on randazzo.net.ar provides an alternative path.

## Recovery Procedure

See [RECOVERY.md](RECOVERY.md) for full disaster recovery steps.
