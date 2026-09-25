// One end-to-end gate for the page: a headless Neovim serves a buffer, a
// headless Chromium renders it, and an edit made through Neovim's RPC reaches
// the page the way a user's edit does, through the plugin's own autocmds and
// its SSE push, with no explicit refresh. It needs network: the page loads
// its libraries from jsDelivr and unpkg until they ship with the plugin. The
// printed diagnosis is the record of a red run (no screenshot is kept), and
// an interrupted run (SIGINT) still leaves Playwright's own profile behind.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import { chromium, type Browser, type Page, type Request } from "playwright";

const root = realpathSync(resolve(import.meta.dir, "..", ".."));

let work = "";
let outLog = "";
let errLog = "";
let sock = "";
let env: Record<string, string | undefined> = {};
let liveServer = "";
let nvim: ReturnType<typeof Bun.spawn> | undefined;
let browser: Browser | undefined;
let page: Page | undefined;
let url = "";
const consoleLines: string[] = [];
const pageErrors: string[] = [];
const failedRequests: string[] = [];
const badResponses: string[] = [];
const pending = new Set<Request>();

const isDir = (p: string) => existsSync(p) && statSync(p).isDirectory();
const readText = (p: string) => (p && existsSync(p) ? readFileSync(p, "utf8") : "");

// The lookup tests/helpers.lua's H.rtp makes, so the suites and this test
// load the same live-server.
function findLiveServer(): string {
  const override = process.env.LIVE_SERVER_RTP;
  const candidates: string[] = [];
  if (override) {
    if (!isDir(override)) throw new Error(`LIVE_SERVER_RTP is set but is not a directory: ${override}`);
    candidates.push(override);
  }
  candidates.push(join(root, "live-server-rtp"), join(dirname(root), "live-server.nvim"));
  const found = candidates.find(isDir);
  if (!found) throw new Error(`live-server.nvim not found: set LIVE_SERVER_RTP or clone it to ${candidates.join(" or ")}`);
  return realpathSync(found);
}

function within<T>(ms: number, what: string, p: Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const limit = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} did not finish within ${ms} ms`)), ms);
  });
  return Promise.race([p, limit]).finally(() => clearTimeout(timer));
}

async function pageState(): Promise<string> {
  if (!page) return "no page";
  try {
    return await within(
      5_000,
      "reading the page state",
      page.evaluate(
        () =>
          `readyState ${document.readyState}; #content: ${JSON.stringify((document.getElementById("content")?.innerText ?? "").slice(0, 500))}`,
      ),
    );
  } catch (e) {
    return (e as Error).message;
  }
}

async function diagnosis(): Promise<string> {
  return [
    `neovim exit: ${!nvim ? "not started" : nvim.signalCode ? "none" : (nvim.exitCode ?? "running")}, signal: ${nvim?.signalCode ?? "none"}`,
    `neovim stdout: ${readText(outLog)}`,
    `neovim stderr: ${readText(errLog)}`,
    `page errors: ${JSON.stringify(pageErrors)}`,
    `console errors and warnings: ${JSON.stringify(consoleLines)}`,
    `pending requests: ${JSON.stringify([...pending].map((r) => r.url()))}`,
    `failed requests: ${JSON.stringify(failedRequests)}`,
    `responses 400 and up: ${JSON.stringify(badResponses)}`,
    `page state: ${await pageState()}`,
  ].join("\n");
}

async function remoteExpr(expr: string): Promise<string> {
  const p = Bun.spawn(["nvim", "--server", sock, "--remote-expr", expr], { env, stdout: "pipe", stderr: "pipe" });
  const run = (async () => {
    const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
    if (code !== 0) throw new Error(`remote-expr ${expr} exited ${code}: ${err}`);
    return out.trim();
  })();
  try {
    return await within(10_000, `remote-expr ${expr}`, run);
  } finally {
    p.kill();
  }
}

async function waitForUrl(ms: number): Promise<string> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    const m = readText(outLog).match(/URL (\S+)/);
    if (m) return m[1];
    if (nvim!.exitCode !== null || nvim!.signalCode !== null) break;
    await Bun.sleep(200);
  }
  const how =
    nvim!.signalCode !== null ? `killed by ${nvim!.signalCode}`
    : nvim!.exitCode !== null ? `exited ${nvim!.exitCode}`
    : `none within ${ms} ms`;
  throw new Error(`no preview URL from Neovim: ${how}\n${await diagnosis()}`);
}

// The file each module was loaded from, so a copy on a start package or an
// earlier runtimepath entry cannot stand in for the one under test.
async function proveOrigin() {
  const sources = await remoteExpr(
    `luaeval("debug.getinfo(require('markdown_preview').setup, 'S').source .. string.char(10) .. debug.getinfo(require('live_server.server').start, 'S').source")`,
  );
  const [own, dep] = sources.split("\n").map((s) => realpathSync(s.replace(/^@/, "")));
  for (const [name, file, dir] of [
    ["markdown_preview", own, root],
    ["live_server.server", dep, liveServer],
  ]) {
    if (!file.startsWith(dir + sep + "lua" + sep)) throw new Error(`${name} loaded from ${file}, outside ${dir}`);
  }
}

