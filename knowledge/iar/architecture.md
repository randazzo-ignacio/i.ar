# i.ar Architecture

## What i.ar Is

i.ar is a self-modifying AI operating environment built in Emacs, running in a hardened Podman container, powered by local LLMs via Ollama. No cloud. No telemetry. No backdoors.

The project lives at `/root/i.ar/` and is a git repository. The Emacs configuration at `/root/i.ar/emacs.d/` is bind-mounted into the container at `/root/.emacs.d/`.

## Repository Layout

```
/root/i.ar/
  emacs.d/          -- Emacs configuration (bind-mounted to /root/.emacs.d)
    init.el          -- Entry point, loads all modules
    init.d/          -- Modular Emacs Lisp components (auto-discovered)
    metaconfig/      -- Central parameter configuration (bind-mounted)
      parameters.el  -- All tunable behavioral parameters
      gptel.el       -- Ollama backend configuration
  prompts/           -- Agent profiles and prompt templates (bind-mounted to agents.d)
    agents/          -- One subdirectory per agent (<name>/prompt.org)
    common/          -- Prompt templates shared across agents
    base_context.org -- Shared context inherited by all agents via #+INCLUDE
    HISTORY.log      -- Shared operational log for all agents
  infra/             -- Ansible infrastructure as code
    playbooks/       -- Site-wide and component-specific playbooks
    roles/           -- Ansible roles (base, caddy, wireguard, ollama, etc.)
    inventory/       -- Host inventory with group/host vars
    docs/            -- Infrastructure documentation (ARCHITECTURE.md, etc.)
  containers/        -- Podman container definitions
    images/emacboros/Containerfile -- Main container image
    scripts/preflight.sh -- Security audit script (runs before Emacs)
    build.sh         -- Container build script
  utils/             -- Utility scripts
    emacboros.sh     -- Container launch script (--knowledge flag for custom KB path)
    darwin-cycle.sh  -- Darwin autonomous cycle launcher
    darwin-loop.sh   -- Darwin loop wrapper
  knowledge/         -- Curated knowledge base (injectable via C-c k, mountable via --knowledge)
    linux/           -- Linux administration knowledge
    iar/             -- This project's self-documentation
    ignisp/          -- ignisp programming language knowledge
  metaconfig/        -- Duplicated metaconfig (may be consolidated)
  logs/              -- System logs
  workspace/         -- Working directory for agent outputs
```

## Container Architecture

The Emacs environment runs inside a Podman container built from `quay.io/fedora/fedora-minimal`.

### Container Hardening

- **Read-only root filesystem**: Overlay is read-only, only bind-mounted paths are writable
- **Capability dropping**: All capabilities dropped, only NET_RAW and NET_BIND_SERVICE added (for nmap, traceroute, binding to low ports)
- **Preflight audit**: `preflight.sh` runs before Emacs starts, checks for dangerous writable paths, capability leaks, and host mount surprises. Exits non-zero if any check fails.
- **Dangerous paths blocked**: `.git/hooks`, `docker.sock`, cron, systemd, ssh are checked for writability

### Bind Mounts

- `/root/i.ar` -> `/root/i.ar` (btrfs subvolume, the project repo)
- `/root/i.ar/emacs.d` -> `/root/.emacs.d` (Emacs configuration)
- `/root/i.ar/prompts` -> `/root/.emacs.d/agents.d` (agent profiles and prompt templates)
- `/root/i.ar/metaconfig` -> `/root/.emacs.d/metaconfig` (parameters)
- Knowledge directory -> `/root/.emacs.d/knowledge` (bind mount, path configurable via `--knowledge` flag, defaults to `i.ar/knowledge/`)

### Network

The container connects to Ollama via WireGuard mesh network:
- Ollama host: `10.66.0.5:11434` (server-pc, RTX 3080)
- Configurable via `EMACBOROS_OLLAMA_HOST` environment variable
- All traffic goes through WireGuard -- no direct internet exposure

## Network Topology

Five nodes connected via WireGuard mesh (10.66.0.0/16):

1. **randazzo-ar** (10.66.0.1) -- VPS proxy hub, Caddy + TLS, Cloudflare Tunnel fallback
2. **ob-ar** (10.66.0.2) -- VPS AI playground, Docker, SSH for AI agents
3. **i-ar** (10.66.0.3) -- Dedicated server, Ollama CPU-only, 64GB RAM
4. **laptop** (10.66.0.4) -- Personal laptop, future NPU agent
5. **server-pc** (10.66.0.5) -- Local GPU server, RTX 3080 10GB, Ollama GPU offloading

Only randazzo-ar has public web ports (80/443). All other services are WireGuard-only.

## Models

Configured in `metaconfig/gptel.el`:
- `glm-5.2:cloud` (default)
- `gpt-oss:120b`, `gpt-oss:20b`
- `mistral-medium-3.5:128b`
- `nemotron-3-super:120b`, `nemotron-3-ultra:cloud`
- `deepseek-v4-pro:cloud`
- `north-mini-code-1.0:q8_0`
- `granite4.1:8b-q8_0`

Ollama request params: temperature 0.7, top_p 0.90, num_ctx 1048576 (1M), num_predict 65536.

## Security Model

1. **Single entry point**: Only randzzo-ar has public web ports. Everything else is WireGuard-only.
2. **TLS everywhere**: Caddy handles Let's Encrypt automatically.
3. **No exposed Ollama**: Ollama binds to WireGuard IP only.
4. **Key-only SSH**: Password auth disabled, fail2ban active.
5. **Firewalld**: Every host runs firewalld -- default deny incoming.
6. **AI agent isolation**: Container with dropped capabilities, read-only rootfs, preflight audit.
7. **File guard**: Emacs-level protection of critical files (agent prompts, base context, history logs). Self-modification mode can relax protection for .el files but NEVER for agent prompts or shared context.