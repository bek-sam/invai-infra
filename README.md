# invai-infra

Infrastructure for all InvAI services.

## One-command local dev

From `invai-infra`:

```
pnpm install
pnpm dev:all      # sets Node 24's PATH itself; starts infra, migrates, starts every app
```

This runs `scripts/dev.sh`, which:

1. Starts local infra (Postgres, Valkey, MinIO, Mailpit) via `docker compose` and waits for
   every healthcheck.
2. Runs `invai-backend`'s `db:migrate` (and `db:seed`, if that script exists yet — it's
   tolerated as a warning if not, since backend migrations/seed are still being built).
3. Starts `api`, `worker` (both `invai-backend`), `imaging` (`invai-imaging`), `web`
   (`invai-web`) and `floor` (`invai-floor`) together via `concurrently`, with prefixed,
   color-coded logs. Missing `node_modules`/`.venv` are installed first.

Ctrl-C stops the five app processes; infra keeps running (leave it running between sessions —
Postgres/MinIO data persists in Docker volumes). Other scripts:

```
pnpm stop         # scripts/stop.sh — stops infra (data volumes kept)
pnpm reset-db     # scripts/reset-db.sh — wipes and re-initializes Postgres, re-runs migrations
```

## Local services (infra only)

```
pnpm local:up     # Postgres 17 + pgvector (5432), Valkey (6379, noeviction), MinIO S3 (9000, console 9001), Mailpit (SMTP 1025, UI 8025)
pnpm local:down
```

`local/docker-compose.yml` (compose project `local`):

- **postgres** — `pgvector/pgvector:pg17`. `local/init.sql` creates two databases, `invai`
  and `invai_test` (same setup, for tests), each with: the `invai_app` role (`LOGIN`, no
  `BYPASSRLS` — this is the RLS-enforced app connection; `invai`, the `POSTGRES_USER`, is the
  migration/owner role), the `pg_trgm`, `vector`, `pgcrypto` and `citext` extensions, and
  `ALTER DEFAULT PRIVILEGES` so tables/sequences that `invai`'s migrations create later are
  automatically usable by `invai_app` without a manual `GRANT` per migration.
- **valkey** — `valkey/valkey:8`, appendonly, `noeviction`.
- **minio** — `quay.io/minio/minio` (the `minio/minio` Docker Hub image no longer exists,
  hence `quay.io`), console on :9001. `MINIO_API_CORS_ALLOW_ORIGIN=*` is set explicitly
  (MinIO's own default) — MinIO's per-bucket `PutBucketCors` S3 API returns `NotImplemented`
  on the current server image, so CORS has to be the server-wide setting, not `mc cors set`.
- **minio-init** — one-shot `quay.io/minio/mc`: creates bucket `invai-local`, sets anonymous
  access to `none`, then exits. Depends on `minio` being healthy.
- **mailpit** — `axllent/mailpit`, SMTP on :1025 (no auth), UI/API on :8025. Catches vendor
  and invite emails sent locally; point `invai-backend`'s SMTP env vars at
  `localhost:1025`.
- Every service has a healthcheck; `minio-init` additionally gates on `minio`'s.

All of the above are the **default** compose profile (infra only). A **`full`** profile also
builds and runs `api`, `worker`, `imaging`, `web` and `floor` from the sibling repos'
Dockerfiles, for a production-like local run:

```
pnpm local:full   # docker compose --profile full up -d --build
```

`invai-backend`, `invai-web` and `invai-floor` link `@invai/contracts` (and `@invai/ui` for
web/floor) via `link:../<repo>`, so their Dockerfiles build from the **workspace root** (the
parent of all `invai-*` repos) rather than their own directory — see the `context`/`dockerfile`
split in `local/docker-compose.yml` and the comment at the top of each of those Dockerfiles.
`invai-imaging` has no such sibling dependency and builds from its own directory.

## AWS (SST)

`sst.config.ts` (written and typechecked against the installed `sst@4.17.1` — check
`.sst/platform/src/components` before changing component options, not older docs) defines:

- A VPC with a NAT **EC2 instance** instead of NAT Gateways (~$30/mo saved).
- **RDS Postgres 17**, encrypted at rest (the component's default), private subnets only, RDS
  Proxy on for the `production` stage.
- **Valkey** via `sst.aws.Redis` (`engine: "valkey"`), matching the local Valkey image.
- A private **S3 bucket** with lifecycle rules matching architecture.md §7: `sheets/` expires
  after 90 days, `raw/` after 30.
- A customer-managed **KMS key** for field-level encryption of buyer PII and OAuth tokens.
- A placeholder **SES** email identity (`SES_DOMAIN` env var, defaults to
  `<stage>.invai.example`) — swap in the real sending domain and verify it before use.
- An ECS **Cluster** with `api` (public, load-balanced, health-checked on `/health`),
  `worker` and `imaging` (4–8 GB memory, internal-only — reached over service discovery via
  `imaging.url`, no load balancer).
- **Static sites** for `web` and `floor` (`sst.aws.StaticSite`, built directly with
  `pnpm build`, not via Docker).
- **Secrets** (`sst.Secret`, set with `sst secret set <Name> <value> --stage <stage>`):
  `BetterAuthSecret` and `FieldEncryptionKey` are required (no placeholder — deploy fails
  loudly if unset); `AnthropicApiKey`, `EasyPostApiKey`, `ShopifyApiKey`, `ShopifyApiSecret`
  default to `""`, matching the mock/sandbox-provider-when-missing convention from the
  workspace `CLAUDE.md`.
- Stages `staging` and `production`; `production` has `removal: "retain"` and `protect: true`.

**Known gap:** the Postgres component only provisions the master (owner) user. Nothing here
yet creates the low-privilege, RLS-enforced `invai_app` role in RDS the way `local/init.sql`
does — that needs a one-time bootstrap step (a script run against the instance, e.g. from the
deploy job or an SST dynamic provider) before `invai_app` can be used in AWS the same way it
is locally.

```
pnpm install
pnpm typecheck    # tsc --noEmit — passes; see the tsconfig.json note below
pnpm deploy:staging
pnpm deploy:prod
```

**This environment has no AWS credentials, so `sst deploy` is unverified here.** `.github/workflows/deploy.yml`
runs it in CI instead, via OIDC role assumption (`role-to-assume` is a placeholder ARN —
`arn:aws:iam::123456789012:role/invai-deploy` — replace it, and the deploy secrets, before
the workflow can actually run). Triggers: manual (`workflow_dispatch`, choose `staging` or
`production`) or a `v*` tag push (always `production`).

### tsconfig.json note

`tsconfig.json` deliberately does **not** set `verbatimModuleSyntax` or
`noUncheckedIndexedAccess`, unlike the other repos in this workspace. `sst.config.ts`'s
triple-slash reference to `.sst/platform/config.d.ts` pulls SST's own vendored platform
source into the type-checked program (that's how `sst.aws.*`/`$config` types are resolved),
and that vendored code isn't written to satisfy those two flags — so turning them on here
fails `pnpm typecheck` on files this repo doesn't own, not on `sst.config.ts` itself. An
explicit `typeRoots: ["./node_modules/@types"]` plus a pinned `@types/node` devDependency
pins ambient `Buffer`/`Uint8Array` types to a version compatible with `typescript@7.0.2`
(SST's own bundled `@types/node@22.10`, resolved first otherwise since it's the closer
`node_modules`, produced real type errors under `typescript@7.0.2`'s newer iterator-helper
lib types).
