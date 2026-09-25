// One end-to-end gate for the page: a headless Neovim serves a buffer, a
// headless Chromium renders it, and an edit made through Neovim's RPC reaches
// the page over SSE. It needs network: the page loads its libraries from
// jsDelivr until they ship with the plugin.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { chromium, type Browser, type Page } from "playwright";

const root = resolve(import.meta.dir, "..", "..");
const liveServer = [
  process.env.LIVE_SERVER_RTP,
  join(root, "live-server-rtp"),
  resolve(root, "..", "live-server.nvim"),
].find((d) => d && existsSync(d));
if (!liveServer) throw new Error("live-server.nvim not found: set LIVE_SERVER_RTP");

const work = mkdtempSync(join(tmpdir(), "mp-smoke-"));
const md = join(work, "doc.md");
const sock = join(work, "nvim.sock");
// Neovim's output goes to files, not pipes: a file can be polled with a
// deadline and read back whole for a diagnosis, while a pipe reader cannot
// be cancelled once it waits.
const outLog = join(work, "nvim.out");
const errLog = join(work, "nvim.err");
const env = {
  ...process.env,
  XDG_CACHE_HOME: join(work, "cache"),
  XDG_DATA_HOME: join(work, "data"),
  XDG_STATE_HOME: join(work, "state"),
};

let nvim: ReturnType<typeof Bun.spawn> | undefined;
let browser: Browser | undefined;
let page: Page | undefined;
let url = "";
const consoleErrors: string[] = [];
const failedRequests: string[] = [];

const readText = (p: string) => (existsSync(p) ? readFileSync(p, "utf8") : "");
const diagnosis = () =>
  `stdout: ${readText(outLog)}\nstderr: ${readText(errLog)}\nconsole errors: ${JSON.stringify(consoleErrors)}\nfailed requests: ${JSON.stringify(failedRequests)}`;

async function remoteExpr(expr: string): Promise<string> {
  const p = Bun.spawn(["nvim", "--server", sock, "--remote-expr", expr], { env, stdout: "pipe", stderr: "pipe" });
  const out = await new Response(p.stdout).text();
  if ((await p.exited) !== 0) throw new Error("remote-expr failed: " + (await new Response(p.stderr).text()));
  return out.trim();
}

async function waitForUrl(ms: number): Promise<string> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    const m = readText(outLog).match(/URL (\S+)/);
    if (m) return m[1];
    if (nvim!.exitCode !== null) break;
    await Bun.sleep(200);
  }
  throw new Error(`no preview URL from Neovim within ${ms} ms (exit ${nvim!.exitCode})\n${diagnosis()}`);
}

beforeAll(async () => {
  writeFileSync(md, "# Smoke\n\nfirst paragraph\n");
  const setup =
    "lua require('markdown_preview').setup({ open_browser = false, instance_mode = 'multi', debounce_ms = 50, " +
    "hooks = { on_start = function(u) io.stdout:write('URL ' .. u .. '\\n') io.stdout:flush() end } })";
  nvim = Bun.spawn(
    [
      "nvim", "--headless", "-u", "NONE", "--listen", sock,
      "-c", `set rtp+=${liveServer}`, "-c", `set rtp+=${root}`,
      "-c", `edit ${md}`, "-c", "set filetype=markdown",
      "-c", setup, "-c", "lua require('markdown_preview').start()",
    ],
    { env, stdout: Bun.file(outLog), stderr: Bun.file(errLog) },
  );
  url = await waitForUrl(15_000);
  browser = await chromium.launch({ headless: true });
  page = await browser.newPage();
  page.on("console", (m) => {
    if (m.type() === "error") consoleErrors.push(m.text());
  });
  page.on("requestfailed", (r) => failedRequests.push(`${r.url()} ${r.failure()?.errorText ?? ""}`));
}, 40_000);

afterAll(async () => {
  try {
    await browser?.close();
  } finally {
    if (nvim) {
      nvim.kill();
      // Reap, escalating to SIGKILL, so a hung Neovim never outlives the run.
      await Promise.race([nvim.exited, Bun.sleep(3_000)]);
      if (nvim.exitCode === null && nvim.signalCode === null) {
        nvim.kill("SIGKILL");
        await Promise.race([nvim.exited, Bun.sleep(3_000)]);
      }
    }
    rmSync(work, { recursive: true, force: true });
  }
});

test("renders the buffer and updates over SSE after an edit through RPC", async () => {
  try {
    await page!.goto(url);
    await page!.waitForSelector("#content h1", { timeout: 30_000 });
    expect(await page!.textContent("#content h1")).toBe("Smoke");
    expect(await page!.locator("#content p").count()).toBe(1);

    await remoteExpr("nvim_buf_set_lines(0, -1, -1, v:false, ['', 'second paragraph'])");
    // refresh() returns nothing; the trailing 'ok' gives --remote-expr a value to print.
    await remoteExpr("luaeval(\"require('markdown_preview').refresh() or 'ok'\")");
    await page!.waitForFunction(() => document.body.innerText.includes("second paragraph"), null, { timeout: 15_000 });
    expect(await page!.locator("#content p").count()).toBe(2);
    // A CDN library that failed to load is a gate failure with its URL named,
    // not a flake to retry blind.
    expect(failedRequests).toEqual([]);
  } catch (e) {
    throw new Error(`${(e as Error).message}\n${diagnosis()}`);
  }
}, 60_000);
