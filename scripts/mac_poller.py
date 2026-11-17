#!/usr/bin/env python3
"""
macOS 云构建轮询器 —— 一直探测可用的 GitHub-hosted macOS runner，
拿到机器就跑 build-ipa，产出未签名 IPA 并自动下载。

策略：
  1. 依次尝试多个 runner 标签（macos-15 / macos-14 / macos-13）
  2. 每次 dispatch 后最多等 QUEUE_TIMEOUT 秒；仍然是 queued 就取消，换下一个标签
  3. 一旦某次运行进入 in_progress，就等到结束：
       success  -> 下载 artifact 到 ./out/
       failure  -> 记录日志，继续下一轮
  4. 无限循环，直到成功（或达到 MAX_ROUNDS）

用法：
  GH_TOKEN=xxx python3 scripts/mac_poller.py
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
import zipfile
from datetime import datetime, timezone

OWNER = "670489857"
REPO = "mst-pump-ios"
WORKFLOW = "build.yml"
REF = "main"

LABELS = ["macos-15", "macos-14", "macos-13"]
QUEUE_TIMEOUT = 240        # 排队超过 4 分钟就换标签重试
POLL_INTERVAL = 20         # 状态轮询间隔（秒）
MAX_ROUNDS = 10_000

TOKEN = os.environ.get("GH_TOKEN", "").strip()
API = "https://api.github.com"
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "out")
LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "poller.log")


def log(msg: str) -> None:
    line = f"[{datetime.now().strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def api(path: str, method: str = "GET", payload=None):
    url = path if path.startswith("http") else f"{API}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"token {TOKEN}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read()
        if resp.status == 204 or not body:
            return None
        return json.loads(body)


def latest_run():
    runs = api(f"/repos/{OWNER}/{REPO}/actions/runs?per_page=5").get("workflow_runs", [])
    for r in runs:
        if r["name"] == "build-ipa":
            return r
    return None


def job_state(run_id: int):
    jobs = api(f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}/jobs").get("jobs", [])
    if not jobs:
        return None, None
    j = jobs[0]
    return j["status"], j["conclusion"]


def cancel(run_id: int):
    try:
        api(f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}/cancel", method="POST")
        log(f"run {run_id} 已取消（排队超时）")
    except Exception as e:
        log(f"取消 run {run_id} 失败: {e}")


def dispatch(label: str) -> int | None:
    try:
        api(
            f"/repos/{OWNER}/{REPO}/actions/workflows/{WORKFLOW}/dispatches",
            method="POST",
            payload={"ref": REF, "inputs": {"runner_label": label}},
        )
        time.sleep(4)
        r = latest_run()
        if r and r["event"] == "workflow_dispatch":
            log(f"已触发 {label} → run {r['id']}")
            return r["id"]
    except Exception as e:
        log(f"dispatch {label} 失败: {e}")
    return None


def download_artifact(run_id: int) -> str | None:
    arts = api(f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}/artifacts").get("artifacts", [])
    for a in arts:
        if not a["name"].startswith("MstPump-unsigned-ipa"):
            continue
        os.makedirs(OUT_DIR, exist_ok=True)
        tmp = os.path.join(OUT_DIR, "artifact.zip")
        req = urllib.request.Request(a["archive_download_url"])
        req.add_header("Authorization", f"token {TOKEN}")
        with urllib.request.urlopen(req, timeout=120) as resp, open(tmp, "wb") as f:
            f.write(resp.read())
        with zipfile.ZipFile(tmp) as z:
            z.extractall(OUT_DIR)
        ipa = os.path.join(OUT_DIR, "MstPump-unsigned.ipa")
        log(f"artifact 下载完成 → {ipa} ({os.path.getsize(ipa)//1024} KB)")
        return ipa
    log("该次运行没有 artifact")
    return None


def main():
    if not TOKEN:
        print("缺少 GH_TOKEN", file=sys.stderr)
        sys.exit(1)

    log("轮询器启动，目标：抢一台免费的 macOS runner")
    round_no = 0
    while round_no < MAX_ROUNDS:
        round_no += 1
        for label in LABELS:
            run_id = dispatch(label)
            if not run_id:
                continue
            waited = 0
            while waited < QUEUE_TIMEOUT:
                status, conclusion = job_state(run_id)
                if status == "in_progress":
                    log(f"{label} 抢到机器了！run {run_id} 开始构建")
                    break
                if status == "completed":
                    log(f"{label} run {run_id} 直接结束: {conclusion}")
                    break
                time.sleep(POLL_INTERVAL)
                waited += POLL_INTERVAL
            else:
                cancel(run_id)
                continue

            # 进入构建阶段或已结束 → 等结果
            last_note = ""
            while True:
                status, conclusion = job_state(run_id)
                if status == "completed":
                    break
                if status == "queued":
                    # 构建中途被踢回队列（极少见）
                    pass
                note = f"{status}/{conclusion}"
                if note != last_note:
                    log(f"状态: {note}")
                    last_note = note
                time.sleep(POLL_INTERVAL)

            if conclusion == "success":
                log("✅ 构建成功")
                download_artifact(run_id)
                return
            log(f"❌ 本次失败: {conclusion}，换下一个标签继续探测")
        log(f"第 {round_no} 轮全部排队，休眠 60s 再试")
        time.sleep(60)


if __name__ == "__main__":
    main()
