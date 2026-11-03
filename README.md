# TVBox 自建自动更新接口

一套可以长期使用的 TVBox 配置源方案：**你只维护一个订阅地址，内容自己会刷新**。

---

## 一、先搞清楚原理

TVBox 是「壳源分离」架构 —— App 只是个播放框架，里面一行影视内容都没有。
你填进「配置地址」的那个 URL 才是真正的内容源。

所以「自动更新」不需要改 App，只要让**那个 URL 背后的内容会自己刷新**即可：

```
上游公开源 ──定时抓取/去重──▶ 你的服务器 ──▶ 你的固定 URL ──▶ TVBox
                                    ▲
                              TVBox 订阅这个地址
```

有三种落地方式，按推荐度排序：

| 方案 | 成本 | 更新频率 | 适合 |
|---|---|---|---|
| **A. GitHub Actions + 仓库 raw** | 免费，0 服务器 | 定时（4~24 小时） | 大多数人 ✅ |
| **B. Cloudflare Worker 实时聚合** | 免费 | 请求时实时，带缓存 | 想要秒级更新 |
| **C. 纯静态 JSON** | 免费 | 手动 | 只想加几个站 |

> ⚠️ **国内直连 `raw.githubusercontent.com` 很慢**，TVBox 里请套一层加速前缀：
> `https://gh-proxy.com/` 或 `https://ghproxy.net/`。
> Cloudflare Worker 方案不受此影响（Worker 在境外，客户端直连反而快）。

---

## 二、目录结构

```
TVBOX/
├── config/
│   ├── sources.json      ← 上游源清单（改这里换源）
│   └── local.json        ← 你自己的内容（自建站/解析器/分组）
├── scripts/
│   ├── build.py          ← 核心：抓取 + 合并 + 去重 + 输出
│   └── serve.py          ← 本地预览服务器
├── worker/
│   ├── src/index.js      ← 方案 B：实时聚合 Worker
│   ├── src/vod-api.js    ← 自建点播接口（type=1 苹果CMS 协议）
│   ├── wrangler.toml
│   └── vod-api.wrangler.toml
├── .github/workflows/
│   └── update.yml        ← 定时更新任务
└── dist/                 ← 生成产物（自动创建）
    ├── config.json       ← ★ 你要订阅的就是这个
    ├── live.txt          ← 直播源（TXT 格式）
    ├── live.m3u          ← 直播源（M3U 格式）
    └── status.json       ← 本次更新统计
```

---

## 三、方案 A：GitHub Actions（推荐）

> ⚠️ **网络前提**：本机 `github.com` 的 git 端点被代理拦截（CONNECT 502），
> 但 `api.github.com` 和 `raw.githubusercontent.com` 直连正常。
> 所以推送走 **SSH over 443**（`ssh.github.com:443`），脚本已配好 `~/.ssh/config`。

### 0. 一次性准备（只需做一次）

**① 把本机公钥添加到 GitHub**

```bash
cat ~/.ssh/id_ed25519.pub
```

打开 https://github.com/settings/keys → `New SSH key` → 粘贴上面输出 → 保存。

**② 在 GitHub 建一个空仓库**

打开 https://github.com/new → 仓库名填 `tvbox-config` → **不要勾选**
README / .gitignore / LICENSE → `Create repository`。

**③ 开启 Actions 写权限**

仓库 → `Settings` → `Actions` → `General` → `Workflow permissions`
→ 选 **Read and write permissions**。

### 1. 一键部署

```bash
cd E:\TVBOX
bash deploy.sh
```

脚本会自动：检查 SSH 连通性 → 生成产物 → 提交 → 推送 → 打印订阅地址。

想顺带体检失效站点用 `bash deploy.sh --check`。

### 2. 验证定时任务

仓库 `Actions` 页面 → 选「更新 TVBox 配置」→ `Run workflow` 手动跑一次。
跑完看 `dist/config.json` 有没有更新，跑绿了定时任务就没问题。

### 3. 订阅地址

产物提交到 `dist/`，raw 地址就是订阅地址：

```
https://gh-proxy.com/https://raw.githubusercontent.com/你的用户名/你的仓库/main/dist/config.json
```

加速前缀备选（第一个失效换下一个）：
`https://ghproxy.net/` → `https://mirror.ghproxy.com/`

在 TVBox 里：`设置` → `配置地址` → 粘贴 → 确定。

### 手动方式（不用脚本时）

```bash
git add . && git commit -m "update"
git push origin main
```

### 5. 手动触发一次

`Actions` → `更新 TVBox 配置` → `Run workflow` → 勾选 `check` → 运行。

---

## 四、方案 B：Cloudflare Worker（实时）

适合想要「上游一改，我这边立刻生效」。

### 1. 部署

```bash
cd E:\TVBOX\worker
npm install -g wrangler
npx wrangler login
npx wrangler kv namespace create KV     # 把返回的 id 填进 wrangler.toml
npx wrangler deploy
```

### 2. 绑定自定义域名（重要）

`workers.dev` 域名在部分国内网络下打不开。**强烈建议绑自己的域名**：

```toml
# wrangler.toml 里取消注释
[[routes]]
pattern = "tvbox.你的域名.com"
custom_domain = true
```

### 3. 订阅地址

```
https://tvbox.你的域名.com/
```

Worker 还提供：

| 路径 | 作用 |
|---|---|
| `/` | TVBox 配置（主入口） |
| `/health` | 健康检查，看缓存状态和站点数 |
| `/refresh` | 强制刷新缓存 |

---

## 五、关键字段说明

生成的 `dist/config.json` 顶层结构：

