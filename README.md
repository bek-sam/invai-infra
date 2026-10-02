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

- Sets its own `TEST_DATABASE_URL`/`TEST_MIGRATION_DATABASE_URL` (`invai_test`) and
  `TEST_REDIS_URL` (Valkey DB 15) for the backend test run, rather than relying on a shell's
  exported env.
- stdout is exactly one line per suite — `PASS <repo> <suite> <n> passed` or
  `FAIL <repo> <suite>: <failing test names>` — plus a final `log: <path>` line pointing at the
  full output (`invai-infra/.gate/run-<timestamp>.log`, gitignored). Everything else goes to
  that log or, for a refusal, to stderr.
- Refuses to start (exit 1, one-line reason on stderr) if another process already holds the test
  Postgres DB (`invai_test`) or the test Redis DB (Valkey DB 15) — checked for every run, since
  `invai-backend`'s `test` suite uses both. When the golden-path phase will run (backend/web/floor
  in scope), it also refuses if ports 3000/8000/5173/5174 are already held by something this run
  didn't start. It never kills a process it didn't start, and a trap stops everything it did
  start even on failure.
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
  A full run resets the shared dev DB, so get a slot from whoever coordinates the gate before
  running it for real (`run-golden-path`'s "before you start").

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

`pnpm deploy:staging` (or `deploy:prod`) runs three steps:

1. Deploy only the `Migrate` task and what it needs (`--target Migrate`).
2. Run it: `pnpm release:migrate:<stage>` runs `infra/run-migrate.ts` inside `sst shell`. The
   task runs `bootstrap-cli`, then `migrate-cli`, then `reference-seed-cli` from the backend
   image, and exits non-zero on failure.
3. Deploy everything else.

If the migration fails, the rollout stops. These steps need AWS credentials, so only the owner
or CI runs them. `.github/workflows/deploy.yml` still has a placeholder `role-to-assume` and
doesn't run the migrate step yet (wave 25).

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
