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

## Pre-push test gate (T-23-6)

```
pnpm gate [repo...]   # scripts/gate.sh — no args: every repo with commits not yet on origin/main
```

Runs `typecheck`, `lint` and the full `test` suite for each repo in scope (`pnpm build` too for
`invai-web`/`invai-floor`; `invai-imaging` runs `uv run ruff check .` and `uv run pytest`
instead). If `invai-backend`, `invai-web` or `invai-floor` is in scope, it also resets, migrates
and seeds the dev database (imaging must be reachable) and runs the API golden path, the browser
suite and the floor suite — see `run-golden-path` for what that covers.

- Runs the backend test suite on names no other process uses (T-46-1, B-426): a database the gate
  creates itself, `invai_test_gate_<UTC stamp>_<pid>` (pinned with `TEST_DATABASE_URL` and
  `TEST_MIGRATION_DATABASE_URL`, dropped when the suite ends and again by the EXIT trap, and any idle
  leftover older than 10 minutes is dropped at the next start), and a Valkey DB claimed by the test
  harness (`REDIS_URL` reset to `redis://localhost:6379`, no `TEST_REDIS_URL`; the log names the claimed
  DB). The shared `invai_test` and Valkey DB 15 (the harness's claim registry) are not used by the
  gate. Why: wave 45 run 1 failed 13 tests when rows vanished from the shared pinned database mid-suite
  (see `invai-docs/waves/46/reports/T-46-1.md`).
- Detection: every connection of the backend suite carries `PGAPPNAME=invai-gate-<run id>`; while the
  suite runs the gate samples `pg_stat_activity` on its database each second and, if any other
  application connected, writes `GATE DETECTION` lines (application, client, state) to the log, adds a
  hint to the `FAIL` line, or warns on stderr when the suite passed. It only reports; it never kills
  anything. Tests: `scripts/gate/testdb.test.sh`.
- stdout is exactly one line per suite — `PASS <repo> <suite> <n> passed` or
  `FAIL <repo> <suite>: <failing test names>` — plus a final `log: <path>` line pointing at the
  full output (`invai-infra/.gate/run-<timestamp>.log`, gitignored). Everything else goes to
  that log or, for a refusal, to stderr.
- Refuses to start (exit 1, one-line reason on stderr) if its own test database name already exists or
  has a session (the old `invai_test` / Valkey DB 15 checks were dropped: other agents' test runs use
  those legitimately). When the golden-path phase will run (backend/web/floor
  in scope), it also refuses if the configured ports (default 3000/8000/5173/5174, see below) are
  already held by something this run didn't start, naming the port, the pid and the variable to set
  (e.g. `port 8000 is held by pid 26738 (not started by this gate); stop it or set INVAI_IMAGING_PORT
  to a free port`). It never kills a process it didn't start, and a trap stops everything it did
  start even on failure.
- **Configurable ports (T-36-1).** `pnpm dev:all` and `pnpm gate` read `INVAI_API_PORT` (3000),
  `INVAI_IMAGING_PORT` (8000), `INVAI_WEB_PORT` (5173) and `INVAI_FLOOR_PORT` (5174), for example
  `INVAI_IMAGING_PORT=8100 INVAI_WEB_PORT=5183 pnpm gate invai-web` when another local project holds
  8000 or 5173. A set variable is turned into the matching backend/E2E settings (`PORT`,
  `BETTER_AUTH_URL`, `IMAGING_URL`, `WEB_ORIGIN`, `FLOOR_ORIGIN`, `E2E_API_URL`, `E2E_WEB_URL`,
  `E2E_FLOOR_URL`; origins are always `http://localhost:<port>`), and these override
  `invai-backend/.env`. With none set, nothing new is exported and `.env` still governs. The
  Vite settings are per process: `VITE_API_URL` only for web and `VITE_API_PROXY` only for floor,
  and only when `INVAI_API_PORT` is set. Values must be integers from 1024 to 65535, all four
  distinct (defaults count), and not 5432, 6379, 9000, 9001, 1025, 8025 or 54322; otherwise both
  scripts exit non-zero with a one-line reason before starting anything. One default-path change:
  web and floor now start with `--port <port> --strictPort`, so vite fails fast instead of drifting
  to a neighbour port. `scripts/full.sh` (container stack) does not read these variables yet.
  Tests: `pnpm gate:test`.
- **Fresh rate-limit buckets (T-36-5).** Before each of the three E2E suites the gate deletes only the `tb:*` keys (SCAN, never KEYS/FLUSH) in the gate's Valkey DB 9 (`GATE_REDIS_URL`; it refuses DB 0 and DB 15, via `docker exec local-valkey-1`), logs the count, and fails the step if the target is not localhost or is DB 15.
- On a full pass, writes `invai-infra/.gate/pass.json` (gitignored) with each checked repo's HEAD
  SHA and a UTC timestamp. `.claude/hooks/guard-bash.py` allows a code repo to be pushed in
  exactly one form, as the whole Bash command with nothing before or after it (no `cd`, `&&`, `;`,
  `|`, `2>&1`, `$(...)`, `bash -c`, env prefix, `~` or relative path):
  ```
  git -C /Users/bekbolsun/invai/<repo> push origin main
  git -C /Users/bekbolsun/invai/<repo> push origin <sha>:main     # 7-40 hex characters
  ```
  and only when this stamp exists, is under 24 hours old, and records the commit being pushed;
  its messages point back at `pnpm gate`. Every other push form is refused (owner decision OI-22).
  `invai-docs` (docs-only) needs no stamp but is pushed only as
  `git -C /Users/bekbolsun/invai/invai-docs push origin main`.
  A golden-path run no longer touches the dev DB (T-41-4): see the next item.
- **Scratch database (T-41-4).** The golden-path phase resets, migrates and seeds database
  `invai_gate` (created when missing, owner `invai`, `invai_app` granted CONNECT) with
  `DATABASE_URL`/`MIGRATION_DATABASE_URL` pointing at it, `REDIS_URL=redis://localhost:6379/9` and
  `SEED_OUTPUT_FILE=E2E_SEED_OUTPUT_FILE=invai-infra/.gate/seed-output.json`, exported to every
  child (dev:all, E2E). The dev DB `invai` and Valkey DB 0 are never reset, so a gate does not
  delete the owner's AI photo sets. The gate refuses to start if either database URL names `invai`,
  if `REDIS_URL` is not DB 9, or if `INVAI_PAID_AI` or `IMAGE_GEN_PROVIDER` is set (spend on the
  scratch DB would escape the dev ledger). The floor suite reads the fixed
  `invai-backend/seed-output.json`, so for that suite only the gate copies its seed output there,
  keeping the dev file as `.gate/seed-output.dev.json`, and puts it back on every exit path (EXIT,
  INT, TERM traps); after a SIGKILL the next gate start restores it first. Open item B-floor-seed-env:
  the floor E2E helper should honor `E2E_SEED_OUTPUT_FILE` (qa-engineer), then the swap can go.
  Tests: `pnpm gate:test`.
- **The gate cleans up after itself (T-42-2).** Each golden-path run adds about 150 MB of files to
  MinIO bucket `invai-gate` (T-45-5) under the seed's company ids. When the stack has stopped (the EXIT
  trap, so pass, fail, Ctrl-C and error exits), the gate reads the company ids from
  `invai_gate.companies`, deletes each exact `<uuid>/` prefix, flushes Valkey DB 9 (it refuses any
  other DB number), and logs one line with the prefix count and bytes. A run killed with SIGKILL
  skips the trap, so the next run does the same for the previous seed before its reset. Fences
  (each pinned by `scripts/gate/cleanup.test.sh`): the database name must be exactly `invai_gate`;
  a prefix that is also a company id in `invai` is refused; an empty `invai` company list is a
  refusal; only `<uuid>/` prefixes of bucket `invai-gate` on a localhost endpoint are ever deleted
  (`scripts/gate/s3tool.mjs`, no bucket-level delete); `delete-prefix` itself refuses an empty,
  non-UUID or slash-less prefix and any bucket but `invai-gate` (the dev bucket `invai-local` included), whatever the caller checked.
  Valkey DB 9 is also used by the compose `full` profile, so the gate refuses to start, and the
  flush refuses, while any full-profile container (`local-api-1`, `-worker-1`, ...) runs; run
  `scripts/full.sh down` first. The two cleanup tests are hermetic: they pin `S3_ENDPOINT` to the
  closed port 1, use non-existent containers and databases, and abort unless that endpoint is
  proven dead, so a mutated fence cannot delete real files. Logs and traces under `.gate/` stay.
