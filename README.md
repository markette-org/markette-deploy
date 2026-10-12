# Markette: deploy

Self-host [Markette](https://github.com/markette-org): this repository has everything to run it with Docker.
The rest of this page describes the whole system: architecture, scheduling, networks and configuration.

**Setting up your own server?** Start with the [self-hosting guide](SELF_HOSTING.md): install, first sign-in,
and where to find the keys for every network, AI provider and Stripe.


Multi-tenant publishing for social networks and websites: write once, tailor per channel,
schedule precisely, and measure what each post did. Like Mixpost, plus a real scheduler, a
best-time engine learned from your own metrics, and optional AI assistance (through OpenRouter or any
OpenAI-compatible API) for timing, campaign planning and per-network copy.

| Kind | Destinations |
|---|---|
| Social | X, Threads, Bluesky, Mastodon (any instance), LinkedIn (members, and company pages via the Community Management API), Facebook Pages, Instagram professional accounts, YouTube (video uploads and Shorts), Telegram channels and groups (Bot API), Discord (channel webhooks), Slack (public and private channels, through a bot token or "Add to Slack"), WhatsApp broadcast lists (Cloud API templates), QQ groups and QQ Guild channels (bot API) |
| Newsletters | Brevo and Listmonk (one channel per mailing list; each post becomes an email campaign) |
| Integrations | Generic signed webhook: every post as JSON to n8n, Make, Zapier or your own code |
| Sites | WordPress (REST API with application passwords), Drupal (JSON:API), Ghost (posts, optionally emailed to members), Medium (integration token; see below), DEV / dev.to and other Forem communities (API key), WeChat Official Accounts (articles), Hugo (git: page bundle commit + push) |

## Architecture

```
Angular 21 SPA ──/api──▶ Django 6 + DRF ──▶ PostgreSQL
 (frontend/)               │   ▲
                           ▼   │
                     Redis ◀── Celery beat  (scheduler tick, metrics, token refresh, best-time rebuild)
                           └──▶ Celery workers (publish, collect metrics)
```

Backend apps (`backend/apps/`):

- **tenants**: organizations (the customer account, with plan limits and an active/suspended status),
  the workspaces inside them (one per brand or client; archived workspaces are read-only), org roles
  `owner > admin > member`, workspace roles `owner > admin > editor > viewer`, and invitations to either.
  Org owners and admins act as workspace owners and admins in every workspace of the organization. Every
  tenant-scoped request carries `X-Workspace: <slug>`, and querysets are filtered by it in one mixin
  (`tenancy.py`).
- **teams**: publishing teams inside a workspace. A channel assigned to teams can be seen and used only by
  those teams' members (and workspace admins), while unassigned channels stay open to everyone. A team can
  require approval: its members' scheduling waits until one of the team's reviewers approves or requests
  changes (`publishing/approval.py`, with an audit trail in `PostReview`). Teams can also have their own queue
  slots.
- **platform**: the superadmin console API (`/api/platform/`). It covers overview, organizations and
  limits, users, publishing health and AI usage and cost. Grant it with
  `python manage.py make_superadmin <email>`.
- **channels**: a connected destination with Fernet-encrypted credentials. Channels belong to the
  organization and are shared with one or more of its workspaces (`ChannelAccess`), so several brands or
  teams can publish to the same account. The gap between posts is enforced per channel across workspaces. `providers/` holds one class per
  network behind a single contract (`base.py`): connect (OAuth2/PKCE or credentials), validate, publish,
  fetch metrics, fetch audience, delete. Errors are classified as *retryable* (rate limits, 5xx, network),
  *auth* (the channel is flagged for reconnection) or *permanent*.
- **publishing**: a `Post` fans out to one `PostTarget` per channel. Each target has its own copy, media,
  options, time, outcome and latest metrics.
- **analytics**: `MetricSnapshot` series per publication and daily `AudienceSnapshot` per channel.
- **insights**: the best-time engine and the AI integration.

### Scheduling

Every target gets its own `scheduled_at`, chosen by one of these modes:

| Mode | How the time is chosen |
|---|---|
| `now` | Immediately. |
| `exact` | A time you pick (interpreted in the workspace time zone by the UI). |
| `queue` | The next free weekly slot (per channel, or workspace-wide). |
| `best_time` | The best-scoring free hour for *that* channel within a window, keeping `min_gap_minutes` from other posts on the channel. |
| per-target pins | The calendar and AI suggestions can pin individual channels to individual times. |

Celery beat runs `dispatch_due_targets` every `SCHEDULER_TICK_SECONDS` (default 15 s). It claims due
targets with `SELECT … FOR UPDATE SKIP LOCKED`, so several schedulers or workers never double-publish, and
hands them to workers. Transient failures back off exponentially, or for as long as the network's
`Retry-After` says, up to `PUBLISH_MAX_ATTEMPTS`.

Locking stops two workers from sending the same publication, but not a network that publishes the post and
then loses its answer (a timeout after the request was sent, a dropped connection, a 502/504 from a gateway,
or a worker that dies mid-call). Markette never retries those blindly:

- **Mastodon** sends a stable `Idempotency-Key`, so the server drops a repeat (for one hour).
- **Drupal** posts get a UUID derived from the publication, so the earlier node is read back by its ID.
- **DEV, Bluesky, WordPress, Slack and LinkedIn pages** look for the earlier post first (latest articles,
  repository records, posts, channel messages or page posts) and adopt it instead of publishing again.
  Slack needs the `channels:history`/`groups:history` scopes for this. If the check itself is refused,
  the publication goes to *unconfirmed* rather than being published again.
- **Every other network** marks the publication *unconfirmed* ("Needs checking"). That covers X, LinkedIn
  profiles, Discord webhooks, Telegram and the rest: they cannot read your own posts back, or not without
  paid API access. Nothing retries it, not
  even *Retry failed*. Publications waiting for it keep waiting. On the post's page someone checks the network
  and answers either *It is live*, optionally pasting its address (needed when others link to it), or *It is
  not there: publish again*. The post's other channels are not touched.

A request that never reached the network (connection refused, connect timeout) is always a plain retry.
So is a lost answer while refreshing a login token or uploading media (steps marked `@repeatable`, which
put nothing online).

### Announcing a publication elsewhere

A publication can **wait for** another one, in the same post or in any other post of the workspace, and link
to it. Example: announce a DEV or WordPress article on X and Bluesky. Once the article is live, the waiting
publications are scheduled (right after it, after a delay, in the next queue slot or at the best time). Their
text gets the article's address in place of `{url}` and its title in place of `{title}`. Without `{url}`, the
address is added at the end. Choose this in the composer, in each channel's tab ("Wait for another
publication"), or click **Announce** on a publication in the post page. Through the API, set a target's `follows`
(a target id) or `follows_channel` (another channel of the same post), plus `follow_mode` and `follow_delay`
(minutes); the MCP tool `create_post` takes `follows_target_id`.

If the article fails, its followers keep waiting and go out when it is retried. If it is cancelled or deleted,
they fail with an explanation.

### Notifications: email, Telegram status bot, webhooks

Under **Settings → Notifications**, workspace admins add destinations and choose their events:

| Event | When |
|---|---|
| `publication.published` | A channel's publication went live (with its address). |
| `post.published` | Every channel of a post is live. |
| `publication.failed` | A publication gave up, or a waiting announcement lost its source. |
| `publication.unconfirmed` | A network may have published it but did not confirm ("Needs checking"). |
| `channel.needs_reconnect` | A channel's authorization expired or was revoked (sent once). |
| `approval.requested` / `approval.approved` / `approval.changes_requested` | The review workflow. |
| `digest.daily` | 8:00 in the workspace's time zone: yesterday's results and today's plan. |

- **Email** goes to the listed addresses, or to the workspace's admins and owners. It needs SMTP settings
  on the server (`EMAIL_HOST`…, or Platform → Settings → Email).
- **Telegram status bot**: create a bot with @BotFather, send it a message (or add it to a group, or as an
  admin to a channel), paste the token and pick the chat. Markette lists the chats the bot has seen.
- **Webhooks** POST JSON (`{"id", "event", "created_at", "workspace", "data"}`) with the headers
  `X-Markette-Event`, `X-Markette-Delivery`, `X-Markette-Timestamp` and
  `X-Markette-Signature: sha256=HMAC_SHA256(secret, "{timestamp}.{body}")`. The signing secret is shown
  once when the webhook is created (and when it is replaced). Verify it, and reject old timestamps.

Failed deliveries are retried for about 8 hours (1 min, 5 min, 30 min, 2 h, 6 h). A destination that
fails 20 times in a row is switched off. Each one has a delivery log and a **Send a test** button.

### Threads

On **X, Bluesky, Mastodon and Threads**, a channel's *Post as a thread* option (target option `thread`)
turns text longer than the network's limit into a chain of replies instead of refusing it. Lines made only of
`---` mark where posts break; otherwise Markette breaks between paragraphs, then sentences, then words. Each
post ends with `i/n` (turn off with `thread_numbering: false`). Images go on the first post. The composer shows
how many posts it will make, counted the network's way.

The first post goes through the normal publishing path (retries, duplicate guards). The replies follow right
away, and progress is saved after each one. If a reply fails, the publication stays *published* with a note,
and the post page offers **Continue the thread**, which picks up from the last post that went out.

### Link tracking (UTM tags and short links)

In **Settings → Workspace → Link tracking**, admins can turn on, for social posts only (blogs and newsletters
keep clean canonical links):

- **UTM tags**: `utm_source` (the network, e.g. `bluesky`), `utm_medium` (default `social`), `utm_campaign`
  (the post's campaign, or `markette`) and `utm_content` (`post-<id>`). Parameters already in a link win.
- **Short links**: `{SHORT_LINK_BASE}/l/<code>`, one per publication and link, redirecting to the (tagged)
  address. Clicks are counted per publication and per day, without link previews and crawlers. They show on
  the post's page and as *Link clicks* in Analytics.

Only links to **your sites** are touched: the domains listed there (subdomains included), or, when none are
listed, the post's own link. That includes the address an announcement points to. `SHORT_LINK_BASE` defaults
to `PUBLIC_API_URL`; point a short domain at the API and set it to get shorter links.

### Best time to post

`insights/engine.py` keeps a 7×24 grid of scores (weekday × local hour) per channel:

1. **Prior:** a per-platform activity curve, so new channels get sensible defaults.
2. **Evidence:** the engagement rate of each post from the last 180 days, measured at the snapshot
   closest to 24 h. Engagement rate is engagements / impressions, or engagements / followers when the
   network does not report impressions.
3. **Blend:** in log space, each bucket is pulled towards "the channel's average, nudged by the prior". The
   pull weakens as more posts land in the bucket, so a channel's own data wins once it has enough history.

The UI shows the source of each grid: platform defaults, blended, or your data.

### AI assistance (optional)

AI assistance goes through the OpenAI SDK, pointed at one of two providers (`insights/ai.py`):

- **OpenRouter** (`AI_PROVIDER=openrouter`, the default): one key for hundreds of models. The default model
  is `openrouter/auto`, and OpenRouter reports the real cost of each call.
- **Any OpenAI-compatible API** (`AI_PROVIDER=openai_compatible` plus `AI_BASE_URL`): OpenAI, Azure OpenAI,
  vLLM, Ollama, LM Studio, LiteLLM, etc. Local servers usually need no key.

Answers are requested as JSON validated against a schema. If the server doesn't support `json_schema`,
Markette falls back to JSON mode and then to instructions alone (`AI_STRUCTURED_OUTPUT`). Every call is
logged in `AIRequest` with its token usage and cost. Superadmins configure all of this in
Platform → Settings, including a "Test key" check.

- **Suggest times:** the model receives the engine's best free moments, the calendar, the campaign and the
  content (so it can respect a deadline it mentions), and picks a time and gives a reason for each channel.
  Every time it proposes is checked against the window and the minimum gap. An invalid time falls back to
  the engine.
- **Plan campaign:** an arc of posts over a period, with copy adapted to each network, which you can then
  create as drafts or schedule.
- **Adapt:** rewrites one text for each network's length and conventions, and flags any variant over its
  character limit.

Without an AI provider, all scheduling still works and suggestions come from the engine.

### First comments

LinkedIn, Facebook and Instagram can post a **first comment** right after the post. With "move links to
the first comment" (per post, or as a channel default), URLs are taken out of the post text, the link
card is dropped, and the links go into the comment. LinkedIn shows posts with outbound links to fewer
people. If the comment fails, the post stays published, and the failure is reported but never retried.

### Single sign-on (per organization)

Organization owners configure OpenID Connect in Organization → Single sign-on. It works with Google
Workspace, Microsoft Entra ID, Okta, Keycloak, Auth0 and others.

1. Register Markette at the identity provider with the redirect URI `{PUBLIC_API_URL}/api/auth/sso/callback/`,
   then enter the issuer URL, client ID and secret.
2. Claim the email domains, and prove ownership with the DNS TXT record shown. Public mail domains can't
   be claimed.
3. Optionally create accounts automatically (default org role and workspace), and **enforce** SSO so
   password sign-in is refused for those domains. Superadmins keep password access.

Sign-in uses the authorization-code flow with PKCE, state and nonce. Each ID token's signature (from the
provider's published keys), issuer, audience and expiry are checked. The browser receives a one-time ticket
that it exchanges for its tokens.

### Billing (Stripe)

The `billing` app sells plans through Stripe. A plan carries the same limits as an organization
(workspaces, channels, members, monthly AI tokens), where an empty limit means **unlimited**, so an
"Unlimited AI" plan is a plan with no `ai_monthly_tokens`.

1. In Platform → Settings → Billing, paste the Stripe secret key.
2. In Stripe → Developers → Webhooks, add `{PUBLIC_API_URL}/api/billing/webhook/` with the events
   `checkout.session.completed` and `customer.subscription.created`/`updated`/`deleted`, then paste the
   signing secret into the same settings section.
3. In Platform → Plans, create the plan and click "Create Stripe price".

Org owners subscribe from the organization page through Stripe Checkout, and manage or cancel in the
Stripe Customer Portal. Webhooks are signature-checked and idempotent. While a subscription is active,
trialing or past due, the plan's limits are applied to the organization. When it ends, the platform
default limits come back.

### MCP server

`mcp_server/` exposes Markette to AI assistants over the Model Context Protocol. It runs as its own
container and is served at `{PUBLIC_API_URL}/mcp` (Streamable HTTP), or over stdio with
`python -m mcp_server`. Users create a personal API token (`mkt_…`) in Settings → API & MCP. Every tool
call runs as that user through the REST API, so workspace roles, team channel access and approvals all
apply.

Tools:
- `list_workspaces`, `list_channels`;
- `list_posts`, `get_post`, `create_post`, `validate_post`, `schedule_post`, `unschedule_post`;
- `review_post`;
- `get_calendar`, `get_best_times`, `suggest_times`, `get_analytics`.

To connect Claude Code:

```bash
claude mcp add --transport http markette https://your-host/mcp --header "Authorization: Bearer mkt_…"
```

### Metrics

Metrics are pulled 1 h, 6 h, 24 h, 3 d, 7 d and 30 d after publishing, and audience size is pulled daily.
What each network exposes differs:

| Network | Metrics |
|---|---|
| X | impressions, likes, replies, reposts + quotes, bookmarks (link clicks with user-context tokens) |
| Bluesky | likes, replies, reposts + quotes |
| Mastodon | favourites, replies, boosts |
| LinkedIn | reactions, comments; for pages also impressions, unique impressions, clicks, shares |
| Facebook | reactions, comments, shares; impressions, reach, clicks when Page insights are available |
| Instagram | likes, comments, reach, views, saves, shares |
| Telegram | member count only (the Bot API has no per-post statistics) |
| WhatsApp | delivered and read per broadcast (from the Cloud API webhook), active subscribers |
| WeChat, QQ | follower count (WeChat); no per-post statistics |
| Threads | views, likes, replies, reposts + quotes + shares; followers |
| YouTube | views, likes, comments; subscribers |
| Brevo / Listmonk | delivered (sent), unique opens, unique clicks; list size |
| Ghost | emails delivered and opened; members |
| Slack | member count only (no per-post statistics) |
| Discord, Webhook | none |
| WordPress / Drupal | approved comments |
| Medium | none (Medium's API has no statistics) |
| DEV (Forem) | page views, reactions, comments; followers (personal accounts) |
| Hugo | none (add your site analytics) |

## Running it

### With Docker (recommended)

```bash
git clone https://github.com/markette-org/markette-deploy.git && cd markette-deploy
cp .env.example .env        # set DJANGO_SECRET_KEY, CREDENTIALS_KEY, PUBLIC_API_URL, FRONTEND_URL…
docker compose up -d        # pulls ghcr.io/markette-org/markette-{server,web}
docker compose exec api python manage.py createsuperuser
docker compose exec api python manage.py make_superadmin you@example.org
```

Open `http://localhost:8080` (or `WEB_PORT`). Run exactly one `beat` container; scale `worker` freely.
Put it behind a TLS-terminating proxy for production: OAuth providers, Stripe live mode and the
mobile apps expect HTTPS.

### Web app on GitHub Pages, API on its own domain

The hosted setup (markette.org) splits the two:

- **app.markette.org** — the Angular app on GitHub Pages, published by the
  [Pages workflow](https://github.com/markette-org/markette-web/blob/main/.github/workflows/pages.yml)
  of markette-web (custom domain set in the repository's Pages settings). Pages cannot proxy, so the
  build calls `MARKETTE_API_ORIGIN` (default `https://api.markette.org`) directly, cross-origin.
  The [Netlify workflow](https://github.com/markette-org/markette-web/blob/main/.github/workflows/netlify.yml)
  publishes optional pull-request previews; Netlify proxies `/api` and the other server paths, so
  previews need no CORS entry.
- **api.markette.org** — this compose stack. On a host where Traefik runs in Swarm mode,
  `traefik/docker-stack.yml` adds a small nginx service on Traefik's network that forwards to the
  stack's web port (Traefik only routes Swarm services):

```bash
EDGE_PLACEMENT='node.hostname == <this host>' MARKETTE_UPSTREAM=http://<host-ip>:8085 \
  docker stack deploy -c traefik/docker-stack.yml markette-edge
```

Then set in `.env`: `PUBLIC_API_URL=https://api.markette.org`, `FRONTEND_URL=https://app.markette.org`,
both hosts in `DJANGO_ALLOWED_HOSTS`, both origins in `DJANGO_CSRF_TRUSTED_ORIGINS`, and
`CORS_ALLOWED_ORIGINS=https://app.markette.org` (required: the app calls the API cross-origin). OAuth callbacks are `https://api.markette.org/api/oauth/<network>/callback`.

### From source

Clone the repositories side by side and build the images locally:

```bash
git clone https://github.com/markette-org/markette-server.git
git clone https://github.com/markette-org/markette-web.git
git clone https://github.com/markette-org/markette-deploy.git && cd markette-deploy
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

For development without Docker, see the READMEs of
[markette-server](https://github.com/markette-org/markette-server) and
[markette-web](https://github.com/markette-org/markette-web).

### Mobile apps

[markette-mobile](https://github.com/markette-org/markette-mobile) builds the Android and iOS apps.
Copy a built `markette.apk` into `downloads/` to offer it at `/downloads/markette.apk`.

## Connecting networks (server admin, once)

Step-by-step instructions for each network are in the [self-hosting guide](SELF_HOSTING.md#5-networks-that-need-a-server-app-server-admin-once).

Register these OAuth callback URLs (`PUBLIC_API_URL` must be the public HTTPS URL of the API):

| Network | Where | Callback / notes |
|---|---|---|
| X | developer.x.com → app → User authentication (OAuth 2.0, Web App) | `…/api/oauth/x/callback`. Posting needs a paid API tier. Scopes: `tweet.read tweet.write users.read media.write offline.access`. |
| LinkedIn | linkedin.com/developers | `…/api/oauth/linkedin/callback`. Add the products *Sign In with LinkedIn using OpenID Connect* and *Share on LinkedIn*. Company pages need *Community Management API*; then set `LINKEDIN_ORG_SCOPES=true`. |
| Facebook + Instagram | developers.facebook.com (Business app) | `…/api/oauth/facebook/callback` (Instagram uses the same one). Permissions: `pages_show_list, pages_read_engagement, pages_manage_posts, read_insights, business_management, instagram_basic, instagram_content_publish, instagram_manage_insights`. Requires App Review for other users. |
| Mastodon | nothing to do | An app is registered automatically on each instance. |
| Bluesky | nothing to do | Users enter their handle and an app password. |
| Telegram | channel/group admin | Create a bot with @BotFather. Add it to the channel as an administrator with *Post messages* (and *Pin messages* to pin), or to the group as a member. Then paste the bot token; leave the chat empty to pick from the chats the bot was added to. |
| WordPress | nothing to do | Users enter site URL, username and an application password. |
| Drupal | site admin | Enable JSON:API with write operations allowed (`/admin/config/services/jsonapi`). Enable HTTP Basic Auth or Simple OAuth. |
| WhatsApp | Meta Business | WhatsApp Business Account, phone number, permanent system-user token, and an approved MARKETING template whose body is `{{1}}` (optional IMAGE header). Webhook: `{PUBLIC_API_URL}/api/channels/whatsapp/webhook/` with the per-channel verify token, subscribed to `messages`; set `META_APP_SECRET` for signature checks. WhatsApp Channels have no API; groups via API are limited to 8 people, so broadcasts go to opted-in subscribers (JOIN / STOP). |
| WeChat | Official Account owner | A **verified** Official Account (unverified/personal accounts can only create drafts via API). Add the server IP to 设置与开发 → 基本配置 → IP白名单. Mode *push* uses the mass-send quota; *publish* gives a permanent link without notifying followers. |
| QQ | QQ Open Platform | Create a bot at q.qq.com, set its callback URL to `{PUBLIC_API_URL}/api/channels/qq/webhook/<AppID>/`. Groups: add the bot, @-mention it once, and the group owner must enable 「机器人主动在群聊内发言」 (proactive group messages, since 2026-06). QQ refuses links in group messages. Guild text channels are listed automatically. |
| Threads | developers.facebook.com | A Meta app with the **Threads** use case; set `THREADS_APP_ID`/`THREADS_APP_SECRET` (or Platform → Settings) and the redirect URI `…/api/oauth/threads/callback`. Permissions: threads_basic, threads_content_publish, threads_manage_insights, threads_manage_replies. 500 characters, ≤5 links, 250 posts/24 h. |
| Reddit | reddit.com/prefs/apps (after approval under Reddit's Responsible Builder Policy) | `…/api/oauth/reddit/callback`, app type *web app*. Set `REDDIT_CLIENT_ID`, `REDDIT_CLIENT_SECRET` and a descriptive `REDDIT_USER_AGENT`. Scopes: `identity submit read mysubreddits flair edit`. |
| YouTube | console.cloud.google.com | Enable YouTube Data API v3, create a Web OAuth client with redirect `…/api/oauth/youtube/callback`, set `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET`. **Uploads stay private until the project passes YouTube's API audit.** |
| Discord | server admin | Channel → Integrations → Webhooks → copy the URL. |
| Slack | workspace member who can install apps | Without a server app: create an app at api.slack.com/apps, add the bot scopes `chat:write, chat:write.public, channels:read, channels:join, groups:read, channels:history, groups:history, files:write, files:read, team:read`, install it to the workspace and paste the *Bot User OAuth Token* (`xoxb-…`). Optional server app for *Add to Slack*: the same scopes, redirect URL `…/api/oauth/slack/callback`, public distribution on, and `SLACK_CLIENT_ID`/`SLACK_CLIENT_SECRET` (or Platform → Settings). Every public channel can be added; private channels after adding the app to them. |
| Ghost | site owner | Settings → Integrations → custom integration → Admin API key; optionally a newsletter slug to email posts. |
| Brevo | account owner | API key and a verified sender; each contact list becomes a channel. |
| Listmonk | instance admin | Admin → Users → API user + token; each list becomes a channel. |
| Webhook | you | Any URL accepting POST JSON; verify `X-Markette-Signature` = sha256 HMAC of `<X-Markette-Timestamp>.<body>` with the channel's signing secret. |
| Medium | nothing to do | Users paste an existing integration token. Medium stopped issuing new tokens in 2023 and no longer supports the API; it can create posts (to a profile or a publication, with a canonical URL) but not edit, delete or read stats. |
| DEV (Forem) | nothing to do | Users paste an API key (dev.to → Settings → Extensions → DEV Community API Keys); optionally an organization username, or another Forem community's address. Images are linked from `/media/`, so it must be public. Deleting unpublishes the article (the API cannot delete). |
| Hugo | repo owner | A token with push rights (e.g. GitHub fine-grained token, *Contents: read & write*) or a deploy key with write access. Your CI builds and deploys the site on push. |

Instagram and Facebook fetch media by URL, so `/media/` must be reachable from the internet. The bundled
nginx proxies it, or you can put a CDN in front.

## Configuration

See `.env.example`. These settings matter in production:

- `DJANGO_SECRET_KEY`: required when `DJANGO_DEBUG=false`.
- `CREDENTIALS_KEY`: the Fernet key that encrypts channel tokens. Back it up: if it is lost, every channel
  has to be reconnected.
- `PUBLIC_API_URL`, `FRONTEND_URL`: used for OAuth redirects and public media URLs.
- `SCHEDULER_TICK_SECONDS`: scheduler precision (default 15).
- `AI_PROVIDER`, `AI_BASE_URL`, `AI_API_KEY`, `AI_MODEL`: the AI provider (OpenRouter by default).

## License

Markette is free software under the [GNU Affero General Public License v3.0](LICENSE). If you run a
modified version as a service, you must offer its source code to your users.
