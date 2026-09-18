#!/usr/bin/env node

// Writes secrets/cloudflare_tunnel_token without ever printing, logging, or
// storing the plaintext token anywhere else. Run with: npm run tunnel:token

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createPrompter } from "./lib/prompt.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SECRETS_DIR = path.join(__dirname, "..", "secrets");
const TOKEN_FILE = path.join(SECRETS_DIR, "cloudflare_tunnel_token");

async function main() {
  const { askHidden, closeLineReader } = createPrompter();
  closeLineReader(); // no line-based prompts before the hidden ones below

  const token = await askHidden("Cloudflare Tunnel token: ");
  const confirm = await askHidden("Confirm token: ");

  if (!token) {
    console.error("A token is required.");
    process.exitCode = 1;
    return;
  }
  if (token !== confirm) {
    console.error("Tokens did not match.");
    process.exitCode = 1;
    return;
  }

  fs.mkdirSync(SECRETS_DIR, { recursive: true });
  fs.writeFileSync(TOKEN_FILE, token + "\n", { mode: 0o600 });
  fs.chmodSync(TOKEN_FILE, 0o600);

  console.log(`Saved token to ${path.relative(process.cwd(), TOKEN_FILE)} (mode 600).`);
  console.log("Enable it with: ./deploy.sh --tunnel your-domain.com");
}

main();
