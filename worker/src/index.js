/**
 * TVBox 配置聚合 Worker
 * ------------------------------------------------------------------
 * 特性：
 *   * 请求时实时抓取多个上游源并合并（不必等定时任务）
 *   * KV 缓存 30 分钟，避免每次请求都打上游
 *   * 全部上游失败时降级到上一次的有效缓存
 *   * 带 CORS 头，可直接当接口地址用
 *   * /refresh 手动强制刷新缓存
 *
 * 部署：
 *   1. npx wrangler kv namespace create KV
 *   2. 把返回的 id 填到 wrangler.toml 的 kv_namespaces
 *   3. npx wrangler deploy
 */

const UPSTREAMS = [
  "https://raw.githubusercontent.com/gaotianliuyun/fongmi/main/json/config.json",
  "https://raw.githubusercontent.com/Lightconer/tvbox-ysc-config/main/output/xiaohezi.json",
];

const CACHE_KEY = "tvbox:config";
const CACHE_TTL = 1800; // 秒

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "*",
    "Access-Control-Allow-Methods": "GET,OPTIONS",
  };
}

function stripComments(text) {
  return text
    .replace(/^\s*\/\/.*$/gm, "")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/,\s*([}\]])/g, "$1");
}

function hostPath(url) {
  try {
    const u = new URL(url);
    return (u.hostname || "").toLowerCase() + (u.pathname || "").replace(/\/+$/, "");
  } catch {
    return url;
  }
}

