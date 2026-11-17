#!/usr/bin/env python3
"""
macOS 云 runner「广撒网」轮询器

背景：GitHub 的 macos-15 排队 job 会在第 15 分钟被系统清掉（实测），
      老老实实排一个永远抢不到。所以这里同时挂 N 个 dispatch run，
      哪个先被 runner 接走就用哪个，其余全部取消；
      拿到机器 → 等构建 → 成功就下载 IPA 并退出。

用法：GH_TOKEN=xxx nohup python3 scripts/mac_shotgun.py >> shotgun.out 2>&1 &
"""

import json, os, sys, time, urllib.request, zipfile
from datetime import datetime

OWNER, REPO, WORKFLOW, REF = "670489857", "mst-pump-ios", "build.yml", "main"
LABEL = "macos-15"
SHOTS = 5              # 同时挂几个
LOOP = 30              # 轮询间隔
API = "https://api.github.com"
TOKEN = os.environ.get("GH_TOKEN", "").strip()
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "out")
LOG = os.path.join(ROOT, "shotgun.log")


def log(m):
    line = f"[{datetime.now().strftime('%H:%M:%S')}] {m}"
    print(line, flush=True)
    open(LOG, "a").write(line + "\n")


def api(path, method="GET", payload=None):
    req = urllib.request.Request(
        path if path.startswith("http") else API + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        method=method,
    )
    for k, v in (("Authorization", f"token {TOKEN}"),
                 ("Accept", "application/vnd.github+json"),
                 ("Content-Type", "application/json")):
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read()
        return json.loads(body) if body else None


def job(run_id):
    try:
        jobs = api(f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}/jobs")["jobs"]
        j = jobs[0]
        return j["status"], j["conclusion"], j.get("runner_name") or ""
    except Exception:
        return "gone", None, ""


def dispatch():
    api(f"/repos/{OWNER}/{REPO}/actions/workflows/{WORKFLOW}/dispatches",
        "POST", {"ref": REF, "inputs": {"runner_label": LABEL}})
    time.sleep(3)
    runs = api(f"/repos/{OWNER}/{REPO}/actions/runs?per_page=5")["workflow_runs"]
    for r in runs:
        if r["name"] == "build-ipa" and r["status"] in ("queued", "in_progress"):
            return r["id"]
    return None


def cancel(run_id):
    try:
        api(f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}/cancel", "POST")
    except Exception:
        pass


def fetch_ipa(run_id):
    arts = api(f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}/artifacts")["artifacts"]
    for a in arts:
        if a["name"].startswith("MstPump-unsigned-ipa"):
            os.makedirs(OUT, exist_ok=True)
            z = os.path.join(OUT, "artifact.zip")
            os.system(f'curl -sL -H "Authorization: token {TOKEN}" "{a["archive_download_url"]}" -o "{z}"')
            with zipfile.ZipFile(z) as zz:
                zz.extractall(OUT)
            ipa = os.path.join(OUT, "MstPump-unsigned.ipa")
            log(f"✅ IPA 已下载: {ipa} ({os.path.getsize(ipa)//1024} KB)")
            return ipa
    return None


def main():
    if not TOKEN:
        sys.exit("缺少 GH_TOKEN")
    log(f"广撒网启动：每轮挂 {SHOTS} 个 macos-15")
    active = {}
    while True:
        # 清理已结束的
        for rid in list(active):
            st, con, runner = job(rid)
            if st in ("completed", "gone"):
                log(f"run {rid} → {st}/{con}")
                if con == "success":
                    cancel_all_others(active, keep=rid)
                    if fetch_ipa(rid):
                        return
                active.pop(rid, None)

        # 有人拿到机器了 → 只留它
        running = [rid for rid in active if job(rid)[0] == "in_progress"]
        if running:
            keep = running[0]
            for rid in list(active):
                if rid != keep:
                    log(f"run {rid} 取消（已由 {keep} 抢到机器）")
                    cancel(rid)
                    active.pop(rid, None)
            log(f"回归单人模式，等待 run {keep} 构建结果")
            time.sleep(LOOP)
            continue

        # 补足 shotgun
        while len(active) < SHOTS:
            rid = dispatch()
            if rid and rid not in active:
                active[rid] = time.time()
                log(f"投出 run {rid}（在飞 {len(active)}）")
            else:
                break
        time.sleep(LOOP)


def cancel_all_others(active, keep):
    for rid in list(active):
        if rid != keep:
            cancel(rid)


if __name__ == "__main__":
    main()
