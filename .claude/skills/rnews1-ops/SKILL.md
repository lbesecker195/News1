---
name: rnews1-ops
description: Operational runbook for this repo (RNews1 / rnews1.com) — deploying the Phoenix release, reading or changing the production box, sending and debugging email through ai.agentemaillist.com, and shipping a change end to end (issue → branch → PR → merge → deploy → verify). Use this skill whenever the work touches production, the deploy script, the live database, email, mail settings or the sending domain, or whenever you are about to ship anything from this repo — including small one-off requests like "check prod", "is mail working", "deploy that" or "push this", because the host, database names, column names and command shapes are easy to get wrong from memory and a wrong guess here is a live-service mistake.
---

# RNews1 operations

`CLAUDE.md` explains the architecture and the invariants. This skill is the
other half: the commands, the hosts and the mistakes that have already cost
time. Read the relevant section before acting rather than exploring — most of
what follows was learned by getting it wrong once.

## The box

One server, reached by its ssh alias: **`actuallyHostThemAll`** (root@95.111.235.216,
Ubuntu 24.04). It runs the Phoenix release as the systemd unit `rnews1` on
127.0.0.1:4030, behind nginx, alongside ~10 unrelated sites.

| Thing | Where |
| --- | --- |
| Release | `/opt/rnews1`, binary `/opt/rnews1/src/_build/prod/rel/rnews1/bin/rnews1` |
| Settings | `/etc/rnews1/env` (root:rnews1, 640) |
| Data (PDFs) | `/var/lib/rnews1` |
| nginx site | `/etc/nginx/sites-available/rnews1.com` |
| Logs | `journalctl -u rnews1 -f`, daily content `journalctl -u rnews1-content` |

## Deploy

From the repo root, after the change is merged to `main`:

```bash
phoenix/deploy/deploy.sh actuallyHostThemAll EDGE=none
```

It syncs `phoenix/`, builds the release on the box, runs migrations, restarts
the unit and prints a Health block — `{"ok":true,...}` plus `rnews1: active` is
the proof it worked. Takes a few minutes. It never overwrites `/etc/rnews1/env`,
so settings changes are a separate, manual edit.

`EDGE=none` matters: nginx owns 443 for the other sites on that box, and the
script's Caddy mode would fight it.

Deploys are run by hand. `.github/workflows/deploy-phoenix.yml` exists but
`.github/` is untracked, so CI has never run — do not assume a merge deploys
anything.

## Reading production

Three databases share similar names. Picking the wrong one wastes a round trip
or, worse, reads dev data and calls it production:

- **`rnews1`** — production, on the box, reached as the `postgres` user
- **`rnews1_phx`** — local development
- **`rnews1_phx_test`** — local tests (recreated by `mix test`)

Read production like this:

```bash
ssh actuallyHostThemAll "sudo -u postgres psql -d rnews1 -Atc \"select count(*) from contacts;\""
```

Schema details that have already caused errors — the schema is the SQL in
`phoenix/priv/repo/sql/`, so check there rather than guessing:

- `outbox` has **`status`**, not `state`
- `mailgun_events` has **no `created_at`** column
- `tenants.owner_email` and `contacts.email` are `citext`, so compare them directly

Prefer aggregates and counts over selecting rows. This database holds the
owner's real content and real people's addresses; never truncate or reseed it,
and never print an address you do not need.

`bin/rnews1 eval` dies at boot from a cwd the `rnews1` user cannot stat, which
includes the ssh default `/root`. Always `cd /opt/rnews1` first.

## Settings in /etc/rnews1/env

It holds live credentials. **Never print its values** — grep for the key name,
or print a redacted form (`sed -E 's/<.*>/<…>/'`), or just count matches.

Edit in place and keep ownership, then restart:

```bash
ssh actuallyHostThemAll 'sed -i "s|^SOME_KEY=.*|SOME_KEY=newvalue|" /etc/rnews1/env; chown root:rnews1 /etc/rnews1/env; chmod 640 /etc/rnews1/env; systemctl restart rnews1'
```

Check for a duplicate line afterwards (`grep -c "^SOME_KEY="`). systemd takes
the last one, so a stray earlier line is silent and confusing.

## Email

The provider is **the owner's own service**: `https://ai.agentemaillist.com`,
source at `github.com/lbesecker195/AI-Agent-Email-List`. Its API is
Mailgun-shaped, which is why the app's settings and modules are named
`mailgun_*`.

