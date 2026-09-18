// Shared ssh/scp helpers for scripts/node/send-to-ec2.mjs and scripts/node/get-from-ec2.mjs.

import path from "node:path";
import { spawnSync } from "node:child_process";

// Wraps a string in single quotes for safe use in a remote (POSIX) shell
// command, escaping any embedded single quotes — needed because ssh joins
// its trailing args into one string and re-parses it via the remote shell.
export function shellQuote(value) {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

// Expands a leading "~" (bare or "~/...") to $HOME and resolves to an
// absolute path — child_process doesn't do shell-style tilde expansion for
// paths used purely locally (i.e. never sent to the remote shell).
export function resolveLocalPath(inputPath) {
  return path.resolve(inputPath.replace(/^~(?=$|\/)/, process.env.HOME ?? "~"));
}

// Runs a local command, letting stdio (including scp's password/passphrase
// prompts, if any) pass straight through to this terminal.
export function run(command, args) {
  const result = spawnSync(command, args, { stdio: "inherit" });
  if (result.error) {
    if (result.error.code === "ENOENT") {
      throw new Error(`'${command}' not found on PATH — is it installed?`);
    }
    throw result.error;
  }
  return result.status ?? 1;
}

// Runs a remote command over ssh and returns true iff it exits 0 — used only
// for non-secret, non-interactive existence checks, so stdio is
// captured/discarded rather than inherited.
export function remoteFileExists(sshArgs, host, remotePath) {
  const result = spawnSync(
    "ssh",
    [...sshArgs, host, `test -e ${shellQuote(remotePath)}`],
    { stdio: "ignore" }
  );
  return result.status === 0;
}

// Builds the shared -o/-i flags used for both ssh (existence check) and scp
// (actual transfer) invocations, given an optional path to a private key.
export function buildSshArgs(keyPath) {
  const sshArgs = ["-o", "StrictHostKeyChecking=accept-new"];
  if (keyPath) sshArgs.push("-i", keyPath);
  return sshArgs;
}