- **The gate has its own bucket (T-45-5, B-402).** Inside `run_golden_path`, after the per-repo suites
  (the backend `pnpm test` refuses non-test buckets), the gate exports `S3_BUCKET=invai-gate` and
  checks it against an allow-list (exactly `invai-gate`, else it refuses to start). The seed and the
  dev:all children (api, worker, imaging) inherit it: backend `loadEnvFile` never overrides a set
  variable and imaging's pydantic-settings ranks env above `.env`. `minio-init` creates `invai-gate`
  (private, unversioned, so deleted gate files really go) and `s3tool.mjs ensure-bucket` creates it if
  missing, before the seed. `s3tool` defaults to `invai-gate`; a read-only count of the dev bucket
  needs `S3_BUCKET=invai-local node scripts/gate/s3tool.mjs count <uuid>/`. `pnpm purge:orphans` reads
  `invai-local`, so run it with `S3_BUCKET=invai-local` for the dry run; its `--apply` delete is now refused by `s3tool`.

- **No file watchers in the gate (B-388).** The gate starts `dev:all` with `INVAI_NO_WATCH=1`;
  `dev.sh` then runs the api and worker with plain `tsx` and imaging without `--reload`, so an edit
  made during a gate run cannot restart them. A plain `pnpm dev:all` still watches.
