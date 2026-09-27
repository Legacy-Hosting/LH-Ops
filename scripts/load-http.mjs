#!/usr/bin/env node
import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const productionHosts = new Set([
  "api.legacyhosting.xyz",
  "auth.legacyhosting.xyz",
]);

function integer(value, name, minimum, maximum) {
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer between ${minimum} and ${maximum}`);
  }
  return value;
}

function finiteNumber(value, name, minimum, maximum) {
  if (!Number.isFinite(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be between ${minimum} and ${maximum}`);
  }
  return value;
}

function primitive(value) {
  return value === null || ["string", "number", "boolean"].includes(typeof value);
}

export function validateHttpLoadConfig(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new Error("Load-test configuration must be a JSON object");
  }
  const name = String(input.name ?? "").trim();
  if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{1,79}$/.test(name)) {
    throw new Error("name must be a safe 2-80 character identifier");
  }
  const mode = input.mode;
  if (mode !== "smoke" && mode !== "capacity") {
    throw new Error("mode must be smoke or capacity");
  }
  const baseUrl = new URL(String(input.baseUrl ?? ""));
  if (!["http:", "https:"].includes(baseUrl.protocol) || baseUrl.username || baseUrl.password) {
    throw new Error("baseUrl must be an HTTP(S) URL without credentials");
  }
  if (baseUrl.search || baseUrl.hash) {
    throw new Error("baseUrl must not contain a query or fragment");
  }

  const durationSeconds = input.durationSeconds === undefined
    ? undefined
    : integer(input.durationSeconds, "durationSeconds", 1, 900);
  const totalRequests = input.totalRequests === undefined
    ? undefined
    : integer(input.totalRequests, "totalRequests", 1, 1_000_000);
  if ((durationSeconds === undefined) === (totalRequests === undefined)) {
    throw new Error("Configure exactly one of durationSeconds or totalRequests");
  }
  const concurrency = integer(input.concurrency, "concurrency", 1, 100);
  const maxRequestsPerSecond = integer(
    input.maxRequestsPerSecond,
    "maxRequestsPerSecond",
    1,
    1_000,
  );
  const timeoutMs = integer(input.timeoutMs ?? 3_000, "timeoutMs", 100, 30_000);
  const maxResponseBytes = integer(
    input.maxResponseBytes ?? 1_048_576,
    "maxResponseBytes",
    1_024,
    10_485_760,
  );

  if (!Array.isArray(input.routes) || input.routes.length < 1 || input.routes.length > 20) {
    throw new Error("routes must contain between 1 and 20 entries");
  }
  const routes = input.routes.map((candidate, index) => {
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
      throw new Error(`routes[${index}] must be an object`);
    }
    const routeName = String(candidate.name ?? "").trim();
    if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{1,79}$/.test(routeName)) {
      throw new Error(`routes[${index}].name is invalid`);
    }
    const path = String(candidate.path ?? "");
    if (!path.startsWith("/") || path.includes("\\") || path.split("/").includes("..")) {
      throw new Error(`routes[${index}].path must stay below the configured origin`);
    }
    const method = String(candidate.method ?? "GET").toUpperCase();
    if (method !== "GET" && method !== "HEAD") {
      throw new Error(`routes[${index}].method must be GET or HEAD`);
    }
    const weight = integer(candidate.weight ?? 1, `routes[${index}].weight`, 1, 100);
    if (!Array.isArray(candidate.expectedStatuses) || candidate.expectedStatuses.length < 1) {
      throw new Error(`routes[${index}].expectedStatuses must not be empty`);
    }
    const expectedStatuses = candidate.expectedStatuses.map((status) =>
      integer(status, `routes[${index}].expectedStatuses`, 100, 599));
    const jsonAssertions = candidate.jsonAssertions ?? {};
    if (!jsonAssertions || typeof jsonAssertions !== "object" || Array.isArray(jsonAssertions)) {
      throw new Error(`routes[${index}].jsonAssertions must be an object`);
    }
    for (const [key, value] of Object.entries(jsonAssertions)) {
      if (!/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$/.test(key) || !primitive(value)) {
        throw new Error(`routes[${index}] contains an unsafe JSON assertion`);
      }
    }
    return {
      name: routeName,
      path,
      method,
      weight,
      expectedStatuses: [...new Set(expectedStatuses)],
      jsonAssertions,
    };
  });

  const thresholdsInput = input.thresholds;
  if (!thresholdsInput || typeof thresholdsInput !== "object" || Array.isArray(thresholdsInput)) {
    throw new Error("thresholds must be an object");
  }
  const thresholds = {
    minimumSuccessRate: finiteNumber(
      thresholdsInput.minimumSuccessRate,
      "thresholds.minimumSuccessRate",
      0.5,
      1,
    ),
    maximumP95Ms: integer(
      thresholdsInput.maximumP95Ms,
      "thresholds.maximumP95Ms",
      1,
      60_000,
    ),
    maximumP99Ms: integer(
      thresholdsInput.maximumP99Ms,
      "thresholds.maximumP99Ms",
      1,
      60_000,
    ),
    maximumNetworkErrors: integer(
      thresholdsInput.maximumNetworkErrors ?? 0,
      "thresholds.maximumNetworkErrors",
      0,
      1_000_000,
    ),
    minimumRequestsPerSecond: finiteNumber(
      thresholdsInput.minimumRequestsPerSecond ?? Math.max(0.1, maxRequestsPerSecond * 0.8),
      "thresholds.minimumRequestsPerSecond",
      0.1,
      1_000,
    ),
  };
  if (thresholds.maximumP99Ms < thresholds.maximumP95Ms) {
    throw new Error("maximumP99Ms must be greater than or equal to maximumP95Ms");
  }

  return {
    name,
    mode,
    baseUrl: baseUrl.toString().replace(/\/$/, ""),
    durationSeconds,
    totalRequests,
    concurrency,
    maxRequestsPerSecond,
    timeoutMs,
    maxResponseBytes,
    routes,
    thresholds,
  };
}

