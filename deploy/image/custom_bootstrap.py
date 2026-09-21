#!/usr/bin/env python3
# -*- coding: UTF-8 -*-
"""二开定制：在服务起来【之前】把定制项写进配置。

由 start.py 在 init_seafile_server() 之后、seafile.sh/seahub.sh 之前调用
（Dockerfile 往 start.py 里插了那一行，带构建期断言）。

## 为什么必须是这个时机

  · 更早 —— setup-seafile-mysql.py 还没跑。它用 open('w') **无条件重写**
    seahub_settings.py（SECRET_KEY 随机、DB 密码取环境变量），我们写的东西
    会被整体覆盖。这正是早先「配置必须在首启之后再追加」的原因。
  · 更晚 —— seahub 已经起来了。seahub_settings.py 是**导入期**读的，改了
    必须重启 seahub 才生效。
  · 就是这个窗口：setup 刚写完、服务还没起。**改完直接生效，不需要重启。**

原先这一步是人手工跑 `init-conf.sh --prod`（先等首启完成，再追加，再重启
两个服务）。手工步骤的问题不是麻烦，是**忘了不会报错**——SSO、账号管控、
WebDAV 全部静默失效，页面照常打开。现在它在镜像里，每次启动都跑。

## 为什么要写文件、不能走 constance

判据是**调用点的绑定方式**，不是「重不重要」（详见 docs/007 §4.2.1）：

  CLIENT_SSO_VIA_LOCAL_BROWSER → urls.py / api2/urls.py / views/sso.py
                                 导入期读它来注册路由
  ENABLE_DINGTALK              → settings.py:1236 用它决定 constance 该键的默认值
  ENABLE_DELETE_ACCOUNT        → profile/views.py 模块级 from seahub.settings import

其余站点相关配置（SERVICE_URL、钉钉凭据与开关）都已是 constance，管理员在
后台「系统管理 → 设置」页填，存库、免重启生效，不归这里管。

## 幂等

按 MARKER 判断，已追加过就跳过。每次启动都跑，所以配置被覆盖/丢掉会自动补回来。
出错时**让启动失败**，不吞异常——定制的缺失是安全问题（比如自助注销被放开），
带病跑起来比停下来更糟。
"""

import os
import re
import sys
import time

# setup 写配置的目录。优先用 /opt/seafile/conf（upstream 的 central_config_dir，
# create_data_links.sh 把它软链到 /shared/seafile/conf）；软链没建起来时退回真实路径。
CONF_CANDIDATES = ('/opt/seafile/conf', '/shared/seafile/conf')

# 新标记 + 旧标记（早先 init-conf.sh --prod 写的）。两者都认，避免升级时追加出
# 第二个内容相同的块。
MARKERS = (
    '# ---- 二开定制（镜像烘焙，勿手改本块）----',
    '# ---- 二开定制（init-conf.sh --prod 追加，勿手改本块）----',
)

LOG_PREFIX = '[custom-bootstrap]'


def log(msg):
    print('%s %s' % (LOG_PREFIX, msg), flush=True)


def conf_dir():
    for d in CONF_CANDIDATES:
        if os.path.isdir(d):
            return d
    sys.exit('%s 找不到配置目录（试过 %s）。这套镜像的目录结构与预期不符，'
             '检查 /shared 是否挂上了。' % (LOG_PREFIX, ' / '.join(CONF_CANDIDATES)))


def settings_block():
    """返回要追加进 seahub_settings.py 的文本块。"""
    # 钉钉凭据只在环境变量里预置了才写。默认不写：它已 constance 化，后台
    # 「系统管理 → 设置」填即可，写空串只会让人以为要在这儿配（docs/002）。
    dt_key = os.environ.get('SEAHUB_DINGTALK_APP_KEY', '').strip()
    dt_secret = os.environ.get('SEAHUB_DINGTALK_APP_SECRET', '').strip()
    dt_lines = ''
    if dt_key or dt_secret:
        dt_lines = ("DINGTALK_APP_KEY = '%s'\nDINGTALK_APP_SECRET = '%s'\n"
                    % (dt_key, dt_secret))

    return """

%s
# 下面三项必须在【模块导入期】就确定，所以只能写文件 —— 改这里要重启 seahub。
# 判断依据是各调用点的绑定方式，不是「重不重要」：
#   CLIENT_SSO_VIA_LOCAL_BROWSER → urls.py / api2/urls.py / views/sso.py 导入期读它来注册路由
#   ENABLE_DINGTALK              → 它决定 constance 里该键的默认值（settings.py:1236）
#   ENABLE_DELETE_ACCOUNT        → profile/views.py 模块级 from seahub.settings import
# 其余站点相关配置（SERVICE_URL、钉钉凭据与开关）都已是 constance：管理员在
# 后台「系统管理 → 设置」页填，存库、免重启生效。所以本块只写这一次，之后不用再动。
#
# 本块由镜像内的 custom_bootstrap.py 在每次容器启动时校验，缺了会自动补回来；
# 不要手改（改了会在下次重启时被识别为「已存在」而保留，但语义上不应依赖这个）。
CLIENT_SSO_VIA_LOCAL_BROWSER = True
ENABLE_DINGTALK = True
ENABLE_DELETE_ACCOUNT = False           # 禁止用户自助注销（docs/003）
# PASSWORD_LOGIN_ADMIN_ONLY = True     # 补丁 0008 默认即 True；紧急放开时取消注释改 False
%s""" % (MARKERS[0], dt_lines)


