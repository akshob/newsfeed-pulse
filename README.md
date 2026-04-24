# pulse

A personal news feed that doubles as a "catch me up on half-heard gossip" engine. Scored and summarized by a local LLM; skipped items drop from the feed via explicit keep/skip votes.

Live at [pulse.akshob.com](https://pulse.akshob.com) — deployed on a home Linux box fronted by Caddy + Cloudflare.

## What it does

- Pulls RSS from a configurable set of sources (tech + general news + politics + "what's buzzing" aggregators)
- Embeds each item and scores it against a personal interest profile
- Rerank via local Llama: generates **TLDR**, **why this fits you**, and a predicted lane (tech / conversation)
- Pre-generates **catch-me-up explainers** for each item (Background / What's new / Two strongest takes / Conversation starter)
- Web UI: ranked feed with a split-pane detail view (desktop) / stacked nav (mobile)
- Uncached items gracefully fall back to an iframe of the original article
- Explicit **keep / skip** buttons; skipped items drop from the feed on next load
- `/capture` endpoint for dropping in "heard this from my wife" style notes (not yet wired to the ranking, but stored)
- **Invite-only signup** — public DNS, gated account creation; see [Inviting users](#inviting-users) below

Full product thinking: see memory notes; short version: the target metric is "did this give me something I can bring up with non-engineers at lunch," not "did I learn something technical."

## Layout

```
newsfeed-pulse/
├── app/                  # Swift / Vapor project (runs on hydrogen at /mnt/butterscotch/newsfeed/app/)
│   ├── Sources/NewsFeed/
│   │   ├── Models/       # Fluent models
│   │   ├── Migrations/   # schema migrations (incl. pgvector raw SQL)
│   │   ├── Commands/     # CLI: ingest, score, catchup-all, seed-feeds
│   │   ├── Services/     # OllamaClient
│   │   ├── routes.swift  # HTTP routes + HTML rendering (HTMX-based)
│   │   └── configure.swift
│   ├── Data/
│   │   ├── feeds.json            # RSS source list (tracked)
│   │   ├── interests.md          # YOUR personal rubric (gitignored)
│   │   └── interests.example.md  # template
│   ├── Package.swift / Package.resolved
│   └── .env.example
├── deploy/               # systemd units + /usr/local/bin scripts (copied here for reference)
│   ├── README.md
│   ├── scripts/
│   │   ├── newsfeed-ingest   # hourly: ingest → score → catchup-all
│   │   └── newsfeed-deploy   # sudo restart after new build
│   └── systemd/
│       ├── newsfeed.service
│       └── override.conf         # Ollama low-priority drop-in
├── tools/                # local dev tooling
│   ├── sync-logs.sh          # pulls hydrogen's logs to ./logs/ every 15 min via launchd
│   └── pulse-logsync.plist   # launchd agent definition
├── logs/                 # synced from hydrogen (gitignored)
└── LICENSE.txt
```

## Stack

- **Swift 6.3** + **Vapor 4**
- **Fluent** + **PostgresKit** + **pgvector** (ORM + vector columns for embeddings)
- **FeedKit** (RSS/Atom parsing)
- **HTMX** (progressive enhancement — split-pane UI without a JS build step)
- **Ollama** (local): `nomic-embed-text` (768-dim) + `llama3.2:3b`
- **Postgres 16** on SSD
- **Caddy** (TLS + reverse proxy)

All LLM work runs in hourly cron-driven background jobs on the server — **no on-click LLM inference**. User clicks always respond in <50ms (either cached explainer or iframe fallback).

## Development workflow

Local repo at `/opt/newsfeed-pulse/`. Remote deploy target is `akshobg@hydrogen.local:/mnt/butterscotch/newsfeed/app/`.

Edit code locally, then:

```bash
# Push source changes to hydrogen
rsync -av -e "ssh -i ~/.ssh/id_ed_hydrogen" \
  --exclude '.build/' --exclude '.swiftpm/' --exclude '.env' --exclude '.env.example' \
  --exclude 'Data/interests.md' \
  /opt/newsfeed-pulse/app/ akshobg@hydrogen.local:/mnt/butterscotch/newsfeed/app/

# Build and restart on hydrogen
ssh akshobg@hydrogen.local 'source ~/.local/share/swiftly/env.sh && cd /mnt/butterscotch/newsfeed/app && swift build -c release'
ssh akshobg@hydrogen.local 'sudo newsfeed-deploy'
```

Claude drives this loop directly via SSH when you're collaborating with it.

## Inviting users

pulse is invite-only. The public DNS is reachable; `/signup` requires a valid unused code. To create an invite code, SSH to hydrogen and run:

```bash
ssh akshobg@hydrogen.local
cd /mnt/butterscotch/newsfeed/app
swift run -c release NewsFeed create-invite
```

You'll see:
```
✓ invite code:  mvcu-8qy6-9978
  share URL:    https://pulse.akshob.com/signup?code=mvcu-8qy6-9978
```

Share the URL with the person you're inviting. Invite codes are **one-shot** — marked as used the moment someone signs up with them. Generate a fresh code per invitee. There's no expiry today; codes stay valid until used.

After signup the user is redirected to `/onboarding` to pick interest categories + write a blurb, then lands on their feed.

**Managing invites directly in the DB** (view/revoke):
```bash
PGPASSWORD=... psql -h localhost -U newsfeed -d newsfeed
# see all invites
SELECT code, created_at, used_at, used_by_user_id FROM invites ORDER BY created_at DESC;
# revoke an unused invite
DELETE FROM invites WHERE code='xxxx-xxxx-xxxx' AND used_at IS NULL;
```

## Setup (fresh install)

See [deploy/README.md](deploy/README.md) for full production install. Quick start for development on any machine:

1. `cp app/.env.example app/.env` — fill in DB password
2. `cp app/Data/interests.example.md app/Data/interests.md` — describe what you care about
3. Create Postgres DB + enable pgvector
4. `swift build -c release`
5. `swift run -c release NewsFeed migrate --auto-migrate -y`
6. `swift run -c release NewsFeed seed-feeds`
7. `swift run -c release NewsFeed ingest && swift run -c release NewsFeed score --limit 100`
8. `swift run -c release NewsFeed serve --port 8080`
