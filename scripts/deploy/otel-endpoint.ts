// Deploy-time tracing input (T-34-4). Imported by sst.config.ts and run by deploy-config.test.sh.
// Erasable TypeScript only, so `node` can run it without a build step.

const LOOPBACK = new Set(["localhost", "127.0.0.1"]);

/**
 * The OTLP endpoint for a stage, or null when tracing stays off (unset or blank).
 * `https://…` is allowed; `http://` only for a sidecar collector in the same task
 * (`http://localhost:<port>` or `http://127.0.0.1:<port>`). Anything else throws.
 */
export function otelEndpoint(raw: string | undefined): string | null {
  const value = (raw ?? "").trim();
  if (!value) return null;
  const refuse = (why: string): never => {
    throw new Error(
      `INVAI_OTEL_ENDPOINT ${why}. Use https://<collector>, or http://localhost:<port> / ` +
        "http://127.0.0.1:<port> for a collector sidecar in the same task. Leave it empty to keep tracing off.",
    );
  };
  const url = (() => {
    try {
      return new URL(value);
    } catch {
      return null;
    }
  })();
  if (!url) return refuse("is not a URL");
  if (url.username || url.password) return refuse("must not contain a user name or password");
  if (url.search || url.hash) return refuse("must not contain a query string or fragment");
  if (url.protocol === "https:") return value;
  if (url.protocol === "http:" && LOOPBACK.has(url.hostname) && url.port) return value;
  return refuse("must be https, or http on localhost with a port");
}

/** Environment for one service: empty when tracing is off, else endpoint, service name and stage. */
export function otelEnv(
  raw: string | undefined,
  serviceName: "invai-api" | "invai-worker" | "invai-imaging",
  stage: string,
): Record<string, string> {
  const endpoint = otelEndpoint(raw);
  if (!endpoint) return {};
  return {
    OTEL_EXPORTER_OTLP_ENDPOINT: endpoint,
    OTEL_SERVICE_NAME: serviceName,
    OTEL_RESOURCE_ATTRIBUTES: `deployment.environment=${stage}`,
  };
}
