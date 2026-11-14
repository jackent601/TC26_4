import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Dev server only. /api is forwarded to PostgREST with the prefix removed,
// the same as the Caddyfile does in the built image.
//   API_PROXY_TARGET  where PostgREST is (default: the dev port on this machine;
//                     the ui-dev container sets http://api:3000)
//   VITE_POLL         set when the source is a Windows folder mounted into a
//                     container, where file-change events don't arrive
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": {
        target: process.env.API_PROXY_TARGET ?? "http://localhost:8000",
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ""),
      },
    },
    watch: process.env.VITE_POLL ? { usePolling: true, interval: 300 } : undefined,
  },
});
