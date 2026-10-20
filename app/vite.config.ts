import { resolve } from "node:path";
import { defineConfig } from "vite";

const page = (p: string) => resolve(__dirname, p, "index.html");

// Served from https://<user>.github.io/Akindo/ on GitHub Pages, "/" on Vercel.
export default defineConfig({
  base: process.env.GITHUB_PAGES ? "/Akindo/" : "/",
  build: {
    target: "es2022",
    // Mezo Passport's Bitcoin wallet stack is one large chunk, loaded only when a Bitcoin wallet connects.
    chunkSizeWarningLimit: 4_000,
    rollupOptions: {
      input: {
        home: resolve(__dirname, "index.html"),
        vault: page("vault"),
        portfolio: page("portfolio"),
        analytics: page("analytics"),
        simulator: page("simulator"),
        docs: page("docs"),
      },
    },
  },
});
