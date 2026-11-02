#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sync_targets.py — 从上游同步回程路由目标与追踪参数到 nq-route.sh

上游来源:
  - https://run.NodeQuality.com   (LloydAsp/NodeQuality: nexttrace 版本锁定)
  - https://Net.Check.Place       (xykt/NetQuality: 回程目标域名/省份/追踪参数)
  - xykt/NetQuality ref/province.json 与 ref/AS_Mapping.txt

同步内容(自动改写 nq-route.sh 中 >>> SYNC:xxx >>> 标记块):
  1. SYNC:CONFIG      追踪参数与默认省份、域名后缀、nexttrace 版本
  2. SYNC:PROV        省份表
  3. SYNC:ASMAPPING   ASN 名称映射
告警(不自动改, 开 issue 提醒人工移植):
  - 上游 nexttrace_route / get_route_mode 判定逻辑变化(参数归一化后指纹比对)

报告输出到 stdout 与 .github/sync-report.md; 提取失败时退出码 1。
"""
import hashlib
import json
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "nq-route.sh"
HASH_FILE = REPO / ".github" / "scripts" / "upstream.sha256"
REPORT = REPO / ".github" / "sync-report.md"

URL_NQ = "https://run.NodeQuality.com"
URL_NET = "https://Net.Check.Place"
URL_REF = "https://raw.githubusercontent.com/xykt/NetQuality/main/ref"

MARK_CONFIG = ("# >>> SYNC:CONFIG >>>", "# <<< SYNC:CONFIG <<<")
MARK_PROV = ("# >>> SYNC:PROV >>>", "# <<< SYNC:PROV <<<")
MARK_ASMAP = ("# >>> SYNC:ASMAPPING >>>", "# <<< SYNC:ASMAPPING <<<")


class SyncError(Exception):
    pass


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "nq-route-sync/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", errors="replace")


def extract_function(src: str, name: str) -> str:
    """按大括号配对提取 bash 函数体(函数内 awk 程序的花括号自身是配对的)"""
    m = re.search(rf"^{re.escape(name)}\(\)\s*\{{", src, re.M)
    if not m:
        raise SyncError(f"上游脚本中找不到函数 {name}()")
    i = src.index("{", m.start())
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
    raise SyncError(f"上游函数 {name}() 大括号不配对")


def extract_trace_params(nt_route_fn: str) -> dict:
    """从 nexttrace_route 函数提取追踪参数"""
    m = re.search(
        r"timeout\s+-s\s+SIGKILL\s+(\d+)\s+nexttrace\s+-p\s+(\d+)\s+-q\s+(\d+)",
        nt_route_fn,
    )
    if not m:
        raise SyncError("无法解析 nexttrace 调用参数 (timeout/-p/-q)")
    timeout_s, port, queries = m.groups()
    m = re.search(r"--psize\s+(\d+)", nt_route_fn)
    if not m:
        raise SyncError("无法解析 --psize")
    psize = m.group(1)
    m = re.search(r"max_retries\s*=\s*(\d+)", nt_route_fn)
    if not m:
        raise SyncError("无法解析 max_retries")
    retries = m.group(1)
    m = re.search(r"retry_delay\s*=\s*(\d+)", nt_route_fn)
    if not m:
        raise SyncError("无法解析 retry_delay")
    delay = m.group(1)
    return {
        "trace_timeout": timeout_s,
        "trace_port": port,
        "trace_queries": queries,
        "trace_psize": psize,
        "trace_max_retries": retries,
        "trace_retry_delay": delay,
    }


def extract_route_targets(route_mode_fn: str, num2code: dict) -> tuple:
    """从 get_route_mode 提取域名后缀与默认省份(展示顺序)"""
    pairs = re.findall(
        r'rdomain\[\d+\]="([a-z0-9]+)-(ct|cu|cm)-v\$ipv\.([a-z0-9.]+)"',
        route_mode_fn,
    )
    if not pairs:
        raise SyncError("无法解析 rdomain 目标域名")
    suffixes = {p[2] for p in pairs}
    if len(suffixes) != 1:
        raise SyncError(f"目标域名后缀不一致: {suffixes}")
    suffix = suffixes.pop()

    # 默认省份: rmcode 非 -R 参数分支, 按序号顺序去重(跳过隐藏的 0 号)
    m = re.search(r"if \[\[ -z \$mode_route_pv \]\];?then(.*?)\n\s*else", route_mode_fn, re.S)
    if not m:
        raise SyncError("无法定位 get_route_mode 的默认分支")
    rmcodes = dict(re.findall(r"rmcode\[(\d+)\]=(\d+)", m.group(1)))
    if not rmcodes:
        raise SyncError("无法解析 rmcode 省份编号")
    nums = []
    for k in sorted((k for k in rmcodes if int(k) >= 1), key=int):
        v = rmcodes[k]
        if v not in nums:
            nums.append(v)
    provs = []
    for n in nums:
        if int(n) not in num2code:
            raise SyncError(f"省份编号 {n} 不在 province.json 中")
        provs.append(num2code[int(n)])

    # 交叉校验: rdomain 出现的省份应与 rmcode 一致
    rdomain_provs = {p[0] for p in pairs}
    if rdomain_provs != set(provs):
        raise SyncError(f"rdomain 省份 {sorted(rdomain_provs)} 与 rmcode 省份 {provs} 不一致")
    return suffix, " ".join(provs)


def normalize_fingerprint(nt_route_fn: str, route_mode_fn: str) -> str:
    """参数归一化后指纹: 数据参数变化不触发告警, 逻辑变化才触发"""
    t = nt_route_fn + "\n" + route_mode_fn
    t = re.sub(r'rdomain\[\d+\]="[^"]*"', "RDOMAIN", t)
    t = re.sub(r"timeout\s+-s\s+SIGKILL\s+\d+", "TIMEOUT", t)
    t = re.sub(r"-p\s+\d+\s+-q\s+\d+", "PQ", t)
    t = re.sub(r"--psize\s+\d+", "PSIZE", t)
    t = re.sub(r"max_retries\s*=\s*\d+", "RETRY", t)
    t = re.sub(r"retry_delay\s*=\s*\d+", "DELAY", t)
    t = re.sub(r"\s+", " ", t)
    return hashlib.sha256(t.encode()).hexdigest()


def shell_quote_val(v: str) -> str:
    return v if re.fullmatch(r"[A-Za-z0-9_.\-]+", v) else f'"{v}"'


def replace_block(text: str, marks: tuple, new_block: str) -> str:
    begin, end = marks
    b = text.find(begin)
    e = text.find(end)
    if b == -1 or e == -1:
        raise SyncError(f"nq-route.sh 中缺少标记 {begin}")
    return text[:b] + new_block + text[e + len(end):]


def read_current_config(text: str) -> dict:
    begin, end = MARK_CONFIG
    block = text[text.find(begin): text.find(end)]
    cur = {}
    for key, val in re.findall(r"^(\w+)=(.+)$", block, re.M):
        cur[key] = val.strip().strip('"')
    return cur


def main() -> int:
    report = []
    logic_changed = False
    try:
        nq_src = fetch(URL_NQ)
        net_src = fetch(URL_NET)
        prov_json = fetch(f"{URL_REF}/province.json")
        asmap_txt = fetch(f"{URL_REF}/AS_Mapping.txt")

        # nexttrace 版本 (NodeQuality 锁定的版本)
        m = re.search(r"NTrace-core/releases/download/(v[\d.]+)/nexttrace_linux_amd64", nq_src)
        if not m:
            raise SyncError("无法从 NodeQuality 提取 nexttrace 版本")
        nt_version = m.group(1)

        # 省份表
        provs_all = [p for p in json.loads(prov_json) if p.get("province", 99) < 70]
        num2code = {p["province"]: p["code"].lower() for p in provs_all}

        # 上游函数
        nt_route_fn = extract_function(net_src, "nexttrace_route")
        route_mode_fn = extract_function(net_src, "get_route_mode")
        params = extract_trace_params(nt_route_fn)
        suffix, default_provs = extract_route_targets(route_mode_fn, num2code)

        # 逻辑指纹
        fp = normalize_fingerprint(nt_route_fn, route_mode_fn)
        old_fp = HASH_FILE.read_text().strip() if HASH_FILE.exists() else ""
        if old_fp and old_fp != fp:
            logic_changed = True

        # ---- 改写 nq-route.sh ----
        text = SCRIPT.read_text()
        cur = read_current_config(text)

        new_cfg = "\n".join(
            [
                MARK_CONFIG[0],
                f'nt_version="{nt_version}"',
                f'trace_domain_suffix="{suffix}"',
                f'trace_port={params["trace_port"]}',
                f'trace_queries={params["trace_queries"]}',
                f'trace_psize={params["trace_psize"]}',
                f'trace_timeout={params["trace_timeout"]}',
                f'trace_max_retries={params["trace_max_retries"]}',
                f'trace_retry_delay={params["trace_retry_delay"]}',
                f'default_provs="{default_provs}"',
                MARK_CONFIG[1],
            ]
        )
        new_prov_lines = ["declare -A PROV=("]
        for p in sorted(provs_all, key=lambda x: x["province"]):
            name = re.sub(r"省|市|自治区|维吾尔|壮族|回族", "", p["name"])
            new_prov_lines.append(f'    [{p["code"].lower()}]="{name}|{p["short"]}"')
        new_prov_lines.append(")")
        new_prov = "\n".join(
            [MARK_PROV[0] + " (来源: xykt/NetQuality ref/province.json, province<70)"]
            + new_prov_lines
            + [MARK_PROV[1]]
        )
        entries = {}
        for line in asmap_txt.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 1)
            if len(parts) == 2:
                entries[parts[0]] = parts[1]
        if not entries:
            raise SyncError("AS_Mapping.txt 解析结果为空")
        new_asmap = "\n".join(
            [MARK_ASMAP[0] + " (来源: xykt/NetQuality ref/AS_Mapping.txt)",
             "declare -A AS_MAPPING=("]
            + [f"    [{k}]={shell_quote_val(v)}" for k, v in entries.items()]
            + [")", MARK_ASMAP[1]]
        )

        # 变更对比报告
        new_vals = {
            "nt_version": nt_version,
            "trace_domain_suffix": suffix,
            **params,
            "default_provs": default_provs,
        }
        changed = []
        for k, v in new_vals.items():
            old = cur.get(k, "")
            mark = "无变化" if old == v else f"{old or '(空)'} -> {v}"
            if old != v:
                changed.append(k)
            report.append(f"- {k}: {mark}")
        if len(entries) != len(re.findall(r"^\s*\[AS", text, re.M)):
            changed.append("AS_MAPPING 规模")
        report.insert(0, f"# 上游同步报告 {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}")
        report.append(f"- 上游逻辑指纹: {'变化' if logic_changed else '一致'}")
        if not changed and not logic_changed:
            report.append("- 结果: 无需更新")
        else:
            report.append(f"- 结果: 更新 {', '.join(changed) if changed else '(仅指纹)'}")

        text = replace_block(text, MARK_CONFIG, new_cfg)
        text = replace_block(text, MARK_PROV, new_prov)
        text = replace_block(text, MARK_ASMAP, new_asmap)
        SCRIPT.write_text(text)
        HASH_FILE.parent.mkdir(parents=True, exist_ok=True)
        HASH_FILE.write_text(fp + "\n")
    except SyncError as e:
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        REPORT.write_text(f"# 上游同步报告(失败)\n\n- 错误: {e}\n")
        print(f"同步失败: {e}", file=sys.stderr)
        return 1
    except Exception as e:  # 网络错误等
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        REPORT.write_text(f"# 上游同步报告(失败)\n\n- 错误: {type(e).__name__}: {e}\n")
        print(f"同步失败: {type(e).__name__}: {e}", file=sys.stderr)
        return 1

    if logic_changed:
        report.append("LOGIC_CHANGED")
    body = "\n".join(report) + "\n"
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(body)
    print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
