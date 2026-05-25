import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { spawn } from "node:child_process";
import net from "node:net";
import { stdin as input, stdout as output } from "node:process";

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const args = parseArgs(rest);

  if (!command || args.help) {
    printHelp();
    return;
  }

  if (command === "info") {
    printInfo(args);
    return;
  }

  if (command === "config") {
    await configureRemote(args);
    return;
  }

  if (command === "port-check") {
    await checkPort(required(args.host, "--host"), Number(required(args.port, "--port")));
    return;
  }

  if (command === "dirs") {
    await rcloneRequired(args, ["lsd", `${required(args.remote, "--remote")}:${args.path ?? "/"}`]);
    return;
  }

  if (command === "debug") {
    await rcloneRequired(args, [
      "lsd",
      `${required(args.remote, "--remote")}:${args.path ?? "/"}`,
      "--contimeout",
      "10s",
      "--timeout",
      "20s",
      "--low-level-retries",
      "1",
      "-vv",
    ]);
    return;
  }

  if (command === "test") {
    await testRemote(args);
    return;
  }

  throw new Error(`Unknown command: ${command}`);
}

function parseArgs(argv) {
  const args = {};

  for (let index = 0; index < argv.length; index += 1) {
    const current = argv[index];

    if (!current.startsWith("--")) {
      throw new Error(`Unexpected argument: ${current}`);
    }

    const key = current.slice(2);
    const next = argv[index + 1];

    if (!next || next.startsWith("--")) {
      args[key] = true;
      continue;
    }

    args[key] = next;
    index += 1;
  }

  return args;
}

function printHelp() {
  console.log(`
Usage:
  bun rclone.ts info --host nas.example.com --user ci-user --port 22
  bun rclone.ts config --host nas.example.com --user ci-user --port 22 --auth password
  bun rclone.ts dirs --remote artifacts-nas --config .rclone/rclone.conf --path /
  bun rclone.ts debug --remote artifacts-nas --config .rclone/rclone.conf --path /
  bun rclone.ts test --remote artifacts-nas --config .rclone/rclone.conf --path /Home/ci-artifacts
`.trim());
}

function printInfo(args) {
  console.log(`NAS IP:          ${required(args.host, "--host")}`);
  console.log(`NAS user:        ${required(args.user, "--user")}`);
  console.log(`SFTP port:       ${required(args.port, "--port")}`);
  console.log(`Rclone remote:   ${args.remote ?? "artifacts-nas"}`);
  console.log(`Remote path:     ${args.path ?? "/artifacts"}`);
  console.log(`Rclone config:   ${args.config ?? ".rclone/rclone.conf"}`);
}

// file: rclone.ts
async function configureRemote(args: Record<string, string | boolean>): Promise<void> {
  const configFile = String(args.config ?? ".rclone/rclone.conf");
  const remote = String(args.remote ?? "artifacts-nas");
  const auth = String(args.auth ?? "password");
  const mode = String(args.mode ?? "merge");

  const host = required(args.host, "--host");
  const user = required(args.user, "--user");
  const port = String(args.port ?? "4589");

  if (!["password", "key"].includes(auth)) {
    throw new Error("--auth must be password or key");
  }

  if (!["merge", "override"].includes(mode)) {
    throw new Error("--mode must be merge or override");
  }

  let block: string;

  if (auth === "password") {
    const password = await readSecret(`Password for ${user}@${host}:${port}: `);
    const obscured = await capture("rclone", ["obscure", password]);
    block = renderPasswordRemote({ remote, host, user, port, obscured: obscured.trim() });
  } else {
    block = renderKeyRemote({
      remote,
      host,
      user,
      port,
      keyFile: required(args["key-file"], "--key-file"),
    });
  }

  if (!block.includes(`port = ${port}`)) {
    throw new Error(`Generated remote block does not contain expected port ${port}`);
  }

  await mkdir(dirname(configFile), { recursive: true });

  const existing = existsSync(configFile) ? await readFile(configFile, "utf8") : "";
  const next = mode === "override" ? `${block}\n` : mergeRemote(existing, remote, block);

  await writeFile(configFile, next, { mode: 0o600 });

  const written = await readFile(configFile, "utf8");
  const remoteSection = extractRemoteSection(written, remote);
  const writtenPort = getRcloneSectionValue(remoteSection, "port");

  if (writtenPort !== port) {
    throw new Error(`Written config for ${remote} contains port ${writtenPort ?? "<missing>"} instead of ${port}`);
  }

  console.log(`Wrote ${configFile}`);
  console.log(`Remote ${remote} uses ${host}:${port}`);
  console.log(`Use: RCLONE_CONFIG=${configFile} rclone lsd ${remote}:/`);
}

// file: rclone.ts
// file: rclone.ts
function extractRemoteSection(config: string, remote: string): string {
  const lines = config.replace(/\r\n/g, "\n").split("\n");
  const section: string[] = [];
  let inside = false;

  for (const line of lines) {
    const sectionName = parseSectionName(line);

    if (sectionName !== null) {
      if (inside) {
        break;
      }

      inside = sectionName === remote;
    }

    if (inside) {
      section.push(line);
    }
  }

  if (section.length === 0) {
    throw new Error(`Remote ${remote} was not found in written config`);
  }

  return section.join("\n");
}

// file: rclone.ts
function parseSectionName(line: string): string | null {
  const match = line.trim().match(/^\[([^\]]+)\]$/);

  if (!match) {
    return null;
  }

  return match[1];
}

// file: rclone.ts
function getRcloneSectionValue(section: string, key: string): string | null {
  const prefix = `${key} =`;

  for (const line of section.split(/\r?\n/)) {
    const trimmed = line.trim();

    if (!trimmed.startsWith(prefix)) {
      continue;
    }

    return trimmed.slice(prefix.length).trim();
  }

  return null;
}