function privateTarget(hostname) {
  const normalized = hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (normalized === "localhost" || normalized === "::1" || normalized.endsWith(".internal")) {
    return true;
  }
  if (/^127\./.test(normalized) || /^10\./.test(normalized) || /^192\.168\./.test(normalized)) {
    return true;
  }
  const match = normalized.match(/^172\.(\d{1,3})\./);
  return Boolean(match && Number(match[1]) >= 16 && Number(match[1]) <= 31);
}

export function assertHttpTargetAllowed(config, confirmedHost) {
  const host = new URL(config.baseUrl).hostname.toLowerCase();
  if (productionHosts.has(host)) {
    if (
      config.mode !== "smoke" ||
      config.concurrency > 5 ||
      config.maxRequestsPerSecond > 5 ||
      (config.durationSeconds ?? 0) > 120 ||
      (config.totalRequests ?? 0) > 600
    ) {
      throw new Error("Production targets allow only the bounded smoke profile");
    }
  }
  if (!privateTarget(host) && confirmedHost?.toLowerCase() !== host) {
    throw new Error(`Public target requires --confirm-host ${host}`);
  }
}

function nestedValue(input, dottedPath) {
  let value = input;
  for (const segment of dottedPath.split(".")) {
    if (!value || typeof value !== "object" || !(segment in value)) return undefined;
    value = value[segment];
  }
  return value;
}

function percentile(sorted, fraction) {
  if (!sorted.length) return 0;
  const index = Math.max(0, Math.ceil(sorted.length * fraction) - 1);
  return Math.round(sorted[index] * 100) / 100;
}

function addCount(record, key) {
  record[key] = (record[key] ?? 0) + 1;
}

