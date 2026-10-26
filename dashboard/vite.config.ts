import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Allow importing ../deployments/local.json written by the Foundry deploy script.
export default defineConfig({
  plugins: [react()],
  server: { fs: { allow: [".."] } },
});
