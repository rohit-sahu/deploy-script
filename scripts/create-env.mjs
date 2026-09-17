#!/usr/bin/env node

// Creates/updates .env.local (local dev) or .env.prod (production secrets,
// scp'd/rsync'd to the server alongside deploy.sh — never committed, never
// git-tracked) with the MongoDB connection, a fresh AUTH_SECRET, and the
// public site URL. Run with:
//   npm run env:create -- local   # writes .env.local
//   npm run env:create -- prod    # writes .env.prod
//   npm run env:create            # prompts which target interactively
//
// Re-running for an existing file keeps its current AUTH_SECRET (rotating
// it would invalidate every logged-in admin session) and reuses any value
// you leave blank at a prompt, so it's safe to re-run any time.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import { createPrompter } from "./lib/prompt.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");

const TARGETS = {
  local: {
    file: path.join(ROOT, ".env.local"),
    defaultSiteUrl: "http://localhost:3000",
  },
  prod: {
    file: path.join(ROOT, ".env.prod"),
    defaultSiteUrl: "https://your-domain.com",
  },
};

// Generates a fresh AUTH_SECRET via the official Auth.js CLI (`npx auth
// secret`), which prints (does not write to a file):
//   Add the following to your .env file:
//   # Auth Secret
//   BETTER_AUTH_SECRET=<64-char hex>
// We only need the value — parse it out and store it as AUTH_SECRET (the
// name this app's Auth.js config actually reads; see .env.example). Falls
// back to a locally generated 32-byte base64 secret if the CLI can't run
// (e.g. offline, no npm registry access) — equally valid, just not printed
// by the official tool.
function generateAuthSecret() {
  try {
    const output = execFileSync("npx", ["--yes", "auth", "secret"], {
      cwd: ROOT,
      stdio: ["ignore", "pipe", "ignore"],
    }).toString("utf8");
    const match = output.match(/BETTER_AUTH_SECRET=(\S+)/);
    if (match) return match[1];
  } catch {
    // fall through to local generation below
  }
  console.warn("Warning: 'npx auth secret' unavailable — generating AUTH_SECRET locally instead.");
  return crypto.randomBytes(32).toString("base64");
}

function loadExisting(file) {
  const env = {};
  if (!fs.existsSync(file)) return env;
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    const match = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (match) env[match[1]] = match[2];
  }
  return env;
}

function writeEnvFile(file, values) {
  const lines = Object.entries(values).map(([key, value]) => `${key}=${value}`);
  fs.writeFileSync(file, lines.join("\n") + "\n", { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}

async function main() {
  const { askLine, closeLineReader } = createPrompter();

  let target = (process.argv[2] || "").toLowerCase();
  if (!target) {
    target = (await askLine("Create env for [local/prod]: ")).toLowerCase();
  }
  if (!TARGETS[target]) {
    console.error(`Unknown target "${target || "(empty)"}" — expected "local" or "prod".`);
    process.exitCode = 1;
    closeLineReader();
    return;
  }
  const { file, defaultSiteUrl } = TARGETS[target];
  const existing = loadExisting(file);
  const relFile = path.relative(process.cwd(), file);

  const mongoUri = await askLine(
    `MongoDB URI${existing.MONGODB_URI ? " [keep existing]" : ""}: `
  );
  const mongoDb = await askLine(
    `MongoDB DB name [${existing.MONGODB_DB || "portfolio"}]: `
  );
  const siteUrl = await askLine(
    `NEXT_PUBLIC_SITE_URL [${existing.NEXT_PUBLIC_SITE_URL || defaultSiteUrl}]: `
  );
  closeLineReader();

  const authSecret = existing.AUTH_SECRET || generateAuthSecret();
  if (!existing.AUTH_SECRET) {
    console.log("==> Generated a new AUTH_SECRET via 'npx auth secret'.");
  } else {
    console.log("==> Keeping existing AUTH_SECRET (re-run would invalidate active admin sessions).");
  }

  const values = {
    NEXT_PUBLIC_SITE_URL: siteUrl || existing.NEXT_PUBLIC_SITE_URL || defaultSiteUrl,
    MONGODB_URI: mongoUri || existing.MONGODB_URI || "",
    MONGODB_DB: mongoDb || existing.MONGODB_DB || "portfolio",
    AUTH_SECRET: authSecret,
    ADMIN_USERS_FILE: existing.ADMIN_USERS_FILE || "",
    RESUME_CACHE_FILE: existing.RESUME_CACHE_FILE || "",
  };

  fs.mkdirSync(path.dirname(file), { recursive: true });
  writeEnvFile(file, values);

  console.log(`Saved ${relFile} (mode 600).`);
  if (!values.MONGODB_URI) {
    console.warn(`WARNING: MONGODB_URI is empty — edit ${relFile} before using it.`);
  }
}

main();
