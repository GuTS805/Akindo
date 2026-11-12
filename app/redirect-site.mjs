// Builds a tiny site that sends every path on an old mirror (GitHub Pages, surge.sh) to the same path on
// https://mblp.neocities.org. MetaMask flags those mirrors' whole domains, so the app itself lives on Neocities.
// Usage: node redirect-site.mjs <outDir> [basePathToStrip, e.g. /Akindo]
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const out = process.argv[2] ?? "dist-redirect";
const base = (process.argv[3] ?? "").replace(/\/$/, "");
const target = "https://mblp.neocities.org";

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>mbLP has moved</title>
<link rel="canonical" href="${target}/">
<meta http-equiv="refresh" content="0; url=${target}/">
<script>
  var p = location.pathname;
  var b = ${JSON.stringify(base)};
  if (b && p.indexOf(b) === 0) p = p.slice(b.length) || "/";
  location.replace(${JSON.stringify(target)} + p + location.search + location.hash);
</script>
<style>body{font-family:system-ui,sans-serif;background:#fbf4ea;color:#0f1b3d;display:grid;place-items:center;min-height:100vh;margin:0;padding:0 16px}a{color:#e36b32}</style>
</head>
<body>
<p>mbLP has moved to <a href="${target}/">mblp.neocities.org</a>.</p>
</body>
</html>
`;

mkdirSync(out, { recursive: true });
for (const f of ["index.html", "404.html", "200.html"]) writeFileSync(join(out, f), html);
console.log(`wrote redirect site to ${out} (strip "${base}")`);
