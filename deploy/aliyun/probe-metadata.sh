# 在沙箱里跑（`run.sh sandbox --acs --apply --exec "$(cat deploy/aliyun/probe-metadata.sh)"`）：看元数据地址能拿到什么。
# 只列目录、看有没有挂云账号的角色（只看名字），不取凭证。
python3 - <<'PY'
import socket
import urllib.request


def get(path, n=400):
    try:
        r = urllib.request.urlopen("http://100.100.100.200" + path, timeout=5)
        return r.status, r.read(n).decode("utf-8", "replace").strip()
    except Exception as e:  # noqa: BLE001
        return "ERR", repr(e)[:160]


code, body = get("/latest/meta-data/")
print("元数据目录:", code, body.replace("\n", " "))
code, body = get("/latest/meta-data/ram/security-credentials/")
print("云账号角色:", code, ("有角色: " + body.split()[0][:60]) if code == 200 and body else (body or "空"))
for path in ("instance-id", "region-id", "zone-id", "vpc-id", "private-ipv4", "owner-account-id", "instance/instance-type"):
    print(path + ":", *get("/latest/meta-data/" + path, 80))
for port in (80, 443):
    s = socket.socket()
    s.settimeout(4)
    try:
        s.connect(("100.100.100.200", port))
        print(f"TCP {port}: 通")
    except Exception as e:  # noqa: BLE001
        print(f"TCP {port}: 不通（{type(e).__name__}）")
    finally:
        s.close()
PY
echo "--- 身份和路由:"
id
(ip -4 addr 2>/dev/null | grep "inet " ; ip route 2>/dev/null) | head -8
cat /etc/resolv.conf 2>/dev/null | head -4
