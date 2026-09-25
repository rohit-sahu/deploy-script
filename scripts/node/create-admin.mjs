#!/usr/bin/env node

// Interactively add, update, remove, or list entries in
// secrets/admin-users.json without ever printing, logging, or writing any
// plaintext password anywhere — only the bcrypt hash is persisted. The file
// is created fresh if it doesn't exist yet, or updated in place if it does.
// Run with: npm run admin:create

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import bcrypt from "bcryptjs";
import qrcodeTerminal from "qrcode-terminal";
import { createPrompter } from "./lib/prompt.mjs";
import { generateTotpSecret, buildOtpAuthUrl, verifyTotpToken, encryptTotpSecret } from "./lib/totp.mjs";
import { autoLoadEnv } from "./lib/env-file.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
autoLoadEnv(ROOT);

const TOTP_ISSUER = process.env.ADMIN_TOTP_ISSUER || "Portfolio Admin";

const SECRETS_DIR = path.join(ROOT, "secrets");
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

// Interactively enables/keeps/disables TOTP 2FA for one admin. Returns the
// AES-256-GCM-encrypted secret to store (see scripts/node/lib/totp.mjs), or
// undefined if 2FA should be off for this account. Never writes the raw
// secret to disk — only encryptTotpSecret()'s output ever reaches
// admin-users.json.
async function configureTotp({ email, existingUser, askLine, closeLineReader }) {
  if (existingUser?.totpSecret) {
    const keep = (await askLine("This account already has 2FA enabled. Keep it as-is? [Y/n]: ")).toLowerCase();
    closeLineReader();
    if (keep !== "n" && keep !== "no") {
      return existingUser.totpSecret;
    }
    const disable = (await askLine("Disable 2FA for this account? [y/N]: ")).toLowerCase();
    closeLineReader();
    if (disable === "y" || disable === "yes") {
      return undefined;
    }
    // Falls through to re-enrollment below (replaces the existing secret).
  } else {
    const enable = (await askLine("Enable 2FA (TOTP, e.g. Google Authenticator) for this account? [y/N]: ")).toLowerCase();
    closeLineReader();
    if (enable !== "y" && enable !== "yes") {
      return undefined;
    }
  }

  const secret = generateTotpSecret();
  const otpAuthUrl = buildOtpAuthUrl(email, secret, TOTP_ISSUER);

  console.log("\nScan this QR code into your authenticator app (Google Authenticator, Authy, etc.):\n");
  await new Promise((resolve) => {
    qrcodeTerminal.generate(otpAuthUrl, { small: true }, (qr) => {
      console.log(qr);
      resolve();
    });
  });
  console.log("If your terminal/font can't display the QR code above, or your app can't scan a");
  console.log("URI directly, use its \"enter setup key\" option with the secret below instead:\n");
  console.log(`  Secret: ${secret}`);
  console.log(`  URI:    ${otpAuthUrl}\n`);

  // Confirm enrollment with a live code before persisting anything, so a
  // typo or clock-sync issue can't lock the admin out immediately.
  for (let attempt = 1; attempt <= 3; attempt++) {
    const code = await askLine("Enter the 6-digit code from your app to confirm: ");
    closeLineReader();
    if (verifyTotpToken(secret, code)) {
      console.log("2FA confirmed.\n");
      return encryptTotpSecret(secret);
    }
    console.error(`That code didn't match (attempt ${attempt}/3).`);
  }

  throw new Error("Could not confirm 2FA setup after 3 attempts — aborting without saving.");
}

function saveUsers(users) {
  fs.mkdirSync(SECRETS_DIR, { recursive: true });
  fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2) + "\n", { mode: 0o600 });
  fs.chmodSync(USERS_FILE, 0o600);
}

function findUserIndex(users, email) {
  const normalized = email.toLowerCase();
  return users.findIndex((u) => u?.email?.toLowerCase() === normalized);
}

async function promptPassword(askHidden) {
  while (true) {
    const password = await askHidden("Password: ");
    const confirm = await askHidden("Confirm password: ");
    if (password !== confirm) {
      console.error("Passwords did not match. Try again.\n");
      continue;
    }
    if (password.length < 8) {
      console.error("Password must be at least 8 characters. Try again.\n");
      continue;
    }
    return bcrypt.hashSync(password, 10);
  }
}

function listAdmins(users) {
  if (users.length === 0) {
    console.log("\nNo admins configured yet.\n");
    return;
  }
  console.log(`\n${users.length} admin${users.length === 1 ? "" : "s"} configured:`);
  for (const u of users) {
    console.log(`  - ${u.email}${u.totpSecret ? " (2FA enabled)" : ""}`);
  }
  console.log("");
}

// Shared enrollment for a brand-new admin: always prompts for a password,
// then runs TOTP setup via configureTotp(), and returns the record to store.
async function collectAdminRecord({ email, ctx }) {
  const passwordHash = await promptPassword(ctx.askHidden);
  const totpSecret = await configureTotp({ email, existingUser: undefined, askLine: ctx.askLine, closeLineReader: ctx.closeLineReader });
  return totpSecret ? { email, passwordHash, totpSecret } : { email, passwordHash };
}