function renderPasswordRemote({ remote, host, user, port, obscured }) {
  return [
    `[${remote}]`,
    "type = sftp",
    `host = ${host}`,
    `user = ${user}`,
    `port = ${port}`,
    `pass = ${obscured}`,
    "shell_type = unix",
    "connect_timeout = 10s",
    "timeout = 20s",
    "md5sum_command = none",
    "sha1sum_command = none",
  ].join("\n");
}

function renderKeyRemote({ remote, host, user, port, keyFile }) {
  return [
    `[${remote}]`,
    "type = sftp",
    `host = ${host}`,
    `user = ${user}`,
    `port = ${port}`,
    `key_file = ${keyFile}`,
    "shell_type = unix",
    "connect_timeout = 10s",
    "timeout = 20s",
    "md5sum_command = none",
    "sha1sum_command = none",
  ].join("\n");
}

// file: rclone.ts
function mergeRemote(existing: string, remote: string, block: string): string {
  const lines = existing.replace(/\r\n/g, "\n").split("\n");
  const output: string[] = [];
  let index = 0;
  let replaced = false;

  while (index < lines.length) {
    const line = lines[index];
    const sectionName = parseSectionName(line);

    if (sectionName !== remote) {
      output.push(line);
      index += 1;
      continue;
    }

    if (!replaced) {
      while (output.length > 0 && output[output.length - 1] === "") {
        output.pop();
      }

      if (output.length > 0) {
        output.push("");
      }

      output.push(...block.split("\n"));
      replaced = true;
    }

    index += 1;

    while (index < lines.length && parseSectionName(lines[index]) === null) {
      index += 1;
    }
  }

  const cleaned = output.join("\n").trim();

  if (!replaced) {
    return cleaned ? `${cleaned}\n\n${block}\n` : `${block}\n`;
  }

  return `${cleaned}\n`;
}

async function testRemote(args) {
  const config = required(args.config, "--config");
  const remote = required(args.remote, "--remote");
  const path = args.path ?? "/artifacts";
  const tmp = await mkdtemp(join(tmpdir(), "rclone-nas-"));

  try {
    const file = join(tmp, "artifact-test.txt");
    await writeFile(file, `artifact test ${new Date().toISOString()}\n`, "utf8");

    await rcloneRequired(args, ["mkdir", `${remote}:${path}/_rclone-test`]);
    await rcloneRequired(args, ["copy", file, `${remote}:${path}/_rclone-test`, "--checksum", "--progress"]);
    await rcloneRequired(args, ["check", tmp, `${remote}:${path}/_rclone-test`, "--one-way"]);
    await rcloneRequired({ config }, ["lsf", `${remote}:${path}/_rclone-test`]);
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
}

// file: rclone.ts
async function rcloneRequired(args: Record<string, string | boolean>, rcloneArgs: string[]): Promise<void> {
  const config = required(args.config, "--config");
  const commandLine = ["rclone", ...rcloneArgs].join(" ");

  console.error(`Running: RCLONE_CONFIG=${config} ${commandLine}`);

  const result = await run("rclone", rcloneArgs, {
    env: {
      ...process.env,
      RCLONE_CONFIG: String(config),
    },
    inherit: true,
  });

  if (result !== 0) {
    throw new Error(`${commandLine} failed with exit code ${result}`);
  }
}

async function checkPort(host, port) {
  await new Promise((resolve, reject) => {
    const socket = net.createConnection({ host, port, timeout: 5000 });

    socket.on("connect", () => {
      socket.destroy();
      console.log(`OK: ${host}:${port} is reachable`);
      resolve();
    });

    socket.on("timeout", () => {
      socket.destroy();
      reject(new Error(`Timeout: ${host}:${port} is not reachable`));
    });

    socket.on("error", reject);
  });
}

// file: rclone.ts
async function readSecret(prompt: string): Promise<string> {
  output.write(prompt);

  let value = "";
  let rawModeWasEnabled = false;

  const restoreInput = (): void => {
    if (rawModeWasEnabled) {
      input.setRawMode?.(false);
      rawModeWasEnabled = false;
    }

    input.pause();
  };

  input.resume();

  if (input.setRawMode) {
    input.setRawMode(true);
    rawModeWasEnabled = true;
  }

  try {
    await new Promise<void>((resolve) => {
      const onData = (chunk: Buffer): void => {
        const text = chunk.toString("utf8");

        for (const char of text) {
          if (char === "\r" || char === "\n") {
            output.write("\n");
            input.off("data", onData);
            resolve();
            return;
          }

          if (char === "\u0003") {
            output.write("\n");
            input.off("data", onData);
            restoreInput();
            process.exit(130);
          }

          if (char === "\u007f") {
            value = value.slice(0, -1);
            continue;
          }

          value += char;
        }
      };

      input.on("data", onData);
    });
  } finally {
    restoreInput();
  }

  if (!value) {
    throw new Error("Password cannot be empty");
  }

  return value;
}

async function capture(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });

    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString("utf8");
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });

    child.on("close", (code) => {
      if (code === 0) {
        resolve(stdout);
      } else {
        reject(new Error(`${command} failed: ${stderr.trim()}`));
      }
    });

    child.on("error", reject);
  });
}

async function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      env: options.env ?? process.env,
      stdio: options.inherit ? "inherit" : ["ignore", "pipe", "pipe"],
    });

    child.on("close", (code) => resolve(code ?? 1));
    child.on("error", reject);
  });
}

function required(value, name) {
  if (!value) {
    throw new Error(`Missing required argument ${name}`);
  }

  return value;
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});