# static-page role

Deploys the emacboros landing page to daftpunk (i.ar). Caddy on daftpunk
serves the files directly via `file_server` — no separate HTTP server
process needed.

## Files

| File | Purpose |
|------|---------|
| `files/index.html` | Landing page markup |
| `files/style.css` | Matrix/terminal aesthetic stylesheet |
| `files/script.js` | Boot sequence, matrix rain, scroll reveal |
| `tasks/main.yml` | Deploys files to web root (owned by caddy user) |

## Deployment

The role runs on `daftpunk` in `playbooks/site.yml`, **before** the
`caddy` role. The `caddy` role creates `/var/www/emacboros` and sets
ownership to the `caddy` user. This role then fills it with content.

## Architecture

```
[Client] → HTTPS → [Caddy @ daftpunk] → file_server → /var/www/emacboros/
                   i.ar:443                             index.html, style.css, script.js
```

Caddy handles TLS automatically via Let's Encrypt. No reverse proxy
needed — static files are served directly from disk.

## Role ordering

```
site.yml:
  1. static-page (copies HTML/CSS/JS to /var/www/emacboros/)
  2. caddy       (creates web root, deploys Caddyfile, starts Caddy)
```