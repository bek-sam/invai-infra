# invai-infra

Infrastructure for all InvAI services.

## Local development

```
pnpm local:up     # Postgres 17 (5432), Valkey (6379, noeviction), MinIO S3 (9000, console 9001)
pnpm local:down
```

## AWS (SST)

`sst.config.ts` defines the VPC (NAT instance), RDS Postgres, ElastiCache Valkey, S3, an ECS cluster with three services (Api, Worker, Imaging), and two static sites (Web, Floor) behind CloudFront. It builds images from the sibling repos, so clone all repos into the same parent folder.

```
pnpm install
pnpm deploy:staging
```

Before storing Amazon buyer data, turn on: CloudTrail + 12-month log retention, GuardDuty, Security Hub, Inspector, customer-managed KMS keys with rotation, a 30-day S3 expiry rule for labels and packing slips, and WAF on public endpoints. See `invai-docs/tools-stack.md`.
