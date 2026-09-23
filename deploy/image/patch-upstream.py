#!/usr/bin/env python3
# -*- coding: UTF-8 -*-
"""构建期补丁：把三处改动打进上游脚本，每一处都带前后断言。

只在镜像构建时跑一次（Dockerfile 里 COPY 进来、跑完删掉），不进最终镜像。

## 为什么是独立脚本而不是 Dockerfile 里堆 sed

要改的是三处**带上下文**的位置（其中一处还要改写一个循环体）。sed 能做，但
读的人得在脑子里模拟正则；而且 `sed` 的失败方式很糟——正则没匹配上时它**静默
成功**，改动没进去，构建照样绿。这个项目里已经吃过一次「假设写死在代码里而不
验证」的亏（见 docs/010 §8.1 的 manifest list），所以这里统一用显式字符串匹配
+ 断言：**匹配不上就让构建失败**。

## 改了什么，为什么

1. `start.py` — 在 `init_seafile_server()` 之后插入二开定制的追加调用。
   时机是唯一的：早了会被 setup 的 open('w') 覆盖，晚了 seahub 已起来、
   seahub_settings.py 是导入期读的、改了要重启。

2. `start.py` — 把起 seahub 的 `call(...)` 换成带重试的 `start_service_retry(...)`。
   上游 `seahub.sh` 的启动判定是「硬编码 sleep 5 然后 pgrep 一次」：
   ```bash
   $PYTHON $gunicorn_exe seahub.wsgi:application -c "${gunicorn_conf}" --preload &
   sleep 5
   if ! pgrep -f "seahub.wsgi:application"; then ... exit 1; fi
   ```
   `--preload` 要先在 master 里把整个 Django 应用导入完才 fork，机器一忙就可能
   超过 5 秒，于是**误判成失败**。本地彩排实测到过一次：容器重启后 seahub 没起来，
   手工再跑一次 `seahub.sh start` 立刻就好。重试是对症的——它不管失败的原因是什么，
   在上层重来一次即可。

3. `enterpoint.sh` — start.py 死掉时让容器也退出。
   **这才是真正要紧的一条。** 上游这个保活循环：
   ```bash
   /scripts/start.py &
   ...
   while [ 1 ]; do sleep 60 & wait $!; done
   ```
   只要循环还在，容器就一直是 Up。于是第 2 条那种启动失败会留下一个
   「`docker ps` 显示 Up、网站却是死的」的容器——而且 `restart: unless-stopped`
   救不了它，因为**容器根本没退出**。这正是本项目一路上在消灭的静默失败。
   改完之后失败会变成容器退出 → 重启策略接管 → 可见、可自愈。

断言策略：每处改动都验「改之前匹配到恰好 1 次」和「改之后确实生效」，任一不满足
就 exit 1。
"""

import sys

START_PY = '/scripts/start.py'
ENTERPOINT_SH = '/scripts/enterpoint.sh'


def die(msg):
    sys.exit('patch-upstream: %s' % msg)


def patch(path, old, new, what, count=1):
    """把 path 里的 old 换成 new。要求 old 出现恰好 count 次，否则构建失败。"""
    with open(path, 'r', encoding='utf-8') as fp:
        src = fp.read()

    n = src.count(old)
    if n != count:
        die('%s：期望匹配 %d 处，实际 %d 处。上游这段可能改了，'
            '对照 docs/007 §4.2.2 重新确认后更新本脚本。\n--- 找的是 ---\n%s'
            % (what, count, n, old))

    src = src.replace(old, new)
    with open(path, 'w', encoding='utf-8') as fp:
        fp.write(src)

    if new not in src:
        die('%s：写入后校验失败（不该发生）' % what)
    print('  ✅ %s' % what)


def patch_start_py():
    # ---- 1) 二开定制的 import 与调用点 ----
    patch(
        START_PY,
        'from bootstrap import ',
        'from custom_bootstrap import init_custom_settings, start_service_retry, sync_nginx_conf\n'
        'from bootstrap import ',
        'start.py: 插入 custom_bootstrap 的 import',
    )

    patch(
        START_PY,
        '    init_seafile_server()\n',
        '    init_seafile_server()\n'
        '    init_custom_settings()\n',
        'start.py: 在 init_seafile_server() 之后插入定制追加调用',
    )

    # ---- 1b) 模板变更自动传播 ----
    # 上游 generate_local_nginx_conf() 只在 conf 不存在时渲染，数据卷里的旧 conf
    # 会无限滞留（2026-09-22 生产 403 第三形态：拉了三版新镜像，跑的还是首启模板
    # 的规则）。必须插在它【之前】——晚了就轮不到上游重渲染。
    patch(
        START_PY,
        '    generate_local_nginx_conf()\n',
        '    # 本地改动（image/patch-upstream.py）：模板指纹同步，见 custom_bootstrap.sync_nginx_conf\n'
        '    sync_nginx_conf()\n'
        '    generate_local_nginx_conf()\n',
        'start.py: 渲染 nginx conf 之前做模板指纹同步',
    )

    # ---- 2) 起 seahub 失败要重试 ----
    # 只替换含 get_script('seahub.sh') 的那两行（non_root 分支各一行），
    # 不能动 seafile.sh 那两行——seafile.sh 没有这个 5 秒误判问题，改了徒增变量。
    for old, new in (
        ("call('su seafile -c \"{} start\"'.format(get_script('seahub.sh')))",
         "start_service_retry('su seafile -c \"{} start\"'.format(get_script('seahub.sh')))"),
        ("call('{} start'.format(get_script('seahub.sh')))",
         "start_service_retry('{} start'.format(get_script('seahub.sh')))"),
    ):
        patch(START_PY, old, new, 'start.py: seahub 启动改为带重试')

    print('  start.py 补丁完成')


def patch_enterpoint_sh():
    # 记下 start.py 的 PID。放在 if/else 之后：两个分支都是「最后一个后台进程」，
    # 所以 $! 在两种情况下都指向它。
    patch(
        ENTERPOINT_SH,
        '    /scripts/start.py &\nfi\n',
        '    /scripts/start.py &\nfi\nSERVER_PID=$!\n',
        'enterpoint.sh: 记下 start.py 的 PID',
    )

    patch(
        ENTERPOINT_SH,
        'while [ 1 ]; do\n    sleep 60 &\n    wait $!\ndone',
        '''while [ 1 ]; do
    # 本地改动（见 image/patch-upstream.py）：start.py 退出 = 服务没起来。
    # 原版这里只是继续空转，于是容器一直显示 Up 而网站是死的，restart 策略
    # 也救不了它（容器没退出）。改成跟着退出，让失败可见、让重启策略接管。
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        log "start.py exited unexpectedly, stopping container so the restart policy can take over"
        exit 1
    fi
    sleep 60 &
    wait $!
done''',
        'enterpoint.sh: start.py 死掉时容器跟着退出',
    )

    print('  enterpoint.sh 补丁完成')


def main():
    print('patch-upstream: 打入三处改动')
    patch_start_py()
    patch_enterpoint_sh()
    print('patch-upstream: 全部完成')


if __name__ == '__main__':
    main()