- **One-off orphan purge (T-42-2).** `pnpm purge:orphans` is a dry run (counts and bytes per class);
  `pnpm purge:orphans -- --apply` deletes. Only top-level UUID prefixes of `invai-local` that are
  not a company id in any local database with a `companies` table and have no object changed in the
  last 6 hours are deleted; non-UUID prefixes, root objects and other buckets are only listed. It
  refuses when `invai` has no readable company list. Tests: `scripts/purge-orphan-files.test.sh`.

## Local services (infra only)

```
pnpm local:up     # Postgres 17 + pgvector (5432), Valkey (6379, noeviction), MinIO S3 (9000, console 9001), Mailpit (SMTP 1025, UI 8025)
pnpm local:down
```

Every port above is published on `127.0.0.1` only, not on the LAN (B-322). Containers started before this change keep their old all-interface binding until they are recreated (`docker compose up -d` in `local/`).

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
- **minio-init** — one-shot `quay.io/minio/mc` (pinned by digest): creates bucket `invai-local`,
  sets anonymous access to `none`, turns on versioning and installs one lifecycle rule
  (`scripts/minio-lifecycle.json`, id `housekeeping`), then exits. Depends on `minio` being healthy.
  **Local files keep deleted or overwritten versions for 7 days** (incident 2026-10-13). A delete
  leaves a hidden delete marker plus the old version; apps and `s3tool` see the file as gone. To list
  and restore one (use the `mc` image and `local_default` network, or any `mc` with the `invai`
  alias): `mc ls --versions local/invai-local/<key>`, then
  `mc cp --version-id <id> local/invai-local/<key> local/invai-local/<key>`.
  Disk freed by the gate cleanup or the purge tool therefore comes back after about 7 days (the
  MinIO scanner expires old versions), not at once; the local PII purge keeps old versions for 7
  days, as production does. The `full` profile bucket `invai-full` stays unversioned (disposable).
  Proof it works, on a throwaway bucket only (never `invai-local`): `bash scripts/minio-versioning.test.sh` (from `invai-infra`, stack up).
- **mailpit** — `axllent/mailpit`, SMTP on :1025 (no auth), UI/API on :8025. Catches vendor
  and invite emails sent locally; point `invai-backend`'s SMTP env vars at
  `localhost:1025`.
- Every service has a healthcheck; `minio-init` additionally gates on `minio`'s.

All of the above are the **default** compose profile (infra only). A **`full`** profile builds and
runs the four Dockerfiles (backend, imaging, web, floor) plus a one-off `migrate` service, for a
production-like local run. Drive it with `scripts/full.sh`, not a bare `docker compose up`:

```
scripts/full.sh up             # build one image at a time, start the stack, seed if empty, start the worker
scripts/full.sh build          # build the four images only (what `pnpm scan` scans)
scripts/full.sh seed --force   # reset and reseed invai_full from the host
scripts/full.sh down           # stop only the full services (infra and volumes stay)
scripts/full.sh down --purge   # also drop invai_full, its bucket, Valkey DB 9 and the built images
```

- **Own data.** Database `invai_full`, Valkey DB 9 and bucket `invai-full`; the shared dev database
  `invai` is never touched. Postgres roles are cluster-wide, so `invai_app` keeps the local password
  `invai` in this profile (changing it would break dev and the tests).
