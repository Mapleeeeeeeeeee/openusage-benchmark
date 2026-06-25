import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function makeAuthCtx() {
  const ctx = makeCtx()
  ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
    tokens: { access_token: "token" },
    last_refresh: new Date().toISOString(),
  }))
  return ctx
}

const RESET_YES_BODY = { state: "yes", reset: true, hasReset: true, updatedAt: Date.now() - 60000 }
const RESET_NO_BODY = { state: "no", reset: false, hasReset: false, updatedAt: Date.now() - 60000 }

function mockApis(ctx, resetResponse) {
  ctx.host.http.request.mockImplementation((opts) => {
    if (String(opts.url || "").includes("hascodexratelimitreset")) {
      return resetResponse
    }
    return {
      status: 200,
      headers: { "x-codex-primary-used-percent": "10" },
      bodyText: JSON.stringify({}),
    }
  })
}

function findResetLine(lines) {
  return lines.find(l => {
    const label = (l.label || "").toLowerCase()
    const value = (l.value || l.text || "").toLowerCase()
    return label.includes("reset") || value.includes("yes") || value.includes("nope")
  })
}

function isGreenish(color) {
  if (!color) return false
  const c = color.toLowerCase()
  return c.includes("22c55e") || c.includes("4ade80") || c.includes("16a34a") ||
    c.includes("74aa9c") || c.includes("green") || c.includes("0f6e56") ||
    c.includes("5dca") || c.includes("1d9e")
}

function isRedOrNegative(color) {
  if (!color) return false
  const c = color.toLowerCase()
  return c.includes("ef4444") || c.includes("f59e0b") || c.includes("red") ||
    c.includes("amber") || c.includes("orange") || c.includes("d85a") ||
    c.includes("f97316") || c.includes("993c") || c.includes("e24b") ||
    c.includes("grey") || c.includes("gray") || c.includes("888")
}

describe("given rate limit reset API, behavioral contract (ref: PR #287)", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("when API returns reset=yes, then shows green positive indicator", async () => {
    const ctx = makeAuthCtx()
    mockApis(ctx, { status: 200, headers: {}, bodyText: JSON.stringify(RESET_YES_BODY) })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = findResetLine(result.lines)

    expect(line).toBeTruthy()
    expect(isGreenish(line.color)).toBe(true)
  })

  it("when API returns reset=no, then shows red/negative indicator", async () => {
    const ctx = makeAuthCtx()
    mockApis(ctx, { status: 200, headers: {}, bodyText: JSON.stringify(RESET_NO_BODY) })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = findResetLine(result.lines)

    expect(line).toBeTruthy()
    expect(isRedOrNegative(line.color)).toBe(true)
  })

  it("when API returns HTTP 500, then omits the reset line", async () => {
    const ctx = makeAuthCtx()
    mockApis(ctx, { status: 500, headers: {}, bodyText: "Internal Server Error" })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(findResetLine(result.lines)).toBeUndefined()
  })

  it("when network request throws, then omits the reset line", async () => {
    const ctx = makeAuthCtx()
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url || "").includes("hascodexratelimitreset")) {
        throw new Error("network timeout")
      }
      return {
        status: 200,
        headers: { "x-codex-primary-used-percent": "10" },
        bodyText: JSON.stringify({}),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(findResetLine(result.lines)).toBeUndefined()
  })

  it("when reset API fails, then probe still returns other lines", async () => {
    const ctx = makeAuthCtx()
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url || "").includes("hascodexratelimitreset")) {
        throw new Error("network timeout")
      }
      return {
        status: 200,
        headers: { "x-codex-primary-used-percent": "10" },
        bodyText: JSON.stringify({}),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result).toBeTruthy()
    expect(result.lines).toBeDefined()
    expect(result.lines.length).toBeGreaterThan(0)
  })
})
