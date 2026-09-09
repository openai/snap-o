import preact from "@preact/preset-vite";
import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  plugins: [preact()],
  server: {
    host: "127.0.0.1",
    port: 5173
  },
  build: {
    outDir: "dist-renderer",
    emptyOutDir: true
  }
});