def apply_settings(confdir):
    path = os.path.join(confdir, 'seahub_settings.py')
    if not os.path.exists(path):
        sys.exit('%s %s 不存在。setup-seafile-mysql.py 应该已经生成它了，'
                 '说明首启没有正常走完。' % (LOG_PREFIX, path))

    with open(path, 'r', encoding='utf-8') as fp:
        current = fp.read()

    if any(m in current for m in MARKERS):
        log('seahub_settings.py 定制块已存在，跳过')
        return

    with open(path, 'w', encoding='utf-8') as fp:
        fp.write(current.rstrip() + '\n' + settings_block())
    log('已追加 seahub_settings.py 定制块（SSO / 钉钉默认开关 / 账号管控）')


def apply_webdav(confdir):
    path = os.path.join(confdir, 'seafdav.conf')
    if not os.path.exists(path):
        log('seafdav.conf 不存在，跳过 WebDAV（该配置由 setup 生成）')
        return

    with open(path, 'r', encoding='utf-8') as fp:
        current = fp.read()

    if re.search(r'^enabled\s*=\s*true', current, re.M):
        log('seafdav.conf 已是 enabled = true，跳过')
        return

    # 官方生成的原文是 "enabled = false"，这里只改这一行的值，其余原样保留。
    new = re.sub(r'^enabled\s*=\s*.*$', 'enabled = true', current, count=1, flags=re.M)
    if new == current:
        sys.exit('%s seafdav.conf 里找不到 enabled = 这一行，无法开启 WebDAV。'
                 '上游模板可能改了，检查 %s。' % (LOG_PREFIX, path))

    with open(path, 'w', encoding='utf-8') as fp:
        fp.write(new)
    log('已开启 WebDAV（seafdav.conf enabled = true）')


def start_service_retry(cmd, attempts=3, delay=5):
    """起服务，失败就重试。替代 start.py 里起 seahub 的那个裸 `call(...)`。

    上游 `seahub.sh` 判断 seahub 起没起来的方式是「硬编码 sleep 5，然后 pgrep 一次」：

        $PYTHON $gunicorn_exe seahub.wsgi:application -c "${gunicorn_conf}" --preload &
        sleep 5
        if ! pgrep -f "seahub.wsgi:application"; then ... exit 1; fi

    `--preload` 要先把整个 Django 应用在 master 里导入完才 fork，机器一忙就可能
    超过 5 秒，于是**误判成失败**。2026-09-21 在容器重启时实测撞到过一次：
    `Seahub failed to start`，而手工再跑一次 `seahub.sh start` 立刻就好。

    重试是对症的——它不关心失败的原因，在上层重来一次即可。失败原因只在日志里
    说明，不在这里解释。
    """
    from utils import call  # 放在函数内：本模块被 start.py 导入时 /scripts 在 sys.path 上

    for i in range(1, attempts + 1):
        try:
            call(cmd)
            if i > 1:
                log('第 %d 次尝试起服务成功：%s' % (i, cmd))
            return
        except Exception as e:
            if i >= attempts:
                log('起服务连续失败 %d 次，放弃：%s' % (attempts, cmd))
                raise
            log('起服务失败（第 %d/%d 次）：%s —— %s；%d 秒后重试'
                % (i, attempts, cmd, e, delay))
            time.sleep(delay)


def init_custom_settings():
    """入口。由 start.py 在 init_seafile_server() 之后调用。"""
    confdir = conf_dir()
    log('应用二开定制（%s）' % confdir)
    apply_settings(confdir)
    apply_webdav(confdir)
    log('完成 —— 此时 seafile/seahub 尚未启动，无需重启即已生效')


if __name__ == '__main__':
    init_custom_settings()