```jsonc
{
  "spider": "http://.../xxx.jar;md5;xxxxxxxx",  // 全局爬虫包，type=3 站点全靠它
  "wallpaper": "背景图地址",
  "sites": [ /* 点播源 */ ],
  "parses": [ /* 解析器 */ ],
  "flags": [ "国产", "港台" ],                    // 分类筛选标签
  "lives": [ /* 直播源 */ ],
  "rules": [ /* proxy 劫持替换、嗅探规则 */ ],
  "doh": [ /* DNS 解析 */ ],
  "headers": [ /* 自定义请求头 */ ],
  "ads": [ /* 广告域名拦截 */ ]
}
```

### sites 里的 type 决定加载方式

| type | 含义 | 你的接口要返回什么 |
|---|---|---|
| `0` | XML 接口（老格式） | 苹果CMS 的 XML 输出 |
| `1` | JSON 接口（苹果CMS 风格） | 固定 JSON，见下 |
| `3` | Spider（`csp_XXX` 类名） | 由 `spider` 指向的 JAR 包负责解析 |

**注意**：绝大多数站点是 `type=3`，依赖 `spider` 字段指向的 JAR。
`build.py` 会自动让没有 `jar` 的 type=3 站点继承顶层 `spider`，并保留 `;md5;xxx` 校验后缀 —— 这步漏了，全部站点加载失败。

### type=1 接口的调用约定

TVBox 会这样请求你的接口：

```
{api}?ac=list&t={分类id}&pg={页码}     分类列表
{api}?ac=detail&ids={影片id}           影片详情
{api}?wd={关键词}&ac=detail&pg={页码}  搜索
```

统一响应格式：

```json
{
  "code": 1,
  "msg": "数据列表",
  "page": 1, "pagecount": 1, "limit": 20, "total": 100,
  "list": [{
    "vod_id": "1001",
    "vod_name": "影片名",
    "vod_pic": "封面图",
    "vod_remarks": "更新至20集",
    "vod_year": "2026",
    "type_name": "电影",
    "vod_play_from": "线路一$$$线路二",
    "vod_play_url": "第1集$http://a/1.m3u8#第2集$http://a/2.m3u8$$$第1集$http://b/1.m3u8"
  }]
}
```

- `vod_play_from` 几条线路，`vod_play_url` 就用几个 `$$$` 分隔
- 同一线路的多集用 `#` 分隔，集名与地址用 `$` 分隔
- 可直接部署 `worker/src/vod-api.js` 作为起点，改掉里面的演示数据即可

---

## 六、去重是怎么做的

| type | 去重依据 | 效果 |
|---|---|---|
| `1` | 主机 + 路径 | `http://a.com/api.php/provide/vod` 和 `https://a.com/api.php/provide/vod/` 合并成一条 |
| `3`（js 源） | `ext` 里的文件名 | 同一份 js 在不同镜像仓库出现，只留一条 |
| `3`（csp 源） | `api` 类名 | `csp_Foo` 只留一个 |

`spider` 走「多源投票」：多个上游各带一个 JAR，出现次数最多的胜出。

---

## 七、常见问题

**Q：订阅地址填进去一片空白？**
配置 JSON 格式错了。TVBox 遇到非法 JSON 会直接报「配置错误」或分类空白。
先在电脑上打开 `dist/config.json` 确认能正常解析。

**Q：所有站点都加载不出来？**
`spider` 字段丢了或 JAR 地址失效。
- 检查 `dist/config.json` 顶层有没有 `spider`
- 访问 spider 地址看能否下载（它常伪装成 `.jpg`，这是正常的）
- `;md5;xxx` 是校验位，客户端会核对，别手改

**Q：部分站打不开？**
上游源已失效。加 `--check` 参数，脚本会逐个探测 type=1 接口存活情况并丢弃失效站：

```bash
python scripts/build.py --check
```

**Q：直播源一个都没有？**
直播源地址在本机被墙。用 `curl` 测一下可达性，换个源。
`config/sources.json` 里 `live` 数组支持 m3u 和 txt 两种格式，脚本会自动识别并转换。

**Q：GitHub Actions 不运行？**
- Actions 权限要选 read and write
- 新仓库默认 Actions 是禁用的，第一次要手动点 `I understand my workflows, go ahead and enable them`
- 定时任务在**无活动时可能被延迟**，想立刻生效用 `workflow_dispatch` 手动触发

**Q：想加自己的站？**
编辑 `config/local.json` 的 `sites`，`type:1` 填自己的 CMS 接口地址，`type:3` 填 `csp_你的类名` 并指定 `jar`。

---

## 八、几件事得说清楚

- **免费源死得最快。** 免费接口没有商业支撑，改版、域名过期、防盗链上线，任何一环断了就失效。这就是为什么需要「自动更新」机制，而不是一次配好就不管。
- **聚合不等于免责。** 你在自己的配置里加了什么源，责任在你。只收录公开可访问的源，别碰盗版站。
- **别指望「永久接口」。** 真正稳的做法是：把 `spider` JAR 和你信任的几个源**下载到自己的仓库**，让 GitHub Actions 定期校验并更新失效链接，而不是每次都实时去抓别人的仓库。
- **4K 卡顿多半不是带宽问题。** 老电视没有 HEVC 硬解，4K 会变成幻灯片。先用 1080P 验证流畅度。

---

## 九、命令速查

```bash
# 生成配置
python scripts/build.py

# 生成 + 校验 type=1 接口存活
python scripts/build.py --check

# 本地预览
python scripts/serve.py
# 浏览器打开 http://127.0.0.1:8899/dist/config.json

# 手动触发一次更新
# GitHub 仓库 → Actions → 更新 TVBox 配置 → Run workflow
```