// Shared update path for an *existing* record (used both by Update proper,
// and by Add when it detects the email already exists). Password change is
// optional — keeps the existing hash unless the operator opts in — and 2FA
// setup/keep/disable is handled by configureTotp() based on existingUser.
async function applyUpdate(users, index, ctx) {
  const email = users[index].email;
  const existingUser = users[index];
  const changePw = (await ctx.askLine("Change password? [y/N]: ")).toLowerCase();
  ctx.closeLineReader();

  let passwordHash = existingUser.passwordHash;
  if (changePw === "y" || changePw === "yes") {
    passwordHash = await promptPassword(ctx.askHidden);
  }

  const totpSecret = await configureTotp({ email, existingUser, askLine: ctx.askLine, closeLineReader: ctx.closeLineReader });
  users[index] = totpSecret ? { email, passwordHash, totpSecret } : { email, passwordHash };
  saveUsers(users);
  console.log(`Updated existing admin: ${email}\n`);
}

async function addAdmin(users, ctx) {
  const email = (await ctx.askLine("New admin email: ")).trim();
  ctx.closeLineReader();

  if (!email || !email.includes("@")) {
    console.error("A valid email is required.\n");
    return;
  }

  const existingIndex = findUserIndex(users, email);
  if (existingIndex >= 0) {
    const goUpdate = (await ctx.askLine(`"${email}" already exists. Update it instead? [Y/n]: `)).toLowerCase();
    ctx.closeLineReader();
    if (goUpdate === "n" || goUpdate === "no") {
      console.log("Cancelled — no changes made.\n");
      return;
    }
    await applyUpdate(users, existingIndex, ctx);
    return;
  }

  users.push(await collectAdminRecord({ email, ctx }));
  saveUsers(users);
  console.log(`Added new admin: ${email}\n`);
}

async function updateAdmin(users, ctx) {
  const email = (await ctx.askLine("Admin email to update: ")).trim();
  ctx.closeLineReader();

  if (!email) {
    console.error("An email is required.\n");
    return;
  }

  const existingIndex = findUserIndex(users, email);
  if (existingIndex < 0) {
    const goAdd = (await ctx.askLine(`No admin found with "${email}". Add as a new admin instead? [Y/n]: `)).toLowerCase();
    ctx.closeLineReader();
    if (goAdd === "n" || goAdd === "no") {
      console.log("Cancelled — no changes made.\n");
      return;
    }
    users.push(await collectAdminRecord({ email, ctx }));
    saveUsers(users);
    console.log(`Added new admin: ${email}\n`);
    return;
  }

  await applyUpdate(users, existingIndex, ctx);
}

async function removeAdmin(users, ctx) {
  const email = (await ctx.askLine("Admin email to remove: ")).trim();
  ctx.closeLineReader();

  if (!email) {
    console.error("An email is required.\n");
    return;
  }

  const existingIndex = findUserIndex(users, email);
  if (existingIndex < 0) {
    console.error(`No admin found with "${email}".\n`);
    return;
  }

  const confirm = (await ctx.askLine(`Remove "${users[existingIndex].email}"? This cannot be undone. [y/N]: `)).toLowerCase();
  ctx.closeLineReader();
  if (confirm !== "y" && confirm !== "yes") {
    console.log("Cancelled — no changes made.\n");
    return;
  }

  users.splice(existingIndex, 1);
  saveUsers(users);
  console.log(`Removed admin. ${users.length} remaining.\n`);
}

async function main() {
  const { askLine, askHidden, closeLineReader } = createPrompter();
  const ctx = { askLine, askHidden, closeLineReader };
  const users = loadUsers();

  console.log(
    `Managing ${path.relative(process.cwd(), USERS_FILE)} (${users.length} admin${users.length === 1 ? "" : "s"} currently saved).`
  );

  while (true) {
    console.log("\nWhat would you like to do?");
    console.log("  [A]dd a new admin");
    console.log("  [U]pdate an existing admin (password and/or 2FA)");
    console.log("  [R]emove an admin");
    console.log("  [L]ist all admins");
    console.log("  [Q]uit");
    const choice = (await askLine("Choice [a/u/r/l/q]: ")).trim().toLowerCase();
    closeLineReader();

    if (choice === "q" || choice === "quit") {
      break;
    } else if (choice === "a" || choice === "add") {
      await addAdmin(users, ctx);
    } else if (choice === "u" || choice === "update") {
      await updateAdmin(users, ctx);
    } else if (choice === "r" || choice === "remove") {
      await removeAdmin(users, ctx);
    } else if (choice === "l" || choice === "list") {
      listAdmins(users);
    } else {
      console.error("Unrecognized choice — please enter a, u, r, l, or q.");
    }
  }

  console.log(`\nDone. ${users.length} admin${users.length === 1 ? "" : "s"} saved to ${path.relative(process.cwd(), USERS_FILE)}`);
}

main().catch((err) => {
  console.error(`\n${err.message}`);
  process.exitCode = 1;
});