- **Ports.** api 3000, imaging 8000, web 5173, floor 5174 (nginx inside listens on unprivileged
  8080), bound to `127.0.0.1` only (not reachable from the LAN). Free them first; `full.sh up` refuses if another process holds one.
- **Mode.** api and worker run `NODE_ENV=production` with `ALLOW_MOCKS=true` (mock providers, a
  warning on every start). The golden path passes in this mode. Seed logins and the station token are
  written to `/tmp/invai-full-seed.json`.
- **Release step.** `migrate` runs `bootstrap-cli` -> `migrate-cli` -> `reference-seed-cli` as the
  owner role `invai`, then the api starts as `invai_app`.
- **Seed and worker.** The host seed uses the same placeholder secrets as the containers (they are in
  `full.sh` and the compose file; both are local-only). The seed runs under `env -i` plus that list,
  so a host `invai-backend/.env` (it may hold real keys) cannot reach it. The worker starts after the seed.
- **Imaging dev endpoints.** The image turns `IMAGING_DEV_ENDPOINTS` off (production default). The
  compose service turns it on because the demo seed needs `/sample-art`. Never set it in an AWS stage.
- **Build context.** backend, web and floor link `@invai/contracts` (and `@invai/ui`) via
  `link:../<repo>`, so they build from the **workspace root** with a per-Dockerfile ignore file
  (`<repo>/Dockerfile.dockerignore`, an allowlist; the root is not a git repo). `invai-imaging`
  builds from its own directory. `VITE_API_URL` is a build argument for web and floor.
- Every base image is pinned by digest. To bump one: `docker buildx imagetools inspect <image>:<tag>`.
  The backend image fetches the RDS CA bundle at build time and checks a pinned sha256.
- `pnpm local:full` (`up -d --build`) predates `full.sh`: it builds in parallel and starts the worker
  before any seed. Prefer `full.sh`.

## Observability: local traces (T-32-5)

Tracing is off by default everywhere. To follow one request through api -> outbox relay -> worker
job -> imaging in a local Jaeger:

```
cd local && docker compose --profile observability up -d     # Jaeger 2.21, 127.0.0.1:4318 (OTLP/HTTP) and :16686 (UI)
cd .. && OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 pnpm dev:all
# ... do something, e.g. build a gang sheet, then open http://127.0.0.1:16686
cd local && docker compose stop jaeger && docker compose rm -f jaeger   # traces live in memory only; never `down` (it stops Postgres, Valkey, MinIO, Mailpit too)
```

- Keep the OpenAI and Anthropic key variables set to empty strings in that shell (an empty value, not unset: `invai-backend/.env` may hold real keys), so the mock providers stay on.
- The endpoint must be in the **shell environment**, not in `invai-backend/.env`: the backend starts
  its tracer with `node --import` before `.env` is read. Service names default to `invai-api`,
  `invai-worker` and `invai-imaging` (`OTEL_SERVICE_NAME` overrides; don't set it for `dev:all`, or
  all three get the same name).
- Only allowlisted span attributes are exported (method, route, status, procedure, job and queue
  names, ids, sizes); no query strings, headers, bodies or error messages.
- Query API for scripts: `GET http://127.0.0.1:16686/api/v3/traces?query.service_name=invai-api&query.start_time_min=<RFC3339>&query.start_time_max=<RFC3339>`
  and `GET /api/v3/traces/<traceId>` (Jaeger 2 has no `/api/traces`).
- Deployed stages (T-34-4): the image CMD and the Api and Worker commands already start with `--import ./dist/lib/telemetry.js`.
  Tracing stays off until the optional deploy input `INVAI_OTEL_ENDPOINT` is set (`https://...`, or `http://localhost:<port>` for a
  sidecar; anything else fails the plan). No collector is chosen yet, so leave it empty. What is collected and how to set it:
  `invai-docs/ops/observability.md`.

## AWS (SST)

`sst.config.ts` is written and typechecked against the installed `sst@4.17.1`. Check
`.sst/platform/src/components` before changing a component option; don't rely on docs for other
versions. Nothing has been deployed yet: deploys are the owner's (`deploy-to-environment`), and
the guard hook blocks deploys, secret changes and AWS CLI calls for agents.

### What it creates (per stage)

- **Stages:** `production` (`removal: retain`, `protect`), `staging`, and `demo`. `demo` is the
  only stage with `ALLOW_MOCKS=true` and blank provider-key placeholders. Any other stage name
  behaves like staging.
