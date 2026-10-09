#!/usr/bin/env python3
"""OCI ARM 抢机面板 - 后端
每个任务在独立 HOME 目录下以 OCI_SNIPER_AUTO=1 运行 snipe.sh。
"""
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import sqlite3
import subprocess
import time
from datetime import datetime

from flask import Flask, jsonify, request, send_file

PANEL_DIR = os.path.dirname(os.path.abspath(__file__))
TASKS_DIR = os.path.join(PANEL_DIR, "tasks")
DB = os.path.join(PANEL_DIR, "panel.db")
SNIPE_SH = os.path.join(PANEL_DIR, "snipe.sh")
CONF_FILE = os.path.join(PANEL_DIR, "panel.conf")

REGIONS = [  # (code, 中文名, 分组) —— OCI commercial (OC1) 全区域
    ("ap-tokyo-1", "东京", "亚太"), ("ap-osaka-1", "大阪", "亚太"),
    ("ap-seoul-1", "首尔", "亚太"), ("ap-chuncheon-1", "春川", "亚太"),
    ("ap-singapore-1", "新加坡", "亚太"), ("ap-singapore-2", "新加坡2", "亚太"),
    ("ap-sydney-1", "悉尼", "亚太"), ("ap-melbourne-1", "墨尔本", "亚太"),
    ("ap-mumbai-1", "孟买", "亚太"), ("ap-hyderabad-1", "海得拉巴", "亚太"),
    ("ap-batam-1", "巴淡岛", "亚太"), ("ap-kulai-2", "古来", "亚太"),
    ("eu-frankfurt-1", "法兰克福", "欧洲"), ("eu-paris-1", "巴黎", "欧洲"),
    ("eu-marseille-1", "马赛", "欧洲"), ("eu-amsterdam-1", "阿姆斯特丹", "欧洲"),
    ("eu-zurich-1", "苏黎世", "欧洲"), ("eu-stockholm-1", "斯德哥尔摩", "欧洲"),
    ("eu-milan-1", "米兰", "欧洲"), ("eu-turin-1", "都灵", "欧洲"),
    ("eu-madrid-1", "马德里", "欧洲"), ("eu-madrid-3", "马德里3", "欧洲"),
    ("uk-london-1", "伦敦", "欧洲"), ("uk-cardiff-1", "卡迪夫", "欧洲"),
    ("us-ashburn-1", "阿什本", "美洲"), ("us-phoenix-1", "凤凰城", "美洲"),
    ("us-chicago-1", "芝加哥", "美洲"), ("us-sanjose-1", "圣何塞", "美洲"),
    ("ca-montreal-1", "蒙特利尔", "美洲"), ("ca-toronto-1", "多伦多", "美洲"),
    ("mx-queretaro-1", "克雷塔罗", "美洲"), ("mx-monterrey-1", "蒙特雷", "美洲"),
    ("sa-saopaulo-1", "圣保罗", "美洲"), ("sa-vinhedo-1", "维涅杜", "美洲"),
    ("sa-santiago-1", "圣地亚哥", "美洲"), ("sa-valparaiso-1", "瓦尔帕莱索", "美洲"),
    ("sa-bogota-1", "波哥大", "美洲"),
    ("me-dubai-1", "迪拜", "中东"), ("me-abudhabi-1", "阿布扎比", "中东"),
    ("me-jeddah-1", "吉达", "中东"), ("me-riyadh-1", "利雅得", "中东"),
    ("il-jerusalem-1", "耶路撒冷", "中东"),
    ("af-johannesburg-1", "约翰内斯堡", "非洲"), ("af-casablanca-1", "卡萨布兰卡", "非洲"),
]
REGION_CODES = {c for c, _, _ in REGIONS}
OS_CHOICES = {"1": "Oracle Linux", "2": "Canonical Ubuntu"}

RE_OCID = re.compile(r"^ocid1\.[a-z0-9_-]+\.oc[0-9]*\..+")
RE_FP = re.compile(r"^([0-9a-fA-F]{2}:){15}[0-9a-fA-F]{2}$")
RE_TID = re.compile(r"^[0-9a-f]{8}$")  # create_task 用 secrets.token_hex(4) 生成

app = Flask(__name__)


def load_conf():
    conf = {}
    if os.path.exists(CONF_FILE):
        with open(CONF_FILE) as f:
            for line in f:
                line = line.strip()
                if line and "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    conf[k.strip()] = v.strip()
    return conf


CONF = load_conf()


def db():
    c = sqlite3.connect(DB)
    c.row_factory = sqlite3.Row
    return c


def init_db():
    os.makedirs(TASKS_DIR, exist_ok=True)
    c = db()
    c.execute("""CREATE TABLE IF NOT EXISTS tasks(
        id TEXT PRIMARY KEY, name TEXT, region TEXT, spec TEXT, os_choice TEXT,
        status TEXT, pid INTEGER, created_at REAL, stopped INTEGER DEFAULT 0,
        boot_gb INTEGER, interval_s INTEGER, ssh_mode TEXT DEFAULT 'key')""")
    try:
        c.execute("ALTER TABLE tasks ADD COLUMN ssh_mode TEXT DEFAULT 'key'")
    except sqlite3.OperationalError:
        pass  # 列已存在
    c.commit()
    c.close()


