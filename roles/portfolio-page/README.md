# portfolio-page role

Deploys the personal portfolio landing page to rammstein (randazzo.ar).
Caddy on rammstein serves the files directly via `file_server`.

## Files

| File | Purpose |
|------|---------|
| `files/index.html` | Portfolio page markup |
| `files/style.css` | Dark technical aesthetic stylesheet |
| `files/script.js` | Scroll reveal, nav effect, footer year |

## Deployment

Run via standalone playbook:

```bash
ansible-playbook playbooks/portfolio-page.yml --vault-password-file .vault_pass
```

Or via the main site playbook (once wired in).

## Architecture

```
[Client] → HTTPS → [Caddy @ rammstein] → file_server → /var/www/randazzo.ar/
                   randazzo.ar:443                        index.html, style.css, script.js
```