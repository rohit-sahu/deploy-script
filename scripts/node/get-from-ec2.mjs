#!/usr/bin/env node

// Downloads a file from an AWS EC2 instance over scp, prompting
// interactively for the connection details and paths (no flags/env vars
// required, though piping answers in via stdin works too — see
// lib/prompt.mjs). Run with:
//   npm run ec2:get
//
// Existing local files are never silently clobbered without being told:
// pass --force to skip that check (e.g. for scripted/CI use).
//
// See also: scripts/node/send-to-ec2.mjs (the reverse direction).

import fs from "node:fs";
import path from "node:path";
import { createPrompter } from "./lib/prompt.mjs";
import { resolveLocalPath, run, remoteFileExists, buildSshArgs } from "./lib/ssh.mjs";

const FORCE = process.argv.includes("--force");

async function main() {
  const { askLine, closeLineReader } = createPrompter();

  const host = await askLine("EC2 host (user@ec2-host-or-ip, e.g. ec2-user@1.2.3.4): ");
  if (!host || !host.includes("@")) {
    console.error("Expected the form user@host, e.g. ec2-user@1.2.3.4 or ubuntu@your-domain.com.");
    process.exitCode = 1;
    closeLineReader();
    return;
  }

  const keyPathRaw = await askLine("Path to SSH private key (.pem) [leave blank to use default SSH agent/keys]: ");
  const keyPath = keyPathRaw ? resolveLocalPath(keyPathRaw) : "";
  if (keyPath && !fs.existsSync(keyPath)) {
    console.error(`Key file not found: ${keyPath}`);
    process.exitCode = 1;
    closeLineReader();
    return;
  }

  const remotePathRaw = await askLine("Remote file to download: ");
  if (!remotePathRaw) {
    console.error("A remote file path is required.");
    process.exitCode = 1;
    closeLineReader();
    return;
  }

  const sshArgs = buildSshArgs(keyPath);

  if (!remoteFileExists(sshArgs, host, remotePathRaw)) {
    console.error(`Remote file not found: ${remotePathRaw} on ${host}.`);
    process.exitCode = 1;
    closeLineReader();
    return;
  }

  const defaultLocalPath = path.join(process.cwd(), path.basename(remotePathRaw));
  const localPathRaw = await askLine(`Local destination path [${path.relative(process.cwd(), defaultLocalPath) || "."}]: `);
  const localPath = localPathRaw ? resolveLocalPath(localPathRaw) : defaultLocalPath;

  closeLineReader();

  if (!FORCE && fs.existsSync(localPath)) {
    console.error(
      `Refusing to overwrite: ${localPath} already exists locally. Re-run with --force to overwrite, or choose a different local path.`
    );
    process.exitCode = 1;
    return;
  }

  fs.mkdirSync(path.dirname(localPath), { recursive: true });

  console.log(`==> Downloading ${host}:${remotePathRaw} -> ${path.relative(process.cwd(), localPath)}`);
  const status = run("scp", [...sshArgs, `${host}:${remotePathRaw}`, localPath]);

  if (status !== 0) {
    console.error(`scp exited with status ${status}.`);
    process.exitCode = status;
    return;
  }

  console.log(`==> Done. File is now at ${path.relative(process.cwd(), localPath)}.`);
}

main();