export async function runHttpLoadTest(input, dependencies = {}) {
  const config = validateHttpLoadConfig(input);
  const fetchImplementation = dependencies.fetch ?? globalThis.fetch;
  const sleep = dependencies.sleep ?? ((milliseconds) =>
    new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds)));
  const schedule = config.routes.flatMap((route) => Array(route.weight).fill(route));
  const startedAtMs = Date.now();
  const deadline = config.durationSeconds === undefined
    ? undefined
    : startedAtMs + config.durationSeconds * 1_000;
  let nextRequest = 0;
  let succeeded = 0;
  let networkErrors = 0;
  const statusCounts = {};
  const errorCounts = {};
  const routeCounts = {};
  const routeFailures = {};
  const latencies = [];

  async function worker() {
    while (true) {
      const requestIndex = nextRequest;
      nextRequest += 1;
      if (config.totalRequests !== undefined && requestIndex >= config.totalRequests) return;
      const scheduledAt = startedAtMs + (requestIndex * 1_000) / config.maxRequestsPerSecond;
      if (deadline !== undefined && scheduledAt >= deadline) return;
      const waitMs = scheduledAt - Date.now();
      if (waitMs > 0) await sleep(waitMs);
      const route = schedule[requestIndex % schedule.length];
      addCount(routeCounts, route.name);
      const requestStarted = performance.now();
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), config.timeoutMs);
      timer.unref?.();
      let successful = false;
      try {
        const response = await fetchImplementation(`${config.baseUrl}${route.path}`, {
          method: route.method,
          redirect: "error",
          signal: controller.signal,
          headers: {
            accept: "application/json",
            "cache-control": "no-cache",
            "user-agent": "LH-Ops-Capacity-Test/1.0",
          },
        });
        addCount(statusCounts, String(response.status));
        if (!route.expectedStatuses.includes(response.status)) {
          addCount(errorCounts, `unexpected_status_${response.status}`);
        } else {
          const contentLength = Number(response.headers.get("content-length") ?? 0);
          if (contentLength > config.maxResponseBytes) {
            addCount(errorCounts, "response_too_large");
          } else if (Object.keys(route.jsonAssertions).length) {
            const body = await response.arrayBuffer();
            if (body.byteLength > config.maxResponseBytes) {
              addCount(errorCounts, "response_too_large");
            } else {
              let parsed;
              try {
                parsed = JSON.parse(Buffer.from(body).toString("utf8"));
              } catch {
                addCount(errorCounts, "invalid_json");
              }
              if (parsed !== undefined) {
                const failedKey = Object.entries(route.jsonAssertions).find(
                  ([key, expected]) => nestedValue(parsed, key) !== expected,
                )?.[0];
                if (failedKey) addCount(errorCounts, `assertion_${route.name}_${failedKey}`);
                else successful = true;
              }
            }
          } else {
            const body = await response.arrayBuffer();
            if (body.byteLength > config.maxResponseBytes) {
              addCount(errorCounts, "response_too_large");
            } else successful = true;
          }
        }
      } catch (error) {
        networkErrors += 1;
        addCount(
          errorCounts,
          error instanceof Error && error.name === "AbortError" ? "timeout" : "network_error",
        );
      } finally {
        clearTimeout(timer);
        latencies.push(performance.now() - requestStarted);
      }
      if (successful) succeeded += 1;
      else addCount(routeFailures, route.name);
    }
  }

  await Promise.all(Array.from({ length: config.concurrency }, () => worker()));
  const finishedAtMs = Date.now();
  const attempted = latencies.length;
  const sortedLatencies = [...latencies].sort((left, right) => left - right);
  const elapsedSeconds = Math.max(0.001, (finishedAtMs - startedAtMs) / 1_000);
  const successRate = attempted ? succeeded / attempted : 0;
  const requestsPerSecond = attempted / elapsedSeconds;
  const latency = {
    p50Ms: percentile(sortedLatencies, 0.5),
    p95Ms: percentile(sortedLatencies, 0.95),
    p99Ms: percentile(sortedLatencies, 0.99),
    maximumMs: sortedLatencies.length
      ? Math.round(sortedLatencies.at(-1) * 100) / 100
      : 0,
  };
  const checks = {
    requestsAttempted: attempted > 0,
    successRate: successRate >= config.thresholds.minimumSuccessRate,
    p95: latency.p95Ms <= config.thresholds.maximumP95Ms,
    p99: latency.p99Ms <= config.thresholds.maximumP99Ms,
    networkErrors: networkErrors <= config.thresholds.maximumNetworkErrors,
    throughput: requestsPerSecond >= config.thresholds.minimumRequestsPerSecond,
  };
  return {
    formatVersion: 1,
    name: config.name,
    mode: config.mode,
    target: new URL(config.baseUrl).origin,
    startedAt: new Date(startedAtMs).toISOString(),
    finishedAt: new Date(finishedAtMs).toISOString(),
    elapsedSeconds: Math.round(elapsedSeconds * 1_000) / 1_000,
    attempted,
    succeeded,
    failed: attempted - succeeded,
    successRate: Math.round(successRate * 100_000) / 100_000,
    requestsPerSecond: Math.round(requestsPerSecond * 100) / 100,
    networkErrors,
    latency,
    statusCounts,
    errorCounts,
    routeCounts,
    routeFailures,
    thresholds: config.thresholds,
    checks,
    passed: Object.values(checks).every(Boolean),
  };
}

function parseArguments(arguments_) {
  if (!arguments_.length) {
    throw new Error("Usage: load-http.mjs CONFIG.json [--confirm-host HOST] [--output REPORT.json]");
  }
  const parsed = { configuration: arguments_[0], confirmedHost: undefined, output: undefined };
  for (let index = 1; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--confirm-host" && arguments_[index + 1]) {
      parsed.confirmedHost = arguments_[index + 1];
      index += 1;
    } else if (argument === "--output" && arguments_[index + 1]) {
      parsed.output = arguments_[index + 1];
      index += 1;
    } else throw new Error(`Unknown or incomplete argument: ${argument}`);
  }
  return parsed;
}

async function main() {
  const arguments_ = parseArguments(process.argv.slice(2));
  const raw = JSON.parse(await readFile(resolve(arguments_.configuration), "utf8"));
  const config = validateHttpLoadConfig(raw);
  assertHttpTargetAllowed(config, arguments_.confirmedHost);
  const report = await runHttpLoadTest(config);
  const serialized = `${JSON.stringify(report, null, 2)}\n`;
  process.stdout.write(serialized);
  if (arguments_.output) await writeFile(resolve(arguments_.output), serialized, { mode: 0o600 });
  if (!report.passed) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
