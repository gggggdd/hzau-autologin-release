# -*- coding: utf-8 -*-
"""
华中农业大学校园网（深澜 Srun）自动认证脚本。

流程：等待网络就绪 -> 查询在线状态 -> get_challenge 取 token ->
本地计算 HMAC-MD5 / xEncode(SBXTEA) / 自定义 base64 / SHA1 -> srun_portal 登录 -> 验证在线。

算法严格对照门户页面 https://rz.hzau.edu.cn/static/themes/pro/js/Portal.js 实现：
  hmd5   = hex( HMAC-MD5( key=token, msg=password ) )        # blueimp-md5: md5(password, token)
  info   = '{SRBX1}' + b64_custom( xencode(JSON.stringify(info), token) )
  chkstr = token+username +token+hmd5 +token+acid +token+ip
         + token+'200' +token+'1' +token+info
  chksum = hex( SHA1(chkstr) )                               # js-sha1
"""

import base64
import ctypes
import hashlib
import hmac
import http.client
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request

if getattr(sys, 'frozen', False):
    # PyInstaller 单文件模式：__file__ 指向临时解压目录 _MEIxxxxxx，
    # 必须用 sys.executable 才能拿到 exe 真实所在目录（config/password/log 都放这里）。
    BASE_DIR = os.path.dirname(os.path.abspath(sys.executable))
else:
    BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, 'config.json')
PASSWORD_PATH = os.path.join(BASE_DIR, 'password.bin')
LOG_PATH = os.path.join(BASE_DIR, 'srun_login.log')

M32 = 0xFFFFFFFF
B64_ALPHA = 'LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA'

SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE


def log(msg):
    line = time.strftime('%Y-%m-%d %H:%M:%S ') + msg
    try:
        print(line)
    except OSError:
        pass
    try:
        with open(LOG_PATH, 'a', encoding='utf-8') as f:
            f.write(line + '\n')
    except OSError:
        pass


def alert(msg):
    """打包版是 noconsole（print 不可见），关键操作失败时用 MessageBox 弹窗提示用户。"""
    try:
        ctypes.windll.user32.MessageBoxW(0, msg, 'HZAU-AutoLogin', 0x40)
    except Exception:
        pass


# 当默认路由被 VPN（Radmin VPN / Clash TUN 等虚拟网卡）占用导致门户不可达时，
# 自动寻找另一块能连通认证服务器的网卡，并强制后续 HTTPS 请求从该网卡源地址发出。
_SRC_IP = None          # 强制使用的源 IP；None 表示走系统默认路由


def _resolve_server_ip(server_host):
    """解析认证服务器主机名，返回第一个 IPv4 地址；失败返回 None。"""
    try:
        return socket.getaddrinfo(server_host, 443, socket.AF_INET,
                                  socket.SOCK_STREAM)[0][4][0]
    except OSError:
        return None


def list_local_ips():
    """枚举本机各网卡的 IPv4 地址（去重、去掉回环）。"""
    ips = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None,
                                       socket.AF_INET, socket.SOCK_DGRAM):
            ip = info[4][0]
            if ip not in ips and not ip.startswith('127.'):
                ips.append(ip)
    except OSError:
        pass
    return ips