def task_dir(tid):
    return os.path.join(TASKS_DIR, tid)


def pid_alive(pid):
    if not pid:
        return False
    try:
        with open("/proc/%d/stat" % pid) as f:
            state = f.read().split()[2]
        return state not in ("Z", "X", "x")  # 僵尸进程视为已结束
    except (FileNotFoundError, ProcessLookupError, OSError):
        return False


def _reaper():
    """后台回收已退出的子进程，避免僵尸堆积"""
    import threading
    def loop():
        while True:
            try:
                while True:
                    p, _ = os.waitpid(-1, os.WNOHANG)
                    if p == 0:
                        break
            except ChildProcessError:
                pass
            except OSError:
                pass
            time.sleep(30)
    threading.Thread(target=loop, daemon=True).start()


def read_status(tid):
    """running / success / failed / stopped"""
    d = task_dir(tid)
    if os.path.exists(os.path.join(d, "oci-arm-instance.txt")):
        return "success"
    c = db()
    row = c.execute("SELECT pid, stopped FROM tasks WHERE id=?", (tid,)).fetchone()
    c.close()
    if row and row["stopped"]:
        return "stopped"
    if row and pid_alive(row["pid"]):
        return "running"
    return "failed"


def parse_result(tid):
    p = os.path.join(task_dir(tid), "oci-arm-instance.txt")
    info = {}
    if os.path.exists(p):
        with open(p, errors="replace") as f:
            for line in f:
                if ":" in line or "：" in line:
                    k, v = re.split(r"[:：]", line.strip(), 1)
                    info[k.strip()] = v.strip()
    return info


def log_attempts(tid):
    p = os.path.join(task_dir(tid), "oci-arm-sniper.log")
    n = 0
    try:
        with open(p, errors="replace") as f:
            for line in f:
                m = re.search(r"第 (\d+) 次尝试", line)
                if m:
                    n = int(m.group(1))
    except FileNotFoundError:
        pass
    return n


@app.route("/api/meta")
def meta():
    return jsonify({
        "regions": [{"code": c, "name": n, "group": g} for c, n, g in REGIONS],
        "os_choices": [{"id": k, "label": v} for k, v in OS_CHOICES.items()],
    })


@app.route("/api/tasks", methods=["GET"])
def list_tasks():
    c = db()
    rows = c.execute("SELECT * FROM tasks ORDER BY created_at DESC").fetchall()
    c.close()
    out = []
    for r in rows:
        tid = r["id"]
        out.append({
            "id": tid, "name": r["name"], "region": r["region"],
            "spec": r["spec"],
            "os": OS_CHOICES.get(r["os_choice"], r["os_choice"]),
            "ssh_mode": r["ssh_mode"] if "ssh_mode" in r.keys() else "key",
            "status": read_status(tid), "attempts": log_attempts(tid),
            "created_at": r["created_at"],
            "elapsed": int(time.time() - r["created_at"]),
        })
    return jsonify(out)


