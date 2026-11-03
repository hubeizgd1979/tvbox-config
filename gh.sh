#!/usr/bin/env bash
# ==============================================================================
# GitHub 仓库管理脚本（基于 api.github.com，绕开 github.com 网页不可达问题）
# ==============================================================================
# 前提：token 存在 ~/.github_mover/token，且具备 repo 权限
#
# 用法:
#   bash gh.sh status              # 列出所有仓库
#   bash gh.sh create <名字>       # 创建仓库
#   bash gh.sh delete <名字>        # 删除仓库（需二次确认）
#   bash gh.sh push <本地目录> <仓库名> [分支]   # 用 API 推送整棵目录
# ==============================================================================
set -uo pipefail

GITHUB_USER="${GITHUB_USER:-hubeizgd1979}"
TOKEN_FILE="${TOKEN_FILE:-$HOME/.github_mover/token}"
BACKUP_DIR="${BACKUP_DIR:-E:/复制github/仓库备份_20261103}"

# api.github.com 直连可用；github.com 网页不可达，必须 --noproxy
CURL=(curl -sS --noproxy '*' -H "Accept: application/vnd.github+json" -H "User-Agent: gh-tool" -H "X-GitHub-Api-Version: 2022-11-28")

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'
say()  { echo -e "${CYN}$1${NC}"; }
ok()   { echo -e "${GRN}✓ $1${NC}"; }
warn() { echo -e "${YEL}! $1${NC}"; }
err()  { echo -e "${RED}✗ $1${NC}"; }

get_token() {
  if [ ! -f "$TOKEN_FILE" ]; then
    err "找不到 token 文件: $TOKEN_FILE"
    exit 1
  fi
  tr -d '\r\n' < "$TOKEN_FILE"
}

# ---------------------------------------------------------------- list
cmd_status() {
  local TOK; TOK=$(get_token)
  say "账号 $GITHUB_USER 的仓库："
  "${CURL[@]}" -H "Authorization: Bearer $TOK" \
    "https://api.github.com/user/repos?per_page=100&affiliation=owner,collaborator,organization_member" \
  | python -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception as e:
    print('  解析失败:', e); sys.exit()
if isinstance(d,dict):
    print('  错误:', d.get('message')); sys.exit()
print(f'  共 {len(d)} 个:')
for r in d:
    print(f\"    {r['full_name']:32} size={r['size']:>7}KB  push={r['permissions']['push']}  fork={r['fork']}  最后推送={r['pushed_at'][:10]}\")
"
}

# ---------------------------------------------------------------- create
cmd_create() {
  local name="$1" desc="${2:-}"
  local TOK; TOK=$(get_token)
  [ -z "$name" ] && { err "用法: bash gh.sh create <仓库名> [描述]"; exit 1; }
  say "创建仓库 $GITHUB_USER/$name ..."
  "${CURL[@]}" -X POST -H "Authorization: Bearer $TOK" \
    -d "{\"name\":\"$name\",\"description\":\"$desc\",\"private\":false,\"auto_init\":false,\"has_issues\":true}" \
    https://api.github.com/user/repos \
  | python -c "
import json,sys
d=json.load(sys.stdin)
if 'full_name' in d:
    print(f\"  ✓ 创建成功: {d['full_name']}\")
    print(f\"    clone: {d['clone_url']}\")
    print(f\"    ssh  : {d['ssh_url']}\")
else:
    print('  ✗', d.get('message'))
    sys.exit(1)
"
}

# ---------------------------------------------------------------- backup
cmd_backup() {
  local repo="$1" br="${2:-main}"
  local TOK; TOK=$(get_token)
  mkdir -p "$BACKUP_DIR"
  say "备份 $repo ($br) → $BACKUP_DIR/$repo.tar.gz"
  "${CURL[@]}" -L -H "Authorization: Bearer $TOK" \
    -o "$BACKUP_DIR/$repo.tar.gz" \
    "https://api.github.com/repos/$GITHUB_USER/$repo/tarball/$br" 2>/dev/null
  local sz; sz=$(wc -c < "$BACKUP_DIR/$repo.tar.gz" 2>/dev/null || echo 0)
  if [ "$sz" -gt 200 ]; then
    python -c "
import tarfile
with tarfile.open(r'$BACKUP_DIR/$repo.tar.gz','r:gz') as t:
    n=len(t.getnames())
print(f'  ✓ 备份成功 {n} 个条目')
" 2>/dev/null || ok "备份 $sz bytes"
  else
    err "备份失败（$sz bytes）。若提示 Repository access blocked，说明该仓库已被 GitHub 封禁，无法备份"
    return 1
  fi
}

# ---------------------------------------------------------------- delete
cmd_delete() {
  local repo="$1"
  local TOK; TOK=$(get_token)
  [ -z "$repo" ] && { err "用法: bash gh.sh delete <仓库名>"; exit 1; }

  echo ""
  warn "=========================================================="
  warn " 即将永久删除仓库： $GITHUB_USER/$repo"
  warn " 这个操作不可撤销（GitHub 回收站最多保留 90 天）"
  warn "=========================================================="
  echo ""

  # 先备份
  local br
  br=$("${CURL[@]}" -H "Authorization: Bearer $TOK" \
        "https://api.github.com/repos/$GITHUB_USER/$repo" 2>/dev/null \
      | python -c "import json,sys; print(json.load(sys.stdin).get('default_branch','main'))" 2>/dev/null)
  [ -z "$br" ] && br="main"
  cmd_backup "$repo" "$br"

  echo ""
  read -r -p "输入仓库名 '$repo' 确认删除: " confirm
  if [ "$confirm" != "$repo" ]; then
    err "输入不匹配，已取消"
    exit 1
  fi

  say "执行删除 ..."
  local code
  code=$("${CURL[@]}" -X DELETE -H "Authorization: Bearer $TOK" \
    -o /dev/null -w "%{http_code}" \
    "https://api.github.com/repos/$GITHUB_USER/$repo" 2>/dev/null)
  case "$code" in
    204) ok "已删除 $GITHUB_USER/$repo" ;;
    403) err "403 权限不足 —— token 缺少 repo 权限（当前是只读的 Copilot token）" ;;
    404) err "404 仓库不存在或无权访问" ;;
    *)   err "失败 HTTP $code" ;;
  esac
}