- **Domain:** one registrable domain from `INVAI_DOMAIN`. In production the hosts are `app.`,
  `floor.` and `api.` plus the domain; on other stages they are `app.<stage>.` and so on. Every
  app is therefore same-site for Better Auth cookies. SST creates the ACM certificates and
  Route 53 records in the domain's hosted zone.
- **Network:** a VPC with a NAT EC2 instance. ECS tasks, RDS and Valkey are in the private
  subnets; only the ALB is public. An S3 gateway endpoint serves the private route tables.
- **RDS Postgres 17:**
  - Instance `t4g.small` (staging) or `t4g.medium` (production), encrypted, `rds.force_ssl=1`.
  - Backups 14 days (35 in production); deletion protection and a final snapshot in
    production; RDS Proxy in production.
  - The api and worker connect as `invai_app` (RLS enforced) with `sslmode=verify-full`.
  - The owner role is used only by the migrate task, the outbox relay and cross-tenant jobs,
    always direct to the instance.
- **Valkey:** cluster mode off and `maxmemory-policy noeviction` (BullMQ), with TLS and AUTH.
- **S3 bucket:**
  - Private, HTTPS only, versioned.
  - Old versions expire after 7 days, so the app's PII purge really removes files within a
    week. Incomplete multipart uploads are aborted after 1 day.
  - CORS allows GET, HEAD and PUT only from the stage's web and floor origins.
  - Per-kind retention is the app's purge job. Keys start with `{companyId}/`, so prefix
    lifecycle rules can't select a kind.
- **KMS key** `alias/invai-<stage>-field-encryption`, for the backend's KMS field-encryption
  provider (`FIELD_ENCRYPTION_PROVIDER=kms`, `FIELD_ENCRYPTION_KMS_KEY_ID`). The api, worker and
  migrate task can Encrypt, Decrypt and GenerateDataKey with it.
- **SES:**
  - Sender domain: `<domain>` in production, `<stage>.<domain>` elsewhere, with DKIM, DMARC
    and a `mail.` MAIL FROM domain.
  - `MAIL_FROM` is `InvAI <no-reply@<sender domain>>`.
- **ECS (Fargate, ARM64):**
  - `Api`: HTTPS on 443 (TLS 1.2/1.3 policy), and HTTP 80 redirects. ALB health is on
    `/readyz`. It autoscales on CPU 60% and 1,000 requests per target.
  - `Worker`.
  - `Imaging`: internal only, reached at `http://<Cloud Map name>:8000`.
  - A `Migrate` one-off task.
  - Every container has a `stopTimeout` of 45 s, and target deregistration takes 30 s. The
    ECS circuit breaker with rollback is on (component default).
- **Secrets reach containers through SSM SecureString parameters** `/invai/<stage>/<ENV>`, so
  they are never plaintext in a task definition. Secrets are not `link`ed.
- **Execution roles read only their own stage's secrets** (S-45). SST's stock execution role
  reads SSM and Secrets Manager on `*`; `Api`, `Worker`, `Imaging` and `Migrate` replace its
  inline policy with `infra/execution-role.ts`: `ssm:GetParameter(s)/GetParameterHistory` on
  `arn:<partition>:ssm:<region>:<account>:parameter/invai/<stage>/*`, no Secrets Manager. The
  managed `AmazonECSTaskExecutionRolePolicy` (ECR pull, logs) is unchanged. Print the policy
  for sample values without AWS: import `executionRolePolicy` from that file with `node`.
- **Static sites** `Web` and `Floor` on CloudFront:
  - A viewer-response function adds the same CSP and security headers that `vite preview` and
    nginx send.
  - The web `connect-src` includes the bucket origin
    `https://<bucket>.s3.<region>.amazonaws.com` (B-190). It is built with the helpers in
    invai-web's `src/lib/build/csp.ts`.
- **WAF (production only)**, on the ALB and on both CloudFront distributions:
  - AWS managed rules: IP reputation, common, and known-bad-inputs.
  - A per-IP rate rule: 20,000 per 5 minutes on the API, 5,000 on CloudFront, with
    `/webhooks/` exempt.
  - The body-size and body-XSS rules only count, because webhook and listing bodies are large
    and contain HTML.

### Owner inputs (before the first deploy of a stage)