@app.route("/api/tasks", methods=["POST"])
def create_task():
    data = request.get_json(force=True, silent=True) or {}
    tenancy = data.get("tenancy", "").strip()
    user_ocid = data.get("user_ocid", "").strip()
    fp = data.get("fingerprint", "").strip()
    pkey = data.get("private_key", "").strip()
    region = data.get("region", "").strip()
    image_id = data.get("image_id", "").strip()
    image_os = data.get("image_os", "").strip()
    image_label = data.get("image_label", "").strip() or image_os
    ssh_mode = data.get("ssh_mode", "key")
    ssh_password = data.get("ssh_password", "")
    name = data.get("name", "oci-arm-1").strip() or "oci-arm-1"
    try:
        ocpus = int(data.get("ocpus", 4))
        mem = int(data.get("mem", 24))
        boot_gb = int(data.get("boot_gb", 50))
        interval = int(data.get("interval", 45))
    except (ValueError, TypeError):
        return jsonify({"error": "规格/启动卷/间隔须为数字"}), 400

    # ---- 校验 (避免 snipe.sh 在 AUTO 模式下 ask_ocid 死循环) ----
    if not RE_OCID.match(tenancy):
        return jsonify({"error": "Tenancy OCID 格式不对"}), 400
    if not RE_OCID.match(user_ocid):
        return jsonify({"error": "User OCID 格式不对"}), 400
    if not RE_FP.match(fp):
        return jsonify({"error": "指纹格式不对，应为 16 组十六进制以冒号分隔"}), 400
    if "PRIVATE KEY" not in pkey or "BEGIN" not in pkey:
        return jsonify({"error": "私钥内容不对，请粘贴完整 PEM 或上传私钥文件"}), 400
    if not region:
        return jsonify({"error": "请选择目标区域"}), 400
    if region not in REGION_CODES:
        return jsonify({"error": "区域无效"}), 400
    if not (1 <= ocpus <= 4):
        return jsonify({"error": "OCPU 须在 1-4 之间"}), 400
    if not (1 <= mem <= 24):
        return jsonify({"error": "内存须在 1-24GB 之间"}), 400
    if not image_id.startswith("ocid1.image."):
        return jsonify({"error": "请选择系统镜像版本（或手动输入镜像 OCID）"}), 400
    if image_os not in ("Oracle Linux", "Canonical Ubuntu"):
        return jsonify({"error": "镜像系统类型无效"}), 400
    if ssh_mode not in ("key", "password"):
        return jsonify({"error": "SSH 登录方式无效"}), 400
    if ssh_mode == "password":
        if not (6 <= len(ssh_password) <= 64):
            return jsonify({"error": "SSH 密码须为 6-64 位"}), 400
        if re.search(r"[\r\n\s]", ssh_password):
            return jsonify({"error": "SSH 密码不能包含空白字符"}), 400
    if not (50 <= boot_gb <= 200):
        return jsonify({"error": "启动卷须在 50-200GB"}), 400
    if not (5 <= interval <= 3600):
        return jsonify({"error": "重试间隔须在 5-3600 秒"}), 400
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$", name):
        return jsonify({"error": "实例名含非法字符"}), 400

    tid = secrets.token_hex(4)
    d = task_dir(tid)
    oci_dir = os.path.join(d, ".oci")
    os.makedirs(oci_dir, exist_ok=True)

    # 私钥
    key_file = os.path.join(oci_dir, "oci_api_key.pem")
    with open(key_file, "w") as f:
        f.write(pkey if pkey.endswith("\n") else pkey + "\n")
    os.chmod(key_file, 0o600)

    # oci config
    with open(os.path.join(oci_dir, "config"), "w") as f:
        f.write("[DEFAULT]\nuser=%s\nfingerprint=%s\ntenancy=%s\nregion=%s\nkey_file=%s\n"
                % (user_ocid, fp, tenancy, region, key_file))
    os.chmod(os.path.join(oci_dir, "config"), 0o600)

    # sniper.conf (AUTO 模式全部取默认值)
    ssh_user = "opc" if image_os == "Oracle Linux" else "ubuntu"
    conf_vars = {
        "TENANCY": tenancy, "USER_OCID": user_ocid, "FINGERPRINT": fp,
        "REGION": region, "KEY_FILE": key_file, "COMPARTMENT": tenancy,
        "AD_CHO": "1", "NET_CHO": "1",
        "OS_CHO": "1" if image_os == "Oracle Linux" else "2",
        "IMAGE": image_id, "SSH_USER": ssh_user,
        "OCPUS": str(ocpus), "MEM": str(mem),
        "NAME": name, "BOOT_GB": str(boot_gb), "INTERVAL": str(interval),
        "MAX_ATTEMPTS": "0",
    }
    if ssh_mode == "password":
        conf_vars["SSH_PASSWORD"] = ssh_password
    with open(os.path.join(oci_dir, "sniper.conf"), "w") as f:
        for k, v in conf_vars.items():
            f.write("%s=%s\n" % (k, shlex.quote(v)))
    os.chmod(os.path.join(oci_dir, "sniper.conf"), 0o600)

    # 启动
    env = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
           "HOME": d, "OCI_SNIPER_AUTO": "1", "LANG": "C.UTF-8"}
    proc = subprocess.Popen(
        ["bash", SNIPE_SH], stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True, cwd=PANEL_DIR, env=env)

    spec_label = "%dC%dG" % (ocpus, mem)
    c = db()
    c.execute("INSERT INTO tasks(id,name,region,spec,os_choice,status,pid,created_at,stopped,boot_gb,interval_s,ssh_mode) VALUES(?,?,?,?,?,?,?, ?,0,?,?,?)",
              (tid, name, region, spec_label, image_label, "running", proc.pid,
               time.time(), boot_gb, interval, ssh_mode))
    c.commit()
    c.close()
    return jsonify({"id": tid})


@app.route("/api/tasks/<tid>", methods=["GET"])
def task_detail(tid):
    c = db()
    row = c.execute("SELECT * FROM tasks WHERE id=?", (tid,)).fetchone()
    c.close()
    if not row:
        return jsonify({"error": "任务不存在"}), 404
    return jsonify({
        "id": tid, "name": row["name"], "region": row["region"],
        "spec": row["spec"],
        "os": OS_CHOICES.get(row["os_choice"], row["os_choice"]),
        "ssh_mode": row["ssh_mode"] if "ssh_mode" in row.keys() else "key",
        "status": read_status(tid), "attempts": log_attempts(tid),
        "created_at": row["created_at"], "elapsed": int(time.time() - row["created_at"]),
        "boot_gb": row["boot_gb"], "interval": row["interval_s"],
        "result": parse_result(tid),
        "has_key": os.path.exists(os.path.join(task_dir(tid), ".ssh", "id_rsa")),
    })


