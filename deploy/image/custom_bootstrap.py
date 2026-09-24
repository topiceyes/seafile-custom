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

`SECURE_PROXY_SSL_HEADER` 的归处不同——它不是被导入期读，而是**属于部署形态**。
上游从没设过它（全镜像只有 Django 自己的默认值 `None`），而反代模式下容器只听 80、
`$scheme` 恒为 http，于是 Django 不认 nginx 传来的 X-Forwarded-Proto，
`request.is_secure()` 恒为假 → CSRF 中间件把 good_origin 算成 `http://域名`，
与浏览器发的 `Origin: https://域名` 不匹配 → **登录直接 403**。
这类设置没有「后台」可放，只能落在配置文件里。

其余站点相关配置（SERVICE_URL、钉钉凭据与开关）都已是 constance，管理员在
后台「系统管理 → 设置」页填，存库、免重启生效，不归这里管。

## 幂等

**逐项核对，缺哪行补哪行**——不是「整块在就跳过」。每次启动都跑，所以配置被
覆盖 / 丢掉 / 只丢其中一项，下次启动都会补回来。

> 早先是整块级的（看见标记就跳过）。2026-09-21 踩到了它的盲区：给**已部署**的
> 机器新增一项设置时，标记块早就在了，于是新设置**永远写不进去**——这个机制能
> 自愈「块被删掉」，却自愈不了「块里少一行」。加 `SECURE_PROXY_SSL_HEADER`
> 时发现的（反代模式下不设它登录直接 403，见下）。改成逐项之后没有这个盲区。

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

# 写进块首的标记。它只影响追加出来的注释文本；**「要不要写」由下面的逐项核对决定**，
# 不再看这个标记 —— 曾经的整块级判断在「给已部署机器新增一项设置」时会失效。
MARKER = '# ---- 二开定制（镜像烘焙，勿手改本块）----'

