export type Series = { name: string; points: [number, number][]; color: string; dashed?: boolean };

type Options = {
  height?: number;
  yFormat?: (y: number) => string;
  xFormat?: (x: number) => string;
  yTicks?: number;
  xTicks?: number;
  marker?: number; // x position of a vertical reference line
  minRelSpan?: number; // smallest y range shown, relative to the mean (keeps noise flat)
  floor?: number; // lowest y the axis may show (e.g. 0 for cumulative amounts)
};

/** Minimal responsive SVG line chart: no dependencies, colors from CSS. */
export function lineChart(el: HTMLElement, series: Series[], opts: Options = {}) {
  const W = 720;
  const H = opts.height ?? 260;
  const pad = { l: 64, r: 34, t: 14, b: 32 };
  const all = series.flatMap((s) => s.points);
  if (all.length === 0) {
    el.innerHTML = `<p class="muted">No data yet.</p>`;
    return;
  }
  let [x0, x1] = [Math.min(...all.map((p) => p[0])), Math.max(...all.map((p) => p[0]))];
  let [y0, y1] = [Math.min(...all.map((p) => p[1])), Math.max(...all.map((p) => p[1]))];
  if (x0 === x1) [x0, x1] = [x0 - 1, x1 + 1];
  if (y0 === y1) [y0, y1] = [y0 * 0.99 - 1e-9, y1 * 1.01 + 1e-9];
  const minSpan = Math.abs((y0 + y1) / 2) * (opts.minRelSpan ?? 0);
  if (y1 - y0 < minSpan) {
    const mid = (y0 + y1) / 2;
    [y0, y1] = [mid - minSpan / 2, mid + minSpan / 2];
  }
  const yPad = (y1 - y0) * 0.08;
  y0 -= yPad;
  y1 += yPad;
  if (opts.floor !== undefined && y0 < opts.floor) y0 = opts.floor;

  const sx = (x: number) => pad.l + ((x - x0) / (x1 - x0)) * (W - pad.l - pad.r);
  const sy = (y: number) => pad.t + (1 - (y - y0) / (y1 - y0)) * (H - pad.t - pad.b);
  const yf = opts.yFormat ?? ((y) => y.toFixed(2));
  const xf = opts.xFormat ?? ((x) => x.toFixed(0));

  const yTicks = opts.yTicks ?? 4;
  const xTicks = opts.xTicks ?? 4;
  let grid = "";
  for (let i = 0; i <= yTicks; i++) {
    const y = y0 + ((y1 - y0) * i) / yTicks;
    grid += `<line x1="${pad.l}" x2="${W - pad.r}" y1="${sy(y)}" y2="${sy(y)}" class="chart-grid"/>`;
    grid += `<text x="${pad.l - 8}" y="${sy(y) + 4}" text-anchor="end" class="chart-label">${yf(y)}</text>`;
  }
  for (let i = 0; i <= xTicks; i++) {
    const x = x0 + ((x1 - x0) * i) / xTicks;
    grid += `<text x="${sx(x)}" y="${H - 10}" text-anchor="middle" class="chart-label">${xf(x)}</text>`;
  }
  if (opts.marker !== undefined && opts.marker >= x0 && opts.marker <= x1) {
    grid += `<line x1="${sx(opts.marker)}" x2="${sx(opts.marker)}" y1="${pad.t}" y2="${H - pad.b}" class="chart-marker"/>`;
  }

  const lines = series
    .map((s) => {
      const d = s.points.map((p, i) => `${i ? "L" : "M"}${sx(p[0]).toFixed(1)},${sy(p[1]).toFixed(1)}`).join("");
      return `<path d="${d}" fill="none" stroke="${s.color}" stroke-width="2.5" stroke-linejoin="round"${
        s.dashed ? ' stroke-dasharray="6 5"' : ""
      }><title>${s.name}</title></path>`;
    })
    .join("");

  const legend = series
    .map((s) => `<span class="legend-item"><i style="background:${s.color}"></i>${s.name}</span>`)
    .join("");

  el.innerHTML = `<svg viewBox="0 0 ${W} ${H}" class="chart" role="img" aria-label="${series
    .map((s) => s.name)
    .join(", ")}">${grid}${lines}</svg><div class="legend">${series.length > 1 ? legend : ""}</div>`;
}
