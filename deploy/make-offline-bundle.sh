#!/usr/bin/env bash
# 把生产所需镜像打成一个离线包，供「服务器连不上镜像仓库」时导入。
#
#   ./make-offline-bundle.sh                              # 自动取当前版本的 tag
#   ./make-offline-bundle.sh 12.0.14-dingtalk.9.e3c4174f  # 指定 tag（示例；以 docs/010 §9 台账为准）
#   OUT_DIR=/tmp ./make-offline-bundle.sh                 # 指定输出目录
#
# 服务器侧：
#   gunzip -c seafile-offline-<tag>.tar.gz | docker load
#   docker compose up -d          # ⚠️ 不要用 pull —— pull 会强制联网，本地有也照拉
#   docker compose config | grep image:   # 确认三个镜像都解析到了
#
# ## 为什么需要这个脚本
#
# compose 里三个镜像**现在同源**（都走 ghcr.io）：seafile 由本项目 CI 构建，
# mariadb/memcached 由 .github/workflows/mirror-infra-images.yml 镜像过去。
# 2026-09-21 之前 db 与 memcached 直接引 Docker Hub，而国内网络常只有那一条不通。
#
# 离线导入是**保底**手段：能救急，但每次更新都要手工搬一次 690MB，所以不是常态。
# 先确认服务器到底连不连得上 ghcr.io（两分钟）：
#     curl -so /dev/null -w '%{http_code}\n' --max-time 20 https://ghcr.io/v2/   # 401 即通
# 通了就别用这个脚本，直接 docker compose pull。不通才走离线。
#
# ## 三个不写下来一定会踩的坑
#
# 1. **必须 --platform linux/amd64**。开发机是 Apple Silicon，本地镜像默认 arm64；
#    不指定平台导出的包在 amd64 服务器上会报 exec format error。
#
# 2. **必须按 tag 拉，不能按 digest 拉**。按 digest 拉下来的镜像没有 RepoTag，
#    `docker save` 会写出 "RepoTags": null，`docker load` 之后是个**无标签的悬空
#    镜像**——compose 按 repo@sha256:… 找不到它，于是又去联网拉。这个坑很隐蔽：
#    load 不报错，镜像也在（docker images 里 repo 是 <none>），但就是不起作用。
#
# 3. **containerd 镜像存储下 `docker image inspect` 只显示宿主架构**。所以在这台
#    Mac 上 inspect 会看到 arm64，看着像 amd64 没拉下来——其实存了。别被骗，
#    用本脚本末尾的校验（读 tar 内 config 的 architecture 字段）来确认。
set -euo pipefail

cd "$(dirname "$0")"

COMPOSE=seafile-prod.yml
REGISTRY_IMAGE=ghcr.io/topiceyes/seafile-mc
PLATFORM=linux/amd64
OUT_DIR="${OUT_DIR:-/tmp}"

die() { echo "错误：$*" >&2; exit 1; }

[ -f "$COMPOSE" ] || die "找不到 ${COMPOSE}（应在 deploy/ 下）"
command -v docker >/dev/null || die "缺 docker"

# ---- 取 tag：优先命令行，其次问 build-image.sh（避免这里重算导致漂移）----
TAG="${1:-}"
if [ -z "$TAG" ]; then
  [ -x ./build-image.sh ] || die "没给 tag，且找不到可执行的 build-image.sh"
  TAG=$(./build-image.sh --print-tag) || die "build-image.sh --print-tag 失败"
fi
case "$TAG" in
  */*|*:*) die "只给 tag 本身，不要带仓库地址：$TAG" ;;
esac

# ---- 从 compose 里取基础设施镜像，别在脚本里另写一份 ----
# 只取写死的基础镜像（mariadb/memcached）；${SEAFILE_PRO_IMAGE} 那行由本脚本自己处理。
#
# ⚠️ 必须先剥掉行尾注释再收。compose 里给 image: 行写行内注释是合法的，而这里的
# 解析是纯文本的——不剥注释就会把「# 说明文字」当成镜像名的一部分，
# 报一个跟真实原因毫无关系的错（docker pull: invalid reference format）。
# 同理必须 tr -d 掉引号，并去掉首尾空白。
INFRA=""
while IFS= read -r img; do
  [ -n "$img" ] && INFRA="$INFRA $img"
done <<EOF
$(grep -E '^[[:space:]]+image:[[:space:]]' "$COMPOSE" \
  | sed -E 's/.*image:[[:space:]]*//' \
  | sed -E 's/[[:space:]]+#.*$//' \
  | tr -d "'\"" \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
  | grep -v '^\$' || true)
EOF
[ -n "$INFRA" ] || die "从 ${COMPOSE} 里没解析出基础镜像，检查 image: 那几行"

SEAFILE_REF="${REGISTRY_IMAGE}:${TAG}"
echo "镜像清单："
echo "  ${SEAFILE_REF}"
for i in $INFRA; do echo "  ${i}"; done
echo

# ---- 按 tag 拉（不是 digest——见头注坑 2）----
echo "==> 拉取（${PLATFORM}）"
docker pull --platform "$PLATFORM" "$SEAFILE_REF"
for i in $INFRA; do
  docker pull --platform "$PLATFORM" "$i"
done

# ---- 打包 ----
OUT_TAR="${OUT_DIR}/seafile-offline-${TAG}.tar"
echo
echo "==> 打包 → ${OUT_TAR}"
rm -f "$OUT_TAR"
# INFRA 不加引号是有意的：它是以空格分隔的镜像列表，这里需要分词
# shellcheck disable=SC2086
docker save --platform "$PLATFORM" -o "$OUT_TAR" "$SEAFILE_REF" $INFRA

# ---- 校验：每个镜像都要有 tag、且都是目标架构 ----
echo
echo "==> 校验包内容"
VERIFY_DIR=$(mktemp -d)
trap 'rm -rf "$VERIFY_DIR"' EXIT
tar -xf "$OUT_TAR" -C "$VERIFY_DIR" 2>/dev/null || die "解包失败"
python3 - "$VERIFY_DIR" "$PLATFORM" <<'PY' || exit 1
import json, os, sys
root, want = sys.argv[1], sys.argv[2]
want_arch, want_os = want.split('/')[::-1]      # linux/amd64 → amd64/linux
man = json.load(open(os.path.join(root, 'manifest.json')))
bad = 0
for m in man:
    cfg = json.load(open(os.path.join(root, m['Config'])))
    tags = m.get('RepoTags') or []
    ok_tag = bool(tags)
    ok_arch = (cfg.get('architecture'), cfg.get('os')) == (want_arch, want_os)
    mark = '✅' if (ok_tag and ok_arch) else '❌'
    if not (ok_tag and ok_arch):
        bad += 1
    print('  %s %-55s %s/%s' % (mark, (tags or ['<无 tag — load 后会成为悬空镜像，compose 找不到它>'])[0],
                                cfg.get('architecture'), cfg.get('os')))
if bad:
    print('\n有 %d 个镜像不合格，别用这个包。' % bad)
    sys.exit(1)
PY

# ---- 压缩 ----
echo
echo "==> 压缩"
gzip -9 -f "$OUT_TAR"
ls -lh "${OUT_TAR}.gz" | awk '{print "  产出:", $9, "("$5")"}'

echo
echo "✅ 完成。传到服务器后："
echo "     scp ${OUT_TAR}.gz <服务器>:/tmp/"
echo "     # 服务器上："
echo "     gunzip -c /tmp/$(basename "${OUT_TAR}.gz") | docker load"
echo "     docker compose up -d        # ⚠️ 用 up，不要用 pull"
