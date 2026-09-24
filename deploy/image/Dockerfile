# Seafile 13.0.28 CE 二开生产镜像。构建入口：deploy/build-image.sh
# （构建上下文由脚本准备：seahub/ 为 git archive 导出的干净源码树 + package-lock.json）
#
# 相对官方 seafileltd/seafile-mc:13.0.28 的差异：
#   1. seahub Python 包（含模板）替换为二开分支（patches/0001）
#   2. 前端 build/ + webpack-stats.pro.json 在镜像内构建（官方镜像不带 build/）
#   3. 构建期 collectstatic 刷新 media/assets（前端与静态资源已变，已实测无 DB 可跑；
#      13.0 settings.py 未设 CACHE_PROVIDER 时 raise，stub 环境显式补 memcached）
#   4. SEAFILE_VERSION 由 0001 补丁的 "-dev" 修正为发布号
#   5. nginx 静态 conf 补 server_name + X-Forwarded-Proto（13.0 起 conf 构建期静态烘入，
#      上游 location / 与 /seafdav/ 两处仍缺 X-Forwarded-Proto）
#   6. 安装 mariadb-client（官方镜像无 mysqldump，容器内 backup.sh 需要）
#   7. 运维脚本与 cron（backup.sh + 备份/离职同步两个 cron）烘进镜像，
#      不再由 compose 从宿主机挂载 —— 生产部署因此不需要固定目录
#   8. 二开定制的追加（SSO/钉钉默认开关/账号管控 + WebDAV）由镜像内的
#      custom_bootstrap.py 在启动时自动完成，不再需要首启后手工跑 init-conf.sh
#
# ⚠️ 被本 Dockerfile 动过的上游文件（升级 Seafile 时要逐个看）：
#   · /scripts/start.py                  ← 第 8 项（插定制调用 + seahub 启动加重试）
#   · /scripts/enterpoint.sh             ← 第 8 项（start.py 死掉时容器跟着退出）
#   · /etc/nginx/sites-enabled/seafile.nginx.conf ← 第 5 项整体替换（13.0 起上游废除
#     /templates/ 模板渲染，conf 构建期静态烘入；补 server_name + X-Forwarded-Proto）
#   · seahub_settings.py 的 SEAFILE_VERSION ← 第 4 项 sed（构建期有断言）
# 前两个的改动全部集中在 image/patch-upstream.py，每处都带断言。
#
# 注意：路径写死 13.0.28（镜像内无 seafile-server-latest 软链，运行时才建）。
# 升级 Seafile 版本 = 同步改 BASE_IMAGE、INSTALLPATH、VERSION 的 seafile_version
# 和 seahub 基线（见 docs/007 §6）。

ARG BASE_IMAGE=seafileltd/seafile-mc:13.0.28
ARG NODE_IMAGE=node:24-bookworm-slim

# ---------- 阶段 1：前端构建 ----------
# node 24 与宿主机实测成功的版本一致（CRA fork 无 engines 限制）
FROM ${NODE_IMAGE} AS frontend
WORKDIR /frontend
# 先装依赖（利用 layer 缓存：源码变动不重装 769M node_modules）
COPY seahub/frontend/package.json seahub/frontend/package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; \
    else npm install --no-audit --no-fund; fi
COPY seahub/frontend/ ./
# 13.0 的前端源码会相对路径逃逸出 frontend/ 目录引用仓库根的 media/img
# （sf-table 的 index.css: url(../../../../../../../media/img/grippy_large.png)）。
# 上游 CI 在完整仓库里构建所以能解析；这里构建上下文只有 frontend/，必须补这份。
COPY seahub/media/img /media/img
# CI=false：CRA 在 CI 环境把 warning 当 error 处理
RUN CI=false NODE_OPTIONS=--max-old-space-size=4096 node scripts/build.js

# ---------- 阶段 2：叠加官方镜像 ----------
FROM ${BASE_IMAGE}
ARG SEAFILE_VERSION=13.0.28
ARG INSTALLPATH=/opt/seafile/seafile-server-13.0.28

