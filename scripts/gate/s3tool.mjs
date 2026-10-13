#!/usr/bin/env node
// Local MinIO helper for the gate cleanup and the orphan purge (T-42-2). Uses the S3 client that
// invai-backend already installs; talks only to a localhost endpoint and only ever deletes under
// one exact `<uuid>/` prefix of bucket invai-gate (T-45-5: the gate's own bucket, never the dev bucket invai-local).
//
//   s3tool.mjs scan                  TSV per top-level prefix: prefix<TAB>objects<TAB>bytes<TAB>newest-epoch-seconds
//   s3tool.mjs buckets               names of all buckets, one per line (read only)
//   s3tool.mjs count <prefix>        prints "objects<TAB>bytes" under the prefix (read only)
//   s3tool.mjs stat <key>...         prints "<key><TAB>ok|MISSING" per key (read only)
//   s3tool.mjs delete-prefix <uuid>/ deletes every object under that prefix, prints "objects<TAB>bytes"
//   s3tool.mjs ensure-bucket         creates bucket invai-gate when missing (idempotent); refuses any other name
//
// Env: S3_ENDPOINT (default http://localhost:9000), S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, S3_BUCKET
// (default invai-gate; `scan`, `count` and `stat` accept any local bucket, so a read-only count of invai-local
// needs S3_BUCKET=invai-local explicitly; deletes and ensure-bucket accept only invai-gate).
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const backend = resolve(here, "../../../invai-backend/package.json");
const { S3Client, ListObjectsV2Command, DeleteObjectsCommand, HeadObjectCommand, ListBucketsCommand, HeadBucketCommand, CreateBucketCommand } =
  createRequire(backend)("@aws-sdk/client-s3");

const UUID_PREFIX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/$/;
const DELETE_BUCKET = "invai-gate";
const endpoint = process.env.S3_ENDPOINT || "http://localhost:9000";
const bucket = process.env.S3_BUCKET || DELETE_BUCKET;

function die(msg) {
  process.stderr.write(`s3tool: ${msg}\n`);
  process.exit(2);
}

// S-83 (T-46-2): with forcePathStyle a path on the endpoint ("http://localhost:9000/invai-local") changes
// the bucket MinIO sees, so only a bare scheme://host[:port][/] endpoint is accepted. Checked before any request.
let endpointUrl;
try {
  endpointUrl = new URL(endpoint);
} catch {
  die("endpoint is not a URL");
}
if (endpointUrl.protocol !== "http:" && endpointUrl.protocol !== "https:") die("endpoint scheme must be http or https");
if (endpointUrl.username !== "" || endpointUrl.password !== "" || endpoint.includes("@")) die("endpoint must not carry user info");
if (endpointUrl.pathname !== "/" && endpointUrl.pathname !== "") die("endpoint must not carry a path");
if (endpointUrl.search !== "" || endpoint.includes("?")) die("endpoint must not carry a query");
if (endpointUrl.hash !== "" || endpoint.includes("#")) die("endpoint must not carry a fragment");
const host = endpointUrl.hostname;
if (host !== "localhost" && host !== "127.0.0.1") die(`endpoint host '${host}' is not local`);

const s3 = new S3Client({
  region: "us-east-1",
  endpoint,
  forcePathStyle: true,
  credentials: {
    accessKeyId: process.env.S3_ACCESS_KEY_ID || "invai",
    secretAccessKey: process.env.S3_SECRET_ACCESS_KEY || "invai-secret",
  },
});

async function* pages(prefix) {
  let token;
  do {
    const r = await s3.send(
      new ListObjectsV2Command({ Bucket: bucket, Prefix: prefix, ContinuationToken: token }),
    );
    yield r.Contents ?? [];
    token = r.IsTruncated ? r.NextContinuationToken : undefined;
  } while (token);
}

const [cmd, ...args] = process.argv.slice(2);

if (cmd === "scan") {
  const acc = new Map();
  for await (const items of pages("")) {
    for (const o of items) {
      const i = o.Key.indexOf("/");
      const p = i < 0 ? "(root)" : o.Key.slice(0, i);
      const a = acc.get(p) ?? { n: 0, b: 0, t: 0 };
      a.n += 1;
      a.b += o.Size ?? 0;
      a.t = Math.max(a.t, Math.floor((o.LastModified?.getTime() ?? 0) / 1000));
      acc.set(p, a);
    }
  }
  for (const [p, a] of acc) process.stdout.write(`${p}\t${a.n}\t${a.b}\t${a.t}\n`);
} else if (cmd === "buckets") {
  const r = await s3.send(new ListBucketsCommand({}));
  for (const x of r.Buckets ?? []) process.stdout.write(`${x.Name}\n`);
} else if (cmd === "count") {
  let n = 0;
  let b = 0;
  for await (const items of pages(args[0] ?? "")) {
    for (const o of items) {
      n += 1;
      b += o.Size ?? 0;
    }
  }
  process.stdout.write(`${n}\t${b}\n`);
} else if (cmd === "stat") {
  for (const key of args) {
    let state = "ok";
    try {
      await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
    } catch {
      state = "MISSING";
    }
    process.stdout.write(`${key}\t${state}\n`);
  }
} else if (cmd === "ensure-bucket") {
  if (bucket !== DELETE_BUCKET) die(`refusing to create bucket '${bucket}'`);
  try {
    await s3.send(new HeadBucketCommand({ Bucket: bucket }));
    process.stdout.write("exists\n");
  } catch (e) {
    if (e?.$metadata?.httpStatusCode !== 404 && e?.name !== "NotFound") throw e;
    await s3.send(new CreateBucketCommand({ Bucket: bucket }));
    process.stdout.write("created\n");
  }
} else if (cmd === "delete-prefix") {
  const prefix = args[0] ?? "";
  if (!UUID_PREFIX.test(prefix)) die(`refusing prefix '${prefix}': must be exactly <uuid>/`);
  // second, independent shape check: exactly 36 UUID characters plus one slash, never empty
  if (prefix.length !== 37 || prefix.indexOf("/") !== 36) die(`refusing prefix '${prefix}': wrong length`);
  if (bucket !== DELETE_BUCKET) die(`refusing to delete in bucket '${bucket}'`);
  let n = 0;
  let b = 0;
  for await (const items of pages(prefix)) {
    if (items.length === 0) continue;
    if (items.some((o) => !o.Key.startsWith(prefix))) die("listing returned a key outside the prefix");
    const r = await s3.send(
      new DeleteObjectsCommand({
        Bucket: bucket,
        Delete: { Objects: items.map((o) => ({ Key: o.Key })), Quiet: true },
      }),
    );
    if (r.Errors?.length) die(`delete failed for ${r.Errors.length} object(s)`);
    n += items.length;
    b += items.reduce((s, o) => s + (o.Size ?? 0), 0);
  }
  process.stdout.write(`${n}\t${b}\n`);
} else {
  die("usage: scan | buckets | count <prefix> | stat <key>... | ensure-bucket | delete-prefix <uuid>/");
}
