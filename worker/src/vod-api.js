/**
 * 自建点播接口（type=1 苹果CMS 协议）
 * ------------------------------------------------------------------
 * 这是给「你自己有片源」时用的：把本文件部署到 Cloudflare Worker /
 * Vercel / 任意 Node 环境，然后把地址填进 config/local.json 的 sites。
 *
 * TVBox 会这样调用你的接口：
 *   {api}?ac=list&t={分类id}&pg={页码}      分类列表
 *   {api}?ac=detail&ids={影片id}            影片详情
 *   {api}?wd={关键词}&ac=detail&pg={页码}   搜索
 *
 * 统一响应格式：
 *   { code:1, msg:"数据列表", page:1, pagecount:1, limit:20, total:1,
 *     list:[ { vod_id, vod_name, vod_pic, vod_remarks, vod_year,
 *              type_name, vod_play_from, vod_play_url } ] }
 *
 * 说明：
 *   - vod_play_from 是线路名，用 $$$ 分隔
 *   - vod_play_url 是「集名$播放地址」，同一条线路的多个集用 # 分隔
 *   - 播放地址可以是直链 m3u8/mp4，也可以放你的解析器前缀
 */

const CATEGORIES = [
  { type_id: "1", type_name: "电影" },
  { type_id: "2", type_name: "电视剧" },
  { type_id: "3", type_name: "综艺" },
  { type_id: "4", type_name: "动漫" },
];

// 演示数据。换成你自己的数据源，或从数据库/对象存储读取
const VODS = [
  {
    vod_id: "1001",
    vod_name: "示例影片 A",
    vod_pic: "https://picsum.photos/seed/a/300/450",
    vod_remarks: "HD中字",
    vod_year: "2026",
    type_name: "电影",
    vod_play_from: "线路一",
    vod_play_url: "第1集$https://example.com/a/1.m3u8#第2集$https://example.com/a/2.m3u8",
  },
  {
    vod_id: "1002",
    vod_name: "示例影片 B",
    vod_pic: "https://picsum.photos/seed/b/300/450",
    vod_remarks: "更新至12集",
    vod_year: "2026",
    type_name: "电视剧",
    vod_play_from: "线路一$$$线路二",
    vod_play_url:
      "第1集$https://example.com/b/1.m3u8#第2集$https://example.com/b/2.m3u8$$$第1集$https://example.com/b2/1.m3u8#第2集$https://example.com/b2/2.m3u8",
  },
];

function ok(list, total, page = 1, pagecount = 1) {
  return {
    code: 1,
    msg: "数据列表",
    page,
    pagecount,
    limit: 20,
    total,
    list,
  };
}

function handle(req) {
  const u = new URL(req.url);
  const ac = u.searchParams.get("ac") || "list";
  const pg = parseInt(u.searchParams.get("pg") || "1", 10);
  const t = u.searchParams.get("t") || "";
  const ids = u.searchParams.get("ids") || "";
  const wd = u.searchParams.get("wd") || "";

  // 分类列表：TVBox 首次进入站点时调用
  if (ac === "list" && !wd && !ids) {
    return ok(
      CATEGORIES.map((c) => ({
        vod_id: c.type_id,
        vod_name: c.type_name,
        vod_pic: "",
        vod_remarks: "",
        vod_year: "",
        type_name: c.type_name,
        vod_play_from: "",
        vod_play_url: "",
      })),
      CATEGORIES.length
    );
  }

  // 影片详情
  if (ac === "detail" && ids) {
    const found = VODS.filter((v) => v.vod_id === ids);
    return ok(found, found.length);
  }

  // 分类分页
  if (ac === "list" && t) {
    const list = VODS.filter((v) => !t || v.type_name === (CATEGORIES.find((c) => c.type_id === t)?.type_name || ""));
    return ok(list, list.length, pg, 1);
  }

  // 搜索
  if (wd) {
    const kw = wd.toLowerCase();
    const list = VODS.filter((v) => v.vod_name.toLowerCase().includes(kw));
    return ok(list, list.length, pg, 1);
  }

  return ok([], 0);
}

export default {
  async fetch(request) {
    const u = new URL(request.url);

    // 直接访问浏览器时给个说明页，方便调试
    if (u.pathname === "/" && !u.searchParams.has("ac")) {
      return new Response(
        "TVBox 自建点播接口已就绪\n\n" +
          "测试链接：\n" +
          "  ?ac=list\n" +
          "  ?ac=list&t=1&pg=1\n" +
          "  ?ac=detail&ids=1001\n" +
          "  ?wd=示例&ac=detail\n",
        { headers: { "Content-Type": "text/plain; charset=utf-8" } }
      );
    }

    const data = handle(request);
    return new Response(JSON.stringify(data), {
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Access-Control-Allow-Origin": "*",
        "Cache-Control": "public, max-age=300",
      },
    });
  },
};
