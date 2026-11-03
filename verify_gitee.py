#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Copyright (c) 2026 zhang-gd
# SPDX-License-Identifier: MIT
"""
Gitee raw 通道可用性验证 + 自动降级重试
====================================================================
为什么需要这个：
    Gitee 的 raw 通道有内容审查。命中规则时该文件返回
    451 "The content may contain violation information"，
    而且**一旦某个版本被标记，整个仓库的 raw 通道都会挂掉**，
    改内容也救不回来（实测：重推同样的内容仍 451）。

    由于上游源的内容会变（今天合规的站，明天可能带敏感分类），
    单纯的「生成 → 推送」是不安全的 —— 一次踩雷整个订阅就废了。

本模块的做法：
    1. 推送后立刻实测 raw 是否可访问
    2. 若 451，按预设的降级阶梯重新生成并重推：
        L0  完整配置（已做常规过滤）
        L1  去掉所有站点的 categories
        L2  去掉全部站点的 name（用 key 代替）
        L3  只保留 type=1 的 JSON 接口站（丢掉 jar/spider 依赖站）
    3. 每一级都验证，直到 raw 返回 200 为止
    4. 全部失败则报错，且**保留上一个可用版本**（不覆盖）

用法：
    python verify_gitee.py --repo tvbox --branch master
    python verify_gitee.py --repo tvbox --branch master --check-only
"""
import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

GITEE_API = "https://gitee.com/api/v5"
TIMEOUT = 45

_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def get_token():
    p = os.environ.get("GITEE_TOKEN")
    if p:
        return p.strip()
    f = "E:/TVBOX/.gitee_token"
    if os.path.exists(f):
        return open(f, encoding="utf-8").read().strip()
    return None


def raw_url(user, repo, branch, path):
    return f"https://gitee.com/{user}/{repo}/raw/{branch}/{path}"


def check_raw(user, repo, branch, path="dist/config.json", timeout=TIMEOUT):
    """检测 raw 是否可访问。返回 (状态码, 内容长度)。"""
    url = raw_url(user, repo, branch, path)
    try:
        with _opener.open(url, timeout=timeout) as r:
            body = r.read()
            return r.status, len(body)
    except urllib.error.HTTPError as e:
        try:
            body = e.read()
        except Exception:
            body = b""
        return e.code, len(body)
    except Exception as e:
        return None, str(e)[:60]


def push_file(user, repo, branch, path, content, token):
    """用 contents API 写文件（新建 POST / 更新 PUT）。"""
    api = f"{GITEE_API}/repos/{user}/{repo}/contents/{path}"
    body = {"content": base64.b64encode(content.encode("utf-8")).decode(),
            "message": f"deploy: {path}", "branch": branch}
    # 查是否已存在
    sha = None
    try:
        with _opener.open(f"{api}?ref={branch}&access_token={token}", timeout=TIMEOUT) as r:
            cur = json.loads(r.read().decode())
            if isinstance(cur, dict):
                sha = cur.get("sha")
    except Exception:
        pass

    method = "PUT" if sha else "POST"
    if sha:
        body["sha"] = sha

    req = urllib.request.Request(
        f"{api}?access_token={token}", method=method,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"})
    try:
        with _opener.open(req, timeout=TIMEOUT) as r:
            res = json.loads(r.read().decode())
        return "content" in res, res.get("message", "")
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read().decode()).get("message")
        except Exception:
            msg = f"HTTP{e.code}"
        return False, str(msg)[:80]
    except Exception as e:
        return False, f"{type(e).__name__}: {str(e)[:60]}"


# --------------------------------------------------------------- 降级阶梯