# 必须存在于 seahub_settings.py 的设置项：(键名, 赋值行)。
# 键名用于逐项核对（正则 ^键名\s*=），赋值行是缺失时补写的内容。
MANAGED_SETTINGS = (
    ('CLIENT_SSO_VIA_LOCAL_BROWSER',
     'CLIENT_SSO_VIA_LOCAL_BROWSER = True'),
    ('ENABLE_DINGTALK',
     'ENABLE_DINGTALK = True'),
    ('ENABLE_DELETE_ACCOUNT',
     'ENABLE_DELETE_ACCOUNT = False           # 禁止用户自助注销（docs/003）'),
    # 反代模式（TLS 在云代理终止、容器只听 80）下 $scheme 恒为 http，而 Django 只在
    # 本项非 None 时才认 X-Forwarded-Proto。不设它 → request.is_secure() 恒为假 →
    # CSRF 的 good_origin 算成 http://域名 → 登录 403（2026-09-21 生产实测）。
    # nginx 侧由 $seafile_fwd_proto 保证该头在两种模式下都正确，见 docs/007 §9。
    ('SECURE_PROXY_SSL_HEADER',
     'SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")'),
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


def dingtalk_settings():
    """钉钉凭据的 (键名, 赋值行)；环境变量没预置就返回空。

    默认不写：它已 constance 化，后台「系统管理 → 设置」填即可，写空串只会让人
    以为要在这儿配（docs/002）。
    """
    key = os.environ.get('SEAHUB_DINGTALK_APP_KEY', '').strip()
    secret = os.environ.get('SEAHUB_DINGTALK_APP_SECRET', '').strip()
    if not (key or secret):
        return ()
    return (
        ('DINGTALK_APP_KEY', "DINGTALK_APP_KEY = '%s'" % key),
        ('DINGTALK_APP_SECRET', "DINGTALK_APP_SECRET = '%s'" % secret),
    )


def has_setting(src, key):
    """src 里是否已有 `key = ...` 的赋值。要求行首 —— 注释掉的（# key =）不算。"""
    return re.search(r'^%s\s*=' % re.escape(key), src, re.M) is not None


def settings_block(lines):
    """返回要追加进 seahub_settings.py 的文本块；lines 是本次缺失项的赋值行。"""
    return """

%s
# 下面几项必须在【模块导入期】就确定（或属于部署形态），所以只能写文件 ——
# 改这里要重启 seahub。判断依据是各调用点的绑定方式，不是「重不重要」：
#   CLIENT_SSO_VIA_LOCAL_BROWSER → urls.py / api2/urls.py / views/sso.py 导入期读它来注册路由
#   ENABLE_DINGTALK              → 它决定 constance 里该键的默认值（settings.py:1236）
#   ENABLE_DELETE_ACCOUNT        → profile/views.py 模块级 from seahub.settings import
#   SECURE_PROXY_SSL_HEADER      → Django 据此认 X-Forwarded-Proto；
#                                  反代模式下不设它 request.is_secure() 恒为假，登录 403
# 其余站点相关配置（SERVICE_URL、钉钉凭据与开关）都已是 constance：管理员在
# 后台「系统管理 → 设置」页填，存库、免重启生效，不归这里管。
#
# 本块由镜像内的 custom_bootstrap.py 在每次容器启动时【逐项】校验，缺哪行补哪行；
# 不要手改（改了会在下次重启时被识别为「已存在」而保留，但语义上不应依赖这个）。

%s
# PASSWORD_LOGIN_ADMIN_ONLY = True     # 补丁 0008 默认即 True；紧急放开时取消注释改 False
""" % (MARKER, '\n'.join(lines))


def apply_settings(confdir):
    path = os.path.join(confdir, 'seahub_settings.py')
    if not os.path.exists(path):
        sys.exit('%s %s 不存在。setup-seafile-mysql.py 应该已经生成它了，'
                 '说明首启没有正常走完。' % (LOG_PREFIX, path))

    with open(path, 'r', encoding='utf-8') as fp:
        current = fp.read()

    wanted = tuple(MANAGED_SETTINGS) + dingtalk_settings()
    missing = [(key, line) for key, line in wanted if not has_setting(current, key)]
    if not missing:
        log('seahub_settings.py 定制项齐全（%d 项），跳过' % len(wanted))
        return

    with open(path, 'w', encoding='utf-8') as fp:
        fp.write(current.rstrip() + '\n' + settings_block([line for _, line in missing]))
    log('已补齐 seahub_settings.py 定制项 %d 项：%s'
        % (len(missing), '、'.join(key for key, _ in missing)))


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
    apply_nginx_server_name()
    log('完成 —— 此时 seafile/seahub 尚未启动，无需重启即已生效')


# ---------------------------------------------------------------------------
# 静态 nginx conf 的域名替换（13.0 起）
#
# 13.0 废除了 /templates/ 模板渲染机制：conf 构建期静态烘入
# /etc/nginx/sites-enabled/seafile.nginx.conf，不再有 generate_local_nginx_conf。
# 这反而治好了 12.0 的病根——「conf 滞留在数据卷」（403 第三形态）在 13.0
# 结构性消失：conf 随镜像走，升级即生效，不再需要 sync_nginx_conf 那套
# sidecar 指纹机制（已删除）。
#
# 但静态化带来一个新问题：conf 里的 server_name 构建期不知道域名，只能烘占位符
# __SEAFILE_SERVER_NAME__。首启时在这里用真实 SEAFILE_DOMAIN 替换——conf 在镜像层，
# 每次启动都重新从镜像层生效（容器重建即恢复占位符，再被这里替换），天然幂等。
# ---------------------------------------------------------------------------

NGINX_STATIC_CONF = '/etc/nginx/sites-enabled/seafile.nginx.conf'
SERVER_NAME_PLACEHOLDER = '__SEAFILE_SERVER_NAME__'


def apply_nginx_server_name():
    """把静态 conf 里的域名占位符替换为真实 SEAFILE_DOMAIN。"""
    domain = os.environ.get('SEAFILE_DOMAIN', '').strip() \
        or os.environ.get('SEAFILE_SERVER_HOSTNAME', '').strip()
    if not domain:
        log('未设 SEAFILE_DOMAIN / SEAFILE_SERVER_HOSTNAME，nginx server_name 保持占位符'
            '（仅 IP 直连可用，域名入口的 https 判定不生效）')
        return
    if not os.path.isfile(NGINX_STATIC_CONF):
        # 13.0 之前是 /templates/ 模板渲染，本函数不适用；静默跳过不阻断启动
        log('静态 conf %s 不存在（非 13.0 镜像？），跳过域名替换' % NGINX_STATIC_CONF)
        return

    with open(NGINX_STATIC_CONF, 'r', encoding='utf-8') as fp:
        current = fp.read()

    if SERVER_NAME_PLACEHOLDER not in current:
        if re.search(r'^\s*server_name\s+%s\s*;' % re.escape(domain), current, re.M):
            return  # 已是目标域名（重启场景，容器层还在）
        log('静态 conf 无占位符也非目标域名，保持现状')
        return

    new = current.replace(SERVER_NAME_PLACEHOLDER, domain)
    with open(NGINX_STATIC_CONF, 'w', encoding='utf-8') as fp:
        fp.write(new)
    log('nginx server_name 已设为 %s（静态 conf，随镜像走，无需数据卷同步）' % domain)


if __name__ == '__main__':
    init_custom_settings()