def _probe_source(ip, server_ip):
    """从指定源 IP 发起一次到认证服务器的 TCP 连接测试（SYN 即回，不发业务数据）。"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(3)
        try:
            s.bind((ip, 0))
            s.connect((server_ip, 443))
            return True
        finally:
            s.close()
    except OSError:
        return False


def switch_to_reachable_nic(server_host, cur_ip):
    """默认路由被 VPN 抢走时：遍历本机网卡，找一块能连通认证服务器的网卡并切换源 IP。

    返回切换后的源 IP；找不到返回 None。只尝试一次。
    """
    global _SRC_IP
    server_ip = _resolve_server_ip(server_host)
    if not server_ip:
        return None
    for ip in list_local_ips():
        if ip == cur_ip or ip == _SRC_IP:
            continue
        if _probe_source(ip, server_ip):
            _SRC_IP = ip
            return ip
    return None


def http_get(url, timeout=10):
    ua = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'}
    if _SRC_IP and url.lower().startswith('https://'):
        # 已切换到特定网卡：绑定源地址发 HTTPS 请求，避免仍走被 VPN 抢走的默认路由
        p = urllib.parse.urlparse(url)
        conn = http.client.HTTPSConnection(p.hostname, p.port or 443, timeout=timeout,
                                           context=SSL_CTX, source_address=(_SRC_IP, 0))
        try:
            conn.request('GET', p.path + ('?' + p.query if p.query else ''), headers=ua)
            return conn.getresponse().read().decode('utf-8', 'replace')
        finally:
            conn.close()
    req = urllib.request.Request(url, headers=ua)
    with urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX) as resp:
        return resp.read().decode('utf-8', 'replace')


def parse_jsonp(text):
    """兼容纯 JSON 与 JSONP 包裹两种返回。"""
    start = text.find('{')
    end = text.rfind('}')
    if start == -1 or end == -1:
        raise ValueError('响应不是 JSON: ' + text[:120])
    return json.loads(text[start:end + 1])


# ---------------- Srun 加密算法（对照 Portal.js 逐行实现） ----------------

def _s(a, keep_len):
    """JS s(): 字符串按 charCodeAt 小端打包为 32 位整数数组；keep_len 时在末尾追加长度。"""
    v = []
    c = len(a)
    for i in range(0, c, 4):
        chunk = 0
        for j in range(4):
            if i + j < c:
                chunk |= (ord(a[i + j]) & M32) << (8 * j)
        v.append(chunk & M32)
    if keep_len:
        v.append(c)
    return v


def _l(v):
    """JS l()（encode 路径，b=false）：每个 32 位整数还原为 4 个低字节字符。"""
    out = []
    for x in v:
        x &= M32
        for j in range(4):
            out.append(chr((x >> (8 * j)) & 0xFF))
    return ''.join(out)


def xencode(msg, key):
    """JS encode(): SBXTEA 加密（delta=0x9E3779B9，掩码 0xFFFFFFFF）。"""
    if msg == '':
        return ''
    v = _s(msg, True)
    k = _s(key, False)
    while len(k) < 4:
        k.append(0)
    n = len(v) - 1
    z = v[n]
    y = v[0]
    delta = 0x86014019 | 0x183639A0          # = 0x9E3779B9
    q = 6 + 52 // (n + 1)                     # Math.floor(6 + 52/(n+1))
    d = 0
    mask = 0x8CE0D9BF | 0x731F2640            # = 0xFFFFFFFF
    vmask = 0xEFB8D130 | 0x10472ECF           # = 0xFFFFFFFF
    nmask = 0xBB390742 | 0x44C6F8BD           # = 0xFFFFFFFF
    while q > 0:
        q -= 1
        d = (d + delta) & mask
        e = (d >> 2) & 3
        p = 0
        while p < n:
            y = v[p + 1]
            m = (z >> 5) ^ ((y << 2) & M32)
            m = (m + ((y >> 3) ^ ((z << 4) & M32) ^ (d ^ y))) & M32
            m = (m + (k[(p & 3) ^ e] ^ z)) & M32
            z = v[p] = (v[p] + m) & vmask
            p += 1
        y = v[0]
        m = (z >> 5) ^ ((y << 2) & M32)
        m = (m + ((y >> 3) ^ ((z << 4) & M32) ^ (d ^ y))) & M32
        m = (m + (k[(n & 3) ^ e] ^ z)) & M32
        z = v[n] = (v[n] + m) & nmask
    return _l(v)


_STD_B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
_B64_TRANS = str.maketrans(_STD_B64, B64_ALPHA)


def custom_b64(s):
    data = bytes(ord(ch) & 0xFF for ch in s)
    return base64.b64encode(data).decode('ascii').translate(_B64_TRANS)


def encode_info(username, password, ip, acid, enc_ver, token):
    info_json = json.dumps(
        {'username': username, 'password': password, 'ip': ip,
         'acid': acid, 'enc_ver': enc_ver},
        separators=(',', ':'), ensure_ascii=False)
    return '{SRBX1}' + custom_b64(xencode(info_json, token))


def calc_login_params(username, password, ip, acid, token):
    """按 Portal.js _loginAccount 组装登录参数。"""
    hmd5 = hmac.new(token.encode('ascii'), password.encode('utf-8'),
                    hashlib.md5).hexdigest()
    info = encode_info(username, password, ip, acid, 'srun_bx1', token)
    chkstr = (token + username + token + hmd5 + token + str(acid) +
              token + ip + token + '200' + token + '1' + token + info)
    chksum = hashlib.sha1(chkstr.encode('utf-8')).hexdigest()
    return hmd5, info, chksum


# ---------------- DPAPI 密码读取 ----------------

class DATA_BLOB(ctypes.Structure):
    _fields_ = [('cbData', ctypes.c_uint),
                ('pbData', ctypes.POINTER(ctypes.c_char))]


def load_password():
    with open(PASSWORD_PATH, 'r', encoding='ascii') as f:
        blob = base64.b64decode(f.read().strip())
    buf = ctypes.create_string_buffer(blob, len(blob))
    bin_ = DATA_BLOB(len(blob), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
    bout = DATA_BLOB(0, None)
    ok = ctypes.windll.crypt32.CryptUnprotectData(
        ctypes.byref(bin_), None, None, None, None, 0, ctypes.byref(bout))
    if not ok:
        err = ctypes.GetLastError()
        raise OSError('DPAPI 解密失败（WinError %d）：password.bin 与当前 Windows 用户不匹配。请重新保存密码（打包版: 运行安装目录里的 change_password.bat；源码版: encrypt_password.ps1）' % err)
    try:
        return ctypes.string_at(bout.pbData, bout.cbData).decode('utf-8')
    finally:
        ctypes.windll.kernel32.LocalFree(bout.pbData)


# ---------------- 网络流程 ----------------

def host_of(server):
    """从 server 配置里取出主机名（如 rz.hzau.edu.cn）。"""
    return urllib.parse.urlparse(server).hostname or ''


def get_local_ip(server_host=''):
    """取本机 IP：优先"向认证服务器地址选路"（UDP connect 不发真实数据包，仅让系统选路由）。

    原先固定连 223.5.5.5 取默认路由出口 IP，在装有 Radmin VPN / Clash TUN 等
    虚拟网卡的机器上会取到 VPN 的假 IP（如 26.x），导致认证永远失败——这是
    "卡住 + E2620 already online" 的根源。改为向认证服务器选路后，只要校园网
    可达，取到的就是校园网物理网卡 IP。
    """
    targets = []
    if server_host:
        try:
            for info in socket.getaddrinfo(server_host, 443, socket.AF_INET, socket.SOCK_STREAM):
                ip = info[4][0]
                if ip not in targets:
                    targets.append(ip)
        except OSError:
            pass
    targets.append('223.5.5.5')          # 解析失败时的回退：老逻辑默认出口
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        for ip in targets:
            try:
                s.connect((ip, 443 if not ip.startswith('223.5.') else 80))
                return s.getsockname()[0]
            except OSError:
                continue
        raise OSError('无法确定本机 IP（所有选路目标均不可达）')
    finally:
        s.close()


def is_apipa(ip):
    """169.254.x.x 是 DHCP 失败后 Windows 自配的地址，等同于"没有 IP"。"""
    return ip.startswith('169.254.')


def is_elevated():
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def _run_cmd(args, timeout=90):
    """静默执行命令（pythonw 下用 CREATE_NO_WINDOW 防止黑框闪烁）。"""
    try:
        r = subprocess.run(args, capture_output=True, timeout=timeout,
                           creationflags=0x08000000)  # CREATE_NO_WINDOW
        return r.returncode
    except Exception as e:
        log('命令执行失败 %s: %s' % (' '.join(args), e))
        return -1


def get_local_ip_if_any(server_host=''):
    try:
        return get_local_ip(server_host)
    except OSError:
        return None


def run_repair(elevated):
    """网络修复：刷新 DNS 缓存；有管理员权限时再做一次 DHCP 续租（火绒修复的核心动作）。"""
    log('执行网络修复（管理员权限: %s）...' % elevated)
    _run_cmd(['ipconfig', '/flushdns'])
    if elevated:
        cur = get_local_ip_if_any()
        if cur and is_apipa(cur):
            _run_cmd(['ipconfig', '/release'], timeout=60)
        _run_cmd(['ipconfig', '/renew'], timeout=150)
    else:
        log('无管理员权限，跳过 DHCP 续租，仅被动等待')


def portal_reachable(server, ac_id):
    try:
        return bool(get_portal_ip(server, ac_id))
    except Exception:
        return False


def wait_for_network(cfg):
    """等待网络就绪；长时间拿不到 IP 或门户不可达时，周期性做 DNS/DHCP 修复。

    返回 True 表示可以继续认证；False 表示放弃（写明日志）。
    """
    server = cfg['server']
    ac_id = cfg.get('ac_id', '5')
    server_host = host_of(server)
    max_wait = int(cfg.get('network_wait_seconds', 300))
    repair_interval = int(cfg.get('repair_interval_seconds', 60))
    elevated = is_elevated()
    deadline = time.time() + max_wait
    next_repair = time.time() + 45      # 先给 DHCP 45 秒机会，卡住才开始修复
    flushed_at = 0.0
    hint_sent = False
    repaired = 0
    while True:
        ip = get_local_ip_if_any(server_host)
        if _SRC_IP:                     # 已自动切到可用网卡，以它为准
            ip = _SRC_IP
        if ip and not is_apipa(ip):
            if portal_reachable(server, ac_id):
                log('网络就绪，本机 IP: %s' % ip)
                return True
            if time.time() - flushed_at > 30:
                _run_cmd(['ipconfig', '/flushdns'])
                flushed_at = time.time()
                log('有 IP (%s) 但门户不可达，已刷新 DNS 缓存' % ip)
                if not hint_sent:
                    hint_sent = True
                    log('提示: 门户持续不可达。若开着 Radmin VPN / Clash TUN 等 VPN 或代理虚拟网卡，'
                        '请断开后重试——虚拟网卡会抢默认路由，导致程序拿错网卡 IP')
                    log('正在尝试自动切换到能连通认证服务器的网卡...')
                    alt = switch_to_reachable_nic(server_host, ip)
                    if alt:
                        log('已切换源网卡 IP: %s（后续请求将从该网卡发出）' % alt)
                    else:
                        log('未找到可用的备用网卡；也可手动断开 VPN 后重试')
        else:
            log('等待 DHCP 分配 IP...%s' % ('（当前为 169.254 自动私网地址）' if ip else ''))
            if time.time() >= next_repair:
                run_repair(elevated)
                repaired += 1
                next_repair = time.time() + repair_interval
        if time.time() >= deadline:
            log('%d 秒内网络未就绪（共修复 %d 次），放弃本次自动认证' % (max_wait, repaired))
            return False
        time.sleep(5)


def get_portal_ip(server, ac_id):
    """从门户页面 CONFIG.ip 里读服务器认定的客户端 IP（与浏览器行为一致）。"""
    html = http_get('%s/srun_portal_pc?ac_id=%s&theme=pro' % (server, ac_id))
    m = re.search(r'ip\s*:\s*"(\d{1,3}(?:\.\d{1,3}){3})"', html)
    return m.group(1) if m else None


def check_online(server):
    try:
        res = parse_jsonp(http_get(server + '/cgi-bin/rad_user_info?callback=_'))
    except Exception:
        return False
    return res.get('error') == 'ok'


def get_challenge(server, username, ip):
    url = ('%s/cgi-bin/get_challenge?%s' % (server, urllib.parse.urlencode(
        {'callback': '_jc', 'username': username, 'ip': ip})))
    res = parse_jsonp(http_get(url))
    if res.get('error') != 'ok' or not res.get('challenge'):
        raise RuntimeError('get_challenge 失败: %r' % res)
    return res['challenge'], res.get('client_ip') or ip


def do_login(cfg, username, password, ip):
    server = cfg['server']
    acid = cfg.get('ac_id', '5')
    token, srv_ip = get_challenge(server, username, ip)
    hmd5, info, chksum = calc_login_params(username, password, srv_ip, acid, token)
    params = {
        'callback': '_lg',
        'action': 'login',
        'username': username,
        'password': '{MD5}' + hmd5,
        'os': 'Windows NT',
        'name': 'Windows',
        'double_stack': 0,
        'chksum': chksum,
        'info': info,
        'ac_id': acid,
        'ip': srv_ip,
        'n': 200,
        'type': 1,
    }
    res = parse_jsonp(http_get(server + '/cgi-bin/srun_portal?' + urllib.parse.urlencode(params)))
    return res, srv_ip


# ---------------- 错误提示（仅用于写日志，不影响认证逻辑） ----------------

def explain_error(emsg):
    """把 Srun 错误码 / 常见异常翻译成直接可用的中文提示。"""
    text = str(emsg)
    low = text.lower()
    if 'password_error' in text or 'E2901' in text:
        return '密码错误。检查是否大小写/多余空格；用运营商宽带时 domain 需填 @cmcc/@telecom/@unicom'
    if 'username_error' in text:
        return '学号错误。username 应为纯学号，@后缀要放在 domain 字段'
    if 'E2620' in text or 'already online' in text:
        return '该账号已在线 / 在线设备数超限（E2620）：可能是你当前的上网会话，或手机等其他设备。能正常上网可忽略；上不了网请到 zizhu.hzau.edu.cn 下线其他设备'
    if 'E2531' in text:
        return '客户端 IP 与服务器记录不一致（E2531），脚本已自动改用服务器 IP 重试；仍失败请重连网络后重试'
    if 'no_response_data_error' in text or 'AUTH failed' in text or 'respond timeout' in text:
        return '认证服务器响应超时/繁忙（高峰期常见），或本机网卡选错——开着 Radmin VPN / Clash TUN 等虚拟网卡会抢默认路由，请断开后重试'
    if 'timed out' in low or 'timeout' in low:
        return '请求超时：校园网高峰期门户繁忙、或本机未真正联网。可稍后重试，或运行诊断工具 diagnose.bat 检查'
    if 'get_challenge' in text:
        return '取不到认证令牌（门户繁忙或网络受限），高峰期常见，可稍后重试'
    return ''


def online_status(server):
    """返回 (是否在线, 服务器原始返回摘要)，供认证后核对与排障。"""
    try:
        text = http_get(server + '/cgi-bin/rad_user_info?callback=_')
        res = parse_jsonp(text)
        return res.get('error') == 'ok', json.dumps(res, ensure_ascii=False)[:200]
    except Exception as e:
        return False, '查询失败: %s' % e


def run_once(cfg, password):
    server = cfg['server']
    domain = cfg.get('domain', '')
    username = cfg['username'] + domain
    if check_online(server):
        log('当前已在线，无需认证')
        return 0

    # 客户端 IP：优先用门户页面注入的（与浏览器一致），失败再用本机路由探测
    try:
        ip = get_portal_ip(server, cfg.get('ac_id', '5'))
    except Exception as e:
        log('获取门户页面 IP 失败(%s)，改用本机探测' % e)
        ip = None
    if not ip:
        ip = _SRC_IP or get_local_ip(host_of(server))

    last_msg = ''
    for attempt in range(1, int(cfg.get('max_attempts', 3)) + 1):
        try:
            res, _ = do_login(cfg, username, password, ip)
        except Exception as e:
            last_msg = '请求异常: %s' % e
            log('第 %d 次尝试: %s' % (attempt, last_msg))
            hint = explain_error(e)
            if hint:
                log('  => %s' % hint)
        else:
            err = res.get('error')
            if err == 'ok':
                log('认证成功（IP %s）' % ip)
                time.sleep(2)
                ok, detail = online_status(server)
                log('在线验证: %s' % ('通过' if ok else '未确认'))
                if not ok:
                    log('  rad_user_info 返回: %s（登录成功但未确认在线，多为多设备共享同一账号被顶下线）' % detail)
                return 0
            emsg = res.get('error_msg') or res.get('ecode') or json.dumps(res, ensure_ascii=False)[:160]
            last_msg = str(emsg)
            log('第 %d 次尝试失败: %s' % (attempt, last_msg))
            hint = explain_error(emsg)
            if hint:
                log('  => %s' % hint)
            # E2531: Client IP 不匹配 -> 用服务器返回的 client_ip 重试一次
            if emsg.startswith('E2531'):
                try:
                    _, cip = get_challenge(server, username, ip)
                    if cip and cip != ip:
                        log('按服务器提示改用 IP %s 重试' % cip)
                        ip = cip
                except Exception:
                    pass
            # E2620: 账号已在线/在线数超限 -> 复核在线状态，不按"失败"处理
            if 'E2620' in last_msg or 'already online' in last_msg.lower():
                log('提示: E2620 = 该账号已在线（可能是你当前的上网会话，或手机等其他设备）。'
                    '能正常上网可忽略；上不了网请到 zizhu.hzau.edu.cn 下线其他设备后重试。')
                ok, detail = online_status(server)
                log('复核在线状态: %s' % ('在线，无需重复登录' if ok else '不在线: %s' % detail))
                return 0 if ok else 2
            # 凭证类错误重试无意义
            if any(k in last_msg for k in ('password_error', 'E2901', 'username_error')):
                break
        time.sleep(int(cfg.get('retry_interval', 3)))
    log('认证最终失败: %s' % last_msg)
    return 2


def main():
    global _SRC_IP
    _SRC_IP = None      # 每次独立运行都重新探测，不残留上次的网卡切换
    log('启动: 目录 %s' % BASE_DIR)
    try:
        with open(CONFIG_PATH, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
    except Exception as e:
        log('读取 config.json 失败: %s' % e)
        alert('未找到配置文件 config.json（期望位置: ' + BASE_DIR + '\\config.json）。\n\n'
              '【打包版】请双击运行 install.bat 完成安装，装好后无需手动运行 exe；\n'
              '配置与日志都在安装目录 %LOCALAPPDATA%\\HZAU-AutoLogin\\ 下。\n\n'
              '如果你是在解压目录里直接双击 hzau-autologin.exe，那是不会生效的——请先运行 install.bat。')
        return 1
    if not (cfg.get('server') and cfg.get('username')):
        msg = 'config.json 缺少 server 或 username（文件: %s）' % CONFIG_PATH
        log(msg)
        alert('配置不完整：config.json 缺少 server 或 username。\n请重新运行 install.bat 填写学号。')
        return 1
    try:
        password = load_password()
    except FileNotFoundError:
        log('未找到 password.bin（打包版请重跑 install.bat，或运行安装目录里的 change_password.bat 重新保存密码）')
        alert('未找到密码文件 password.bin。\n\n请重新运行 install.bat 输入学号和密码，'
              '或运行安装目录 %LOCALAPPDATA%\\HZAU-AutoLogin\\ 里的 change_password.bat。')
        return 1
    except Exception as e:
        msg = '读取密码失败: %s' % e
        log(msg)
        alert('密码读取失败：' + str(e) + '\n\n请用平时登录 Windows 的账号重新运行 install.bat 保存密码'
              '（密码与 Windows 用户绑定，用管理员账号装会解不开）。')
        return 1

    if not wait_for_network(cfg):
        return 1
    return run_once(cfg, password)


if __name__ == '__main__':
    sys.exit(main())
