# Rnews1

Company news feeds, website embeds and daily team briefings. One company per
tenant, $25/month, up to 10 confirmed recipients.

Two processes share one Postgres database:

- **web** (`npm start`) — Express, EJS, PayPal and the public feeds.
- **worker** (`npm run worker`) — crawling, summarising, scheduling and email.

```text
Request:  Route → Middleware → Controller → Service / Model → View or JSON
Worker:   Loop  → Service / Model → Google News, OpenAI, Mailgun, PDFs
```

## Layout

| Concern | Location |
|---|---|
| Postgres persistence | `src/models/` |
| HTTP handlers | `src/controllers/` |
| HTML and XML templates | `src/views/` |
| Route registration | `src/routes/` |
| Auth, origin checks, rate limits, errors | `src/middleware/` |
| PayPal, Mailgun, OpenAI, news, PDF, briefs | `src/services/` |
| Crawling, scheduling, delivery | `src/workers/` |
| Ad server (targeting, caps, tracking) | `src/models/ad.model.mjs`, `src/services/ad.service.mjs` |
| Editorial archive (12 locales) | `src/controllers/editorial.controller.mjs` |
| Staff ad management | `/admin` |
| Browser behaviour and styling | `public/` |
| Schema | `migrations/` |

`src/services/platform.service.mjs` is the shared surface — origin, tokens,
hashing, escaping, the outbox `enqueue` — and re-exports the focused services
so callers have one import to reach for.

## Running it

```bash
cp .env.example .env    # then fill it in
npm install
npm run migrate
npm start               # web, port 3000
npm run worker          # background processing, separate process
```

Other entry points:

```bash
npm run create-content -- --dry-run             # write the journal, 12 sections
npm run translate -- --dry-run                  # fill missing locales
npm run import-hugo -- ../hugo/content          # editorial archive, 12 locales
npm run login                                   # sign-in links, when mail is off
npm run import -- ./contacts.json [--dry-run]   # authorised contact import
npm run plan -- 2026-10-01                      # queue a campaign for a date
npm run create-admin -- you@example.com 'password' --comp   # staff account
node --env-file=.env src/workers/main.mjs --once  # one pass of each loop
```

## Tests

```bash
npm test
```

Runs without a database: unit tests, every EJS template, the PDF writer's
bytes, and the Express app over real HTTP.

To also exercise the SQL and the worker end to end, point at a scratch database
that the tests may wipe:

```bash
createdb rnews1_test
DATABASE_URL=postgres://localhost/rnews1_test npm run migrate
TEST_DATABASE_URL=postgres://localhost/rnews1_test npm test
```

## How it fits together

**Signing in** is signing up. A tenant row is created the first time an address
is seen; the account becomes real when the emailed link is followed. Login and
session secrets are only ever stored as SHA-256 hashes. The link lands on an
interstitial page and the session is created by a POST, so a mail scanner
following the link cannot burn it.

**Three stories a day, written once.** A customer picks one industry and two
keywords. Each morning the worker leases the topic, finds candidate stories,
then fetches and reads three articles and writes them up in our own words.

