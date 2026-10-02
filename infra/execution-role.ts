/**
 * Least-privilege inline policy for the ECS execution roles of Api, Worker, Imaging and Migrate
 * (S-45). SST's stock execution role (`.sst/platform/src/components/aws/fargate.ts`,
 * `createExecutionRole`) grants `ssm:GetParameter*` and `secretsmanager:GetSecretValue` on
 * `"*"`, which would let a task in one stage read every other stage's parameters, including
 * production's MIGRATION_DATABASE_URL. This replaces that inline policy with a read of the task's
 * own stage only: `/invai/<stage>/*`, where sst.config.ts `toSsm()` writes every secret.
 *
 * Kept free of SST/Pulumi globals so it can be evaluated with plain `node` (see README.md).
 * The stock AmazonECSTaskExecutionRolePolicy (ECR pull, CloudWatch Logs) is a managed policy
 * on the same role and is left as it is.
 */

export interface StageScope {
  partition: string;
  region: string;
  accountId: string;
  stage: string;
}

const STAGE_NAME = /^[a-z0-9][a-z0-9-]*$/i;

/** ARN pattern for every SSM parameter of one stage: `arn:<p>:ssm:<region>:<acct>:parameter/invai/<stage>/*`. */
export function stageParameterArn({ partition, region, accountId, stage }: StageScope): string {
  if (!STAGE_NAME.test(stage)) throw new Error(`Unsafe stage name for an IAM resource: ${stage}`);
  if (!/^\d{12}$/.test(accountId)) throw new Error(`Not an AWS account id: ${accountId}`);
  if (!/^[a-z0-9-]+$/.test(region)) throw new Error(`Not an AWS region: ${region}`);
  if (!/^aws[a-z-]*$/.test(partition)) throw new Error(`Not an AWS partition: ${partition}`);
  return `arn:${partition}:ssm:${region}:${accountId}:parameter/invai/${stage}/*`;
}

/**
 * The execution role's only inline statement. No Secrets Manager action: sst.config.ts hands
 * secrets to containers through SSM SecureString parameters only (SST's `sst.Secret` values are
 * read at deploy time by the deployer, not by the task).
 */
export function executionRolePolicy(scope: StageScope) {
  return {
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "ReadOwnStageSsm",
        Effect: "Allow",
        Action: ["ssm:GetParameters", "ssm:GetParameter", "ssm:GetParameterHistory"],
        Resource: [stageParameterArn(scope)],
      },
    ],
  };
}
