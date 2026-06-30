# Security Model

## Defense in Depth

```
┌─────────────────────────────────────────────────────┐
│                    INTERNET                           │
│                                                       │
│  Only ports: 80, 443 (Caddy), 51820/udp (WireGuard) │
│  Everything else: DENIED by firewalld                 │
└──────────────────────┬──────────────────────────────┘
                       │
          ┌────────────┴────────────┐
          │   randazzo-ar (Proxy)   │
          │   Caddy + TLS + firewalld│
          │   Fail2ban + SSH harden │
          │   CF Tunnel (fallback)  │
          └────────────┬────────────┘
                       │
           WireGuard (encrypted tunnel)
                       │
     ┌─────────────────┼─────────────────┐
     │                 │                 │
     ▼                 ▼                 ▼
┌─────────┐     ┌─────────┐      ┌──────────┐
│ ob-ar   │     │ i-ar    │      │ server-pc│
│firewalld│     │firewalld│      │firewalld │
│ Docker  │     │ Ollama  │      │ Ollama   │
│ AI user │     │ (WG IP  │      │ (WG IP   │
│ (lim.)  │     │  only)  │      │  only)   │
└─────────┘     └─────────┘      └──────────┘
```

## Security Layers

### Layer 1: Network (firewalld + WireGuard)
- **firewalld:** Default deny all incoming. Only SSH (22/tcp), WireGuard (51820/udp), and on the proxy: HTTP/HTTPS.
- **WireGuard:** All inter-server communication is encrypted. No service listens on a public interface except Caddy and SSH.
- **Ollama:** Binds to `10.66.0.x` (WireGuard IP) only. Not accessible without VPN.

### Layer 2: Host Hardening
- **SSH:** Key-only authentication. No passwords. Root login restricted to key-based.
- **Fail2ban:** 3 failed SSH attempts → 1 hour ban.
- **Sysctl:** SYN cookies, no redirects, kptr/dmesg restrictions.
- **Automatic updates:** Security patches applied automatically via dnf-automatic.
- **Admin user:** Non-root sudo user created on cloud servers.

### Layer 3: Application
- **Caddy:** Automatic TLS via Let's Encrypt. Security headers (HSTS, X-Frame-Options, etc.).
- **Ollama:** No authentication built-in — relies on network isolation (WireGuard only).
- **Docker:** AI agent has docker group access but limited sudo. Process/file limits set.

### Layer 4: AI Agent Isolation (ob-ar)
- **Separate user:** `ai-agent` with its own SSH key.
- **Limited sudo:** Only docker and docker-related systemctl commands.
- **Resource limits:** Max 1000 processes, 50GB file size.
- **No access to other servers:** WireGuard config only allows the agent's host to see the hub, not other peers (unless explicitly configured).

### Layer 5: Fallback VPN (Cloudflare Tunnel)
- **Purpose:** If WireGuard UDP is blocked (corporate networks, hotels), Cloudflare Tunnel provides TCP-based fallback through Cloudflare's network.
- **Domain:** randazzo.net.ar (delegated to Cloudflare).
- **Setup:** cloudflared runs as a service on randazzo-ar, creates an outbound tunnel to Cloudflare. No inbound ports needed.
- **Access:** Use `cloudflared access ssh --hostname randazzo.net.ar` as a ProxyCommand.

## Threat Model

| Threat                    | Mitigation                                      |
|---------------------------|------------------------------------------------|
| Server compromise         | firewalld + key-only SSH + fail2ban              |
| Network sniffing          | WireGuard encryption + TLS (Caddy)             |
| Ollama API abuse          | Binds to WG IP only — requires VPN             |
| AI agent runaway          | Resource limits + limited sudo + Docker isol.  |
| WG port blocked           | Cloudflare Tunnel fallback (randazzo.net.ar)   |
| Key compromise            | Ansible Vault encryption + rotation procedure  |
| DNS hijack                | Registrar-locked + Cloudflare DNS              |
| Provider outage           | Full IaC — rebuild from scratch in minutes     |
| Data loss                 | All config in Git. No persistent state needed. |

## Known Limitations

1. **Ollama has no authentication:** It relies entirely on network isolation. If WireGuard is compromised, Ollama is open. Consider adding a reverse proxy with auth in front of Ollama if this concerns you.

2. **AI agent has Docker access:** Docker root-equivalent in practice (can mount host filesystem). The resource limits are advisory, not enforced by cgroups. For stronger isolation, consider running the agent inside a Docker container itself or using Podman with SELinux.

3. **Single hub (randazzo-ar):** If the proxy/hub goes down, the WireGuard mesh breaks. Peers can't reach each other. This is acceptable for the current scale but would need a multi-hub design for larger deployments.

4. **No monitoring/alerting:** Currently no automated monitoring. Consider adding Prometheus + Grafana or Uptime Kuma as a future enhancement.

5. **No backup of runtime data:** The IaC covers configuration, not data. If ob-ar has AI-generated work in containers, it is not backed up. Consider adding a backup role for critical data.