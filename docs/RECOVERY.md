# Disaster Recovery

## Scenario 1: Full Rebuild (all servers lost)

### Prerequisites
- Ansible installed on your local machine
- SSH private key (`~/.ssh/id_ed25519`)
- Vault password (`.vault_pass`)
- Git clone of this infrastructure repo
- Access to your domain registrar (to point DNS to new IPs)
- Access to Cloudflare dashboard (for tunnel token)

### Steps

1. **Provision new servers** at your provider(s). Note the new public IPs.

2. **Update inventory** with new IPs:
   ```bash
   vim inventory/hosts.yml
   # Update ansible_host for each server
   ```

3. **Update DNS** at your registrar:
   - randazzo.ar → new proxy IP
   - randazzo.com.ar → new proxy IP
   - 0b.ar → new proxy IP (proxied through Caddy)
   - i.ar → new proxy IP (proxied through Caddy)
   - randazzo.net.ar → keep at Cloudflare

4. **Verify DNS propagation**:
   ```bash
   dig randazzo.ar +short
   dig 0b.ar +short
   dig i.ar +short
   ```

5. **Generate new WireGuard keys** (if keys were lost):
   ```bash
   ./scripts/generate-wg-keys.sh
   # Copy keys into group_vars/vault.yml
   # Encrypt: ansible-vault encrypt group_vars/vault.yml
   ```
   If you still have the vault file with keys, skip this step.

6. **Run the full playbook**:
   ```bash
   ansible-playbook playbooks/site.yml -i inventory/hosts.yml --vault-password-file .vault_pass
   ```

7. **Verify WireGuard mesh**:
   ```bash
   # From randazzo-ar:
   ping 10.66.0.2  # ob-ar
   ping 10.66.0.3  # i-ar
   ping 10.66.0.5  # server-pc (if online)
   ```

8. **Verify web services**:
   ```bash
   curl -I https://randazzo.ar
   curl -I https://i.ar
   ```

9. **Verify Cloudflare tunnel** (if needed):
   ```bash
   # Test fallback VPN access
   ssh -o ProxyCommand="cloudflared access ssh --hostname randazzo.net.ar" admin@randazzo.net.ar
   ```

---

## Scenario 2: Single Server Replacement

1. Provision new server, note IP.
2. Update `inventory/hosts.yml` (or `host_vars/<hostname>.yml`) with new IP.
3. If replacing the hub (randazzo-ar), regenerate WireGuard keys for it and update all peers' configs.
4. Run the relevant playbook:
   ```bash
   # Just the proxy:
   ansible-playbook playbooks/proxy.yml --vault-password-file .vault_pass
   
   # Just WireGuard (re-mesh):
   ansible-playbook playbooks/wireguard.yml --vault-password-file .vault_pass
   
   # AI playground:
   ansible-playbook playbooks/ai_playground.yml --vault-password-file .vault_pass
   
   # Ollama:
   ansible-playbook playbooks/ollama.yml --vault-password-file .vault_pass
   ```

---

## Scenario 3: WireGuard Key Compromise

1. Generate new keys for the compromised host:
   ```bash
   wg genkey | tee /tmp/new.key | wg pubkey > /tmp/new.pub
   ```

2. Update `group_vars/vault.yml`:
   ```bash
   ansible-vault edit group_vars/vault.yml
   # Replace the affected host's private and public keys
   ```

3. Re-run WireGuard on all hosts (peers need the new public key):
   ```bash
   ansible-playbook playbooks/wireguard.yml --vault-password-file .vault_pass
   ```

---

## Scenario 4: Cloudflare Tunnel Token Compromise

1. Rotate token in Cloudflare dashboard (Zero Trust → Tunnels → your tunnel → rotate)
2. Update vault:
   ```bash
   ansible-vault edit group_vars/vault.yml
   # Replace cloudflare_tunnel_token
   ```
3. Re-run:
   ```bash
   ansible-playbook playbooks/cloudflare.yml --vault-password-file .vault_pass
   ```

---

## Scenario 5: AI Agent SSH Key Compromise

1. Generate new keypair for the AI agent.
2. Update vault:
   ```bash
   ansible-vault edit group_vars/vault.yml
   # Replace ai_agent_ssh_public_key
   ```
3. Re-run:
   ```bash
   ansible-playbook playbooks/ai_playground.yml --vault-password-file .vault_pass
   ```
4. Remove old key from `~/.ssh/authorized_keys` on ob-ar (Ansible will handle this if you use `authorized_key` with `exclusive: true` — or manually remove).

---

## Backup Checklist

Store these in a secure, encrypted location (e.g., password manager, encrypted USB):

- [ ] `~/.ssh/id_ed25519` (Ansible SSH key)
- [ ] `.vault_pass` (Ansible vault password)
- [ ] `group_vars/vault.yml` (encrypted — contains all WG private keys, CF tokens)
- [ ] Cloudflare account credentials + API token
- [ ] Domain registrar account credentials
- [ ] VPS provider credentials
- [ ] `wg-keys/` directory (if not yet cleaned up)
- [ ] Git remote URL for this infrastructure repo

---

## Quick Health Check Script

```bash
#!/bin/bash
# health-check.sh — verify all infrastructure is alive
echo "=== Infrastructure Health Check ==="

# Cloud servers
for host in randazzo-ar ob-ar i-ar; do
    ip=$(grep "${host}" inventory/hosts.yml | head -1 | awk -F'"' '{print $2}')
    echo -n "${host} (${ip}): "
    ping -c1 -W2 "${ip}" >/dev/null 2>&1 && echo "UP" || echo "DOWN"
done

# WireGuard mesh
echo "=== WireGuard Peers ==="
ssh randazzo-ar 'wg show wg0' 2>/dev/null || echo "Cannot reach hub"

# Web services
echo "=== Web Services ==="
for domain in randazzo.ar i.ar 0b.ar; do
    echo -n "${domain}: "
    curl -sI "https://${domain}" 2>/dev/null | head -1 || echo "FAIL"
done

# Ollama
echo "=== Ollama ==="
echo -n "i-ar (cloud): "
ssh randazzo-ar 'curl -s http://10.66.0.3:11434/api/tags' 2>/dev/null | jq -r '.models[].name' 2>/dev/null || echo "FAIL"
echo -n "server-pc (local GPU): "
ssh randazzo-ar 'curl -s http://10.66.0.5:11434/api/tags' 2>/dev/null | jq -r '.models[].name' 2>/dev/null || echo "FAIL"
```
