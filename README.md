# Infrastructure as Code — Ansible

Complete, reproducible infrastructure for 3 cloud servers + 2 local machines,
unified by a WireGuard mesh network with Cloudflare Tunnel fallback.

**All servers run Fedora Server 44 or AlmaLinux 10.** The playbooks target
RHEL-family systems only — no Debian/Ubuntu or Arch Linux branches.

## Quick Start

```bash
# 1. Generate WireGuard keys (one-time)
./scripts/generate-wg-keys.sh

# 2. Create vault password file
echo 'your-vault-password' > .vault_pass
chmod 600 .vault_pass

# 3. Copy generated keys into vault.yml
#    The script generates a YAML snippet at wg-keys/vault-snippet.yml
#    Copy its contents into inventory/group_vars/vault.yml

# 4. Encrypt the vault file
ansible-vault encrypt inventory/group_vars/vault.yml --vault-password-file .vault_pass

# 5. Edit inventory with your actual IP addresses
vim inventory/hosts.yml

# 6. Run the full playbook
ansible-playbook playbooks/site.yml --vault-password-file .vault_pass

# Or run individual playbooks:
ansible-playbook playbooks/base.yml          --vault-password-file .vault_pass
ansible-playbook playbooks/wireguard.yml     --vault-password-file .vault_pass
ansible-playbook playbooks/proxy.yml         --vault-password-file .vault_pass
ansible-playbook playbooks/ai_playground.yml --vault-password-file .vault_pass
ansible-playbook playbooks/ollama.yml        --vault-password-file .vault_pass
ansible-playbook playbooks/cloudflare.yml    --vault-password-file .vault_pass
```

## Architecture Summary

| Host          | Domain         | WG IP       | Role                          |
|---------------|----------------|-------------|-------------------------------|
| rammstein     | randazzo.ar    | 10.66.0.1   | Proxy hub, Caddy, CF Tunnel   |
| greenday      | 0b.ar          | 10.66.0.2   | AI playground, Docker          |
| daftpunk      | i.ar           | 10.66.0.3   | Ollama, emacboros static page |
| yoga          | (local)        | 10.66.0.4   | Future NPU agent              |
| sophon        | (local)        | 10.66.0.5   | GPU Ollama, local services     |

## Variable Hierarchy (DRY)

Variables are defined in a layered hierarchy — each layer overrides the one above:

| Layer | File | Purpose |
|-------|------|---------|
| 1. Role defaults | `roles/<name>/defaults/main.yml` | Safe defaults for standalone role use |
| 2. Group vars (all) | `inventory/group_vars/all.yml` | Global settings: packages, domains, WG, SSH |
| 3. Group vars (group) | `inventory/group_vars/<group>.yml` | Per-group settings (cloud, local) |
| 4. Host vars | `inventory/host_vars/<host>.yml` | Per-host settings: WG IP, enabled services |
| 5. Vault | `inventory/group_vars/vault.yml` | Secrets (encrypted) |

**Rule:** Define a variable at the *highest* layer where it is constant.
Only push it down to host_vars when it varies per host.

## Inventory Groups

The inventory uses functional groups so playbooks target by *role*, not hostname:

- `cloud` — all VPS hosts (get admin user, SSH key)
- `local` — all local machines (get personal user)
- `proxy` — hosts running Caddy + CF Tunnel (randazzo-ar)
- `ai_playground` — hosts running Docker + AI agent (ob-ar)
- `ollama_hosts` — hosts running Ollama (i-ar, server-pc)

Hosts can belong to multiple groups. Adding a new host to a group
automatically includes it in the relevant playbooks.

See `docs/` for full documentation.