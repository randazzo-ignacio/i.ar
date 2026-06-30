# Deployment Guide

## Phase 1: Preparation (Local Machine)

### 1.1 Install Ansible
```bash
# Fedora / AlmaLinux
sudo dnf install ansible

# macOS
brew install ansible

# pip (any OS)
pip3 install ansible
```

### 1.2 Generate SSH Key (if not existing)
```bash
ssh-keygen -t ed25519 -C "infrastructure-admin" -f ~/.ssh/id_ed25519
```

### 1.3 Clone This Repo
```bash
git clone <your-repo-url> infrastructure
cd infrastructure
```

### 1.4 Create Vault Password File
```bash
echo 'your-strong-vault-password' > .vault_pass
chmod 600 .vault_pass
```

### 1.5 Generate WireGuard Keys
```bash
./scripts/generate-wg-keys.sh
```
This creates `wg-keys/` with private/public keypairs for each host and a YAML snippet to paste into `vault.yml`.

### 1.6 Fill In Secrets
```bash
# Edit the vault file with generated keys + tokens
vim inventory/group_vars/vault.yml
# Replace all CHANGE_ME values:
#   - wg_private_keys (from wg-keys/vault-snippet.yml)
#   - wg_public_keys (from wg-keys/vault-snippet.yml)
#   - vault_cloudflare_api_token (from Cloudflare dashboard)
#   - cloudflare_tunnel_token (from Cloudflare Zero Trust)
#   - ai_agent_ssh_public_key (generate: ssh-keygen -t ed25519 -f ~/.ssh/ai_agent_key)
```

### 1.7 Encrypt the Vault
```bash
ansible-vault encrypt inventory/group_vars/vault.yml --vault-password-file .vault_pass
# Verify:
ansible-vault view inventory/group_vars/vault.yml --vault-password-file .vault_pass
```

### 1.8 Fill In IPs
```bash
# Edit inventory with your actual server IPs
vim inventory/hosts.yml
# Replace CHANGE_ME_PUBLIC_IP and CHANGE_ME_LOCAL_IP

# Also update host_vars
vim inventory/host_vars/randazzo-ar.yml
vim inventory/host_vars/ob-ar.yml
vim inventory/host_vars/i-ar.yml
vim inventory/host_vars/laptop.yml
vim inventory/host_vars/server-pc.yml
```

### 1.9 Set Caddy Email (for Let's Encrypt)
```bash
vim inventory/host_vars/randazzo-ar.yml
# Add: caddy_email: your-email@example.com
# Or set in group_vars/all.yml
```

---

## Phase 2: Initial Server Access

### 2.1 Copy SSH Key to New Servers
```bash
# For each cloud server (initial access — may require password)
ssh-copy-id root@<server-ip>
```

### 2.2 Verify SSH Works
```bash
ssh root@<randazzo-ar-ip> "hostname"
ssh root@<ob-ar-ip> "hostname"
ssh root@<i-ar-ip> "hostname"
```

---

## Phase 3: Deploy

### 3.1 Full Deployment
```bash
ansible-playbook playbooks/site.yml -i inventory/hosts.yml --vault-password-file .vault_pass
```

This runs in order:
1. **base** — hardening, updates, firewalld, fail2ban, sysctl, admin user
2. **wireguard** — mesh network setup
3. **caddy** — reverse proxy with TLS
4. **cloudflare-tunnel** — fallback VPN
5. **docker** — on ob-ar and server-pc
6. **ai-environment** — AI agent user, SSH key, limits
7. **ollama** — on i-ar and server-pc

### 3.2 Verify WireGuard
```bash
# From randazzo-ar, ping all peers:
ssh randazzo-ar 'ping -c3 10.66.0.2'  # ob-ar
ssh randazzo-ar 'ping -c3 10.66.0.3'  # i-ar
ssh randazzo-ar 'ping -c3 10.66.0.5'  # server-pc (if online)

# From ob-ar, ping through hub:
ssh ob-ar 'ping -c3 10.66.0.3'  # i-ar via hub
```

### 3.3 Verify Web Services
```bash
# Caddy should be serving:
curl -I https://randazzo.ar
curl -I https://randazzo.com.ar  # should redirect
curl -I https://i.ar
curl -I https://0b.ar
```

### 3.4 Verify Ollama
```bash
# Via WireGuard (from any peer):
ssh randazzo-ar 'curl http://10.66.0.3:11434/api/tags'  # i-ar
ssh randazzo-ar 'curl http://10.66.0.5:11434/api/tags'  # server-pc

# Models should be listed
```

### 3.5 Verify AI Playground
```bash
# SSH as ai-agent:
ssh ai-agent@<ob-ar-ip>
# Should have docker access:
docker ps
# Should have workspace:
ls ~/workspace/
```

---

## Phase 4: Local Machines

### 4.1 Laptop
```bash
# Ensure SSH key is on laptop
ssh-copy-id <user>@<laptop-ip>

# Run base + wireguard only:
ansible-playbook playbooks/base.yml -i inventory/hosts.yml --vault-password-file .vault_pass --limit laptop
```

### 4.2 Server-PC
```bash
# Ensure SSH key is on server-pc
ssh-copy-id <user>@<server-pc-ip>

# Run base + wireguard + docker + ollama:
ansible-playbook playbooks/base.yml -i inventory/hosts.yml --vault-password-file .vault_pass --limit server-pc
ansible-playbook playbooks/wireguard.yml -i inventory/hosts.yml --vault-password-file .vault_pass --limit server-pc
ansible-playbook playbooks/ollama.yml -i inventory/hosts.yml --vault-password-file .vault_pass --limit server-pc
```

---

## Phase 5: Cloudflare Tunnel (Fallback VPN)

### 5.1 Create Tunnel in Cloudflare
1. Go to Cloudflare Zero Trust → Tunnels → Create a tunnel
2. Name it `randazzo-fallback`
3. Copy the tunnel token
4. Add it to vault: `ansible-vault edit group_vars/vault.yml`
5. Set up a public hostname: `randazzo.net.ar` → `ssh://localhost:22`
6. Run: `ansible-playbook playbooks/cloudflare.yml --vault-password-file .vault_pass`

### 5.2 Test Fallback
```bash
# Install cloudflared locally
# Connect via tunnel:
cloudflared access ssh --hostname randazzo.net.ar
```

---

## Phase 6: Post-Deployment

### 6.1 Cleanup
```bash
# Remove generated key files (keys are now in vault)
rm -rf wg-keys/
```

### 6.2 Commit to Git
```bash
git add -A
git commit -m "Initial infrastructure setup"
git push
```

### 6.3 Save Backup
Store in password manager:
- Vault password
- SSH private key
- Cloudflare API token
- Cloudflare tunnel token
- Git credentials

### 6.4 Document Any Manual Changes
If you make manual changes to any server, update the Ansible playbooks to match.
The goal is: **if the playbooks are run on fresh servers, the result is identical.**