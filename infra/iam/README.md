# IAM policy documents (copy into the AWS console; nothing here is applied by code)

Placeholders to replace: `<ACCOUNT_ID>`, `<REGION>`, `<MAIL_DOMAIN>`, `<CONFIG_SET_NAME>`. Nothing else
is a placeholder, and no real account id belongs in this folder.

| File | Used by (`invai-docs/build/go-live-checklist.md`) | What it is |
|---|---|---|
| `deploy-trust-nonprod.json` | B2: trust policy of the role for `demo` and `staging` | GitHub may assume it only from the `demo` or `staging` environment of `bek-sam/invai-infra` |
| `deploy-trust-production.json` | B2: trust policy of the role for `production` | Same, only from the `production` environment |
| `smtp-send.json` | E3: permission policy of the SES SMTP IAM user (one user per stage) | May only send raw email through the stage's sending domain and its default configuration set (SST's Email component creates that set) |

Notes for the owner:
- Set the role's MaxSessionDuration to 7200 seconds on both roles. The workflow asks for a two-hour
  session; a first deploy plus a 20-minute release task can outlive the one-hour default and leave the
  SST lock held.
- The trust subject names the environment, not the branch. The only branch check is the environment
  setting in GitHub (B5): `demo` and `staging` allow deployment from `main` only; `production` allows
  `main` and tags `v*` and needs the owner as reviewer.
- One non-prod role for `demo` and `staging` adds no boundary compared with two roles: they share an
  account and the same account-wide permission policy. Real separation from production needs a separate
  account (S-45) or a narrowed permission policy.
- The deploy role's permission policy stays as written in checklist B3. Narrowing it needs a real
  account to prove SST still deploys (follow-up).
