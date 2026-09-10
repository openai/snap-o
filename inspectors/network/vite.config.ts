import preact from "@preact/preset-vite";
import { defineConfig } from "vite";
export default defineConfig({
  base: "./",
  plugins: [preact({ reactAliasesEnabled: false })],
  server: { host: "127.0.0.1" },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    assetsInlineLimit: Infinity,
    rolldownOptions: { output: { codeSplitting: false } }
  }
});
