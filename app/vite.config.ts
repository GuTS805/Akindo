import { defineConfig } from "vite";

// Served from https://<user>.github.io/Akindo/ on GitHub Pages.
export default defineConfig({
  base: process.env.GITHUB_PAGES ? "/Akindo/" : "/",
  build: { target: "es2022" },
});
