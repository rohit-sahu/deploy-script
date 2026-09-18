import fs from "node:fs";
import readline from "node:readline";

// Shared prompt helpers for scripts/*.mjs that need to read a secret value
// from the terminal without ever echoing or logging it.
//
// Usage:
//   const { askLine, askHidden, closeLineReader } = createPrompter();
//   const email = await askLine("Email: ");
//   closeLineReader(); // required before any askHidden() call, see below
//   const password = await askHidden("Password: ");
export function createPrompter() {
  const isInteractive = process.stdin.isTTY;

  // Piped/non-TTY input (testing, CI): read the whole stream upfront and pop
  // lines off a queue. Issuing sequential readline.question() calls here
  // would race — readline flushes all buffered lines into 'line' events as
  // soon as the data arrives, before a later question() has attached its
  // listener, so only the first line would ever be seen.
  const pipedLines = isInteractive ? null : fs.readFileSync(0, "utf8").split("\n");

  let rl = isInteractive
    ? readline.createInterface({ input: process.stdin, output: process.stdout })
    : null;

  function askLine(promptText) {
    if (!isInteractive) {
      process.stdout.write(promptText);
      const line = (pipedLines.shift() ?? "").trim();
      process.stdout.write(line + "\n");
      return Promise.resolve(line);
    }
    // askHidden() requires closeLineReader() to have been called first (see
    // below), so a caller that needs askLine() again afterward (e.g. to loop
    // "add another?" after a hidden password prompt) would otherwise find rl
    // permanently null. Lazily reopen it here instead.
    if (!rl) {
      rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    }
    return new Promise((resolve) => {
      rl.question(promptText, (answer) => resolve(answer.trim()));
    });
  }

  // Must be called (even if no askLine() calls were made) before the first
  // askHidden() call: readline's keystroke listener stays active until
  // closed, and double-processes input alongside the raw-mode reader below,
  // producing garbled/duplicated echoed characters.
  function closeLineReader() {
    rl?.close();
    rl = null;
  }

  // Reads a line from stdin without echoing it back to the terminal.
  function askHidden(promptText) {
    if (!isInteractive) {
      process.stdout.write(promptText + "\n");
      return Promise.resolve((pipedLines.shift() ?? "").trim());
    }
    if (rl) {
      throw new Error("closeLineReader() must be called before the first askHidden()");
    }

    return new Promise((resolve) => {
      const stdin = process.stdin;
      process.stdout.write(promptText);

      const wasRaw = stdin.isRaw;
      stdin.setRawMode(true);
      stdin.resume();
      stdin.setEncoding("utf8");

      let input = "";
      const onData = (char) => {
        switch (char) {
          case "\n":
          case "\r":
          case "\u0004": // Ctrl-D
            stdin.setRawMode(wasRaw);
            stdin.pause();
            stdin.removeListener("data", onData);
            process.stdout.write("\n");
            resolve(input);
            break;
          case "\u0003": // Ctrl-C
            process.stdout.write("\n");
            process.exit(1);
            break;
          case "\u007f":
          case "\b":
            if (input.length > 0) {
              input = input.slice(0, -1);
              process.stdout.write("\b \b");
            }
            break;
          default:
            input += char;
            process.stdout.write("*");
            break;
        }
      };
      stdin.on("data", onData);
    });
  }

  return { askLine, askHidden, closeLineReader };
}
