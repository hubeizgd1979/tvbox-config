#!/usr/bin/env bash
# ==============================================================================
# Gitee 仓库管理脚本
# ==============================================================================
# 为什么用 Gitee：本机网络下 github.com 完全不可达（代理 CONNECT 502，
# 直连 DNS 节点被墙），但 gitee.com 直连 200、raw 通道 200 —— 反而更稳更快。
#
# 令牌获取：https://gitee.com/profile/personal_access_tokens
#   勾选 projects 权限（建仓/删仓/读写文件）
#   令牌放到 E:/复制github/.gitee_token 或环境变量 GITEE_TOKEN
#
# 用法:
#   bash gitee.sh status              # 列出仓库
#   bash gitee.sh create <名字> [描述]  # 创建仓库
#   bash gitee.sh delete <名字>        # 删除仓库（自动备份+二次确认）
#   bash gitee.sh push <目录> <仓库名> [分支]  # 推送整棵目录
#   bash gitee.sh backup <名字> [分支]  # 单独备份
#   bash gitee.sh token-info           # 检查令牌权限
# ==============================================================================
set -uo pipefail

GITEE_USER="${GITEE_USER:-zhang-gd}"
API="https://gitee.com/api/v5"
TOKEN_FILE="${TOKEN_FILE:-E:/TVBOX/.gitee_token}"
BACKUP_DIR="${BACKUP_DIR:-E:/复制github/仓库备份_20261103}"
PY="/c/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe"

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'
say()  { echo -e "${CYN}$1${NC}"; }
ok()   { echo -e "${GRN}✓ $1${NC}"; }
warn() { echo -e "${YEL}! $1${NC}"; }
err()  { echo -e "${RED}✗ $1${NC}"; }

# Gitee 直连可用，不要走代理
export no_proxy="127.0.0.1,localhost"
export NO_PROXY="127.0.0.1,localhost"

get_token() {
  if [ -n "${GITEE_TOKEN:-}" ]; then
    echo "$GITEE_TOKEN" | tr -d '\r\n '
    return 0
  fi
  if [ -f "$TOKEN_FILE" ]; then
    tr -d '\r\n ' < "$TOKEN_FILE"
    return 0
  fi
  err "找不到 Gitee 令牌。请任选一种方式提供："
  echo "    1) 放到文件: $TOKEN_FILE"
  echo "    2) 设环境变量: export GITEE_TOKEN=xxxx"
  echo "    令牌获取页: https://gitee.com/profile/personal_access_tokens"
  echo "    （勾选 projects 权限）"
  exit 1
}

api() {
  local path="$1" method="${2:-GET}" body="${3:-}"
  local tok; tok=$(get_token)
  if [ -n "$body" ]; then
    curl -sS --noproxy '*' -X "$method" -H "Content-Type: application/json" \
      -d "$body" "${API}${path}?access_token=${tok}"
  else
    curl -sS --noproxy '*' "${API}${path}?access_token=${tok}"
  fi
}