@app.route("/api/tasks/<tid>/log")
def task_log(tid):
    try:
        offset = int(request.args.get("offset", 0))
    except ValueError:
        offset = 0
    p = os.path.join(task_dir(tid), "oci-arm-sniper.log")
    if not os.path.exists(p):
        return jsonify({"lines": [], "offset": 0})
    with open(p, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        if offset > size:
            offset = 0
        f.seek(offset)
        data = f.read().decode("utf-8", "replace")
    return jsonify({"lines": data.splitlines(), "offset": size})


@app.route("/api/tasks/<tid>/stop", methods=["POST"])
def stop_task(tid):
    c = db()
    row = c.execute("SELECT pid FROM tasks WHERE id=?", (tid,)).fetchone()
    if not row:
        c.close()
        return jsonify({"error": "任务不存在"}), 404
    pid = row["pid"]
    try:
        os.killpg(pid, signal.SIGTERM)
    except (OSError, ProcessLookupError):
        pass
    time.sleep(1)
    if pid_alive(pid):
        try:
            os.killpg(pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass
    c.execute("UPDATE tasks SET stopped=1 WHERE id=?", (tid,))
    c.commit()
    c.close()
    with open(os.path.join(task_dir(tid), "oci-arm-sniper.log"), "a") as f:
        f.write("[%s] ⏹ 用户手动停止任务\n" % datetime.now().strftime("%F %T"))
    return jsonify({"ok": True})


@app.route("/api/tasks/<tid>", methods=["DELETE"])
def delete_task(tid):
    c = db()
    row = c.execute("SELECT pid FROM tasks WHERE id=?", (tid,)).fetchone()
    if not row:
        c.close()
        return jsonify({"error": "任务不存在"}), 404
    try:
        os.killpg(row["pid"], signal.SIGKILL)
    except (OSError, ProcessLookupError):
        pass
    c.execute("DELETE FROM tasks WHERE id=?", (tid,))
    c.commit()
    c.close()
    import shutil
    shutil.rmtree(task_dir(tid), ignore_errors=True)
    return jsonify({"ok": True})


@app.route("/api/tasks/<tid>/sshkey")
def ssh_key(tid):
    p = os.path.join(task_dir(tid), ".ssh", "id_rsa")
    if not os.path.exists(p):
        return jsonify({"error": "私钥尚未生成"}), 404
    return send_file(p, as_attachment=True, download_name="oci-arm-%s.pem" % tid)


# ================= 机器管理 =================
# 账号凭证由浏览器 localStorage 保存，每次请求随表单发送，服务端仅在内存中使用，不落盘。
import threading as _th

mgmt_jobs = {}  # job_id -> {"status": running|done|error, "lines": [], "result": ...}


def _mgmt_creds(data):
    """校验并提取管理接口的账号凭证，返回 (creds, error)"""
    tenancy = (data.get("tenancy") or "").strip()
    user_ocid = (data.get("user_ocid") or "").strip()
    fp = (data.get("fingerprint") or "").strip()
    pkey = (data.get("private_key") or "").strip()
    if not RE_OCID.match(tenancy):
        return None, "Tenancy OCID 格式不对"
    if not RE_OCID.match(user_ocid):
        return None, "User OCID 格式不对"
    if not RE_FP.match(fp):
        return None, "指纹格式不对"
    if "PRIVATE KEY" not in pkey or "BEGIN" not in pkey:
        return None, "私钥内容不对"
    return {"tenancy": tenancy, "user_ocid": user_ocid,
            "fingerprint": fp, "private_key": pkey}, None


def _oci_cfg(creds, region):
    return {"user": creds["user_ocid"], "fingerprint": creds["fingerprint"],
            "tenancy": creds["tenancy"], "region": region,
            "key_content": creds["private_key"]}


def _job_log(job_id, msg):
    j = mgmt_jobs.get(job_id)
    line = "[%s] %s" % (datetime.now().strftime("%H:%M:%S"), msg)
    if j:
        j["lines"].append(line)
        j["lines"] = j["lines"][-200:]
    try:
        with open("/tmp/oci-panel-jobs.log", "a") as f:
            f.write("%s %s %s\n" % (datetime.now().strftime("%m-%d %H:%M:%S"), job_id, line))
    except Exception:
        pass


def _job_done(job_id, result=None):
    j = mgmt_jobs.get(job_id)
    if j:
        j["status"] = "done"
        j["result"] = result


def _job_error(job_id, err):
    j = mgmt_jobs.get(job_id)
    line = "✘ " + str(err)[:500]
    if j:
        j["status"] = "error"
        j["lines"].append(line)
    try:
        with open("/tmp/oci-panel-jobs.log", "a") as f:
            f.write("%s %s %s\n" % (datetime.now().strftime("%m-%d %H:%M:%S"), job_id, line))
    except Exception:
        pass


def _start_job(fn, *args):
    job_id = secrets.token_hex(6)
    mgmt_jobs[job_id] = {"status": "running", "lines": [], "result": None}
    # 防止无限增长：只保留最近 100 个 job
    if len(mgmt_jobs) > 100:
        for jid in list(mgmt_jobs)[:len(mgmt_jobs) - 100]:
            if mgmt_jobs[jid]["status"] != "running":
                del mgmt_jobs[jid]

    def run():
        try:
            fn(job_id, *args)
        except Exception as e:  # noqa
            _job_error(job_id, e)

    _th.Thread(target=run, daemon=True).start()
    return job_id


def _vnic_ips(comp, vnet, tenancy, iid):
    """返回 (public_ip, private_ip, ipv6)"""
    pub = priv = v6 = ""
    try:
        atts = comp.list_vnic_attachments(tenancy, instance_id=iid).data
        if atts:
            vid = atts[0].vnic_id
            v = vnet.get_vnic(vid).data
            pub, priv = v.public_ip or "", v.private_ip or ""
            try:
                ips = vnet.list_ipv6s(vnic_id=vid).data
                if ips:
                    v6 = ips[0].ip_address or ""
            except Exception:  # noqa
                pass
    except Exception:  # noqa
        pass
    return pub, priv, v6


def _wait_state(comp, iid, want, job_id, timeout=600):
    import time as _t
    start = _t.time()
    while _t.time() - start < timeout:
        try:
            st = comp.get_instance(iid).data.lifecycle_state
        except Exception as e:  # noqa
            if "404" in str(e):
                return "GONE"
            raise
        if st == want:
            return st
        _t.sleep(10)
    raise TimeoutError("等待实例变为 %s 超时(600秒)，请稍后在控制台确认状态" % want)
    raise TimeoutError("等待 %s 超时(600s)，请稍后在控制台确认" % want)


@app.route("/api/mgmt/scan", methods=["POST"])
def mgmt_scan():
    """扫描账号订阅区域下的所有实例"""
    import oci
    data = request.get_json(force=True, silent=True) or {}
    creds, err = _mgmt_creds(data)
    if err:
        return jsonify({"error": err}), 400
    try:
        ident = oci.identity.IdentityClient(_oci_cfg(creds, "us-phoenix-1"))
        subs = ident.list_region_subscriptions(creds["tenancy"]).data
        regions = [s.region_name for s in subs if getattr(s, "status", "") == "READY"]
    except Exception as e:  # noqa
        return jsonify({"error": "账号验证失败: " + str(e)[:200]}), 400
    out = []
    for r in regions:
        try:
            cfg = _oci_cfg(creds, r)
            comp = oci.core.ComputeClient(cfg)
            vnet = oci.core.VirtualNetworkClient(cfg)
            items = []
            for i in comp.list_instances(creds["tenancy"]).data:
                if i.lifecycle_state in ("TERMINATED", "TERMINATING"):
                    continue
                pub, priv, ipv6 = _vnic_ips(comp, vnet, creds["tenancy"], i.id)
                sc = i.shape_config
                tc = i.time_created
                items.append({
                    "id": i.id, "name": i.display_name or "-",
                    "shape": i.shape,
                    "ocpus": getattr(sc, "ocpus", None),
                    "memory": getattr(sc, "memory_in_gbs", None),
                    "state": i.lifecycle_state,
                    "ad": i.availability_domain,
                    "public_ip": pub, "private_ip": priv, "ipv6": ipv6,
                    "created": tc.strftime("%Y-%m-%d %H:%M") if tc else "",
                })
            if items:
                out.append({"region": r, "instances": items})
        except Exception as e:  # noqa
            out.append({"region": r, "error": str(e)[:150]})
    return jsonify({"regions": out})


@app.route("/api/mgmt/images", methods=["POST"])
def mgmt_images():
    """列出某区域 ARM 兼容的平台镜像细分版本（Oracle Linux / Ubuntu）"""
    import oci, re as _re
    data = request.get_json(force=True, silent=True) or {}
    creds, err = _mgmt_creds(data)
    if err:
        return jsonify({"error": err}), 400
    region = (data.get("region") or "").strip()
    if region not in REGION_CODES:
        return jsonify({"error": "请先选择目标区域"}), 400
    try:
        comp = oci.core.ComputeClient(_oci_cfg(creds, region))
        seen, out = set(), []
        for os_name in ("Oracle Linux", "Canonical Ubuntu"):
            try:
                imgs = comp.list_images(
                    creds["tenancy"], operating_system=os_name,
                    shape="VM.Standard.A1.Flex",
                    sort_by="TIMECREATED", sort_order="DESC", limit=30).data
            except Exception:  # noqa
                continue
            for im in imgs:
                dn = im.display_name or ""
                m = _re.search(r"(?:Oracle-Linux|Canonical-Ubuntu|Ubuntu)-(\d+\.\d+)", dn)
                if not m:
                    continue
                ver = m.group(1)
                key = (os_name, ver)
                if key in seen:
                    continue  # 同版本只保留最新构建
                seen.add(key)
                short_os = "Ubuntu" if "Ubuntu" in os_name else "Oracle Linux"
                tc = im.time_created
                out.append({
                    "id": im.id, "os": os_name,
                    "label": "%s %s" % (short_os, ver),
                    "time": tc.strftime("%Y-%m-%d") if tc else "",
                })
                if len([o for o in out if o["os"] == os_name]) >= 8:
                    break
        # Oracle Linux 在前，Ubuntu 在后
        out.sort(key=lambda o: (0 if o["os"] == "Oracle Linux" else 1, o["label"]))
        return jsonify({"images": out})
    except Exception as e:  # noqa
        return jsonify({"error": "获取镜像列表失败: " + str(e)[:200]}), 400


@app.route("/api/mgmt/terminate", methods=["POST"])
def mgmt_terminate():
    data = request.get_json(force=True, silent=True) or {}
    creds, err = _mgmt_creds(data)
    if err:
        return jsonify({"error": err}), 400
    region = data.get("region", "")
    iid = data.get("instance_id", "")
    if region not in REGION_CODES or not iid.startswith("ocid1.instance."):
        return jsonify({"error": "参数无效"}), 400
    return jsonify({"job": _start_job(_do_terminate, creds, region, iid)})


def _do_terminate(job_id, creds, region, iid):
    import oci
    comp = oci.core.ComputeClient(_oci_cfg(creds, region))
    name = ""
    try:
        name = comp.get_instance(iid).data.display_name or ""
    except Exception:  # noqa
        pass
    _job_log(job_id, "正在终止实例 %s ..." % (name or iid[-12:]))
    comp.terminate_instance(iid)
    final = ""
    for _ in range(40):
        try:
            final = comp.get_instance(iid).data.lifecycle_state
        except Exception as e:  # noqa
            if "404" in str(e):
                final = "TERMINATED"
            else:
                raise
        _job_log(job_id, "状态: " + final)
        if final == "TERMINATED":
            break
        import time as _t
        _t.sleep(10)
    if final != "TERMINATED":
        raise TimeoutError("终止超时，实例当前状态: %s，请在控制台确认" % final)
    _job_done(job_id, "实例已终止，启动卷已随之释放")


@app.route("/api/mgmt/change-ip", methods=["POST"])
def mgmt_change_ip():
    data = request.get_json(force=True, silent=True) or {}
    creds, err = _mgmt_creds(data)
    if err:
        return jsonify({"error": err}), 400
    region = data.get("region", "")
    iid = data.get("instance_id", "")
    if region not in REGION_CODES or not iid.startswith("ocid1.instance."):
        return jsonify({"error": "参数无效"}), 400
    return jsonify({"job": _start_job(_do_change_ip, creds, region, iid)})


@app.route("/api/mgmt/reboot", methods=["POST"])
def mgmt_reboot():
    data = request.get_json(force=True, silent=True) or {}
    creds, err = _mgmt_creds(data)
    if err:
        return jsonify({"error": err}), 400
    region = data.get("region", "")
    iid = data.get("instance_id", "")
    if region not in REGION_CODES or not iid.startswith("ocid1.instance."):
        return jsonify({"error": "参数无效"}), 400
    return jsonify({"job": _start_job(_do_reboot, creds, region, iid)})


def _do_reboot(job_id, creds, region, iid):
    """软重启实例（ACPI 关机再开机），等回到 RUNNING。"""
    import oci
    cfg = _oci_cfg(creds, region)
    comp = oci.core.ComputeClient(cfg)
    inst = comp.get_instance(iid).data
    name = inst.display_name or iid[-12:]
    _job_log(job_id, "实例: %s，正在软重启 ..." % name)
    comp.instance_action(iid, "SOFTRESET")
    _wait_state(comp, iid, "RUNNING", job_id)
    _job_log(job_id, "已回到 RUNNING")
    _job_done(job_id, {"note": "重启完成"})


@app.route("/api/mgmt/ipv6", methods=["POST"])
def mgmt_ipv6():
    data = request.get_json(force=True, silent=True) or {}
    creds, err = _mgmt_creds(data)
    if err:
        return jsonify({"error": err}), 400
    region = data.get("region", "")
    iid = data.get("instance_id", "")
    if region not in REGION_CODES or not iid.startswith("ocid1.instance."):
        return jsonify({"error": "参数无效"}), 400
    return jsonify({"job": _start_job(_do_enable_ipv6, creds, region, iid)})


def _do_enable_ipv6(job_id, creds, region, iid):
    """给实例的 VNIC 分配 IPv6。步骤（幂等，缺啥补啥）：
    VCN 加 IPv6 段 → 子网划 /64 → 路由表加 ::/0 → 安全列表放行 IPv6 → VNIC 分配地址。"""
    import oci
    import ipaddress
    import time as _t
    cfg = _oci_cfg(creds, region)
    comp = oci.core.ComputeClient(cfg)
    vnet = oci.core.VirtualNetworkClient(cfg)
    inst = comp.get_instance(iid).data
    name = inst.display_name or iid[-12:]
    _job_log(job_id, "实例: %s" % name)

    # 1. VNIC 与子网
    atts = comp.list_vnic_attachments(creds["tenancy"], instance_id=iid).data
    if not atts:
        raise RuntimeError("找不到该实例的 VNIC")
    vnic_id = atts[0].vnic_id
    vnic = vnet.get_vnic(vnic_id).data
    subnet = vnet.get_subnet(vnic.subnet_id).data
    vcn = vnet.get_vcn(subnet.vcn_id).data
    _job_log(job_id, "VNIC/子网/VCN 就绪")

    # 2. VCN 加 IPv6 段（Oracle 分配 /56）
    v6blocks = list(getattr(vcn, "ipv6_cidr_blocks", None) or [])
    if not v6blocks:
        _job_log(job_id, "VCN 未启用 IPv6，正在申请 Oracle 分配的 /56 ...")
        vcn = vnet.add_ipv6_vcn_cidr(
            subnet.vcn_id,
            add_vcn_ipv6_cidr_details=oci.core.models.AddVcnIpv6CidrDetails(
                is_oracle_gua_allocation_enabled=True)).data
        v6blocks = list(getattr(vcn, "ipv6_cidr_blocks", None) or [])
        if not v6blocks:
            raise RuntimeError("VCN IPv6 段分配失败")
        _job_log(job_id, "VCN IPv6 段: %s" % v6blocks[0])
    else:
        _job_log(job_id, "VCN 已有 IPv6 段: %s" % v6blocks[0])

    # 3. 子网划 /64（取 /56 的第一个 /64）
    s6blocks = list(getattr(subnet, "ipv6_cidr_blocks", None) or [])
    if not s6blocks:
        net56 = ipaddress.ip_network(v6blocks[0])
        cidr64 = str(next(net56.subnets(new_prefix=64)))
        _job_log(job_id, "子网未划 IPv6，正在分配 %s ..." % cidr64)
        vnet.add_ipv6_subnet_cidr(
            subnet.id,
            oci.core.models.AddSubnetIpv6CidrDetails(
                ipv6_cidr_block=cidr64))
        subnet = vnet.get_subnet(subnet.id).data
        _job_log(job_id, "子网 IPv6: %s" % cidr64)
    else:
        _job_log(job_id, "子网已有 IPv6: %s" % s6blocks[0])

    # 4. 路由表加 ::/0（复用现有 0.0.0.0/0 的 IGW）
    rt = vnet.get_route_table(subnet.route_table_id).data
    rules = list(rt.route_rules or [])
    has_v6 = any(getattr(r, "destination", "") == "::/0" for r in rules)
    if not has_v6:
        igw = ""
        for r in rules:
            if getattr(r, "destination", "") == "0.0.0.0/0":
                igw = getattr(r, "network_entity_id", "")
                break
        if not igw:
            raise RuntimeError("路由表没有 0.0.0.0/0 规则，找不到 Internet 网关")
        rules.append(oci.core.models.RouteRule(
            destination="::/0", network_entity_id=igw))
        vnet.update_route_table(
            rt.id,
            oci.core.models.UpdateRouteTableDetails(route_rules=rules))
        _job_log(job_id, "路由表已加 ::/0")
    else:
        _job_log(job_id, "路由表已有 ::/0")

    # 5. 安全列表放行 IPv6 入站（与 IPv4 一致：全放开，端口由机器防火墙管）
    for sl_id in (subnet.security_list_ids or []):
        sl = vnet.get_security_list(sl_id).data
        irules = list(sl.ingress_security_rules or [])
        has_v6_in = any(":" in (getattr(r, "source", "") or "") for r in irules)
        if not has_v6_in:
            irules.append(oci.core.models.IngressSecurityRule(
                source="::/0", protocol="all"))
            vnet.update_security_list(
                sl_id,
                oci.core.models.UpdateSecurityListDetails(
                    ingress_security_rules=irules))
            _job_log(job_id, "安全列表已放行 IPv6 入站 (::/0)")
        else:
            _job_log(job_id, "安全列表已有 IPv6 入站规则")

    # 6. VNIC 分配 IPv6 地址
    exist = vnet.list_ipv6s(vnic_id=vnic_id).data
    if exist:
        ipv6 = exist[0].ip_address
        _job_log(job_id, "VNIC 已有 IPv6: %s" % ipv6)
    else:
        _job_log(job_id, "正在给 VNIC 分配 IPv6 ...")
        obj = vnet.create_ipv6(
            oci.core.models.CreateIpv6Details(vnic_id=vnic_id)).data
        ipv6 = ""
        for _ in range(24):
            _t.sleep(5)
            cur = vnet.get_ipv6(obj.id).data
            ipv6 = getattr(cur, "ip_address", "") or ""
            if ipv6:
                break
        if not ipv6:
            raise RuntimeError("IPv6 分配后未能读取，请在控制台确认")
        _job_log(job_id, "已分配 IPv6: %s" % ipv6)
    _job_done(job_id, {
        "ipv6": ipv6,
        "note": ("客机内一般会自动获取（SLAAC）；若无地址可尝试 dhclient -6。"
                 "IPv6 防火墙需手动配，在机器上跑这一条：\n"
                 "sudo ip6tables -F && sudo ip6tables -X && "
                 "sudo ip6tables -P INPUT DROP && sudo ip6tables -P FORWARD DROP && "
                 "sudo ip6tables -P OUTPUT ACCEPT && "
                 "sudo ip6tables -A INPUT -i lo -j ACCEPT && "
                 "sudo ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT && "
                 "sudo ip6tables -A INPUT -p tcp --dport 61234 -j ACCEPT && "
                 "sudo ip6tables -A INPUT -p icmpv6 -j ACCEPT && "
                 "sudo netfilter-persistent save")})


def _do_change_ip(job_id, creds, region, iid):
    import oci
    import time as _t
    cfg = _oci_cfg(creds, region)
    comp = oci.core.ComputeClient(cfg)
    vnet = oci.core.VirtualNetworkClient(cfg)
    inst = comp.get_instance(iid).data
    name = inst.display_name or iid[-12:]
    old_pub, _, _ = _vnic_ips(comp, vnet, creds["tenancy"], iid)
    if not old_pub:
        _job_done(job_id, {"note": "该实例没有公网 IP，无需更换"})
        return
    _job_log(job_id, "实例: %s" % name)
    _job_log(job_id, "当前 IP: %s" % old_pub)
    # 预留 IP 不会变，提前提示
    try:
        pubs = vnet.list_public_ips(
            creds["tenancy"], scope="REGION",
            ip_address=old_pub).data
        if pubs and getattr(pubs[0], "lifetime", "") == "RESERVED":
            _job_done(job_id, {"note": "该实例绑定的是预留 IP，无法更换临时 IP；如需换 IP 请先在控制台解绑预留 IP"})
            return
    except Exception as e:  # noqa
        _job_log(job_id, "预留 IP 检查跳过: %s" % str(e)[:120])
    # 官方文档：stop 实例不会释放临时公网 IP（它跟随 VNIC/实例生命周期，
    # 只有 terminate 才释放）。正确换法是删除当前临时 IP 再分配一个新的，
    # 实例保持运行，无需重启。
    atts = comp.list_vnic_attachments(creds["tenancy"], instance_id=iid).data
    if not atts:
        raise RuntimeError("找不到该实例的 VNIC")
    vnic_id = atts[0].vnic_id
    privs = vnet.list_private_ips(vnic_id=vnic_id).data
    primary = next((p for p in privs if getattr(p, "is_primary", False)), None)
    if not primary and privs:
        primary = privs[0]
    if not primary:
        raise RuntimeError("找不到主私网 IP")
    _job_log(job_id, "正在释放当前公网 IP（实例保持运行，无需重启）...")
    cur_pub = vnet.get_public_ip_by_private_ip_id(
        oci.core.models.GetPublicIpByPrivateIpIdDetails(
            private_ip_id=primary.id)).data
    vnet.delete_public_ip(cur_pub.id)
    # 关键：必须等旧 IP 在 OCI 侧彻底删除（查不到为止），再分配新的；
    # 否则数据层 NAT 新旧映射冲突，出站会断（实测）。
    _job_log(job_id, "等待旧 IP 彻底释放...")
    for _ in range(36):
        _t.sleep(5)
        try:
            vnet.get_public_ip(cur_pub.id)
        except Exception as e:  # noqa
            if "404" in str(e):
                break
    else:
        raise RuntimeError("旧 IP 长时间未释放，请稍后重试")
    _t.sleep(10)
    _job_log(job_id, "已释放，正在分配新公网 IP...")
    new_obj = vnet.create_public_ip(
        oci.core.models.CreatePublicIpDetails(
            compartment_id=primary.compartment_id,
            lifetime="EPHEMERAL",
            private_ip_id=primary.id,
        )).data
    new_pub = ""
    for _ in range(24):
        _t.sleep(5)
        cur = vnet.get_public_ip(new_obj.id).data
        new_pub = getattr(cur, "ip_address", "") or ""
        if new_pub:
            break
    if not new_pub:
        new_pub = vnet.get_vnic(vnic_id).data.public_ip or ""
    if not new_pub:
        raise RuntimeError("新 IP 已分配但未能读取，请在控制台确认；实例当前可能没有公网 IP")
    _job_log(job_id, "旧 IP: %s -> 新 IP: %s" % (old_pub, new_pub))
    if new_pub == old_pub:
        _job_done(job_id, {"old_ip": old_pub, "new_ip": new_pub,
                           "note": "分配到的 IP 与之前相同（地址池复用），可再次更换"})
    else:
        _job_done(job_id, {"old_ip": old_pub, "new_ip": new_pub,
                           "note": "实例未重启，SSH 请改用新 IP 连接"})


@app.route("/api/mgmt/jobs/<job_id>")
def mgmt_job(job_id):
    j = mgmt_jobs.get(job_id)
    if not j:
        return jsonify({"error": "任务不存在"}), 404
    return jsonify(j)


@app.route("/")
def index():
    return send_file(os.path.join(PANEL_DIR, "templates", "index.html"))


if __name__ == "__main__":
    init_db()
    _reaper()
    from waitress import serve
    port = int(CONF.get("port", 5887))
    print("OCI 抢机面板启动: http://0.0.0.0:%d" % port, flush=True)
    serve(app, host="0.0.0.0", port=port)