function resolveUrl(base, ref) {
  if (!ref || typeof ref !== "string") return ref;
  if (/^(https?:|data:|file:|clan:)/.test(ref)) return ref;
  // 拆出 ;md5;hash 校验后缀，解析后再拼回
  let suffix = "";
  const m = ref.match(/^(.*?)(;md5;[0-9a-fA-F]+)$/);
  if (m) { ref = m[1]; suffix = m[2]; }
  if (!/^[./]/.test(ref)) return ref + suffix;
  try {
    return new URL(ref.replace(/^\.\//, ""), base).href + suffix;
  } catch {
    return ref + suffix;
  }
}

function extFp(site) {
  const ext = site.ext;
  if (typeof ext === "string") {
    const m = ext.match(/([^/\\]+\.js)(?:\?|$)/);
    if (m) return m[1];
  }
  if (ext && typeof ext === "object") {
    for (const v of Object.values(ext)) {
      if (typeof v === "string") {
        const m = v.match(/([^/\\]+\.js)(?:\?|$)/);
        if (m) return m[1];
      }
    }
  }
  return null;
}

function fingerprint(site) {
  const api = site.api || "";
  if (site.type === 1) return "cms:" + hostPath(api);
  if (site.type === 3) {
    const fp = extFp(site);
    if (fp) return "js:" + fp;
    if (api.startsWith("csp_")) return "csp:" + api;
  }
  return "raw:" + (site.key || "") + "|" + hostPath(api);
}

async function fetchJson(url) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 15000);
  try {
    const resp = await fetch(url, {
      signal: ctrl.signal,
      headers: { "User-Agent": "Mozilla/5.0", Accept: "application/json,*/*" },
    });
    if (!resp.ok) return null;
    const text = await resp.text();
    return JSON.parse(stripComments(text));
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

function mergeConfigs(configs) {
  const sitesMap = new Map();
  const order = [];
  const jarVotes = new Map();
  const spiderVotes = new Map();
  const parseSeen = new Set();
  const parses = [];
  const flagsSeen = new Set();
  const flags = [];
  const liveSeen = new Set();
  const lives = [];

  for (const { base, cfg } of configs) {
    // 顶层 spider 是全局爬虫包，type=3 的站点全靠它
    const topSpider = cfg.spider ? resolveUrl(base, cfg.spider) : null;
    if (topSpider) {
      spiderVotes.set(topSpider, (spiderVotes.get(topSpider) || 0) + 1);
    }

    for (const rawSite of cfg.sites || []) {
      if (!rawSite || typeof rawSite !== "object") continue;
      const site = { ...rawSite };
      if (site.jar) site.jar = resolveUrl(base, site.jar);
      if (typeof site.ext === "string" && site.ext.includes("/")) {
        site.ext = resolveUrl(base, site.ext);
      }
      // 站点没写 jar 时继承顶层 spider，否则这个站加载不了
      if (!site.jar && topSpider && site.type === 3) site.jar = topSpider;

      const fp = fingerprint(site);
      if (sitesMap.has(fp)) {
        const old = sitesMap.get(fp);
        for (const [k, v] of Object.entries(site)) {
          if (k === "ext" || k === "categories") continue;
          if (old[k] === undefined || old[k] === null || old[k] === "" || old[k] === 0) {
            old[k] = v;
          }
        }
        if (site.categories && !old.categories) old.categories = site.categories;
        continue;
      }
      if (site.searchable === undefined) site.searchable = 1;
      if (site.quickSearch === undefined) site.quickSearch = 1;
      if (site.filterable === undefined) site.filterable = 1;
      sitesMap.set(fp, site);
      order.push(fp);
      if (site.jar) jarVotes.set(site.jar, (jarVotes.get(site.jar) || 0) + 1);
    }

    for (const p of cfg.parses || []) {
      const k = String(p.url || p.name || JSON.stringify(p));
      if (!parseSeen.has(k)) { parseSeen.add(k); parses.push(p); }
    }
    for (const f of cfg.flags || []) {
      const k = String(f);
      if (!flagsSeen.has(k)) { flagsSeen.add(k); flags.push(f); }
    }
    for (const lv of cfg.lives || []) {
      const k = lv.channels ? "g:" + lv.group : "u:" + hostPath(lv.url || "");
      if (!liveSeen.has(k)) { liveSeen.add(k); lives.push(lv); }
    }
  }

  let spider = null;
  if (spiderVotes.size) {
    spider = [...spiderVotes.entries()].sort((a, b) => b[1] - a[1])[0][0];
  } else if (jarVotes.size) {
    spider = [...jarVotes.entries()].sort((a, b) => b[1] - a[1])[0][0];
  }

  // 顶层扩展字段
  const extra = {};
  for (const field of ["wallpaper", "logo", "homepage", "warning", "doh", "headers", "ads"]) {
    const parts = [];
    for (const { cfg } of configs) {
      const v = cfg[field];
      if (v === undefined || v === null) continue;
      if (Array.isArray(v)) parts.push(...v);
      else parts.push(v);
    }
    if (!parts.length) continue;
    if (["wallpaper", "logo", "homepage", "warning"].includes(field)) {
      extra[field] = parts[0];
    } else {
      const seen = new Set();
      extra[field] = parts.filter((x) => {
        const k = typeof x === "object" ? JSON.stringify(x) : String(x);
        if (seen.has(k)) return false;
        seen.add(k);
        return true;
      });
    }
  }

  // rules：数组按 name 去重合并
  const ruleSeen = new Set();
  const rules = [];
  for (const { cfg } of configs) {
    const r = cfg.rules;
    if (!Array.isArray(r)) continue;
    for (const item of r) {
      if (!item || typeof item !== "object") continue;
      if (ruleSeen.has(item.name)) continue;
      ruleSeen.add(item.name);
      rules.push(item);
    }
  }
  if (rules.length) extra.rules = rules;

  return {
    spider,
    sites: order.map((k) => sitesMap.get(k)),
    parses,
    flags,
    lives,
    ...extra,
    _meta: { generated_at: new Date().toISOString(), sites: order.length },
  };
}

async function buildConfig(env) {
  const results = await Promise.all(
    UPSTREAMS.map(async (u) => {
      const cfg = await fetchJson(u);
      return cfg ? { base: u, cfg } : null;
    })
  );
  const ok = results.filter(Boolean);
  if (!ok.length) return null;
  return mergeConfigs(ok);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    // 手动强制刷新
    if (url.pathname === "/refresh") {
      const fresh = await buildConfig(env);
      if (fresh) await env.KV.put(CACHE_KEY, JSON.stringify(fresh));
      return new Response(
        JSON.stringify({ ok: !!fresh, at: new Date().toISOString() }),
        { headers: { ...corsHeaders(), "Content-Type": "application/json" } }
      );
    }

    // 健康检查
    if (url.pathname === "/health") {
      const cached = await env.KV.get(CACHE_KEY, "json");
      return new Response(
        JSON.stringify({
          ok: true,
          has_cache: !!cached,
          sites: cached ? cached.sites.length : 0,
          at: new Date().toISOString(),
        }),
        { headers: { ...corsHeaders(), "Content-Type": "application/json" } }
      );
    }

    // 主入口：TVBox 填这个地址
    let cached = await env.KV.get(CACHE_KEY, "json");
    const fresh = cached && Date.now() - new Date(cached._meta.generated_at).getTime() < CACHE_TTL * 1000;

    if (!fresh) {
      const built = await buildConfig(env);
      if (built) {
        cached = built;
        await env.KV.put(CACHE_KEY, JSON.stringify(built));
      } else if (!cached) {
        return new Response(JSON.stringify({ error: "所有上游源均不可用" }), {
          status: 502,
          headers: { ...corsHeaders(), "Content-Type": "application/json" },
        });
      }
    }

    return new Response(JSON.stringify(cached), {
      headers: {
        ...corsHeaders(),
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "public, max-age=300",
      },
    });
  },
};
