# -*- coding: utf-8 -*-
# 本文件是模板，不是运行时文件。
# 部署时由 deploy/init-conf.sh 把 __占位符__ 替换成 .env 里的值，
# 渲染结果写入 <SEAFILE_VOLUME>/seafile/conf/seahub_settings.py（该目录不入库）。
# 生产部署用 --prod 模式（init-conf.sh --prod，见 docs/007）。

SECRET_KEY = "__SEAHUB_SECRET_KEY__"

# 13.0 起 SERVICE_URL / FILE_SERVER_ROOT 不写在这里：settings.py 在加载完本文件之后，
# 只要容器环境变量 SEAFILE_SERVER_PROTOCOL + SEAFILE_SERVER_HOSTNAME 都在（dev/prod
# compose 都设了），就【无条件】按它们重算——写在这里的值会被覆盖，纯属误导。
# 且补丁 0009 已把 SERVICE_URL 注册进 constance，后台「系统管理 → 设置」可改。
# 必须与「钉钉后台注册的回调域名」一致，否则钉钉登录会因 session cookie 跨域丢失
# 而报 invalid state。

# 客户端（桌面/移动端）单点登录：通过本地浏览器完成。
# 必须写在配置文件里：相关 URL 在模块导入期注册，constance 动态开关管不到。
CLIENT_SSO_VIA_LOCAL_BROWSER = True

# dev 容器自签 HTTPS（conf-templates/nginx/seafile.nginx.conf 以 $scheme 上送
# X-Forwarded-Proto）。不设本项 Django 不认这个头 → request.is_secure() 恒为假 →
# CSRF 把 good_origin 算成 http://… → 表单登录 403（与生产 403 同一族，docs/007 §9）。
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")

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

# 13.0 起缓存不写在这里：settings.py 由 CACHE_PROVIDER 环境变量决定后端
# （compose 里已设 CACHE_PROVIDER=redis + REDIS_HOST=redis），且 env 会强制改写
# BACKEND/LOCATION。历史上这里写过 memcached 的 CACHES 块——在 13.0 下它会被 env
# 逻辑中和，但留着纯属误导，已删除。别再加回来。

TIME_ZONE = 'Asia/Shanghai'

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