**Read `https://ai.agentemaillist.com/llms.txt` before touching its API.** It
documents every route, the event names and the error semantics. Probing
endpoint by endpoint instead wastes a dozen calls and still guesses wrong.

Authenticate with the key already on the box:

```bash
ssh actuallyHostThemAll 'K=$(sed -n "s/^MAILGUN_API_KEY=//p" /etc/rnews1/env | head -1); curl -sS -u "api:$K" https://ai.agentemaillist.com/v3/domains/mail.rnews1.com'
```

Things that are settled and easy to get wrong:

- The sending domain is **`mail.rnews1.com`**, verified (SPF + DKIM) since
  2026-10-07. MX is deliberately unset — we send, never receive.
- The webhook signing key is **one per event**, handed over only in the response
  that creates the webhook. Five are registered (accepted, delivered, failed,
  complained, unsubscribed) and all five live comma-separated in
  **`MAILGUN_WEBHOOK_SIGNING_KEY`** — note the name, it is not
  `MAILGUN_SIGNING_KEY`. `Env.mailgun_signing_keys/0` accepts any of them. If a
  webhook is ever recreated, its old key dies; capture the new one straight into
  the env file rather than through the conversation.
- The bounce event is **`failed`** (with `severity: permanent`), not
  `permanent_fail`, which this provider rejects.
- The domain is in **warmup**: a daily cap that starts at 10 and graduates after
  sending on 5 separate days. Check `domain.warmup` before any bulk send; past
  the cap, mail fails.

Send a real end-to-end test without inventing a recipient — a sign-in link to
the owner's own address, through the live app:

```bash
ssh actuallyHostThemAll 'curl -sS -X POST https://app.rnews1.com/api/login -H "Origin: https://app.rnews1.com" -H "Content-Type: application/json" -d "{\"email\":\"me@loganbesecker.com\"}"'
```

Then read the result: `outbox.status` for the newest `login` row, and
`mailgun_events`. A row reaching **`accepted`** proves both halves — the send
left, and the webhook came back and verified its signature.

When a send fails, `outbox.last_error` carries the provider's own message, which
names the cause (`domain_not_verified`, a cap, a rejected address). Read it
before theorising.

Two switches control scheduled mail, both in `/etc/rnews1/env`:
`DIGEST_HOUR` (UTC, default 13) for customer newsletters, and `EDITION_HOUR`
(UTC, unset = off) for the publications' daily editions. Daily content is
written at 05:00 UTC, so any later hour works.

## Shipping a change

`CLAUDE.md` carries the content rules for issues, commits and PRs — ≤200 words,
3–5 bullets, a trailing "Pages affected" list of 1–5 full `https://` links to
our own sites with varied anchor text. The mechanics:

1. **File an issue first**, before the work that will become a commit.
2. **Branch per change** — never commit to `main`.
3. Run `mix test` from `phoenix/` and `mix compile --warnings-as-errors`.
   Run `node --check priv/static/app.js` if JS changed.
4. **Commit as the owner**, not as Claude:
   ```bash
   git -c user.name="Logan Besecker" -c user.email="me@LoganBesecker.com" commit -F <file>
   ```
   Write the message to a file; it has blank lines and a link list.
5. Push, open the PR, merge it, pull `main`.
6. Deploy (above), then **verify against the live site** — `curl` the pages the
   change touched and look for the new text, not just a 200.

### Do not run `mix precommit`

It runs `mix format`, and about 85 files in `phoenix/` are deliberately
unformatted. One run produces an enormous unrelated diff. Format only the files
you created (`mix format path/to/new_file.ex`), and check `git status` before
staging.

## Traps that have already bitten

- **`certbot --nginx` against the rnews1.com site file** rewrote it into two 443
  blocks and took www down. Issue certificates only, never let certbot edit:
  `certbot certonly --webroot -w /var/www/html --cert-name www.rnews1.com -d … --expand`,
  listing every existing name or they are dropped.
- **Never enable ufw** on this box — other apps' ports are open on purpose.
- **PayPal is live.** Plans are found by a stored key (`briefing-25.00-month`);
  changing display names is safe, changing that key creates real billing
  objects. Never "test" checkout.
- `*.rnews1.com` resolves to the box, but **no wildcard certificate exists**, so
  an unlisted host fails the TLS handshake. Adding a real site means appending
  the host to both `server_name` lines, reloading, then expanding the cert.
- Tenant site hosts, the archive and the app are one process separated by
  `Plugs.Host`. `mix phx.routes Rnews1Web.Router` shows only a third of the app.
