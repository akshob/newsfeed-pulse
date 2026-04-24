# Deployment

These files are the live production config on hydrogen. They're checked into the repo for reference / version control, but are not deployed by rsync. Install them manually via the commands below.

## Scripts (`scripts/`)

### `newsfeed-ingest`
Hourly pipeline: `ingest → score --limit 100 → catchup-all --limit 50`. Uses `flock` to prevent overlapping runs; per-run logs timestamped at `/mnt/butterscotch/newsfeed/logs/ingest/`.

Installed to `/usr/local/bin/newsfeed-ingest` (root:root, 755). Cron entry in `akshobg`'s crontab:
```
0 * * * * /usr/local/bin/newsfeed-ingest
```

### `newsfeed-deploy`
Restarts the systemd service after a new binary is built. Requires sudo (it self-checks `$EUID -eq 0`). Installed to `/usr/local/bin/newsfeed-deploy` (root:root, 755).

Use:
```bash
sudo newsfeed-deploy
```

## systemd (`systemd/`)

### `newsfeed.service`
Runs the Vapor release binary under user `akshobg`. Loads `.env` via `EnvironmentFile`, restarts on failure, depends on `postgresql.service`.

Install:
```bash
sudo install -o root -g root -m 644 deploy/systemd/newsfeed.service /etc/systemd/system/newsfeed.service
sudo systemctl daemon-reload
sudo systemctl enable --now newsfeed.service
```

### `override.conf` (for Ollama)
Drop-in for `ollama.service`. Pins `OLLAMA_MODELS` path to the SSD and reduces Ollama to low priority so background catchup-all work doesn't thrash the system (`Nice=10 CPUWeight=50 CPUQuota=500% IOSchedulingClass=idle`).

Install:
```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo install -o root -g root -m 644 deploy/systemd/override.conf /etc/systemd/system/ollama.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

## Script install (both)
```bash
sudo install -o root -g root -m 755 deploy/scripts/newsfeed-ingest /usr/local/bin/
sudo install -o root -g root -m 755 deploy/scripts/newsfeed-deploy /usr/local/bin/
```

## Host prerequisites

- Ubuntu 24.04 (or similar)
- Postgres 16 + `postgresql-16-pgvector`
- Ollama with `nomic-embed-text` and `llama3.2:3b` pulled
- Caddy reverse-proxying `pulse.<yourdomain>` → `127.0.0.1:8080`
- Swift toolchain (via `swiftly install latest`) for building
- User `akshobg` with passwordless write access to `/mnt/butterscotch/newsfeed/`

Caddyfile entry:
```
pulse.yourdomain.com {
    reverse_proxy 127.0.0.1:8080
}
```
