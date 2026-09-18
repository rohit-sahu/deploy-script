#!/usr/bin/env node

// Sends a local file to an AWS EC2 instance over scp, prompting interactively
// for the connection details and paths (no flags/env vars required, though
// piping answers in via stdin works too — see lib/prompt.mjs). Run with:
//   npm run ec2:send
//
// Existing remote files are never silently clobbered without being told:
// pass --force to skip that check (e.g. for scripted/CI use).
//
// See also: scripts/node/get-from-ec2.mjs (the reverse direction).

import fs from "node:fs";
import path from "node:path";
import { createPrompter } from "./lib/prompt.mjs";
import { resolveLocalPath, run, remoteFileExists, buildSshArgs } from "./lib/ssh.mjs";

const FORCE = process.argv.includes("--force");

async function main() {
  const { askLine, closeLineReader } = createPrompter();

  const localPathRaw = await askLine("Local file to send: ");
  const localPath = resolveLocalPath(localPathRaw);

  if (!localPathRaw) {
    console.error("A local file path is required.");
    process.exitCode = 1;
    closeLineReader();
    return;
  }
  if (!fs.existsSync(localPath)) {
    console.error(`File not found: ${localPath}`);
    process.exitCode = 1;
    closeLineReader();
    return;
  }
  if (fs.statSync(localPath).isDirectory()) {
    console.error(`${localPath} is a directory — this script sends a single file at a time.`);
    process.exitCode = 1;
    closeLineReader();
    return;
  }

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

  const defaultRemotePath = `~/${path.basename(localPath)}`;
  const remotePathRaw = await askLine(`Remote destination path [${defaultRemotePath}]: `);
  const remotePath = remotePathRaw || defaultRemotePath;

  closeLineReader();

  const sshArgs = buildSshArgs(keyPath);

  if (!FORCE && remoteFileExists(sshArgs, host, remotePath)) {
    console.error(
      `Refusing to overwrite: ${remotePath} already exists on ${host}. Re-run with --force to overwrite, or choose a different remote path.`
    );
    process.exitCode = 1;
    return;
  }

  console.log(`==> Sending ${path.relative(process.cwd(), localPath)} -> ${host}:${remotePath}`);
  const status = run("scp", [...sshArgs, localPath, `${host}:${remotePath}`]);

  if (status !== 0) {
    console.error(`scp exited with status ${status}.`);
    process.exitCode = status;
    return;
  }

  console.log(`==> Done. File is now at ${remotePath} on ${host}.`);
}

main();