# ---------------------------------------------------------------- status
cmd_status() {
  local tok; tok=$(get_token)
  say "Gitee 账号 $GITEE_USER 的仓库："
  local raw code body
  raw=$(curl -sS --noproxy '*' -w "\n__CODE__%{http_code}" \
        "${API}/user/repos?access_token=${tok}&per_page=100" 2>/dev/null)
  code=$(printf '%s' "$raw" | grep -o '__CODE__[0-9]*$' | sed 's/__CODE__//')
  body=$(printf '%s' "$raw" | sed 's/__CODE__[0-9]*$//')
  if [ "$code" != "200" ]; then
    err "令牌无效或权限不足（HTTP ${code:-未知}）"
    printf '%s' "$body" | head -3
    echo ""
    echo "  令牌需要 projects 权限："
    echo "    https://gitee.com/profile/personal_access_tokens"
    return 1
  fi
  printf '%s' "$body" | python -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception as e:
    print('  解析失败:', e); sys.exit()
if isinstance(d,dict):
    print('  错误:', d.get('message')); sys.exit()
if not d:
    print('  （暂无仓库）')
for r in d:
    print(f\"    {r.get('full_name'):32} private={r.get('private')} 默认分支={r.get('default_branch')} 更新={r.get('updated_at','')[:10]}\")
"
}

# ---------------------------------------------------------------- token-info
cmd_token_info() {
  local tok; tok=$(get_token)
  say "检查令牌权限..."
  local code
  code=$(curl -sS --noproxy '*' -o /tmp/gt.json -w "%{http_code}" \
    "${API}/user?access_token=${tok}" 2>/dev/null)
  if [ "$code" = "200" ]; then
    ok "令牌有效"
    python -c "
import json
d=json.load(open('/tmp/gt.json',encoding='utf-8'))
print(f\"  登录名: {d.get('login')} | 昵称: {d.get('name')}\")
print(f\"  邮箱: {d.get('email')}\")
" 2>/dev/null
  else
    err "令牌无效（HTTP $code）"
    python -c "
import json
try:
    d=json.load(open('/tmp/gt.json',encoding='utf-8'))
    print('  ', d.get('message'))
except: pass
" 2>/dev/null
  fi
}

# ---------------------------------------------------------------- create
cmd_create() {
  local name="$1" desc="${2:-TVBox 自建自动更新配置源}"
  local tok; tok=$(get_token)
  [ -z "$name" ] && { err "用法: bash gitee.sh create <名字> [描述]"; exit 1; }
  say "创建仓库 $GITEE_USER/$name ..."
  local body
  body=$(python -c "
import json
print(json.dumps({
  'name': '$name',
  'description': '$desc',
  'private': False,
  'auto_init': True,
  'gitignores': None,
  'license': None,
  'readme': 'Auto Update TVBox Config',
}, ensure_ascii=False))
")
  local out
  out=$(curl -sS --noproxy '*' -X POST -H "Content-Type: application/json" \
    -d "$body" "${API}/user/repos?access_token=${tok}" 2>/dev/null)
  echo "$out" | python -c "
import json,sys
d=json.load(sys.stdin)
if 'full_name' in d:
    print(f\"  ✓ 创建成功: {d['full_name']}\")
    print(f\"    clone: {d.get('html_url')}\")
    print(f\"    默认分支: {d.get('default_branch')}\")
else:
    print('  ✗', d.get('message') or d.get('error'))
    sys.exit(1)
"
}

# ---------------------------------------------------------------- backup
cmd_backup() {
  local repo="$1" br="${2:-master}"
  local tok; tok=$(get_token)
  mkdir -p "$BACKUP_DIR"
  say "备份 $repo ($br) → $BACKUP_DIR/$repo.tar.gz"
  curl -sSL --noproxy '*' -H "Accept: application/json" \
    -o "$BACKUP_DIR/$repo.tar.gz" \
    "${API}/repos/$GITEE_USER/$repo/tarball?access_token=${tok}&sha=$br" 2>/dev/null
  local sz; sz=$(wc -c < "$BACKUP_DIR/$repo.tar.gz" 2>/dev/null || echo 0)
  if [ "$sz" -gt 200 ]; then
    "$PY" -c "
import tarfile
try:
    with tarfile.open(r'$BACKUP_DIR/$repo.tar.gz','r:gz') as t:
        n=len(t.getnames())
    print(f'  ✓ 备份成功 {n} 个条目')
except Exception as e:
    print('  ⚠ 备份包异常:', e)
" 2>/dev/null || ok "备份 $sz bytes"
  else
    err "备份失败（$sz bytes）"
    return 1
  fi
}

# ---------------------------------------------------------------- delete
cmd_delete() {
  local repo="$1"
  local tok; tok=$(get_token)
  [ -z "$repo" ] && { err "用法: bash gitee.sh delete <名字>"; exit 1; }

  echo ""
  warn "=========================================================="
  warn " 即将永久删除 Gitee 仓库： $GITEE_USER/$repo"
  warn " 操作不可撤销。脚本会先自动备份。"
  warn "=========================================================="
  echo ""

  cmd_backup "$repo" "master" || warn "备份未成功，仍继续（请自行确认）"

  echo ""
  read -r -p "输入仓库名 '$repo' 确认删除: " confirm
  if [ "$confirm" != "$repo" ]; then
    err "输入不匹配，已取消"
    exit 1
  fi

  say "执行删除 ..."
  local code
  code=$(curl -sS --noproxy '*' -X DELETE -o /dev/null -w "%{http_code}" \
    "${API}/repos/$GITEE_USER/$repo?access_token=${tok}" 2>/dev/null)
  case "$code" in
    204) ok "已删除 $GITEE_USER/$repo" ;;
    401|403) err "权限不足（HTTP $code）—— 检查令牌的 projects 权限" ;;
    404) err "404 仓库不存在或无权访问" ;;
    *)   err "失败 HTTP $code" ;;
  esac
}

# ---------------------------------------------------------------- push
cmd_push() {
  local dir="$1" repo="$2" branch="${3:-master}"
  local tok; tok=$(get_token)
  [ -z "$dir" ] || [ -z "$repo" ] && { err "用法: bash gitee.sh push <目录> <仓库名> [分支]"; exit 1; }

  say "把 $dir 推送到 $GITEE_USER/$repo ($branch)"
  "$PY" - "$dir" "$repo" "$branch" "$tok" "$API" "$GITEE_USER" <<'PYEOF'
import base64, json, os, sys, urllib.request, urllib.parse

d, repo, branch, tok, API, user = sys.argv[1:7]
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def api(path, method="GET", data=None, raw=False):
    sep = "&" if "?" in path else "?"
    url = f"{API}{path}{sep}access_token={tok}"
    req = urllib.request.Request(url, method=method,
        data=json.dumps(data).encode() if data is not None else None,
        headers={"Content-Type": "application/json", "User-Agent": "tvbox-deployer"})
    try:
        with opener.open(req, timeout=60) as r:
            body = r.read()
        if raw: return r.status, body
        return r.status, (json.loads(body) if body.strip() else {})
    except urllib.error.HTTPError as e:
        body = e.read()
        if raw: return e.code, body
        try: return e.code, json.loads(body)
        except Exception: return e.code, {"message": body[:200].decode("utf-8","ignore")}

# 1. 收集文件
files = []
skipped = []
BLOCKED_NAMES = {".gitee_token", ".git-credentials", "id_rsa", "id_ed25519"}
for root, dirs, names in os.walk(d):
    dirs[:] = [x for x in dirs if x not in (".git", "__pycache__", "node_modules", ".wrangler")]
    for n in names:
        p = os.path.join(root, n)
        rel = os.path.relpath(p, d).replace("\\", "/")
        if rel.startswith(".git/"): continue
        # 安全底线：绝不推送凭据文件
        if n in BLOCKED_NAMES or n.endswith(".pem") or n.endswith(".key"):
            print(f"    ! 安全拦截（凭据文件不推送）: {rel}")
            continue
        try:
            with open(p, "rb") as f:
                raw = f.read()
        except Exception as e:
            print(f"    ! 跳过（读取失败）{rel}: {e}")
            continue
        # 空文件会让 Gitee 报 "content is empty"，直接跳过
        if not raw:
            skipped.append(rel)
            continue
        files.append((rel, base64.b64encode(raw).decode()))
print(f"  待推送 {len(files)} 个文件" + (f"，跳过 {len(skipped)} 个空文件" if skipped else ""))
for s in skipped:
    print(f"    ! 跳过空文件: {s}")

# 2. 确认仓库与分支
st, info = api(f"/repos/{user}/{repo}")
if st != 200:
    print(f"  ✗ 仓库访问失败 HTTP {st}: {info.get('message')}"); sys.exit(1)
default = info.get("default_branch", "master")
print(f"  仓库默认分支 = {default}")

# 3. 逐文件写（PUT /contents/{path}）
okc = failc = 0
for rel, content in files:
    enc = urllib.parse.quote(rel, safe="/")
    # 先查文件是否已存在（Gitee: 单文件返回 dict，不存在返回空 list）
    st, cur = api(f"/repos/{user}/{repo}/contents/{enc}?ref={branch}")
    sha = cur.get("sha") if (st == 200 and isinstance(cur, dict)) else None

    body = {"content": content, "message": f"deploy: {rel}", "branch": branch}
    if sha:
        # 已存在 → PUT 更新，必须带该文件的 sha
        body["sha"] = sha
        st, res = api(f"/repos/{user}/{repo}/contents/{enc}", "PUT", body)
    else:
        # 不存在 → POST 新建，不能带 sha
        st, res = api(f"/repos/{user}/{repo}/contents/{enc}", "POST", body)

    if st in (200, 201):
        okc += 1
        print(f"    ✓ {rel}")
    else:
        failc += 1
        if isinstance(res, dict):
            msg = res.get("message") or res.get("messages") or str(res)
        else:
            msg = str(res)[:120]
        print(f"    ✗ {rel}: {msg}")
print(f"  完成：成功 {okc}，失败 {failc}")
sys.exit(1 if failc else 0)
PYEOF
}

# ---------------------------------------------------------------- main
case "${1:-}" in
  status)     cmd_status ;;
  token-info) cmd_token_info ;;
  create)     cmd_create "$2" "$3" ;;
  backup)     cmd_backup "$2" "$3" ;;
  delete)     cmd_delete "$2" ;;
  push)       cmd_push "$2" "$3" "$4" ;;
  *) echo "用法: bash gitee.sh {status|token-info|create <名>|backup <名>|delete <名>|push <目录> <仓库名> [分支]}"; exit 1 ;;
esac
