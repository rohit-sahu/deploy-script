#!/usr/bin/env node

// Creates or updates entries in secrets/admin-users.json without ever
// printing, logging, or writing any plaintext password anywhere — only the
// bcrypt hash is persisted. Loops so you can add/update multiple admins in
// one run. Run with: npm run admin:create

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import bcrypt from "bcryptjs";
import { createPrompter } from "./lib/prompt.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SECRETS_DIR = path.join(__dirname, "..", "secrets");
const USERS_FILE = path.join(SECRETS_DIR, "admin-users.json");

function loadUsers() {
  if (!fs.existsSync(USERS_FILE)) return [];
  try {
    const parsed = JSON.parse(fs.readFileSync(USERS_FILE, "utf8"));
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    console.error(`Warning: ${USERS_FILE} contained invalid JSON — starting from an empty list.`);
    return [];
  }
}

async function main() {
  const { askLine, askHidden, closeLineReader } = createPrompter();
  const users = loadUsers();

  while (true) {
    const email = await askLine("Admin email: ");
    closeLineReader();

    if (!email || !email.includes("@")) {
      console.error("A valid email is required.");
      process.exitCode = 1;
      break;
    }

    const password = await askHidden("Password: ");
    const confirm = await askHidden("Confirm password: ");
    if (password !== confirm) {
      console.error("Passwords did not match.");
      process.exitCode = 1;
      break;
    }
    if (password.length < 8) {
      console.error("Password must be at least 8 characters.");
      process.exitCode = 1;
      break;
    }

    const passwordHash = bcrypt.hashSync(password, 10);
    // `password`/`confirm` are not referenced again past this point.

    const normalizedEmail = email.toLowerCase();
    const existingIndex = users.findIndex((u) => u?.email?.toLowerCase() === normalizedEmail);

    if (existingIndex >= 0) {
      users[existingIndex] = { email, passwordHash };
      console.log(`Updated existing admin: ${email}`);
    } else {
      users.push({ email, passwordHash });
      console.log(`Added new admin: ${email}`);
    }

    // closeLineReader() was already called above (before askHidden()); askLine()
    // lazily reopens the line reader on demand, so this is safe to call again.
    const again = (await askLine("Do you want to add another user? [y/N]: ")).toLowerCase();
    closeLineReader();
    if (again !== "y" && again !== "yes") break;
  }

  fs.mkdirSync(SECRETS_DIR, { recursive: true });
  fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2) + "\n", { mode: 0o600 });
  fs.chmodSync(USERS_FILE, 0o600);

  console.log(`Saved ${users.length} admin${users.length === 1 ? "" : "s"} to ${path.relative(process.cwd(), USERS_FILE)}`);
}

main();