Discovery runs through [treg](https://treg.to), not Google News RSS. Google
stopped redirecting to publishers and now serves a JavaScript interstitial that
resolves the target through an internal API, so an RSS link leads only back to
Google — and without a publisher URL there is no article to read. `NEWS_PROVIDER`
selects between `exa` (neural search, ~$0.007/call, genuine recent news with
real publish dates) and `serp` (Google News via DataForSEO, ~$0.002/call,
cheaper but ranks listicles and market reports alongside the reporting). Both
return the publisher's own URL. Give the worker its own treg identity rather
than a personal token: `treg org agent-new rnews1-worker`.

The fetch obeys `robots.txt`, identifies itself with a contactable agent
string, and the publisher's text is used to write from and then **dropped**.
`dropSource()` in `story.service.mjs` is the only path by which a story leaves
the rewrite, and it strips the source; the `stories` table has no column that
could hold one. What is kept is a record of having read it — the resolved URL,
the extraction method, the character count.

`corpus.integration.test.mjs` is the guard on that. It runs the real pipeline
with every network boundary stubbed, plants distinctive prose in the article,
and then searches the saved row for any word that could only have come from the
source — including down the rejection path, which is the dangerous one, because
that path handles text that *is* the source.

Before a story is kept, its text is compared against the source with
`longestSharedRun()`. Sharing twelve consecutive words with the original means
the model paraphrased rather than rewrote, and the story is rejected in favour
of a headline-only write-up. The measured run is stored on every row, because
"we checked, every time, and here are the numbers" is a far better answer to a
publisher than "we intended not to".

Every story carries a `fingerprint` of its normalised source URL, unique **per
topic**. Two customers on the same beat both get the story, each with their own
rewrite; what the constraint prevents is one topic covering the same article
twice, which is what a reader would experience as the same story coming round
again. A candidate published by us is dropped before it is ever considered, so a
hosted story that finds its way into an aggregator can never be rewritten into a
rewrite of itself — drifting further from the reporting with every pass and
citing ourselves as the source.

That check is on the **host**, never the publisher name: a feed can put any
text in the publisher field, while the host is the only part that identifies
who actually published a page. `OWN_HOSTS` extends it to enterprise custom
domains, and subdomains are covered. The resolved URL is checked as well as the
candidate, since a link can redirect back to us through an aggregator that
picked up our feed.

**Every reader gets a different issue.** Contacts carry name, title, company and
industry. At send time the model is given one reader and that day's three
stories and asked which should lead; the other two become blurbs. It can only
reorder stories that already exist, a malformed answer falls back to the default
order, and the choice is cached per reader per day so a delivery retry costs
nothing. A reader with no enrichment on file never triggers a model call at all.

**Advertising pays for the personalisation.** Each issue carries one labelled
sponsored story and up to two banners, selected by `src/services/ad.service.mjs`
against the reader's role and industry plus the topic of the issue. Campaigns
have flights, daily and total caps, and a CPM for reporting. One advertiser
never takes two slots in the same issue. Impressions are counted when the issue
is built rather than when the pixel loads, because blocked images under-report
delivery by more than send-time counting over-reports it; the `ad_events` ledger
keeps confirmed opens separately. Clicks always route through `/a/c/:id`, and the
destination is re-checked against `safeURL()` before the redirect, so an
advertiser cannot store a `javascript:` URL and use our domain to deliver it.

**Recipients are added on the customer's authority.** There is no confirmation
email: the customer ticks a box attesting they may mail this person, and the
attestation is stored against the row with who made it and when. What protects
the recipient is everything downstream — one-click unsubscribe in every issue,
and platform-wide suppression that no attestation can override.

**Every outgoing email goes through the outbox**, queued in the same
transaction as the state change that justifies it. A job is claimed with
`FOR UPDATE SKIP LOCKED`, so multiple workers can share the queue. A send whose
outcome is unknown (a timeout, say) is parked rather than retried: Mailgun may
already have accepted it, and the events webhook resolves it.

**Suppression is global.** An opt-out or hard bounce is recorded against the
contact, not the subscription, so it applies across every tenant that has ever
mailed the address, and it retracts anything still queued — except sign-in
links, which are transactional.

**Billing is the gate.** The public feed, embed and hosted articles resolve
only while `billing_status` is `active`.

Payments run on PayPal, using the **same PayPal application as csuite_finder** —
`PAYPAL_CLIENT_ID`, `PAYPAL_CLIENT_SECRET` and `PAYPAL_WEBHOOK_ID` name the same
credentials in both projects, so one app serves both. The $25/month plan is
created at PayPal on first use and cached in `paypal_plans`, keyed on the price,
so changing the price creates a new plan instead of silently billing the old
amount and existing subscribers stay on the plan they agreed to.

Subscribing returns a PayPal approval link; nothing is charged until the
customer approves, and `BILLING.SUBSCRIPTION.ACTIVATED` is what grants access.
PayPal has no hosted billing portal, so cancelling happens in the dashboard
(`POST /api/cancel`) and stops future renewals without ending the paid period.

Register a PayPal webhook at `https://<host>/webhooks/paypal` for the
`BILLING.SUBSCRIPTION.*` and `PAYMENT.SALE.COMPLETED` events, and put its id in
`PAYPAL_WEBHOOK_ID`. Without that id the signature check cannot pass and every
webhook is dropped — the correct failure, but a silent one, so check the log
after the first payment.

Leave the PayPal variables empty to run without payments: everything except
subscribing works, `/api/checkout` answers 503, and `/health` reports
`payments_configured: false`. Bad credentials are still a boot failure, since
they mean payments were meant to work and silently would not.

## Security notes

- CSRF is handled by an exact `Origin` match plus a `SameSite=Lax` session
  cookie. `POST /u/:token` is the one deliberate exception, so mail clients can
  use RFC 8058 one-click unsubscribe.
- PayPal webhooks are verified by posting the event back to PayPal's own
  verification endpoint. If that call fails the app answers 503 so PayPal
  retries, rather than dropping a real event or trusting an unverified one. The
  event id is the idempotency key.
- A webhook is applied to whichever tenant owns the subscription id, never to a
  tenant id read out of the event, so a forged `custom_id` cannot move someone
  else's subscription onto an attacker's account.
- Mailgun webhooks are verified by HMAC, with the shape checked first so
  `timingSafeEqual` is never handed mismatched buffers, and the event id is the
  idempotency key.
- Article URLs come from third-party feeds and are passed through `safeURL()`,
  which drops anything that is not http(s).
- Set `TRUST_PROXY=1` only when a proxy really is in front, or a client can
  spoof `X-Forwarded-For` and defeat the rate limits.

## Known limits

- Rate limiting uses per-process memory. Running more than one web process
  multiplies each limit; use a shared store before scaling out.
- Sending without confirmed opt-in puts a shared domain's reputation in every
  customer's hands. `src/services/campaign.service.mjs` already halts outbound
  campaigns on complaint and bounce rates; the same guard is worth extending to
  newsletter sends before the audience gets large.
- Story rewriting works from headline metadata only, never publisher text. Keep
  it that way: the prompt in `src/services/story.service.mjs` forbids inventing
  detail precisely because the model has not read the article.
- Ad targeting reads a reader's job title and industry, which makes those
  details an advertising input. That is disclosed on the privacy page and
  carries real GDPR/PECR duties for EU and UK recipients.
- `createCheckout` holds a tenant row lock across PayPal calls. That is what
  makes a double-clicked Activate button safe, but it ties up a pool
  connection for the duration.
- `src/views/legal/` is placeholder text and needs review for the real
  business.
- The design document this implementation came from is kept at
  [`docs/refactor-notes.md`](docs/refactor-notes.md).

## The editorial archive

1,818 articles imported from the Hugo site: 154 stories in 12 languages,
served at `/{language}/{topic}/{slug}/{yyyy-mm-dd}`.

**Locales are separate pages, deliberately.** Every translation is its own row
with its own URL; `translation_key` links the set so each page declares its
siblings with `hreflang` and points `canonical` at itself. That is what makes
twelve translations read as one article in twelve languages rather than twelve
duplicates competing with each other. English carries `x-default`.

**Every URL the Hugo site published still resolves.** The old paths had no date
segment, so an undated request — or one carrying a stale topic — answers `301`
to the canonical dated URL rather than 404ing. Nothing that used to work stops
working when the domain moves behind a CNAME.

The date in the URL comes from Postgres as a formatted string, never from a JS
`Date`. An article published at 18:11 UTC-7 is the *following day* in UTC, and
deriving the URL from `toISOString()` silently filed it under the wrong date —
`editorial.integration.test.mjs` has a fixture that catches exactly that.

Bodies are Markdown, rendered by `src/utils/markdown.mjs`: a small
deterministic renderer rather than a dependency, escaping everything before it
adds a single tag, so nothing in the content can introduce markup.

## Writing the journal

`npm run create-content` replaces the two scripts the Hugo site ran — the
Python crawler that wrote each section in English, and the Node script that
translated it into eleven more languages. Both stages now happen against the
database, for the same twelve sections.

Per section: discover a story that has not been covered, read the publisher's
article, write an original piece from it, then translate. The same guards as
the newsletter apply — `robots.txt` obeyed, the source dropped after writing,
and the result measured against the source for verbatim overlap. Here there is
**no headline-only fallback**: a journal piece written from a headline alone
would be worth nothing, so a rewrite that reads as a paraphrase is not
published at all.

`npm run translate` fills gaps. The Hugo import brought over 29 groups that
were only ever published in eight or ten of the twelve languages, and a
translation that fails mid-run leaves the same gap. It is safe to run
repeatedly and does nothing once the archive is complete. Run `--dry-run`
first: it is one model call per missing locale.

A translation copies its sibling's `issue_date` verbatim rather than deriving
one. Casting a timestamp to a date uses the session timezone, so an article
published at midnight UTC lands on the previous day in Los Angeles — and the
translation would then sit at a different URL from the article it translates,
breaking the hreflang set it belongs to.

## The daily report

`/brief/:id` is the day's issue laid out to be read and printed;
`/brief/:id/email` is the HTML that was actually mailed, kept as the record of
what a recipient received.

`content.json` holds every string that is words rather than code — the brand
name and tagline, the archive's heading and intros, and the report below. One
file to edit, no markup to touch.

The report is assembled from **`content.json`** — an ordered list of blocks
(`masthead`, `summary`, `note`, `stories`, `footer`) plus the words around
them, the accent colour and the page size. A new report variant is a config
change, not another template. The file is re-read when its mtime changes, so
editing copy is a save rather than a restart.

Everything in it is optional and everything falls back: a malformed
`content.json` logs and renders the defaults rather than failing a report
someone is waiting for. Colours are validated as colours, because the value
reaches a `<style>` block and anything else would be arbitrary CSS injected
through a config file.

The page carries `@page` sizing, `break-inside: avoid` on every story, and
`print-color-adjust`, and it loads no stylesheet, script or font — so a
headless browser can convert it with no network access:

```bash
chrome --headless --no-pdf-header-footer \
  --print-to-pdf=report.pdf http://localhost:3000/brief/<id>
```
