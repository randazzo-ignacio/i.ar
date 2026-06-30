# Step-by-Step Deployment — Read This First

> You have 3 fresh cloud servers and 2 local machines. Domains already point
> to the right IPs. This guide takes you from zero to running, one step at a time.
>
> **Do these steps in order. Don't skip ahead. Each one depends on the last.**
>
> **All servers run Fedora Server 44 or AlmaLinux 10.**

---

## STEP 0: Get the files to your local machine

You need this infrastructure folder on the computer you'll be deploying from
(probably your laptop or server-pc).

If this repo is in git, clone it:
```bash
git clone <your-repo-url> ~/infrastructure
cd ~/infrastructure
```

If it's not in git yet, copy the `infrastructure/` folder to your machine however
you prefer (USB, scp, whatever). Then:
```bash
cd ~/infrastructure
```

**You should be inside the `infrastructure/` folder for every step from here on.**


---


## STEP 1: Install Ansible on your local machine

Check if you already have it:
```bash
ansible --version
```

If that prints a version number, skip to Step 2.

If not, install it:

**Fedora / AlmaLinux:**
```bash
sudo dnf install -y ansible
```

**macOS:**
```bash
brew install ansible
```

**If none of those work (or you don't have sudo):**
```bash
pip3 install ansible
```

Verify it worked:
```bash
ansible --version
```

You should see a version number. Move on.


---


## STEP 2: Make sure you have an SSH key

Check if you already have one:
```bash
ls ~/.ssh/id_ed25519.pub
```

If that file exists, skip to Step 3.

If not, generate one:
```bash
ssh-keygen -t ed25519 -C "infrastructure" -f ~/.ssh/id_ed25519
```

Press Enter when it asks for a passphrase (or set one if you want — it's more
secure but you'll type it every time you SSH). This creates two files:
- `~/.ssh/id_ed25519` (private key — NEVER share this)
- `~/.ssh/id_ed25519.pub` (public key — this goes on the servers)


---


## STEP 3: Generate a separate SSH key for the AI agent

The AI agent that will use ob-ar needs its own key:
```bash
ssh-keygen -t ed25519 -C "ai-agent" -f ~/.ssh/ai_agent_key
```

Press Enter for no passphrase (the AI needs to use it non-interactively).

You now have:
- `~/.ssh/ai_agent_key` (private — give this to the AI later)
- `~/.ssh/ai_agent_key.pub` (public — goes in the vault file)


---


## STEP 4: Generate WireGuard keys

WireGuard needs a private+public keypair for each of your 5 machines.

Check if you have `wg` installed:
```bash
wg --version
```

If not installed:
```bash
# Fedora / AlmaLinux:
sudo dnf install -y wireguard-tools

# macOS:
brew install wireguard-tools
```

Now run the script that's in this repo:
```bash
bash scripts/generate-wg-keys.sh
```

This will print out 5 keypairs and save them to a `wg-keys/` folder. It also
creates `wg-keys/vault-snippet.yml` with all the keys formatted as YAML, ready
to paste into the vault file.

**Write down or keep that terminal output visible — you'll need it in Step 7.**


---


## STEP 5: Get your server IPs

You need the public IP addresses of your 3 cloud servers. Find them however
you normally do — your VPS provider's dashboard, `dig randazzo.ar`, whatever.

You should end up with 3 numbers that look like:
- randazzo.ar → something like `203.0.113.10`
- 0b.ar → something like `203.0.113.20`
- i.ar → something like `203.0.113.30`

Also note the local IPs of your laptop and server-pc (the ones on your home
network — like `192.168.1.50`).

Write these down. You'll need them in Step 6.


---


## STEP 6: Fill in the server IPs

Open the main inventory file:
```bash
nano inventory/hosts.yml
```

(Use `vim` instead of `nano` if you prefer.)

Find every `CHANGE_ME_PUBLIC_IP` and replace it with the real IP for that server.
Find every `CHANGE_ME_LOCAL_IP` and replace it with the real local IP.

It should look something like this when done:
```yaml
randazzo-ar:
  ansible_host: 203.0.113.10
ob-ar:
  ansible_host: 203.0.113.20
i-ar:
  ansible_host: 203.0.113.30
laptop:
  ansible_host: 192.168.1.50
server-pc:
  ansible_host: 192.168.1.60
```

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X` in nano).

Also open each host_vars file and update the IP there too:
```bash
nano inventory/host_vars/randazzo-ar.yml
nano inventory/host_vars/ob-ar.yml
nano inventory/host_vars/i-ar.yml
nano inventory/host_vars/laptop.yml
nano inventory/host_vars/server-pc.yml
```

In each one, replace `CHANGE_ME_PUBLIC_IP` or `CHANGE_ME_LOCAL_IP` with the
matching IP.

For the local machines, also change `ansible_user` to your actual username
on those machines (not root, unless it actually is root).


---


## STEP 7: Fill in all the secrets

Open the vault file:
```bash
nano inventory/group_vars/vault.yml
```

This file has several `CHANGE_ME` values. Replace each one:

### 7a. WireGuard keys
You generated these in Step 4. Either:
- Copy the contents of `wg-keys/vault-snippet.yml` and paste it over the
  `wg_private_keys` and `wg_public_keys` sections, OR
- Manually replace each `CHANGE_ME_WG_PRIVATE_KEY` and `CHANGE_ME_WG_PUBLIC_KEY`
  with the values the script printed out.

### 7b. Cloudflare API token
1. Go to https://dash.cloudflare.com/profile/api-tokens
2. Click "Create Token"
3. Use "Edit zone DNS" template (or create custom)
4. Copy the token
5. Paste it as `vault_cloudflare_api_token`

If you don't need the Cloudflare tunnel right now, you can leave this as is
and skip the Cloudflare playbook for now. Come back to it later.

### 7c. Cloudflare Tunnel token
1. Go to https://one.dash.cloudflare.com/
2. Networks → Tunnels → Create a tunnel
3. Name it `randazzo-fallback`
4. Copy the token it gives you
5. Paste it as `cloudflare_tunnel_token`

Again, if you want to do this later, leave it for now.

### 7d. AI agent SSH key
Read the public key you generated in Step 3:
```bash
cat ~/.ssh/ai_agent_key.pub
```

Paste that entire line (starts with `ssh-ed25519 ...`) as
`ai_agent_ssh_public_key`.

Save and exit when everything is filled in.


---


## STEP 8: Set your email for Let's Encrypt

Caddy needs an email address to register TLS certificates. Open:
```bash
nano inventory/host_vars/randazzo-ar.yml
```

Add this line at the bottom (use your real email):
```yaml
caddy_email: "your-actual-email@example.com"
```

Save and exit.


---


## STEP 9: Create the vault password file

This is the password Ansible uses to encrypt/decrypt your secrets file.

```bash
echo 'pick-a-strong-password-here' > .vault_pass
chmod 600 .vault_pass
```

Replace `pick-a-strong-password-here` with something actually strong.
**Don't lose this password.** If you lose it, you can't decrypt your secrets.


---


## STEP 10: Encrypt the vault file

```bash
ansible-vault encrypt inventory/group_vars/vault.yml --vault-password-file .vault_pass
```

You should see: `Encryption successful`

Verify it's encrypted:
```bash
cat inventory/group_vars/vault.yml
```

It should look like gibberish starting with `$ANSIBLE_VAULT`. If you can still
read your keys in plaintext, something went wrong — try again.


---


## STEP 11: Copy your SSH key to the 3 cloud servers

You need to be able to SSH into each server without a password for Ansible to work.

For each cloud server, run this (replace the IP):
```bash
ssh-copy-id root@203.0.113.10   # randazzo-ar
ssh-copy-id root@203.0.113.20   # ob-ar
ssh-copy-id root@203.0.113.30   # i-ar
```

It will ask for the server's root password (this is the last time you'll need it).
Type `yes` if it asks about the host key.

Test that it worked:
```bash
ssh root@203.0.113.10 "hostname"
```

If it logs you in without asking for a password, you're good. Do this for all 3.

For your local machines (laptop, server-pc), do the same but with your username:
```bash
ssh-copy-id youruser@192.168.1.50   # laptop
ssh-copy-id youruser@192.168.1.60   # server-pc
```


---


## STEP 12: Test that Ansible can reach your servers

```bash
ansible all -i inventory/hosts.yml -m ping --vault-password-file .vault_pass
```

You should see `SUCCESS` for each server. If any say `UNREACHABLE`:
- Check the IP is correct in `inventory/hosts.yml`
- Check you can SSH manually: `ssh root@<that-ip>`
- Check the SSH key was copied (Step 11)

Fix any unreachable hosts before continuing. Don't run the playbook if ping fails.


---


## STEP 13: Run the full deployment

This is the big one. It configures all 3 cloud servers at once:

```bash
ansible-playbook playbooks/site.yml -i inventory/hosts.yml --vault-password-file .vault_pass --limit cloud
```

(Note: `--limit cloud` means it only touches your 3 cloud servers, not your
local machines. We'll do those separately in Step 15.)

**This will take 5-15 minutes.** You'll see a lot of output. Green = OK,
Yellow = Changed, Red = Failed.

If anything fails in red:
- Read the error message
- It's usually something simple (package name differs, service name differs)
- Fix it and re-run the same command — Ansible is idempotent, it won't
  break things by running twice

If it gets stuck on the Ollama model pulling step, that's normal — large
models take a while to download. Be patient or `Ctrl+C` and skip that for now.


---


## STEP 14: Verify the cloud servers are working

### Check WireGuard:
```bash
ssh root@<randazzo-ar-ip> "wg show"
```

You should see all peers listed with their public keys. If handshakes are
happening, you'll see `latest handshake: X seconds ago`.

### Check Caddy (web server):
```bash
curl -I https://randazzo.ar
```

You should get `HTTP/2 200` or `HTTP/2 502` (502 means Caddy is running but
the backend service isn't up yet — that's OK for now).

### Check Ollama on i-ar:
```bash
ssh root@<randazzo-ar-ip> "curl http://10.66.0.3:11434/api/tags"
```

You should see JSON with model names. If it says connection refused, Ollama
might still be starting up or pulling models. Give it a minute.

### Check AI playground:
```bash
ssh root@<ob-ar-ip> "su - ai-agent -c 'docker ps'"
```

Should show no containers (empty list is fine — nothing's running yet) but
no errors.


---


## STEP 15: Set up your local machines

If your laptop and server-pc are online and reachable from your deploy machine:

```bash
ansible-playbook playbooks/base.yml -i inventory/hosts.yml --vault-password-file .vault_pass --limit local
```

Then for server-pc specifically (it needs Docker + Ollama):
```bash
ansible-playbook playbooks/ollama.yml -i inventory/hosts.yml --vault-password-file .vault_pass --limit server-pc
```

If your local machines aren't reachable right now (you're not on the same
network, etc.), skip this step. You can do it later when you're home.


---


## STEP 16: Clean up

Delete the temporary key files (they're now safely in the encrypted vault):
```bash
rm -rf wg-keys/
```

**Do NOT delete `.vault_pass`** — you need it every time you run Ansible.

**Do NOT delete `~/.ssh/ai_agent_key`** — the AI needs that to connect to ob-ar.


---


## STEP 17: Save your backups

Put these somewhere safe (password manager, encrypted USB, whatever you trust):

1. **`.vault_pass`** — the vault password (or the file itself)
2. **`~/.ssh/id_ed25519`** — your admin SSH private key
3. **`~/.ssh/ai_agent_key`** — the AI agent's private key
4. **Cloudflare API token** (also in the encrypted vault, but keep a copy)
5. **Cloudflare Tunnel token** (same)
6. **This infrastructure folder** — push it to a private git repo:
   ```bash
   git init
   git add -A
   git commit -m "Infrastructure baseline"
   git remote add origin <your-private-repo-url>
   git push -u origin main
   ```


---


## You're done. Here's what you have now:

- **3 cloud servers**, hardened, updated, firewalled
- **WireGuard mesh** — all servers can talk to each other privately
- **Caddy reverse proxy** — randazzo.ar, i.ar, 0b.ar all serve HTTPS
- **Ollama** on i-ar (cloud, CPU) and ready for server-pc (GPU)
- **AI playground** on ob-ar — Docker ready, AI agent can SSH in
- **Cloudflare Tunnel** — fallback VPN if WireGuard is blocked
- **Everything in code** — to rebuild, just run the playbook again on fresh servers

## If something breaks later:

```bash
# Re-run everything:
ansible-playbook playbooks/site.yml -i inventory/hosts.yml --vault-password-file .vault_pass

# Or just one piece:
ansible-playbook playbooks/wireguard.yml  --vault-password-file .vault_pass
ansible-playbook playbooks/proxy.yml      --vault-password-file .vault_pass
ansible-playbook playbooks/ollama.yml     --vault-password-file .vault_pass
ansible-playbook playbooks/ai_playground.yml --vault-password-file .vault_pass
```

Ansible is idempotent — running it again won't break anything. It just makes
sure everything matches the configuration. Think of it as "re-sync to known good state."