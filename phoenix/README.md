# RNews1 — Phoenix

The RNews1 application ("Real News, Made for One") as an Elixir/Phoenix
application: the same product, database schema and URLs as the Node version
in `../saas`, running as one OTP release.

## What is here

    lib/rnews1/            contexts — data access (hand-written SQL, verbatim from the
                           Node app) and the services on top of it
      util/                hosts, plans, overlap guard, teaser, slug, markdown, …
      services/            treg discovery, article extraction, OpenAI, the story and
                           editorial pipelines, PayPal, Mailgun, DNS verification,
                           the brief page and its PDF, the newsletter email
      workers/             the four background loops (content, delivery, scheduler,
                           maintenance) as GenServers
      cli.ex               what the npm scripts did; mix tasks call these
    lib/rnews1_web/        three routers dispatched by host, plugs, controllers,
                           HEEx pages, EEx feeds/sitemaps/brief page
    priv/repo/sql/         the twelve SQL migrations, unchanged
    priv/repo/migrations/  Ecto wrappers that execute them
    deploy/                Caddy, nginx cache, deploy.sh (the one deploy script)
    content.json           brand, archive and briefing copy (hot-reloaded)

## Running it locally

Needs Elixir 1.17+ / OTP 26+, PostgreSQL, and (for PDFs) a Chrome.

```bash
cp ../saas/.env .env         # same variable names; edit DATABASE_URL and APP_ORIGIN
mix setup                    # deps, create, migrate
mix rnews1.content.load      # the archive export from deploy/content.csv.gz
mix phx.server               # http://localhost:4000
```

Three hosts, one process — browsers resolve `*.localhost` on their own:

| URL | What |
| --- | --- |
| `http://localhost:4000` | the app — marketing, dashboard, API, admin |
| `http://www.localhost:4000` | the archive — twelve sections, twelve languages |
| `http://{subdomain}.localhost:4000` | a customer's site |

Sign in without mail: `mix rnews1.login you@example.com` prints the link.
Staff: `mix rnews1.admin you@example.com 'password' --comp`.

Other tasks: `rnews1.content`, `rnews1.translate`, `rnews1.report`, `rnews1.pdf`,
`rnews1.clicks`, `rnews1.plan`, `rnews1.once`, `rnews1.import_hugo`.

## Tests

```bash
mix test                     # 73 tests; creates and migrates rnews1_phx_test itself
mix test --include chrome    # also the real PDF render, when a Chrome is installed
```

## Differences from the Node version, deliberately

- **Passwords are Argon2id**, not scrypt — OTP has no scrypt. Existing hashes
  cannot be verified; the two that existed are re-set with `mix rnews1.admin`
  and the dashboard.
- **One process.** The web app and the worker loops run in one release;
  `WORKER=0` runs a web-only node.
- **PDFs via ChromicPDF**, scaling down in steps until the page fits one sheet.
  Without a Chrome, `/pdf/:id` answers 503 and everything else works.
- **Ecto keeps its own migration table** (`ecto_schema_migrations`), so this
  app can be pointed at a database the Node app built: every migration is
  idempotent SQL and runs cleanly on top of an existing schema.
- Client IP behind proxies is read with an explicit hop count
  (`TRUST_PROXY_HOPS`, 1 for Caddy alone, 2 with the nginx cache).

## Deploying

```bash
deploy/deploy.sh root@SERVER DOMAIN=rnews1.com ACME_EMAIL=you@rnews1.com
deploy/deploy.sh                    # every deploy after: DEPLOY_TARGET, default actuallyHostThemAll
```

One script. Run from a laptop or CI it syncs `phoenix/` to the server and runs
itself there as root (`VAR=value` arguments travel with it; your local
environment does not). It builds a release on the server (Erlang Solutions
packages), runs migrations, loads the archive export on first run, installs
the `rnews1` systemd service, Caddy with on-demand TLS, and — when nginx is
present — the one-hour page cache. Secrets live in `/etc/rnews1/env` under
the same names as before. Rerun to deploy.

### Continuous deployment

`.github/workflows/deploy-phoenix.yml` (at the repository root) runs the tests
on every push and pull request that touches `phoenix/`, and on a push to
`main` runs the same `deploy/deploy.sh` against the production box. It needs
three repository secrets: `RNEWS1_DEPLOY_HOST` (`user@host`),
`RNEWS1_DEPLOY_SSH_KEY` (a key that exists only for this) and
`RNEWS1_DEPLOY_KNOWN_HOSTS` (the box's host key line). The runner has no
`.env` and no `content.csv.gz`; the sync leaves the server's copies alone, and
the server's `/etc/rnews1/env` is what the release reads.

### Daily content

The deploy installs `/etc/cron.d/rnews1-content`, which starts the systemd
oneshot `rnews1-content.service` once a day at `CONTENT_HOUR` (UTC, default 5,
`off` removes it). The unit runs `Rnews1.Release.cli(:content, [])` — the same
operation as `mix rnews1.content` — which writes one story per section in
every language, from the news provider and the model named in the env file.
It starts the application without the web listener or the worker loops, so it
runs beside the live service without touching its port or its queues. A run
that is still going blocks the next start; a failure shows in
`systemctl status rnews1-content` and `journalctl -u rnews1-content`. To run
it now: `systemctl start rnews1-content`.

### A box where nginx (or anything else) already owns :443

`deploy/deploy.sh root@SERVER DOMAIN=rnews1.com EDGE=none` (auto-detected when
something other than Caddy is listening on 443). Everything is installed as
above except the edge: the app listens on 127.0.0.1:PORT and your existing
server proxies to it, sending `Host`, `X-Forwarded-For` and
`X-Forwarded-Proto`. Certificates for customer hostnames are then your edge's
problem; Caddy's on-demand issuance is the reason `EDGE=caddy` is the default
on an empty box.

### Replacing the Node deploy on the same box

Run the same command. The script finds `/etc/rnews1/env` and reuses it, so
the release takes over the Node app's database, data directory and secrets
as they are: Ecto records the SQL files Node already applied as applied
(`Rnews1.Release.adopt_node_migrations/1`) and runs only newer ones. The two
Node services (`rnews1-web`, `rnews1-worker`) are stopped and disabled before
the release starts, the Caddyfile the Node deploy wrote is replaced (a copy is
kept as `Caddyfile.before-rnews1`), and the nginx cache, if present, is
re-pointed. `PORT` stays what the env file says (3000 from the Node deploy)
unless you pass one; `/opt/rnews1/saas` is left on disk and can be deleted.

### Sharing the box with another Phoenix app

Everything is namespaced — user, service, directories, database and role are
all `rnews1` — and the release ships its own ERTS, so two releases with
different Erlang versions coexist. Two things to set:

- `deploy/deploy.sh root@SERVER PORT=4001 DOMAIN=…` if the other app already
  has :4000 (and `CACHE_PORT=…` if it uses 8080). Pass them as arguments —
  the script forwards arguments, not your local environment. The Caddy and
  nginx configs are rendered from the port, and on later runs the value in
  `/etc/rnews1/env` is used unless you pass PORT again.
- Caddy: this deploy never overwrites `/etc/caddy/Caddyfile`. Our hosts go in
  `/etc/caddy/sites/rnews1.caddy`; the main file only gains an
  `import /etc/caddy/sites/*.caddy` line and, if it has no global block, the
  `on_demand_tls { ask … }` one. Put the other app's hosts in the same
  `sites/` directory and they share one Caddy.

The one shared thing is the build-time Elixir: both apps compile with the
system `elixir` unless you pin per project (mise/asdf). If the other app needs
a different version, build releases elsewhere and ship the tarball.