# 6) 备份依赖（mysqldump）
RUN apt-get update && apt-get install -y --no-install-recommends mariadb-client \
    && rm -rf /var/lib/apt/lists/*

# 7) 运维脚本与 cron —— 烘进镜像，不从宿主机 bind-mount。
#    原先这三个文件是 compose 挂载的宿主机相对路径，副作用是：
#    · 部署必须先 checkout 仓库，且必须待在固定目录（换目录挂载落空，
#      容器照样起得来，备份和离职同步静默失效）
#    · 脚本改动不进镜像，与镜像内容脱钩
#    烘进来之后，服务器上只需要一个 compose 文件 + 一个 .env。
#    cron 要求 /etc/cron.d/ 下的文件属主为 root 且不可被 group/other 写。
COPY image/backup.sh /usr/local/bin/seafile-backup.sh
COPY image/backup.cron /etc/cron.d/seafile-backup
COPY image/dingtalk-sync.cron /etc/cron.d/dingtalk-sync
RUN chmod 0755 /usr/local/bin/seafile-backup.sh \
 && chmod 0644 /etc/cron.d/seafile-backup /etc/cron.d/dingtalk-sync \
 && chown root:root /etc/cron.d/seafile-backup /etc/cron.d/dingtalk-sync

# 8) 二开定制烘进镜像 —— 消灭「首启之后再手工追加一次配置」那一步。
#
#    原先这步是人手工跑 `init-conf.sh --prod`：等首启完成 → 追加配置 → 重启两个服务。
#    手工步骤的问题不是麻烦，是**忘了不会报错**：SSO、账号管控、WebDAV 会静默失效，
#    而页面照常打开。现在它在镜像里，每次启动都跑一遍（幂等）。
#
#    插入点是 start.py 里 init_seafile_server() 之后、seafile.sh/seahub.sh 之前。
#    这个窗口是唯一正确的：早了会被 setup 的 open('w') 覆盖，晚了 seahub 已起来、
#    而 seahub_settings.py 是导入期读的，改了要重启。所以在这里改完**直接生效**。
#    （不想动上游脚本的替代方案与代价，见 docs/007 §4.2.2。）
COPY image/custom_bootstrap.py /scripts/custom_bootstrap.py
COPY image/patch-upstream.py /tmp/patch-upstream.py

# 5) 定制静态 nginx conf（13.0 起上游废除 /templates/ 模板渲染，conf 构建期静态烘入）。
#    在上游 services/seafile.nginx.conf 基础上补 server_name + X-Forwarded-Proto 两处
#    （上游依然没修，反代模式登录 403 的病根，docs/007 §9）。域名占位符
#    __SEAFILE_SERVER_NAME__ 由 custom_bootstrap 首启时替换为真实 SEAFILE_DOMAIN。
#    ⚠️ 必须在 patch-upstream.py 之前：它会校验占位符确实进了镜像（防 COPY 错文件）。
COPY image/nginx/seafile.nginx.conf /etc/nginx/sites-enabled/seafile.nginx.conf

# 三处改动由 patch-upstream.py 打入（start.py ×2、enterpoint.sh ×1），
# **每一处都带前后断言**。改完立刻删掉脚本，它只服务于构建期。
#
# 补丁脚本的头部注释写了每处改动「改了什么、为什么」；这里不重复。
RUN set -eux; \
    python3 /tmp/patch-upstream.py; \
    rm -f /tmp/patch-upstream.py; \
    chmod 0755 /scripts/custom_bootstrap.py; \
    python3 -c 'import ast; ast.parse(open("/scripts/start.py").read())'; \
    python3 -c 'import ast; ast.parse(open("/scripts/custom_bootstrap.py").read())'; \
    bash -n /scripts/enterpoint.sh

# 2) 前端构建产物
COPY --from=frontend /frontend/build ${INSTALLPATH}/seahub/frontend/build
COPY --from=frontend /frontend/webpack-stats.pro.json ${INSTALLPATH}/seahub/frontend/webpack-stats.pro.json

# 1) 二开 Python 包与模板（只覆盖 seahub/seahub；thirdpart/、seahub.sh、bin/ 保持官方）
COPY seahub/seahub/ ${INSTALLPATH}/seahub/seahub/
# 清掉官方层遗留的 __pycache__，避免旧字节码遮蔽补丁后的源文件
RUN find ${INSTALLPATH}/seahub/seahub -name '__pycache__' -prune -exec rm -rf {} +

# 4) 版本号：grep 前后断言，模式失配直接让构建失败（防 sed 静默不生效）
RUN grep -q '^SEAFILE_VERSION = ' ${INSTALLPATH}/seahub/seahub/settings.py \
 && sed -ri "s/^SEAFILE_VERSION = .*$/SEAFILE_VERSION = \"${SEAFILE_VERSION}\"/" \
       ${INSTALLPATH}/seahub/seahub/settings.py \
 && grep -q "^SEAFILE_VERSION = \"${SEAFILE_VERSION}\"" ${INSTALLPATH}/seahub/seahub/settings.py

# 3) 构建期 collectstatic：stub 配置 + 一次性环境（已实测配方，无需数据库）。
#    全部在同一条 RUN 内完成并清理——包括临时目录本身：
#    /opt/seafile/{conf,seafile-data} 若残留在镜像层，首启 setup 会因
#    "seafile-data already exists" 拒绝初始化（彩排实测踩坑）。
RUN set -eux; \
    export PYTHONPATH="${INSTALLPATH}/seafile/lib/python3/site-packages:${INSTALLPATH}/seahub:${INSTALLPATH}/seahub/thirdpart"; \
    export CCNET_CONF_DIR=/opt/seafile/conf \
           SEAFILE_CONF_DIR=/opt/seafile/conf/seafile \
           SEAFILE_CENTRAL_CONF_DIR=/opt/seafile/conf \
           SEAFILE_RPC_PIPE_PATH=/opt/seafile/seafile-data \
           CACHE_PROVIDER=memcached; \
    mkdir -p /opt/seafile/conf /opt/seafile/seafile-data; \
    printf 'SECRET_KEY = "build-time-stub"\nDATABASES = {"default": {"ENGINE": "django.db.backends.sqlite3", "NAME": "/tmp/buildstub.db"}}\nSERVICE_URL = "https://build.invalid"\n' \
      > /opt/seafile/conf/seahub_settings.py; \
    cd ${INSTALLPATH}/seahub && python3 manage.py collectstatic --noinput; \
    rm -f /opt/seafile/conf/seahub_settings.py /tmp/buildstub.db; \
    rm -rf /opt/seafile/conf /opt/seafile/seafile-data
