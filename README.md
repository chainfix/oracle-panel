# OCI ARM 抢机面板

一个给朋友用的 Oracle Cloud 免费 ARM 实例抢机 Web 面板：填一次 API 凭证，后台循环调用创建实例 API，抢到为止。另带机器管理（查看 / 删除实例、一键更换公网 IP）。

## 功能

**抢机任务**
- 新建抢机任务：目标区域（Oracle 全部 44 个商业区域）、自由规格（1–4 OCPU / 1–24GB 内存）、系统镜像细分版本（实时从 Oracle 获取，如 Ubuntu 24.04 / Oracle Linux 9.8）、实例名、启动卷、重试间隔
- SSH 登录方式：密钥登录（一键下载私钥）或密码登录（cloud-init 自动设置）
- 实时日志、尝试次数、运行状态、停止 / 删除任务
- 抢到后显示公网 IP

**机器管理**
- 多账号管理（API 凭证只存在浏览器本地）
- 一键扫描账号所有区域的实例
- 删除机器（实例 + 启动卷一起释放）
- 一键换 IP（关机释放临时公网 IP → 开机分配新 IP）

## 快速开始

### 方式一：一键部署到服务器

```bash
./deploy.sh root@你的服务器IP 5887
```

部署后访问 `http://你的服务器IP:5887/`。

### 方式二：手动运行

```bash
python3 -m venv venv && ./venv/bin/pip install -r requirements.txt
./venv/bin/python app.py   # 默认监听 0.0.0.0:5887
```

依赖：Python 3.8+、`snipe.sh` 需在同一目录（抢机核心脚本）。

## 准备 Oracle API 凭证

1. 登录 [Oracle Cloud 控制台](https://cloud.oracle.com) → 右上角用户 → API 密钥 → 添加 API 密钥
2. 记下 Tenancy OCID、User OCID、指纹，下载私钥（.pem）
3. 在面板"新建抢机任务"里填写（支持上传私钥文件），会自动缓存在浏览器本地

## 安全说明

- 面板本身无登录鉴权，适合内网 / 可信网络使用，公网部署请自行加反向代理鉴权
- API 凭证缓存在各用户浏览器 localStorage；创建任务后会写入服务器该任务的独立目录（权限 600），删除任务时一并清除
- 机器管理的账号凭证仅在内存中使用，不落盘

## 文件结构

```
├── app.py              # Flask 面板后端
├── snipe.sh            # 抢机核心脚本（也可独立交互使用）
├── templates/index.html# 前端页面
├── deploy.sh           # 一键部署脚本
├── requirements.txt
└── panel.conf.example  # 配置示例
```

`snipe.sh` 也可单独在服务器上交互运行：`./snipe.sh`。

## License

MIT
