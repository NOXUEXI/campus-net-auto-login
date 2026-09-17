import os, re, shutil, sqlite3, sys, tempfile

PAT = re.compile(
    r"(10\.\d{1,3}\.\d{1,3}\.\d{1,3}"
    r"|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}"
    r"|192\.168\.\d{1,3}\.\d{1,3}"
    r"|portal|srun|eportal|drcom|dr\.com|ac_portal|auth|wifi|wlan"
    r"|campus|校园|无线|认证|login|10\.\d)",
    re.I,
)

BASE = os.path.expandvars(r"%LOCALAPPDATA%")
TARGETS = {
    "Edge": os.path.join(BASE, r"Microsoft\Edge\User Data\Default\History"),
    "Chrome": os.path.join(BASE, r"Google\Chrome\User Data\Default\History"),
}

tmp = tempfile.mkdtemp(prefix="hist_")
for name, src in TARGETS.items():
    if not os.path.exists(src):
        print(f"[{name}] 未找到 History 文件")
        continue
    dst = os.path.join(tmp, name + ".db")
    try:
        shutil.copy2(src, dst)
    except Exception as e:
        print(f"[{name}] 复制失败: {e}")
        continue

    con = sqlite3.connect(dst)
    cur = con.cursor()
    try:
        rows = cur.execute(
            "SELECT url, title, visit_count, datetime(last_visit_time/1000000-11644473600,'unixepoch','localtime') "
            "FROM urls ORDER BY last_visit_time DESC LIMIT 6000"
        ).fetchall()
    except Exception as e:
        print(f"[{name}] 查询失败: {e}")
        con.close()
        continue
    con.close()

    hits = [r for r in rows if PAT.search(r[0] or "")]
    print(f"\n===== {name}: 命中 {len(hits)} 条（共扫描 {len(rows)} 条）=====")
    seen = set()
    for url, title, vc, t in hits:
        host = re.sub(r"^https?://", "", url).split("/")[0]
        key = host
        if key in seen:
            continue
        seen.add(key)
        print(f"  [{t}] 访问{vc}次  {url[:130]}")
        if len(seen) >= 40:
            print("  ...(截断)")
            break
