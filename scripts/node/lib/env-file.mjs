// Tiny dependency-free .env file loader — reads KEY=VALUE lines (same format
// create-env.mjs writes) and fills in process.env entries that aren't
// already set. Never overrides a value the caller's shell already exported,
// matching deploy.sh's own "exported env wins over file" resolution order.
import fs from "node:fs";
import path from "node:path";

function parseEnvFile(file) {
  const values = {};
  if (!fs.existsSync(file)) return values;
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    const match = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (match) values[match[1]] = match[2];
  }
  return values;
}

// Loads env vars (without overriding already-exported ones) from, in order:
//   1. $ENV_FILE_PATH, if set (deploy.sh exports this — the same file it
//      already resolved settings from for this run)
//   2. <root>/.env.local
//   3. <root>/.env.prod
// Stops at the first file that actually contains anything, so a standalone
// `npm run admin:create` (no deploy.sh involved) still picks up
// ADMIN_SECRETS_KEY/ADMIN_TOTP_ISSUER from whichever env file already
// exists, without requiring the operator to export them by hand.
export function autoLoadEnv(root) {
  const candidates = [];
  if (process.env.ENV_FILE_PATH) candidates.push(path.resolve(process.env.ENV_FILE_PATH));
  candidates.push(path.join(root, ".env.local"), path.join(root, ".env.prod"));

  for (const file of candidates) {
    const values = parseEnvFile(file);
    if (Object.keys(values).length === 0) continue;
    for (const [key, value] of Object.entries(values)) {
      if (process.env[key] === undefined) process.env[key] = value;
    }
    console.log(`==> Loaded env values from ${file}`);
    return;
  }
}
