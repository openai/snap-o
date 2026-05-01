import { runCli } from "./cli.js";

try {
  process.exitCode = await runCli(process.argv.slice(2));
} catch (error) {
  console.error(`snapo: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
}
