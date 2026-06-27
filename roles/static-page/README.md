# static-page role

Deploys the emacboros landing page to daftpunk (i.ar) and serves it on port 8080
via a hardened systemd-managed Python HTTP server. Caddy on rammstein reverse-proxies
`i.ar` to `10.66.0.3:8080` over the WireGuard mesh.

## Files

| File | Purpose |
|------|---------|
| `files/index.html` | Landing page markup |
| `files/style.css` | Matrix/terminal aesthetic stylesheet |
| `files/script.js` | Boot sequence, matrix rain, scroll reveal |
| `templates/static-page.service.j2` | Systemd unit for the HTTP server |

## Deployment

The role is included in `playbooks/site.yml` and runs on `daftpunk` when
`tool_static_page_enabled: true` (set in `host_vars/daftpunk.yml`).

```bash
# Deploy only the static page
ansible-playbook playbooks/site.yml --vault-password-file .vault_pass --tags static-page
```

## Customization

Edit `files/index.html`, `files/style.css`, and `files/script.js` directly,
then re-run the playbook. The `notify: restart static-page` handler picks up
changes automatically.

## Architecture

```
[Client] → HTTPS → [Caddy @ rammstein] → WireGuard → [Python HTTP @ daftpunk:8080]
                   randazzo.ar:443                     10.66.0.3:8080
```

The Python HTTP server runs under systemd with:
- `NoNewPrivileges=true`
- `ProtectSystem=strict`
- `ProtectHome=true`
- `PrivateTmp=true`
- `ReadOnlyPaths` on the web root
- Only `CAP_NET_BIND_SERVICE` capability