| Input | Consumed as |
|---|---|
| AWS account and region | the deploy credentials (profile or OIDC role, `AWS_REGION`); the CloudFront WAF is always `us-east-1` |
| Registrable domain with a Route 53 hosted zone in the account | env `INVAI_DOMAIN` at deploy time |
| `BetterAuthSecret` (32+ chars) | `BETTER_AUTH_SECRET` |
| `FloorTokenSecret` (32+ chars, not the same as the above) | `FLOOR_TOKEN_SECRET` |
| `FieldEncryptionKey` (`k1:<base64 32 bytes>`) | `FIELD_ENCRYPTION_KEY` |
| `ImagingSharedSecret` (32+ chars) | `IMAGING_SHARED_SECRET` (api, worker, imaging) |
| `AppDbPassword` (URL-safe, 32+ chars) | the `invai_app` password in `DATABASE_URL` and the RDS Proxy credential |
| `AnthropicApiKey`, `EasyPostApiKey`, `EasyPostWebhookSecret`, `ShopifyApiKey`, `ShopifyApiSecret`, `StripeSecretKey`, `StripeWebhookSecret` | the env var with the same name in upper snake case |
| `SmtpUrl` (`smtps://<SES SMTP user>:<password>@email-smtp.<region>.amazonaws.com:465`) | `SMTP_URL`; needs SES production access |

Set each secret once per stage with SST's secret command. Outside `demo` no secret has a
placeholder, so a deploy fails while one is missing.

### Release order

`pnpm deploy:demo`, `deploy:staging` or `deploy:prod` runs three steps:

1. Deploy only the `Migrate` task and what it needs (`--target Migrate`).
2. Run it: `pnpm release:migrate:<stage>` runs `infra/run-migrate.ts` inside `sst shell`. The
   task runs `bootstrap-cli`, then `migrate-cli`, then `reference-seed-cli` from the backend
   image, and exits non-zero on failure.
3. Deploy everything else.

If the migration fails, the rollout stops. These steps need AWS credentials, so only the owner
or CI runs them. `.github/workflows/deploy.yml` runs the same script: pick `demo`, `staging` or
`production` (a `v*` tag push deploys `production`). The job's GitHub environment is the stage; it
reads the variables `INVAI_DOMAIN` and `AWS_DEPLOY_ROLE_ARN` (and optionally `INVAI_OTEL_ENDPOINT`)
from that environment and stops with a plain message if one is empty. The role is assumed by OIDC
with the trust policies in `infra/iam/` (see its README). `pnpm deploy:test` checks the workflow,
the scripts and those files without calling AWS.

```
pnpm typecheck    # tsc --noEmit (sst.config.ts, and the invai-web/invai-floor csp.ts it imports)
pnpm lint
```

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

## Scanning (`pnpm scan`)

`pnpm scan` runs gitleaks (history and working tree), trivy (every lockfile and the four
`invai-full-*:local` images), actionlint with SHA-pin and `permissions:` checks, and the S-62
hardening checks, all as containers pinned by digest (`scan/tools.env`). It exits non-zero on any
secret or any HIGH/CRITICAL finding with a fix. Ignores live only in `scan/ignores.json`, each with
a reason, an owner and an expiry. `pnpm scan:test` tests the machinery. How-to and CI layout:
`invai-docs/ops/scanning.md`.

## Contracts consumer check (`pnpm contracts:check`)

`pnpm contracts:check [--contracts <dir>]` typechecks invai-backend, invai-web, invai-floor and
invai-ui against a contracts tree (default `../invai-contracts`) and prints one PASS or FAIL line per
consumer with the contracts version. Exit 0 all pass, 1 a consumer failed (first 20 error lines each),
2 setup error. It writes a throwaway tsconfig per consumer in a temp dir (`extends` the consumer's
tsconfig, `paths` maps `@invai/contracts` to `<dir>/src/index.ts`), so no repo, link or
`node_modules` is touched. A throwaway copy of contracts needs `node_modules` symlinked to the real
one. When `<dir>` is a git repo and `src/` changed since the commit that last set `"version"`, a
missing `## <version>` CHANGELOG heading prints a WARN (not a failure). `pnpm gate` runs it right
after invai-contracts' own checks, only when invai-contracts is in the gate. Test it with
`pnpm contracts:check:test` (add `--mutants` to prove each case fails against a broken script).
It typechecks working trees as they are, so another person's unfinished edit in a consumer shows up
as a FAIL: run `git -C <repo> status --short` before blaming the contracts change.
