# Seafile 12.0.14 CE 二开生产镜像。构建入口：deploy/build-image.sh
# （构建上下文由脚本准备：seahub/ 为 git archive 导出的干净源码树 + package-lock.json）
#
# 相对官方 seafileltd/seafile-mc:12.0.14 的差异：
#   1. seahub Python 包（含模板）替换为二开分支（patches/0001-0008）
#   2. 前端 build/ + webpack-stats.pro.json 在镜像内构建（官方镜像不带 build/）
#   3. 构建期 collectstatic 刷新 media/assets（前端与静态资源已变，已实测无 DB 可跑）
#   4. SEAFILE_VERSION 由 0002 补丁的 "-dev" 修正为发布号
#   5. nginx 模板补 X-Forwarded-Proto（官方模板 location / 与 /seafdav/ 两处缺失）
#   6. 安装 mariadb-client（官方镜像无 mysqldump，容器内 backup.sh 需要）
#   7. 运维脚本与 cron（backup.sh + 备份/离职同步两个 cron）烘进镜像，
#      不再由 compose 从宿主机挂载 —— 生产部署因此不需要固定目录
#
# 注意：路径写死 12.0.14（镜像内无 seafile-server-latest 软链，运行时才建）。
# 升级 Seafile 版本 = 同步改 BASE_IMAGE、INSTALLPATH 和 seahub 基线（见 docs/007）。

ARG BASE_IMAGE=seafileltd/seafile-mc:12.0.14
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
# CI=false：CRA 在 CI 环境把 warning 当 error 处理
RUN CI=false NODE_OPTIONS=--max-old-space-size=4096 node scripts/build.js

# ---------- 阶段 2：叠加官方镜像 ----------
FROM ${BASE_IMAGE}
ARG SEAFILE_VERSION=12.0.14
ARG INSTALLPATH=/opt/seafile/seafile-server-12.0.14

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

# 5) 修好的 nginx 模板（官方 12.0.14 原文 + 两行 X-Forwarded-Proto，Jinja2 语法原样保留）
COPY image/nginx/seafile.nginx.conf.template /templates/seafile.nginx.conf.template

# 3) 构建期 collectstatic：stub 配置 + 一次性环境（已实测配方，无需数据库）。
#    全部在同一条 RUN 内完成并清理——包括临时目录本身：
#    /opt/seafile/{conf,seafile-data} 若残留在镜像层，首启 setup 会因
#    "seafile-data already exists" 拒绝初始化（彩排实测踩坑）。
RUN set -eux; \
    export PYTHONPATH="${INSTALLPATH}/seafile/lib/python3/site-packages:${INSTALLPATH}/seahub:${INSTALLPATH}/seahub/thirdpart"; \
    export CCNET_CONF_DIR=/opt/seafile/conf \
           SEAFILE_CONF_DIR=/opt/seafile/conf/seafile \
           SEAFILE_CENTRAL_CONF_DIR=/opt/seafile/conf \
           SEAFILE_RPC_PIPE_PATH=/opt/seafile/seafile-data; \
    mkdir -p /opt/seafile/conf /opt/seafile/seafile-data; \
    printf 'SECRET_KEY = "build-time-stub"\nDATABASES = {"default": {"ENGINE": "django.db.backends.sqlite3", "NAME": "/tmp/buildstub.db"}}\nSERVICE_URL = "https://build.invalid"\n' \
      > /opt/seafile/conf/seahub_settings.py; \
    cd ${INSTALLPATH}/seahub && python3 manage.py collectstatic --noinput; \
    rm -f /opt/seafile/conf/seahub_settings.py /tmp/buildstub.db; \
    rm -rf /opt/seafile/conf /opt/seafile/seafile-data
