/// <reference path="./.sst/platform/config.d.ts" />

/**
 * InvAI on AWS. Repos are siblings of this one: ../invai-backend, ../invai-imaging,
 * ../invai-web, ../invai-floor. Check component options against sst.dev/docs when
 * deploying for the first time (written for SST 4.x).
 */
export default $config({
  app(input) {
    return {
      name: "invai",
      home: "aws",
      removal: input?.stage === "production" ? "retain" : "remove",
      protect: input?.stage === "production",
    };
  },
  async run() {
    const isProd = $app.stage === "production";

    // Cheap NAT instance instead of NAT gateways (~$30/mo saved).
    const vpc = new sst.aws.Vpc("Vpc", { nat: "ec2" });

    const db = new sst.aws.Postgres("Db", { vpc });
    const redis = new sst.aws.Redis("Redis", { vpc });
    const files = new sst.aws.Bucket("Files");

    const cluster = new sst.aws.Cluster("Cluster", { vpc });

    const imaging = new sst.aws.Service("Imaging", {
      cluster,
      image: { context: "../invai-imaging" },
      cpu: "2 vCPU",
      memory: "8 GB",
      link: [files, redis],
    });

    const api = new sst.aws.Service("Api", {
      cluster,
      image: { context: "../invai-backend" },
      link: [db, redis, files],
      environment: { IMAGING_URL: imaging.url },
      loadBalancer: { ports: [{ listen: "80/http", forward: "3000/http" }] },
      scaling: { min: isProd ? 2 : 1, max: isProd ? 6 : 1 },
    });

    new sst.aws.Service("Worker", {
      cluster,
      image: { context: "../invai-backend" },
      command: ["node", "dist/index.js"],
      link: [db, redis, files],
      environment: { IMAGING_URL: imaging.url },
    });

    const web = new sst.aws.StaticSite("Web", {
      path: "../invai-web",
      build: { command: "pnpm build", output: "dist" },
      environment: { VITE_API_URL: api.url },
    });

    const floor = new sst.aws.StaticSite("Floor", {
      path: "../invai-floor",
      build: { command: "pnpm build", output: "dist" },
      environment: { VITE_API_URL: api.url },
    });

    return { api: api.url, web: web.url, floor: floor.url };
  },
});
