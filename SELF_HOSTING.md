# Self-hosting Markette: getting started

This guide takes you from an empty server to a working Markette, then explains, service by service,
where to find each key and where to put it. The [README](README.md) describes how the system works;
this page is the checklist.

**Contents**

1. [Before you start](#1-before-you-start)
2. [Install](#2-install)
3. [First sign-in](#3-first-sign-in)
4. [Where settings live](#4-where-settings-live)
5. [Networks that need a server app](#5-networks-that-need-a-server-app-server-admin-once): X, LinkedIn,
   Facebook and Instagram, Threads, YouTube, Reddit, Slack (optional)
6. [Networks where each user brings a key](#6-networks-where-each-user-brings-a-key): Mastodon, Bluesky,
   Telegram, Discord, Slack, WhatsApp, QQ, WeChat, WordPress, Drupal, Ghost, Medium, DEV, Hugo, Brevo,
   Listmonk, webhook
7. [AI assistance](#7-ai-assistance-optional)
8. [Billing with Stripe](#8-billing-with-stripe-optional)
9. [Single sign-on](#9-single-sign-on-optional)
10. [MCP server and mobile apps](#10-mcp-server-and-mobile-apps)
11. [Production checklist](#11-production-checklist)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Before you start

You need:

- A Linux server with Docker and the Compose plugin. Two CPUs and 2 GB of RAM are enough for a small
  team; video uploads need more disk space.
- A domain name, with HTTPS in front of Markette. Most networks refuse OAuth redirects to plain `http://`
  addresses (only `localhost` is sometimes allowed), and Stripe live mode and the mobile apps need HTTPS
  too. Any reverse proxy works: Caddy, Traefik, nginx with Let's Encrypt, or a tunnel.
- The `/media/` path must be reachable from the internet, because Instagram, Facebook and Threads
  download the images and videos from your server instead of receiving them, and DEV articles link to them.

Choose one of two layouts:

| Layout | Example | Notes |
|---|---|---|
| **One domain** (simplest) | `https://markette.example.org` | The `web` container serves the app and proxies `/api`, `/media` and `/mcp` to the server. `PUBLIC_API_URL` and `FRONTEND_URL` are the same address. |
| **Two domains** | `https://app.example.org` + `https://api.example.org` | For example, the app on GitHub Pages and the API on your server. See [the README](README.md#web-app-on-github-pages-api-on-its-own-domain). The app calls the API cross-origin, so CORS must be set. |

Every OAuth callback has the form `{PUBLIC_API_URL}/api/oauth/<network>/callback`, so decide on the final
address **before** you register apps with the networks. Changing it later means editing every app.

Markette sends no email. Invitations are links that you copy and send yourself.

## 2. Install

```bash
git clone https://github.com/markette-org/markette-deploy.git
cd markette-deploy
cp .env.example .env
```

Edit `.env`. Only these settings are required:

| Setting | What to put |
|---|---|
| `DJANGO_SECRET_KEY` | A long random string: `openssl rand -base64 48` |
| `CREDENTIALS_KEY` | The key that encrypts every channel token: `openssl rand -base64 32 \| tr '+/' '-_'`. **Back it up.** If you lose it, every channel has to be connected again. |
| `DJANGO_DEBUG` | `false` |
| `PUBLIC_API_URL` | The public HTTPS address of the API, e.g. `https://markette.example.org` (no trailing slash) |
| `FRONTEND_URL` | The address people open. The same as above for one domain. |
| `DJANGO_ALLOWED_HOSTS` | The host names, comma separated, e.g. `markette.example.org` (keep `api` if you use the bundled `web` container: `markette.example.org,api`) |
| `DJANGO_CSRF_TRUSTED_ORIGINS` | The origins with scheme, e.g. `https://markette.example.org` |
| `POSTGRES_PASSWORD` | A password for the bundled database |

For two domains, also set `CORS_ALLOWED_ORIGINS=https://app.example.org`, and list both hosts and both
origins in the two settings above.

Start it and create your account:

```bash
docker compose up -d
docker compose exec api python manage.py createsuperuser
docker compose exec api python manage.py make_superadmin you@example.org
```

The `web` container listens on port 8080 (change it with `WEB_PORT`). Point your HTTPS proxy at it.
Run exactly one `beat` container. You can add more `worker` containers.

To update: `docker compose pull && docker compose up -d`. Migrations run automatically. Pin a version with
`MARKETTE_VERSION=<tag>` in `.env`.

## 3. First sign-in

1. Open `FRONTEND_URL` and sign in with the account you just created.
2. Create your organization and first workspace.
3. Open **Platform → Settings**, which only superadmins see. It shows the exact callback URL to register
   for each network, built from your `PUBLIC_API_URL`, and has fields for the app keys. Use it while you
   follow section 5.
4. In **Channels → Connect**, networks whose server app is missing appear locked with "Server admin must add
   API credentials". Networks from section 6 work right away.

## 4. Where settings live

Every network key and AI setting can be set in either of two places:

- **`.env`**: read at start-up. After editing it, run `docker compose up -d` to apply.
- **Platform → Settings**: stored in the database and applied within about 15 seconds, with no restart.
  These **override** `.env`. Secrets (client secrets, API keys) are write-only: once saved, they are never
  shown again, only whether they are set and where they come from.

Channel tokens that users enter when they connect are encrypted with `CREDENTIALS_KEY`, and are never
returned by the API.

## 5. Networks that need a server app (server admin, once)

For these networks you register **one** app for your whole installation. Users then click **Connect** and
approve access at the network. For each one, the table at the top gives the callback to register (with
your `PUBLIC_API_URL` in front) and the settings to fill in.

| Network | Callback | Settings | Review or cost |
|---|---|---|---|
| X | `/api/oauth/x/callback` | `X_CLIENT_ID`, `X_CLIENT_SECRET` | Posting needs a paid API tier |
| LinkedIn | `/api/oauth/linkedin/callback` | `LINKEDIN_CLIENT_ID`, `LINKEDIN_CLIENT_SECRET` (+ `LINKEDIN_ORG_SCOPES`) | Company pages need Community Management API approval |
| Facebook + Instagram | `/api/oauth/facebook/callback` | `META_APP_ID`, `META_APP_SECRET` | App Review and business verification before other people can connect |
| Threads | `/api/oauth/threads/callback` | `THREADS_APP_ID`, `THREADS_APP_SECRET` | App Review before other people can connect |
| YouTube | `/api/oauth/youtube/callback` | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Uploads stay private until the API audit is passed |
| Reddit | `/api/oauth/reddit/callback` | `REDDIT_CLIENT_ID`, `REDDIT_CLIENT_SECRET`, `REDDIT_USER_AGENT` | New apps need Reddit's approval |
| Slack (optional) | `/api/oauth/slack/callback` | `SLACK_CLIENT_ID`, `SLACK_CLIENT_SECRET` | None. Without it, users paste a bot token. |

Networks review apps on their own schedules, which can take days or weeks. Until an app is approved,
it usually works only for the accounts listed as its admins, developers or testers, which is enough to try
Markette yourself.

### X

1. Sign in at [developer.x.com](https://developer.x.com) and open the **Developer Portal**. Create a
   project and an app inside it. Posting needs a paid access tier (Basic or above); the free tier cannot
   publish reliably.
2. In the app, open **User authentication settings → Set up**:
   - App permissions: **Read and write**
   - Type of App: **Web App, Automated App or Bot** (a confidential client)
   - Callback URI: `{PUBLIC_API_URL}/api/oauth/x/callback`
   - Website URL: your `FRONTEND_URL`
3. Save. Under **Keys and tokens → OAuth 2.0 Client ID and Client Secret**, copy both. The secret is
   shown once; regenerate it if you lose it.
4. Set `X_CLIENT_ID` and `X_CLIENT_SECRET`.

Markette asks for the scopes `tweet.read tweet.write users.read media.write offline.access`.

### LinkedIn

1. At [linkedin.com/developers/apps](https://www.linkedin.com/developers/apps), click **Create app**. It
   must be linked to a LinkedIn company page; an admin of that page confirms the link.
2. On the **Products** tab, add **Sign In with LinkedIn using OpenID Connect** and **Share on LinkedIn**.
   Both are granted immediately.
3. On the **Auth** tab, add the redirect URL `{PUBLIC_API_URL}/api/oauth/linkedin/callback`, then copy the
   **Client ID** and **Primary Client Secret**.
4. Set `LINKEDIN_CLIENT_ID` and `LINKEDIN_CLIENT_SECRET`.
5. Company pages are optional. Request the **Community Management API** product. LinkedIn reviews it
   and expects a registered business with a privacy policy. Once it is approved, set
   `LINKEDIN_ORG_SCOPES=true`, and users who are page admins can add their pages.

`LINKEDIN_API_VERSION` (format `YYYYMM`) selects LinkedIn's versioned API. LinkedIn retires versions
after about a year, so raise it if posting starts failing with a version error.

### Facebook Pages and Instagram

Facebook and Instagram share one Meta app and one callback.

1. At [developers.facebook.com/apps](https://developers.facebook.com/apps), create an app of type
   **Business** (or, in the newer flow, choose the use cases for managing Pages and Instagram content).
2. Add the products **Facebook Login for Business** (or Facebook Login) and **Instagram** (Instagram API
   with Facebook Login).
3. In **Facebook Login → Settings**, add the valid OAuth redirect URI
   `{PUBLIC_API_URL}/api/oauth/facebook/callback`.
4. In **App settings → Basic**, copy the **App ID** and **App secret**. Fill in the privacy policy URL and
   app domain, which Meta requires before going live.
5. Set `META_APP_ID` and `META_APP_SECRET`. `META_GRAPH_VERSION` defaults to a recent Graph API version.
6. Permissions requested: `pages_show_list, pages_read_engagement, pages_manage_posts, read_insights,
   business_management, instagram_basic, instagram_content_publish, instagram_manage_insights,
   instagram_manage_comments`.
7. While the app is in **development mode**, only people with a role on the app can connect. For
   everyone else: complete **Business verification**, request **Advanced access** for these permissions in
   **App Review** (with a screencast of the flow), then switch the app to **Live**.

Instagram accounts must be professional (Business or Creator) and linked to a Facebook Page. Meta fetches
media from `{PUBLIC_API_URL}/media/…`, so that path must be public.

The same `META_APP_SECRET` also verifies WhatsApp webhook signatures (see WhatsApp below).

### Threads

1. In a Meta app (a new one, or the same one), add the use case **Access the Threads API**.
2. In that use case's **Settings**, set the redirect callback URL to
   `{PUBLIC_API_URL}/api/oauth/threads/callback`. Meta asks for uninstall and delete callback URLs too;
   you can use the same address.
3. Copy the **Threads app ID** and **Threads app secret** shown there. They differ from the main
   app ID.
4. Set `THREADS_APP_ID` and `THREADS_APP_SECRET`.
5. Permissions: `threads_basic, threads_content_publish, threads_manage_insights, threads_manage_replies`.
   Add your Threads account as a tester (**App roles → Roles → Threads Testers**, then accept the invitation
   in Threads → Settings → Account → Website permissions) to test before App Review.

### YouTube

1. In [console.cloud.google.com](https://console.cloud.google.com), create a project and enable
   **YouTube Data API v3** (APIs & Services → Library).
2. Configure the **OAuth consent screen**: External, with app name, support email, privacy policy and
   authorized domain. Add the scopes `youtube.upload` and `youtube.readonly`. While the app is in
   **Testing**, add the Google accounts that will connect as **test users**.
3. Go to **Credentials → Create credentials → OAuth client ID**, choose **Web application**, and add
   the authorized redirect URI `{PUBLIC_API_URL}/api/oauth/youtube/callback`.
4. Copy the **Client ID** and **Client secret** into `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`.
5. Videos uploaded by unverified projects are locked to **private**. To publish publicly: publish the
   consent screen and get it verified, which is needed because `youtube.upload` is a sensitive scope. Then
   request the **YouTube API Services audit**. The default quota allows about six uploads a day; ask for
   more in the same audit form.

### Reddit

1. Reddit no longer gives out API access on request. Read the **Responsible Builder Policy** and submit a
   data access request; commercial use needs Reddit's written approval.
2. Once approved, go to [reddit.com/prefs/apps](https://www.reddit.com/prefs/apps) → **create another
   app…**, choose **web app**, and set the redirect URI `{PUBLIC_API_URL}/api/oauth/reddit/callback`.
3. The **client ID** is the string under the app's name; the **secret** is labelled as such.
4. Set `REDDIT_CLIENT_ID`, `REDDIT_CLIENT_SECRET` and a descriptive `REDDIT_USER_AGENT`, e.g.
   `web:markette:1.0 (by /u/yourname)`. Reddit throttles or blocks generic user agents.

Scopes requested: `identity submit read mysubreddits flair edit`. Each subreddit becomes a channel; more
can be added from the channel card with **Add subreddit**.

### Slack ("Add to Slack", optional)

Without a server app, users connect Slack with a bot token (see section 6). With one, they get a single
**Add to Slack** button instead.

1. At [api.slack.com/apps](https://api.slack.com/apps), click **Create New App → From scratch**.
2. Under **OAuth & Permissions**:
   - Add the redirect URL `{PUBLIC_API_URL}/api/oauth/slack/callback`.
   - Add the **bot token scopes** `chat:write, chat:write.public, channels:read, channels:join,
     groups:read, channels:history, groups:history, files:write, files:read, team:read`. The two history
     scopes let Markette check whether a message whose answer was lost was posted, instead of asking you.
3. Under **Manage Distribution**, turn on **public distribution** so that other workspaces can install the
   app. Slack Marketplace listing is not required.
4. From **Basic Information → App Credentials**, copy the **Client ID** and **Client Secret** into
   `SLACK_CLIENT_ID` and `SLACK_CLIENT_SECRET`.

### Mastodon

Nothing to do. Markette registers itself on each server the first time someone connects an account
there. `MASTODON_APP_NAME` sets the application name shown under posts (default "Markette").

## 6. Networks where each user brings a key

These networks need no server setup. In **Channels → Connect**, each user enters the details listed here.
The connect dialog repeats these hints.

| Network | What the user enters | Where to find it |
|---|---|---|
| **Bluesky** | Handle (or email) and an **app password** | Bluesky → Settings → Privacy and security → App passwords. For a self-hosted PDS, fill in its address. |
| **Mastodon** | The server, e.g. `mastodon.social` | Then approve access on that server. |
| **Telegram** | Bot token, and optionally the channel | Message [@BotFather](https://t.me/BotFather) → `/newbot` → copy the token. Add the bot to the channel as an **administrator** with *Post messages* (and *Pin messages* to pin), or to the group as a member. Leave the channel empty to pick from the chats the bot was added to (post something there first). |
| **Discord** | Webhook URL | Channel → Edit channel → **Integrations → Webhooks → New Webhook → Copy Webhook URL**. |
| **Slack** (when there is no server app) | Bot token (`xoxb-…`), and optionally the channel | [api.slack.com/apps](https://api.slack.com/apps) → Create New App → From scratch → **OAuth & Permissions** → add the bot scopes listed in section 5 → **Install to Workspace** → copy the *Bot User OAuth Token*. All public channels are offered; for a private channel, add the app to it first (channel → Integrations → Add apps). |
| **WhatsApp** | Phone number ID, WhatsApp Business Account ID, access token, template name and language | In Meta Business: WhatsApp Manager → **API setup** shows both IDs. Create a **system user** (Business settings → Users → System users), give it the WhatsApp account, and generate a **permanent token** with `whatsapp_business_messaging` and `whatsapp_business_management`. Create a **MARKETING** template whose body is just `{{1}}` (optionally with an image header) and wait for approval. Then set the webhook `{PUBLIC_API_URL}/api/channels/whatsapp/webhook/` with the verify token shown on the channel card, subscribed to `messages`. Set `META_APP_SECRET` so signatures are checked. Meta bills each delivered marketing message. |
| **QQ** | Bot AppID and AppSecret | [q.qq.com](https://q.qq.com) → your bot → **Development settings**. Set the bot's callback URL to `{PUBLIC_API_URL}/api/channels/qq/webhook/<AppID>/`. For groups: add the bot, @-mention it once, and have the group owner allow proactive bot messages. QQ refuses links in group messages. |
| **WeChat** | AppID, AppSecret, publishing mode | Official Account admin → 设置与开发 → 基本配置 (Basic configuration). Add your server's **outgoing IP** to the IP whitelist on the same page. The account must be **verified** to publish; otherwise only drafts are possible. |
| **WordPress** | Site URL, username, **application password** | wp-admin → Users → Profile → **Application Passwords**. Needs HTTPS, or a plugin, because WordPress disables application passwords over plain HTTP. |
| **Drupal** | Site URL, Basic auth username and password, or a Simple OAuth token, plus the content type | Enable **JSON:API** with write operations allowed (`/admin/config/services/jsonapi`), plus **HTTP Basic Authentication** or **Simple OAuth**. |
| **Ghost** | Admin URL, **Admin API key**, optional newsletter slug | Ghost Admin → Settings → **Integrations → Add custom integration** → Admin API key. The newsletter slug (e.g. `default-newsletter`) also emails each post to members. |
| **Medium** | Integration token | Medium → Settings → Security and apps → Integration tokens. Medium stopped issuing new tokens in 2023, so this works only for accounts that already have one. |
| **DEV** (dev.to or another Forem community) | **API key**, optionally an organization and the community address | dev.to → Settings → **Extensions → DEV Community API Keys → Generate API Key**. To publish under an organization you belong to, enter its username (from `dev.to/<username>`). Forem has no image upload API: images are linked from `{PUBLIC_API_URL}/media/`, so it must be public. |
| **Hugo** | Repository URL, branch, content folder, site URL, and a token or deploy key | A token with push rights (GitHub fine-grained token with *Contents: read and write*; user `x-access-token`), or an SSH deploy key with write access. Your own CI builds and deploys the site on push. |
| **Brevo** | API key and a verified sender | Brevo → **SMTP & API → API keys**; the sender in **Senders & IPs**. Each contact list becomes a channel. |
| **Listmonk** | URL, API user and token | Listmonk → Admin → **Users → New API user**. Each list becomes a channel. |
| **Webhook** | Endpoint URL, optional headers | Any URL that accepts a JSON POST, e.g. an n8n Webhook node. Verify `X-Markette-Signature`, the SHA-256 HMAC of `<X-Markette-Timestamp>.<body>` with the signing secret shown on the channel. |

## 7. AI assistance (optional)

AI features are suggested posting times, campaign plans and per-network rewrites. Without them,
scheduling and the best-time engine still work.

- **OpenRouter** (default, one key for many models): create a key at
  [openrouter.ai/keys](https://openrouter.ai/keys) and set `AI_API_KEY`. `AI_MODEL=openrouter/auto` lets
  OpenRouter pick, or name a model such as `anthropic/claude-sonnet-4`.
- **Any OpenAI-compatible API**: set `AI_PROVIDER=openai_compatible`, `AI_BASE_URL` (e.g.
  `https://api.openai.com/v1`, or `http://ollama:11434/v1` for a local Ollama), `AI_MODEL`, and
  `AI_API_KEY` if the server needs one.

In **Platform → Settings → AI**, **Test key** checks the setup. If your model rejects structured output,
lower `AI_STRUCTURED_OUTPUT`. Per-organization monthly token limits are set under Platform → Organizations
or on plans.

## 8. Billing with Stripe (optional)

Only needed if you sell plans to other organizations.

1. **Stripe Dashboard → Developers → API keys**: copy the **secret key** (`sk_live_…`, or `sk_test_…`
   to try it) into Platform → Settings → Billing (or `STRIPE_SECRET_KEY`).
2. **Developers → Webhooks → Add endpoint**: `{PUBLIC_API_URL}/api/billing/webhook/`, with the events
   `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated` and
   `customer.subscription.deleted`. Copy the **signing secret** (`whsec_…`) into the same section (or
   `STRIPE_WEBHOOK_SECRET`).
3. Turn on the **Customer Portal** in Stripe (Settings → Billing → Customer portal).
4. In **Platform → Plans**, create plans and click **Create Stripe price**.

## 8b. Email for notifications (optional)

Workspaces send notifications to email, a Telegram status bot or webhooks (Settings → Notifications).
Telegram and webhooks need nothing on the server. Email needs an SMTP server: any transactional provider
(Postmark, Mailgun, Amazon SES, Brevo, Scaleway TEM…) or your own.

Set `EMAIL_HOST`, `EMAIL_PORT` (587), `EMAIL_HOST_USER`, `EMAIL_HOST_PASSWORD`, `EMAIL_USE_TLS=true` and
`DEFAULT_FROM_EMAIL`, or fill **Platform → Settings → Email**. Verify the sender's domain with your
provider (SPF and DKIM records), or the messages land in spam.

## 9. Single sign-on (optional)

Organization owners configure this themselves in **Organization → Single sign-on**. There is nothing to
set on the server. At their identity provider (Google Workspace, Microsoft Entra ID, Okta, Keycloak,
Auth0…), they register an OpenID Connect web application with the redirect URI
`{PUBLIC_API_URL}/api/auth/sso/callback/`, then enter the issuer URL, client ID and client secret in
Markette and prove each email domain with the DNS TXT record shown.

## 10. MCP server and mobile apps

- **MCP**: the `mcp` container serves `{PUBLIC_API_URL}/mcp`. Users create a personal token (`mkt_…`)
  in **Settings → API & MCP** and add it to their assistant. Set `PUBLIC_MCP_URL` only if you publish it
  at a different address.
- **Android**: build the APK from [markette-mobile](https://github.com/markette-org/markette-mobile) and copy
  it to `downloads/markette.apk`; it is then offered at `/downloads/markette.apk`. The apps ask for the
  server address at sign-in.
- **Chrome extension**: [markette-extension](https://github.com/markette-org/markette-extension) works with
  any server. Users enter your `PUBLIC_API_URL` when they sign in.

## 11. Production checklist

- [ ] HTTPS in front of the `web` container; `PUBLIC_API_URL` and `FRONTEND_URL` use `https://`
- [ ] `DJANGO_DEBUG=false`, and a unique `DJANGO_SECRET_KEY`
- [ ] `CREDENTIALS_KEY` set and **stored somewhere safe** (a password manager)
- [ ] A strong `POSTGRES_PASSWORD`
- [ ] Backups of the `pgdata` and `media` volumes (and `hugo` if you use Hugo), e.g. a nightly
      `docker compose exec -T db pg_dump -U markette markette | gzip > markette-$(date +%F).sql.gz`
- [ ] `/media/` reachable from the internet (Instagram, Facebook, Threads, DEV)
- [ ] Exactly one `beat` container
- [ ] Callback URLs registered with the exact `PUBLIC_API_URL`
- [ ] Logs: `docker compose logs -f api worker beat`

## 12. Troubleshooting

| Symptom | Likely cause |
|---|---|
| A network is greyed out in Connect | Its client ID or secret is missing. Check Platform → Settings, which shows whether each key is set and whether it comes from the settings page or from `.env`. |
| "redirect_uri mismatch" or "invalid redirect" at the network | The callback registered there differs from `{PUBLIC_API_URL}/api/oauth/<network>/callback`, often because of `http` vs `https`, a trailing slash or a different host. Copy it from Platform → Settings. |
| The browser shows CORS or CSRF errors | With two domains, the app's origin must be in `CORS_ALLOWED_ORIGINS` and `DJANGO_CSRF_TRUSTED_ORIGINS`, and both hosts in `DJANGO_ALLOWED_HOSTS`. |
| Instagram or Facebook: "media could not be fetched" | `/media/` is not publicly reachable, or `PUBLIC_API_URL` points at an internal address. |
| Posts stay "scheduled" and never publish | The `beat` or `worker` container is not running: `docker compose ps`. |
| Every channel says it needs reconnecting after a move | `CREDENTIALS_KEY` changed. Restore the old key. |
| YouTube videos are private | The Google project has not passed the YouTube API audit. |
| LinkedIn: "version is not active" | Raise `LINKEDIN_API_VERSION` to a recent `YYYYMM`. |
