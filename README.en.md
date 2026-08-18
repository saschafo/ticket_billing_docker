# Ticket Billing — Docker setup (Frappe 16 + ERPNext 16)

*[Deutsch](README.md) · English*

Docker Compose setup for the **ticket_billing** app on **Frappe Framework 16**
and **ERPNext 16**.

The build bakes Frappe, ERPNext and the app into the image. Nothing beyond
Docker is required — no bench, no Python, no Node on the host.

Runs natively on **arm64 (Apple Silicon)** and **amd64**.

The app itself lives in its own repository:
[`ticket_billing`](https://github.com/saschafo/ticket_billing).

---

## Contents

* [Quick start](#quick-start)
* [What is in here](#what-is-in-here)
* [Configuration](#configuration)
* [Building the app](#building-the-app)
* [Development: dev-sync.sh](#development-dev-syncsh)
* [Backing up mailboxes: mail-config.sh](#backing-up-mailboxes-mail-configsh)
* [Rebuilding from scratch: neu-aufsetzen.sh](#rebuilding-from-scratch-neu-aufsetzensh)
* [E-mail prerequisites](#e-mail-prerequisites)
* [Common tasks](#common-tasks)
* [Updating](#updating)
* [Production](#production)
* [How the image is built](#how-the-image-is-built)
* [Licence](#licence)

---

## Quick start

```bash
cp .env.example .env     # set at least ADMIN_PASSWORD and DB_PASSWORD
./build.sh               # build the image (~20–40 min the first time)
./ticket.sh up           # start the stack, the site is created automatically
```

Requires Docker Engine **23.0+** with Compose v2 (the build uses BuildKit
secrets).

Then in the browser:

| | |
|---|---|
| URL | <http://ticketbilling.localhost:8080> |
| User | `Administrator` |
| Password | value of `ADMIN_PASSWORD` from `.env` |

`/` shows the app's Vue interface, the classic Frappe desk is at `/app`.

> **Open the app under the site name, not via `localhost`.**
> Otherwise realtime stays silent: Frappe's socket service validates the
> session by calling back to the backend, and it builds that address from the
> browser's `Origin`. Inside the container `localhost` points at the container
> itself — the call fails and every connection ends in
> `Unauthorized: fetch failed`. Under the site name the network alias on the
> `frontend` service resolves it.
>
> For the same reason `HTTP_PUBLISH_PORT` should stay at `8080`: the port is
> part of the `Origin`, and nginx listens on 8080 inside. A different
> published port breaks the callback again.

Stop with `./ticket.sh down` — data stays in the Docker volumes.

> After the first start the site is empty: ERPNext requires the setup wizard
> (company, currency, fiscal year). For an immediately populated system to
> demonstrate, use
> [`./neu-aufsetzen.sh`](#rebuilding-from-scratch-neu-aufsetzensh).

---

## What is in here

| File | Purpose |
|---|---|
| `Containerfile` | Builds the image: Frappe 16 + ERPNext 16 + ticket_billing, assets prebuilt |
| `compose.yaml` | The complete stack (see below) |
| `.env` / `.env.example` | All configuration (versions, repos, passwords, port) |
| `build.sh` | Image build, generates `apps.json` from `.env` |
| `ticket.sh` | Helper: up/down/logs/bench/backup/update/reset |
| `dev-sync.sh` | Push the local app state into the running containers |
| `mail-config.sh` | Back up and restore mailbox settings |
| `neu-aufsetzen.sh` | Wipe the site, install demo data, restore mailboxes |
| `resources/` | nginx template and entrypoints (from `frappe_docker`) |
| `apps-local/` | Working copy of the app repo when `APP_SOURCE=local` (not tracked here) |

### Services in the stack

| Service | Task |
|---|---|
| `db` | MariaDB 11.8 |
| `redis-cache`, `redis-queue` | cache and job queue |
| `configurator` | one-shot: writes `common_site_config.json` |
| `create-site` | one-shot: creates the site and reconciles `SITE_APPS`; on later starts also runs `bench migrate` |
| `backend` | Gunicorn (Frappe web server) |
| `frontend` | nginx, publishes port `8080` |
| `websocket` | Socket.IO for realtime |
| `scheduler` | scheduled jobs |
| `queue-short`, `queue-long` | background workers |

The one-shot jobs are idempotent: `./ticket.sh up` can be run again at any
time without damaging the site.

---

## Configuration

Everything is driven by `.env`. The important values:

```dotenv
APP_SOURCE=local             # local = own state from apps-local | git = build clones itself
APP_REPO_URL=https://github.com/saschafo/ticket_billing
APP_BRANCH=main
APP_NAME=ticket_billing      # must match app_name in hooks.py

FRAPPE_BRANCH=version-16     # or a fixed tag, e.g. v16.30.0
ERPNEXT_BRANCH=version-16

SITE_NAME=ticketbilling.localhost
SITE_APPS="erpnext ticket_billing"   # order matters, quoting mandatory
SITE_LANG=de                 # site language, only applied at creation
HTTP_PUBLISH_PORT=8080
ADMIN_PASSWORD=...
DB_PASSWORD=...
```

`FRAPPE_SITE_NAME_HEADER` refers to `SITE_NAME` and therefore follows it
automatically. That makes the site reachable under any hostname
(`localhost`, the site name itself, the machine's IP). For multi-site
operation set it to `$$host` instead.

> When a fixed name was written there, nginx kept serving the old site after
> `SITE_NAME` was changed — and that site no longer exists. The result was
> **404 on everything**, with no hint as to why. The site name belongs in
> exactly one place.

`.env` contains passwords and is excluded via `.gitignore`. The template is
`.env.example`.

> **`SITE_APPS` must be quoted.** The scripts read the file with `source`;
> without quotes it breaks at the space.

### Order of apps

Two places, and in both ERPNext must come before `ticket_billing`:

* **`build.sh`** turns it into `apps.json` — determines the order in which
  `bench init` pulls the apps into the bench.
* **`SITE_APPS`** determines the order in which `create-site` installs them.

`ticket_billing` additionally declares ERPNext as `required_apps`. If it is
missing, installation aborts with a clear message instead of failing later on
missing doctypes.

### Site language

`SITE_LANG` is evaluated **only when the site is created**. `create-site` sets
the value in two places because Frappe reads them differently: *System
Settings* applies to signed-in users, the `lang` default to guests. Without
that a fresh site runs in English — then neither the translations under
`ticket_billing/translations` apply, nor does the Vue interface start in
German, since it takes the session language from `window.frappe_boot_lang`.

On an existing site changing `SITE_LANG` does nothing — switch it in the desk
under *System Settings → Language*.

---

## Building the app

While the app repo is not public, the build uses `APP_SOURCE=local`: the
working copy sits in `apps-local/ticket_billing` (an independent Git repo) and
is copied into the build.

> **Important:** even in this mode `bench` clones from the repo. A `git clone`
> only carries **committed** state — changes that exist merely in the working
> tree do not reach the image. `build.sh` therefore warns about a dirty
> working copy and prints the commit hash it built.

Once the repo is publicly reachable, switch over:

```dotenv
APP_SOURCE=git
```

The build then clones from `APP_REPO_URL` itself. For a **private** repo put a
personal access token into `APP_REPO_TOKEN` — it is passed as a BuildKit secret
and therefore does **not** end up in the image layers (`docker image history`).

### Frontend

The app's Vue frontend is **committed prebuilt**
(`ticket_billing/public/frontend`), so the Docker build needs no Node step.
After frontend changes:

```bash
cd apps-local/ticket_billing/ticket_billing/frontend
npm install && npm run build
cd - && git -C apps-local/ticket_billing commit -am "Rebuild frontend"
./build.sh --refresh
```

---

## Development: `dev-sync.sh`

Rebuilding the image is too slow for day-to-day work. `dev-sync.sh` copies the
local app state straight into the running containers:

```bash
./dev-sync.sh                # copy, clear cache, restart services
./dev-sync.sh --no-restart   # copy only
```

It copies into **all** services that need app files — `backend`, `scheduler`,
`queue-short`, `queue-long`, `websocket` and `frontend` (nginx serves
`/assets` from its own container).

Two traps the script handles for you — both cost hours otherwise:

> **Restarting the backend alone is not enough.** Incoming mail, scheduled
> tasks and background jobs run in the **workers**. If those keep running they
> keep using the old code while the API already has the new one. A newly
> registered hook then does nothing, even though it is right there in the file.

> **Hooks live in Redis, not only in process memory.** A restart therefore does
> *not* pick up a changed `hooks.py`: the service restarts but still reads the
> hook list from the cache. That is why `bench clear-cache` runs before the
> restart.

Both are easy to miss because any check via `bench` or the console starts a
fresh process and sees the new code — while the worker would have been the one
executing it.

New doctypes additionally need a migration:

```bash
./ticket.sh migrate
```

macOS note: the script sets `COPYFILE_DISABLE=1` and removes `._*` files.
Without that `tar` smuggles AppleDouble files along, which breaks fixture
import.

---

## Backing up mailboxes: `mail-config.sh`

E-mail accounts are created by hand and are **not** part of the demo data —
removing the demo leaves them alone. They are still easy to lose: when the
site is recreated, the database reset, or the container rebuilt.

```bash
./mail-config.sh export                    # -> mail-accounts.json
./mail-config.sh export --ohne-passwort    # without passwords
./mail-config.sh import                    # restore
```

The backup covers the accounts **and the associated `Email Domain`**. Without
it, restoring onto a fresh site fails with *Could not find Domain*.

`uidnext` and `uidvalidity` are deliberately excluded: they describe where the
last fetch stopped and would place a new mailbox at a position that means
nothing there — in the worst case existing mail is skipped.

> The file contains mailbox passwords in **clear text**. It is created with
> mode `600` and excluded via `.gitignore`. If you would rather not have that,
> use `--ohne-passwort` and enter them by hand after restoring.

A restored account performs an **initial sync** and fetches recent messages
again. After a rebuild that is what you want — the tickets come back. Running
two sites against the same mailboxes, however, produces duplicate tickets and
mail marked as read.

---

## Rebuilding from scratch: `neu-aufsetzen.sh`

One command for the whole path — for demos and testing:

```bash
./neu-aufsetzen.sh          # asks for confirmation
./neu-aufsetzen.sh --ja     # no confirmation
```

1. back up mailboxes (while the old site is still running)
2. delete volumes, create the site anew
3. **push the local app state and migrate**
4. complete the ERPNext setup wizard non-interactively
5. install demo data
6. restore mailboxes

> **This deletes the database completely.** Real tickets, mail threads and
> invoices are gone afterwards — and received mail does not come back, because
> the mailboxes only serve unread messages.

Configurable through `.env` or the environment:

```dotenv
DEMO_COMPANY=Musterfirma
DEMO_COMPANY_ABBR=MF
DEMO_COUNTRY=Germany
DEMO_CURRENCY=EUR
DEMO_TIMEZONE=Europe/Berlin
DEMO_COA=SKR04 mit Kontonummern
DEMO_FY_YEAR=2026
```

Two quirks of the setup wizard the script works around:

* **The chart of accounts must match a bundled name exactly.** If it does not,
  ERPNext creates the company and then crashes in `on_update` — the wizard
  swallows that and still reports `status: ok`. The script therefore checks for
  the *company*, not for the return value. Valid values for Germany:
  `SKR04 mit Kontonummern`, `SKR03 mit Kontonummern`, `Standard`,
  `Standard with Numbers`.
* **Without explicit dates an invalid fiscal year is created** ("End Date
  should be one year after Start Date"). The error is logged and skipped —
  leaving a system in which no invoice can be booked. The script passes the
  dates and adds the fiscal year afterwards if needed.

A failed wizard run leaves the site marked as "set up" and records apps as
completed; a second attempt then skips them silently. The script resets that
flag beforehand.

---

## E-mail prerequisites

Inbound mail needs one `Email Account` per department with `tb_department`
set, and with IMAP `append_to = Issue` must be on the **folder** row, not on
the account.

Outbound mail is rejected by large providers when the sending domain cannot
authenticate. Since 2024 Gmail requires **SPF or DKIM**:

```
550-5.7.26 Your email has been blocked because the sender is unauthenticated.
550-5.7.26 Gmail requires all senders to authenticate with either SPF or DKIM.
```

The sending domain's DNS therefore needs an `A` record, an SPF entry naming
the server that **actually sends**, a DKIM key under `default._domainkey` and
a DMARC record. Details are in the
[app README](https://github.com/saschafo/ticket_billing/blob/main/README.en.md#e-mail).

Two traps from practice: an SPF record still pointing at a previous mail
provider, and a DNS zone that is not hosted on your own server — you then edit
a zone in the server panel that nobody queries. Check with
`dig +short TXT <domain>` against the authoritative name servers.

`host_name` should also be set, otherwise unsubscribe and attachment links in
outgoing mail point nowhere:

```bash
./ticket.sh bench --site ticketbilling.localhost set-config host_name https://tickets.example.org
```

---

## Common tasks

```bash
./ticket.sh status                 # container status
./ticket.sh logs backend           # logs of a service
./ticket.sh bench --site ticketbilling.localhost list-apps
./ticket.sh migrate                # apply schema migrations
./ticket.sh backup                 # backup incl. files into ./backups/
./ticket.sh console                # Frappe Python console
./ticket.sh shell                  # shell inside the backend container
./ticket.sh reset                  # delete EVERYTHING (asks first)
```

---

## Updating

The image is immutable. New app states, new Frappe/ERPNext versions and schema
changes arrive exclusively through a new build — the data lives separately in
Docker volumes and stays untouched.

```bash
./ticket.sh update
```

That performs four steps:

1. **Backup** of the site including files into `backups/`
2. **Rebuild** of the image with `--refresh` — Frappe, ERPNext and the app are
   cloned fresh, the rest comes from the layer cache
3. **Restart** of the containers with the new image
4. **`bench migrate`** — runs automatically in the `create-site` job once a
   site exists

Step 1 can be skipped with `./ticket.sh update --no-backup`. I would not:
`bench migrate` runs patches, and a patch failing halfway leaves a
half-migrated database.

### Rolling back

Every build sets two tags: the moving `:16` and a fixed one carrying the app
commit, e.g. `:16-dc31481`. That is the only reason a way back exists — the
next build would otherwise have overwritten the previous state.

```bash
docker images ticket-billing/frappe     # list available states
```

Then put the desired tag into `.env` and restart:

```dotenv
CUSTOM_TAG=16-dc31481
```

```bash
./ticket.sh up
```

Important: this rolls back **only the code**, not the database. If a migration
has already changed the schema, the old code may not cope. For a full rollback
restore the backup as well:

```bash
./ticket.sh bench --site ticketbilling.localhost restore backups/<file>.sql.gz
```

### Pinning versions

`FRAPPE_BRANCH=version-16` and `ERPNEXT_BRANCH=version-16` are **moving
branches** — every build with `--refresh` picks up the latest state. For
reproducible builds use tags instead:

```dotenv
FRAPPE_BRANCH=v16.30.0
ERPNEXT_BRANCH=v16.30.0
```

Frappe and ERPNext belong on the same major version. The same applies to
`APP_BRANCH`, where a tag or commit works too.

---

## Production

For server deployment, additionally:

1. **Replace the passwords** in `.env` (`ADMIN_PASSWORD`, `DB_PASSWORD`).
2. **TLS**: put a reverse proxy (Traefik, Caddy, nginx-proxy) in front of
   `frontend` and bind `HTTP_PUBLISH_PORT` to `127.0.0.1` only. Ready-made
   overrides are in the upstream `frappe_docker` repo under `overrides/`.
3. **Site name** set to the real domain (`SITE_NAME`,
   `FRAPPE_SITE_NAME_HEADER`) — the site folder must be named like the domain.
4. **Set `host_name`** so links in outgoing mail are correct.
5. **Registry**: build the image once, push it, and only pull on the server —
   `CUSTOM_IMAGE=ghcr.io/<user>/ticket-billing`, `PULL_POLICY=always`.
6. **Back up regularly** (`./ticket.sh backup` or the
   `compose.backup-cron.yaml` override from `frappe_docker`).
7. **No demo data.** While it is installed, anyone gets in without a password.

---

## How the image is built

`Containerfile` comes from the official `frappe_docker` (the `custom`
variant). One deviation: a `COPY` line pulling `apps-local/` into the build
stage (for `APP_SOURCE=local`; with `git` the folder is empty and has no
effect).

A second deviation, in `resources/core/nginx/nginx-template.conf`: the
`/socket.io` block passes the real `Origin` through instead of pinning it to
the site name. Frappe's socket authentication compares `Origin` against
`Host` — with the original value every connection via `http://localhost:8080`
fails with "Invalid origin", and realtime stays silent without the UI
reporting anything. The forwarded origin is also the stricter check: a foreign
page is rejected, whereas the fixed value would have let it through.

---

## Licence

[GNU Affero General Public License v3.0](LICENSE)

Copyright (C) 2026 Sascha Böhm Software & App, Inhaber Sascha Böhm

The setup builds on [`frappe_docker`](https://github.com/frappe/frappe_docker)
(MIT) and operates ERPNext (GPL-3.0). For different terms, contact the
copyright holder.
