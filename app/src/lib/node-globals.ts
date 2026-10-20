// Mezo Passport's Bitcoin libraries expect Node's Buffer; give them the browser build first.
import { Buffer } from "buffer";

type Proc = { env: object; version: string; browser: boolean; nextTick: (fn: (...a: unknown[]) => void, ...a: unknown[]) => void };
const g = globalThis as unknown as { Buffer?: typeof Buffer; global?: typeof globalThis; process?: Proc };
g.Buffer ??= Buffer;
g.global ??= globalThis;
g.process ??= {
  env: {},
  version: "",
  browser: true,
  nextTick: (fn, ...a) => queueMicrotask(() => fn(...a)),
};