beforeAll(async () => {
  liveServer = findLiveServer();
  console.log(`live-server.nvim: ${liveServer}`);
  work = mkdtempSync(join(tmpdir(), "mp-smoke-"));
  const md = join(work, "doc.md");
  sock = join(work, "nvim.sock");
  // Files, not pipes: a file can be polled with a deadline and read back
  // whole for a diagnosis, while a pipe reader cannot be cancelled.
  outLog = join(work, "nvim.out");
  errLog = join(work, "nvim.err");
  env = { ...process.env };
  for (const k of ["CONFIG", "DATA", "STATE", "CACHE"]) {
    env[`XDG_${k}_HOME`] = join(work, k.toLowerCase());
    mkdirSync(join(work, k.toLowerCase()));
  }
  writeFileSync(md, "# Smoke\n\nfirst paragraph\n");
  const lua = JSON.stringify;
  const setup =
    "lua require('markdown_preview').setup({ open_browser = false, instance_mode = 'multi', debounce_ms = 50, " +
    "hooks = { on_start = function(u) io.stdout:write('URL ' .. u .. '\\n') io.stdout:flush() end } })";
  nvim = Bun.spawn(
    [
      "nvim", "--headless", "-u", "NONE", "--listen", sock,
      "-c", `lua vim.opt.rtp:prepend(${lua(liveServer)}) vim.opt.rtp:prepend(${lua(root)})`,
      "-c", `lua vim.cmd.edit(vim.fn.fnameescape(${lua(md)})) vim.bo.filetype = 'markdown'`,
      "-c", setup, "-c", "lua require('markdown_preview').start()",
    ],
    { env, stdout: Bun.file(outLog), stderr: Bun.file(errLog) },
  );
  url = await waitForUrl(15_000);
  await proveOrigin();
  browser = await chromium.launch({ headless: true, timeout: 20_000 });
  page = await browser.newPage();
  // The file watcher reloads too, so the text alone cannot tell whether the
  // plugin's own push arrived: record each reload the page's stream carries.
  await page.addInitScript(() => {
    const Native = window.EventSource;
    (window as any).__reloads = [];
    window.EventSource = class extends Native {
      constructor(u: string | URL, init?: EventSourceInit) {
        super(u, init);
        this.addEventListener("reload", (e) => (window as any).__reloads.push((e as MessageEvent).data));
      }
    };
  });
  page.on("console", (m) => {
    if (m.type() === "error" || m.type() === "warning") consoleLines.push(`${m.type()}: ${m.text()}`);
  });
  page.on("pageerror", (e) => pageErrors.push(e.message));
  page.on("request", (r) => pending.add(r));
  page.on("requestfinished", (r) => pending.delete(r));
  page.on("requestfailed", (r) => {
    pending.delete(r);
    failedRequests.push(`${r.url()} ${r.failure()?.errorText ?? ""}`);
  });
  page.on("response", (r) => {
    if (r.status() >= 400) badResponses.push(`${r.status()} ${r.url()}`);
  });
}, 60_000);

afterAll(async () => {
  try {
    if (browser) await within(10_000, "browser.close()", browser.close()).catch((e) => console.error(e.message));
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
    if (work) rmSync(work, { recursive: true, force: true });
  }
}, 30_000);

test("renders the buffer and follows an edit through the plugin's autocmds and SSE push", async () => {
  try {
    await page!.goto(url, { timeout: 40_000 });
    await page!.waitForSelector("#content h1", { timeout: 20_000 });
    expect(await page!.textContent("#content h1")).toBe("Smoke");
    expect(await page!.locator("#content p").count()).toBe(1);

    // The page subscribes only after its first render and never replays a
    // reload it missed, so an edit made before the stream opens is lost.
    await page!.waitForSelector("#statusDot.connected", { timeout: 15_000 }).catch(() => {
      throw new Error("the page never connected its event stream within 15000 ms");
    });

    await remoteExpr("nvim_buf_set_lines(0, -1, -1, v:false, ['', 'second paragraph'])");
    await page!
      .waitForFunction(() => document.getElementById("content")?.innerText.includes("second paragraph"), null, {
        timeout: 15_000,
      })
      .catch(() => {
        throw new Error("the edit never reached the page within 15000 ms: the update was missed");
      });
    expect(await page!.locator("#content p").count()).toBe(2);
    const reloads: string[] = await within(5_000, "reading the reloads", page!.evaluate(() => (window as any).__reloads));
    if (!reloads.some((d) => /"path":"content\.md"/.test(d))) {
      throw new Error(`the plugin's own reload push never reached the page; reloads seen: ${JSON.stringify(reloads)}`);
    }
    // A CDN library that failed to load is a gate failure with its URL named,
    // not a flake to retry blind.
    expect(failedRequests).toEqual([]);
  } catch (e) {
    throw new Error(`${(e as Error).message}\n${await diagnosis()}`);
  }
}, 120_000);
