import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

if (process.platform === "darwin") {
  const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const sourcePath = path.join(projectRoot, "native", "process-memory.c");
  const outputDirectory = path.join(projectRoot, "dist");
  const outputPath = path.join(outputDirectory, "process-memory");

  mkdirSync(outputDirectory, { recursive: true });
  execFileSync("/usr/bin/clang", ["-O2", "-Wall", "-Wextra", "-o", outputPath, sourcePath], {
    stdio: "inherit",
  });
  chmodSync(outputPath, 0o755);
}