# ---------------------------------------------------------------- push
# 用 Git Data API 推送整棵目录（不依赖 git 协议，绕开 github.com git 端点）
cmd_push() {
  local dir="$1" repo="$2" branch="${3:-main}"
  local TOK; TOK=$(get_token)
  [ -z "$dir" ] || [ -z "$repo" ] && { err "用法: bash gh.sh push <本地目录> <仓库名> [分支]"; exit 1; }

  say "把 $dir 推送到 $GITHUB_USER/$repo ($branch)"
  python3 - "$dir" "$repo" "$branch" "$TOK" <<'PY'
import base64, json, os, sys, urllib.request, urllib.parse

d, repo, branch, tok = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
API = "https://api.github.com"
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def api(path, method="GET", data=None):
    req = urllib.request.Request(
        API + path, method=method,
        data=json.dumps(data).encode() if data else None,
        headers={"Authorization": f"Bearer {tok}",
                 "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json",
                 "User-Agent": "tvbox-deployer"})
    try:
        with opener.open(req, timeout=40) as r:
            body = r.read()
        return r.status, (json.loads(body) if body.strip() else {})
    except urllib.error.HTTPError as e:
        body = e.read()
        try: return e.code, json.loads(body)
        except Exception: return e.code, {"message": body[:200].decode("utf-8","ignore")}

# 1. 收集文件
files = []
for root, dirs, names in os.walk(d):
    dirs[:] = [x for x in dirs if x not in (".git", "__pycache__", "node_modules", ".wrangler")]
    for n in names:
        p = os.path.join(root, n)
        rel = os.path.relpath(p, d).replace("\\", "/")
        if rel.startswith(".git/"): continue
        with open(p, "rb") as f:
            files.append((rel, base64.b64encode(f.read()).decode()))
print(f"  待推送 {len(files)} 个文件")

# 2. 找默认分支与 HEAD
st, repoinfo = api(f"/repos/{repo}")
if st != 200:
    print(f"  ✗ 仓库访问失败 HTTP {st}: {repoinfo.get('message')}"); sys.exit(1)
default = repoinfo.get("default_branch", "main")

st, ref = api(f"/repos/{repo}/git/ref/heads/{branch}")
if st != 200:
    # 建分支
    st, refdata = api(f"/repos/{repo}/git/refs", "POST",
        {"ref": f"refs/heads/{branch}", "sha": repoinfo.get("default_branch") and "" or ""})
    st, _ = api(f"/repos/{repo}/git/refs", "POST", {"ref": f"refs/heads/{branch}"})
    print(f"  ! 分支 {branch} 需手动确认")
sha = ref.get("object", {}).get("sha")
print(f"  当前 {branch} HEAD = {sha}")

# 3. 逐个文件 PUT
okc = failc = 0
for rel, content in files:
    st, sha_res = api(f"/repos/{repo}/contents/{urllib.parse.quote(rel)}", "GET")
    body = {"message": f"deploy: {rel}", "content": content, "branch": branch}
    if st == 200:
        body["sha"] = sha_res.get("sha")
    st, res = api(f"/repos/{repo}/contents/{urllib.parse.quote(rel)}", "PUT", body)
    if st in (200, 201):
        okc += 1
    else:
        failc += 1
        print(f"  ✗ {rel}: {res.get('message')}")
print(f"  完成：成功 {okc}，失败 {failc}")
sys.exit(1 if failc else 0)
PY
}

# ---------------------------------------------------------------- main
case "${1:-}" in
  status) cmd_status ;;
  create) cmd_create "$2" "$3" ;;
  backup) cmd_backup "$2" "$3" ;;
  delete) cmd_delete "$2" ;;
  push)   cmd_push "$2" "$3" "$4" ;;
  *) echo "用法: bash gh.sh {status|create <名>|backup <名>|delete <名>|push <目录> <仓库名> [分支]}" ;;
esac