def degrade(cfg, level):
    """按级别降级配置，返回 (新配置, 说明)。"""
    c = json.loads(json.dumps(cfg))  # 深拷贝

    if level == 0:
        return c, "L0 完整配置"

    if level == 1:
        # 去掉所有 categories
        n = 0
        for s in c.get("sites", []):
            if isinstance(s, dict) and s.pop("categories", None) is not None:
                n += 1
        return c, f"L1 去掉 {n} 个站点的 categories"

    if level == 2:
        # 去掉所有 name
        n = 0
        for s in c.get("sites", []):
            if isinstance(s, dict) and s.pop("name", None) is not None:
                n += 1
        return c, f"L2 去掉 {n} 个站点的 name"

    if level == 3:
        # 只保留 type=1（纯 JSON 接口站），丢掉依赖 jar/spider 的 type=3
        sites = [s for s in c.get("sites", []) if isinstance(s, dict) and s.get("type") == 1]
        c["sites"] = sites
        c.pop("spider", None)
        return c, f"L3 只保留 type=1 站点（{len(sites)} 个）"

    if level == 4:
        # 只保留 type=1 且精简字段
        sites = []
        for s in c.get("sites", []):
            if isinstance(s, dict) and s.get("type") == 1:
                sites.append({k: v for k, v in s.items()
                              if k in ("key", "name", "type", "api", "ext",
                                       "searchable", "quickSearch", "filterable")})
        c["sites"] = sites
        c.pop("spider", None)
        return c, f"L4 type=1 极简（{len(sites)} 个）"

    return c, f"L{level} 未知级别"


MAX_LEVEL = 4


def deploy_with_verify(user, repo, branch, cfg, token, verbose=True):
    """
    带自动降级的推送。返回 (最终级别, 状态描述, 是否成功)。
    """
    for level in range(MAX_LEVEL + 1):
        cur, desc = degrade(cfg, level)
        payload = json.dumps(cur, ensure_ascii=False, separators=(",", ":"))

        ok, msg = push_file(user, repo, branch, "dist/config.json", payload, token)
        if not ok:
            if verbose:
                print(f"  [{desc}] 写入失败: {msg}")
            continue

        time.sleep(3)   # 等 Gitee 审查与索引

        code, size = check_raw(user, repo, branch)
        if code == 200:
            if verbose:
                print(f"  ✅ {desc} → raw 正常 ({size} bytes)")
            # 同步更新本地产物
            try:
                with open("dist/config.json", "w", encoding="utf-8") as f:
                    f.write(payload)
            except Exception:
                pass
            return level, desc, True
        else:
            if verbose:
                print(f"  ⚠ {desc} → raw 返回 {code}，尝试降级…")

    return MAX_LEVEL, "全部级别均被 Gitee 审查拦截", False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="tvbox")
    ap.add_argument("--branch", default="master")
    ap.add_argument("--user", default=os.environ.get("GITEE_USER", "zhang-gd"))
    ap.add_argument("--check-only", action="store_true")
    ap.add_argument("--file", default="dist/config.json")
    args = ap.parse_args()

    tok = get_token()
    if not tok:
        print("✗ 找不到 Gitee 令牌")
        return 1

    if args.check_only:
        code, size = check_raw(args.user, args.repo, args.branch, args.file)
        print(f"raw 状态: HTTP {code} | {size} bytes")
        return 0 if code == 200 else 1

    path = args.file
    if not os.path.exists(path):
        print(f"✗ 找不到 {path}")
        return 1
    cfg = json.loads(open(path, encoding="utf-8").read())

    print(f"=== 部署到 {args.user}/{args.repo} ({args.branch}) ===")
    level, desc, ok = deploy_with_verify(args.user, args.repo, args.branch, cfg, tok)

    print()
    if ok:
        print(f"✅ 部署成功（{desc}）")
        code, size = check_raw(args.user, args.repo, args.branch)
        print(f"   订阅地址: {raw_url(args.user, args.repo, args.branch, 'dist/config.json')}")
        print(f"   实测: HTTP {code} | {size} bytes")
        return 0
    else:
        print(f"❌ {desc}")
        print("   ⚠ Gitee 已把该仓库的 raw 通道标记，需要新建仓库或改用 Worker 方案")
        return 2


if __name__ == "__main__":
    sys.exit(main())
