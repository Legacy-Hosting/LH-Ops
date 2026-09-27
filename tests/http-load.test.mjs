import assert from "node:assert/strict";
import { test } from "node:test";
import {
  assertHttpTargetAllowed,
  runHttpLoadTest,
  validateHttpLoadConfig,
} from "../scripts/load-http.mjs";

function configuration(overrides = {}) {
  return {
    name: "local-smoke",
    mode: "smoke",
    baseUrl: "http://127.0.0.1:8080",
    totalRequests: 8,
    concurrency: 2,
    maxRequestsPerSecond: 1000,
    timeoutMs: 1000,
    routes: [
      {
        name: "readiness",
        path: "/health",
        weight: 1,
        expectedStatuses: [200],
        jsonAssertions: { status: "ok", database: "connected" },
      },
    ],
    thresholds: {
      minimumSuccessRate: 1,
      maximumP95Ms: 100,
      maximumP99Ms: 200,
      maximumNetworkErrors: 0,
      minimumRequestsPerSecond: 0.1,
    },
    ...overrides,
  };
}

test("HTTP load test reports latency, throughput, and readiness assertions", async () => {
  const report = await runHttpLoadTest(configuration(), {
    fetch: async () => new Response(
      JSON.stringify({ status: "ok", database: "connected" }),
      { status: 200, headers: { "content-type": "application/json" } },
    ),
  });
  assert.equal(report.attempted, 8);
  assert.equal(report.succeeded, 8);
  assert.equal(report.passed, true);
  assert.equal(report.statusCounts["200"], 8);
  assert.equal(report.routeCounts.readiness, 8);
  assert.ok(report.requestsPerSecond > 0);
});

test("HTTP load test fails when a healthy status contains degraded state", async () => {
  const report = await runHttpLoadTest(configuration({ totalRequests: 3 }), {
    fetch: async () => new Response(
      JSON.stringify({ status: "ok", database: "unavailable" }),
      { status: 200, headers: { "content-type": "application/json" } },
    ),
  });
  assert.equal(report.succeeded, 0);
  assert.equal(report.passed, false);
  assert.equal(report.errorCounts.assertion_readiness_database, 3);
});

test("public and production targets require deliberate bounded execution", () => {
  const publicConfig = validateHttpLoadConfig(configuration({
    baseUrl: "https://staging.example.com",
  }));
  assert.throws(() => assertHttpTargetAllowed(publicConfig), /confirm-host/);
  assert.doesNotThrow(() => assertHttpTargetAllowed(publicConfig, "staging.example.com"));

  const productionCapacity = validateHttpLoadConfig(configuration({
    mode: "capacity",
    baseUrl: "https://api.legacyhosting.xyz",
  }));
  assert.throws(
    () => assertHttpTargetAllowed(productionCapacity, "api.legacyhosting.xyz"),
    /bounded smoke profile/,
  );
});

test("load routes are read-only and cannot traverse the target origin", () => {
  assert.throws(
    () => validateHttpLoadConfig(configuration({
      routes: [{
        name: "mutation",
        path: "/api/v1/applications",
        method: "POST",
        expectedStatuses: [200],
      }],
    })),
    /GET or HEAD/,
  );
  assert.throws(
    () => validateHttpLoadConfig(configuration({
      routes: [{
        name: "escape",
        path: "/../admin",
        expectedStatuses: [200],
      }],
    })),
    /stay below/,
  );
});
