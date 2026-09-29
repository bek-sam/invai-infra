/**
 * Runs the one-off `Migrate` ECS task (bootstrap `invai_app` -> migrate -> reference seed, see
 * sst.config.ts) and waits for it. Exits 0 only when the container exited 0, so a deploy script
 * can refuse to roll out on a failed migration (B-03, B-59).
 *
 * Needs AWS credentials for the stage, so the owner (or CI, wave 25) runs it through `sst shell`,
 * which injects the linked resources:
 *   pnpm release:migrate:staging
 */
import { Resource } from "sst";
import { task } from "sst/aws/task";

const TIMEOUT_MS = 20 * 60_000;
const POLL_MS = 10_000;

// `Resource`'s generated types (sst-env.d.ts) only exist after a deploy, so look it up by name.
const migrate = (Resource as unknown as Record<string, task.Resource | undefined>).Migrate;
if (!migrate) {
  console.error("Migrate task not found. Run through `sst shell --stage <stage>` after a deploy.");
  process.exit(1);
}

const started = await task.run(migrate);
console.log(`migrate task started: ${started.arn}`);

const deadline = Date.now() + TIMEOUT_MS;
while (Date.now() < deadline) {
  await new Promise((resolve) => setTimeout(resolve, POLL_MS));
  const current = await task.describe(migrate, started.arn);
  if (current.status !== "STOPPED") continue;
  const stopped = current.response?.tasks?.[0];
  const exitCode = stopped?.containers?.[0]?.exitCode;
  console.log(`migrate task stopped: exit ${exitCode ?? "none"} (${stopped?.stoppedReason ?? ""})`);
  process.exit(exitCode === 0 ? 0 : 1);
}
console.error(`migrate task still running after ${TIMEOUT_MS / 60_000} minutes: ${started.arn}`);
process.exit(1);
