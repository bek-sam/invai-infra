/**
 * What the app's own services may do with the `Files` bucket (T-49-2, S-87, architect ruling R3),
 * and the crash alarm that watches them (B-306).
 *
 * The bucket keeps old versions for 7 days so an accidental delete is recoverable. SST's
 * `link: [files]` would grant `s3:*`, which lets a compromised task read, list and delete those
 * old versions (purged PII) or change versioning, lifecycle and bucket policy. So no service links
 * the bucket: each gets the explicit allow list below plus an explicit Deny. `S3_BUCKET` carries
 * the bucket name; nothing reads `Resource.Files`.
 *
 * Kept free of SST/Pulumi globals so plain `node --experimental-strip-types` can load it. Three
 * readers share these lists: sst.config.ts, scripts/files-iam.test.sh (static) and
 * scripts/files-iam-minio.test.sh (generated MinIO policy).
 */

/** Allowed on `<bucket arn>/*`: current-object reads, writes, deletes and multipart. */
export const FILES_ALLOW_OBJECT_ACTIONS = [
  "s3:GetObject",
  "s3:PutObject",
  "s3:DeleteObject",
  "s3:AbortMultipartUpload",
] as const;

/**
 * Allowed on `<bucket arn>`: ListObjectsV2 and HeadBucket. Without it a HEAD of a missing key
 * answers 403 instead of 404 and imaging `exists()` breaks. No CreateBucket: production never
 * creates the bucket (S3_CREATE_BUCKET=false).
 */
export const FILES_ALLOW_BUCKET_ACTIONS = ["s3:ListBucket"] as const;

/** Explicit names on purpose: no wildcards, so a reader sees exactly what is refused. */
export const FILES_DENY_ACTIONS = [
  "s3:GetObjectVersion",
  "s3:GetObjectVersionAttributes",
  "s3:GetObjectVersionAcl",
  "s3:GetObjectVersionTagging",
  "s3:GetObjectVersionTorrent",
  "s3:ListBucketVersions",
  "s3:DeleteObjectVersion",
  "s3:DeleteObjectVersionTagging",
  "s3:PutObjectVersionAcl",
  "s3:PutObjectVersionTagging",
  "s3:PutBucketVersioning",
  "s3:PutLifecycleConfiguration",
  "s3:PutBucketPolicy",
  "s3:DeleteBucketPolicy",
  "s3:DeleteBucket",
  "s3:PutBucketAcl",
  "s3:PutObjectAcl",
  "s3:PutBucketPublicAccessBlock",
  "s3:PutBucketOwnershipControls",
  "s3:PutReplicationConfiguration",
  "s3:BypassGovernanceRetention",
] as const;

export interface FilesStatement<R> {
  effect: "allow" | "deny";
  actions: string[];
  resources: R[];
}

/**
 * The four statements for a service role. `bucketArn` is the bucket, `objectsArn` is
 * `<bucket arn>/*`. The Deny covers both, so bucket-level actions (versioning, lifecycle,
 * policy) are refused as well as object-level ones.
 */
export function filesStatements<R>(bucketArn: R, objectsArn: R): FilesStatement<R>[] {
  return [
    { effect: "allow", actions: [...FILES_ALLOW_OBJECT_ACTIONS], resources: [objectsArn] },
    { effect: "allow", actions: [...FILES_ALLOW_BUCKET_ACTIONS], resources: [bucketArn] },
    { effect: "deny", actions: [...FILES_DENY_ACTIONS], resources: [bucketArn, objectsArn] },
  ];
}

/** The same statements as an AWS-style policy document for a bucket name (local MinIO proof). */
export function filesPolicyDocument(bucket: string) {
  const bucketArn = `arn:aws:s3:::${bucket}`;
  return {
    Version: "2012-10-17",
    Statement: filesStatements(bucketArn, `${bucketArn}/*`).map((s, i) => ({
      Sid: `Files${i}`,
      Effect: s.effect === "allow" ? "Allow" : "Deny",
      Action: s.actions,
      Resource: s.resources,
    })),
  };
}

// ---- B-306: crash alarm ---------------------------------------------------------------------

/** Exact message of `process.on("unhandledRejection")` in api/server.ts and worker/index.ts. */
export const UNHANDLED_REJECTION_MSG = "unhandled rejection";
/** Production logs are JSON lines with a `msg` field (backend src/lib/log.ts). */
export const UNHANDLED_REJECTION_FILTER_PATTERN = `{ $.msg = "${UNHANDLED_REJECTION_MSG}" }`;
export const UNHANDLED_REJECTION_METRIC_NAME = "UnhandledRejection";

export const UNHANDLED_REJECTION_ALARM = {
  metricName: UNHANDLED_REJECTION_METRIC_NAME,
  statistic: "Sum",
  period: 300,
  evaluationPeriods: 1,
  threshold: 1,
  comparisonOperator: "GreaterThanOrEqualToThreshold",
  treatMissingData: "notBreaching",
} as const;

export function metricNamespace(stage: string): string {
  return `InvAI/${stage}`;
}

export type AppLogService = "api" | "worker" | "imaging" | "migrate";

/** One explicit log group per service, so the metric filter never guesses SST's generated name. */
export function appLogGroupName(stage: string, service: AppLogService): string {
  if (!/^[a-z0-9][a-z0-9-]*$/i.test(stage)) throw new Error(`Unsafe stage name: ${stage}`);
  return `/invai/${stage}/${service}`;
}
