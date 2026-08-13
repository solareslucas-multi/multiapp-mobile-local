# GrowthBook self-hosted — Multiapp Mobile

A zero-config local GrowthBook instance for the Multiapp mobile app: anyone who
clones this repo can start a fully provisioned GrowthBook (admin account,
organization, feature flags, mobile SDK key) with two commands.

## Quick start

Prerequisites: [Docker] or [Podman] (Mac OS X users: `brew install podman` works too).

```sh
cp .env.example .env   # optional — defaults work out of the box
make setup
```

That's it. `make setup` starts the stack and provisions everything:

| Thing        | Value                                                        |
| ------------ | ------------------------------------------------------------ |
| UI           | http://localhost:3000                                         |
| API          | http://localhost:3100                                         |
| Admin email  | `admin@multiapp.local` (from `.env`)                          |
| Admin pass   | `multiapp-local-2026` (from `.env`)                           |
| SDK key      | printed by `make seed` (e.g. `sdk-…`) — use it as `GROWTHBOOK_SDK_KEY` |

The SDK key for your app is printed at the end of `make setup`. In your mobile
app:

```ts
const growthbook = new GrowthBook({
  apiHost: "http://localhost:3100",
  clientKey: "<SDK key from make setup>",
  ...
});
```

## Workflow

### Feature flags are versioned in git

Every flag lives as a JSON file in `growthbook/flags/` — one file per flag, in
the [GrowthBook REST API](https://docs.growthbook.io/api) create-feature shape.
Changes land in git history and normal PRs.

**To add / edit a flag:**

1. Edit or add a file under `growthbook/flags/` (see the existing examples).
2. Run `make seed` — it creates new flags and updates existing ones.
3. Commit the JSON file.

`make seed` is idempotent: re-running it never duplicates data. You can also
edit flags directly in the UI; the JSON files stay the source of truth for
whoever sets up the repo next.

### Resetting to a clean state

```sh
make reset && make setup
```

`make reset` wipes Mongo and uploads so the *next* provisioning behaves exactly
like a fresh clone.

## Scripts / Make targets

```sh
make up       # start containers
make seed     # provision account + org + flags + SDK key (idempotent)
make setup    # up + seed
make down     # stop, keep data
make reset    # stop + wipe data
make logs     # follow GrowthBook logs
```

Engine notes: `docker compose` is used when available, otherwise `podman
compose`. Both are supported by the compose file.

## Configuration (`.env`)

All values have dev-friendly defaults (see `.env.example`), so a plain clone
works without touching anything. Override in your local `.env` if you want:

- `GB_ADMIN_EMAIL` / `GB_ADMIN_PASSWORD` / `GB_ORG_NAME` — auto-provisioned admin
- `GB_SDK_NAME` / `GB_SDK_LANGUAGE` — auto-created SDK connection
- `JWT_SECRET` / `ENCRYPTION_KEY` / `MONGO_ROOT_PASSWORD` — service secrets

> **Security note:** the committed defaults are intentionally weak **dev-only**
> credentials so clones "just work". GrowthBook listens on localhost only; do
> not expose these ports to a network, and set strong values in `.env` if you
> share the instance beyond your machine.

## How provisioning works

[`scripts/seed-growthbook.sh`](scripts/seed-growthbook.sh) is idempotent bash +
curl with no extra dependencies:

1. Waits for the API to be healthy (`GET /api/v1/openapi.yaml`).
2. On a fresh install calls `POST /auth/firsttime` (first user becomes the
   organization's super admin); on existing installs uses `POST /auth/login`.
3. Resolves the organization id from `GET /user` and sends it as
   `X-Organization` on all REST calls (required for JWT auth).
4. Upserts every flag from `growthbook/flags/` via `POST /api/v1/features` /
   `POST /api/v1/features/:id`.
5. Creates the SDK connection (`POST /api/v1/sdk-connections`) if missing and
   prints the SDK key.

The GrowthBook image is pinned to a stable release tag (`5.0.0`) so every clone
runs the same version. Bump it in `docker-compose.yml` when you want to update.

[Docker]: https://docs.docker.com/get-docker/
[Podman]: https://podman.io/docs/installation