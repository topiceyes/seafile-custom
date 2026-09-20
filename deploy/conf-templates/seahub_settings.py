# -*- coding: utf-8 -*-
# 本文件是模板，不是运行时文件。
# 部署时由 deploy/init-conf.sh 把 __占位符__ 替换成 .env 里的值，
# 渲染结果写入 <SEAFILE_VOLUME>/seafile/conf/seahub_settings.py（该目录不入库）。
# 生产部署用 --prod 模式（init-conf.sh --prod，见 docs/007）。

SECRET_KEY = "__SEAHUB_SECRET_KEY__"

# 站点地址 = https://<SEAFILE_DOMAIN>。必须与「容器环境变量 SEAFILE_SERVER_HOSTNAME」
# （见 seafile-server.yml / seafile-prod.yml，会覆盖本行，见 seahub/settings.py）以及
# 「钉钉后台注册的回调域名」三者一致，否则钉钉登录会因 session cookie 跨域丢失而报 invalid state。
SERVICE_URL = "https://__SEAFILE_DOMAIN__"

# 客户端（桌面/移动端）单点登录：通过本地浏览器完成。
# 必须写在配置文件里：相关 URL 在模块导入期注册，constance 动态开关管不到。
CLIENT_SSO_VIA_LOCAL_BROWSER = True

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': 'seahub_db',
        'USER': 'seafile',
        'PASSWORD': '__SEAHUB_DB_PASSWORD__',
        'HOST': 'db',
        'PORT': '3306',
        'OPTIONS': {'charset': 'utf8mb4'},
    }
}


CACHES = {
    'default': {
        'BACKEND': 'django_pylibmc.memcached.PyLibMCCache',
        'LOCATION': 'memcached:11211',
    },
    'locmem': {
        'BACKEND': 'django.core.cache.backends.locmem.LocMemCache',
    },
}
COMPRESS_CACHE_BACKEND = 'locmem'

TIME_ZONE = 'Asia/Shanghai'
FILE_SERVER_ROOT = 'https://__SEAFILE_DOMAIN__/seafhttp'

# 钉钉扫码登录（企业内部应用）。
# 这三项已 constance 化：管理员后台「设置」页可改、免重启生效，
# 这里的值只作为默认值（DB 里无记录时生效）。详见 docs/002。
ENABLE_DINGTALK = True
DINGTALK_APP_KEY = '__SEAHUB_DINGTALK_APP_KEY__'
DINGTALK_APP_SECRET = '__SEAHUB_DINGTALK_APP_SECRET__'

# 账号管控（详见 docs/003、008）
ENABLE_DELETE_ACCOUNT = False        # 禁止用户自助注销账号
# 密码登录仅限管理员（钉钉 SSO 是普通用户唯一入口）。
# 紧急放开：改为 False 后 docker exec seafile .../seahub.sh restart
PASSWORD_LOGIN_ADMIN_ONLY = True
