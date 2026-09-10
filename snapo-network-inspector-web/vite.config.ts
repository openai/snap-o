import preact from "@preact/preset-vite";
import { defineConfig } from "vite";

export default defineConfig(({ mode }) => ({
  base: "./",
  plugins: [preact({ reactAliasesEnabled: false })],
  server: {
    host: "127.0.0.1",
    port: 5173
  },
  build: {
    outDir: mode === "tweaks" ? "dist-tweaks" : "dist-renderer",
    rolldownOptions: { input: mode === "tweaks" ? "tweaks.html" : "index.html" },
    emptyOutDir: true
  }
}));
