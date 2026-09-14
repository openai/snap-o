import preact from "@preact/preset-vite";
import { defineConfig } from "vite";
export default defineConfig({
  base: "./",
  plugins: [preact({ reactAliasesEnabled: false })],
  server: {
    host: "127.0.0.1",
    port: 5174,
    strictPort: true,
    hmr: { host: "127.0.0.1", clientPort: 5174 }
  },
  build: {
    outDir: "dist",
    emptyOutDir: true
  }
});
