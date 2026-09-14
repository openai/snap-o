import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  server: {
    host: "127.0.0.1",
    port: 5175,
    strictPort: true,
    hmr: { host: "127.0.0.1", clientPort: 5175 }
  }
});
