#!/usr/bin/env python3
"""Generate an interactive, standalone HTML timeline from Hailo VCTX logs.

The input may be one of the following:

* a vctx experiment matrix directory;
* a single case/run directory containing ``dmesg-vctx.log``;
* a ``dmesg-vctx.log`` file.

Only the Python standard library is required.  The generated HTML embeds all
parsed data and does not need a web server or an Internet connection.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


DMESG_RE = re.compile(
    r"^\[(?P<timestamp>\d+(?:\.\d+)?)\].*?"
    r"vctx-(?P<source>trace|fw):\s*(?P<message>.*)$"
)
KV_RE = re.compile(r"(?P<key>[A-Za-z_][A-Za-z0-9_]*)=(?P<value>\"[^\"]*\"|\S+)")
WORKER_PREFIX_RE = re.compile(r"^\[worker=(?P<worker>[^]]+)]\[pid=(?P<pid>\d+)]\s+")

NOISY_EVENTS = {
    "WAIT_EVENT",
    "WAIT_DELIVER",
    "WAIT_ROLLBACK",
    "WORKER_DRAIN",
}


def parse_scalar(value: str) -> Any:
    """Convert simple decimal values while preserving masks and compound fields."""

    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1]
    if re.fullmatch(r"-?\d+", value):
        try:
            return int(value)
        except ValueError:
            return value
    if re.fullmatch(r"-?(?:\d+\.\d*|\d*\.\d+)(?:[eE][+-]?\d+)?", value):
        try:
            return float(value)
        except ValueError:
            return value
    return value


def parse_key_values(text: str) -> Dict[str, Any]:
    return {
        match.group("key"): parse_scalar(match.group("value"))
        for match in KV_RE.finditer(text)
    }


def read_key_value_file(path: Path) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    if not path.is_file():
        return result
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key.strip()] = parse_scalar(value.strip())
    return result


def fw_event_name(message: str) -> str:
    lower = message.lower()
    if lower.startswith("global initialization"):
        return "FW_GLOBAL_INIT"
    if lower.startswith("suppress repeated global reset"):
        return "FW_SUPPRESS_RESET"
    if lower.startswith("suppress repeated global clear"):
        return "FW_SUPPRESS_CLEAR"
    first = message.split(None, 1)[0] if message else "UNKNOWN"
    return "FW_" + re.sub(r"[^A-Za-z0-9]+", "_", first).upper()


def event_vctx(fields: Dict[str, Any]) -> int:
    for key in ("vctx", "to", "requester", "owner"):
        value = fields.get(key)
        if isinstance(value, int):
            return value
    return 0


def parse_dmesg(path: Path, include_wait_events: bool) -> Tuple[List[Dict[str, Any]], int]:
    events: List[Dict[str, Any]] = []
    ignored_lines = 0
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1
    ):
        match = DMESG_RE.match(raw_line)
        if not match:
            ignored_lines += 1
            continue
        timestamp_seconds = float(match.group("timestamp"))
        source = match.group("source")
        message = match.group("message").strip()
        fields = parse_key_values(message)
        if source == "trace":
            event_type = message.split(None, 1)[0] if message else "UNKNOWN"
        else:
            event_type = fw_event_name(message)
        if not include_wait_events and event_type in NOISY_EVENTS:
            continue
        events.append(
            {
                "time_s": timestamp_seconds,
                "type": event_type,
                "source": source,
                "vctx": event_vctx(fields),
                "fields": fields,
                "message": message,
                "line": line_number,
            }
        )
    events.sort(key=lambda event: (event["time_s"], event["line"]))
    return events, ignored_lines


def transfer_key(event: Dict[str, Any]) -> Optional[Tuple[int, int, int, int]]:
    fields = event["fields"]
    values = (
        event.get("vctx"),
        fields.get("seq"),
        fields.get("engine"),
        fields.get("channel"),
    )
    if not all(isinstance(value, int) for value in values):
        return None
    return values  # type: ignore[return-value]


def build_transfers(events: Sequence[Dict[str, Any]], t0: float) -> List[Dict[str, Any]]:
    transfers: List[Dict[str, Any]] = []
    open_transfers: Dict[Tuple[int, int, int, int], Dict[str, Any]] = {}
    for event in events:
        if event["type"] == "TRANSFER_COMMIT":
            key = transfer_key(event)
            if key is None:
                continue
            fields = event["fields"]
            transfer = {
                "vctx": key[0],
                "seq": key[1],
                "engine": key[2],
                "channel": key[3],
                "start": (event["time_s"] - t0) * 1000.0,
                "end": None,
                "duration": None,
                "descriptors": fields.get("descriptors"),
                "logical_start": fields.get("logical_start"),
                "logical_last": fields.get("logical_last"),
                "physical_start": fields.get("physical_start"),
                "physical_last": fields.get("physical_last"),
                "logical_wrap": fields.get("logical_ring_wrap", 0),
                "physical_wrap": fields.get("physical_ring_wrap", 0),
                "device_ongoing": fields.get("device_ongoing"),
                "quantum_commits": fields.get("quantum_commits"),
                "commit_line": event["line"],
                "complete_line": None,
                "status": "open",
                "message": event["message"],
            }
            transfers.append(transfer)
            open_transfers[key] = transfer
        elif event["type"] == "TRANSFER_COMPLETE":
            key = transfer_key(event)
            if key is None:
                continue
            transfer = open_transfers.pop(key, None)
            if transfer is None:
                continue
            end = (event["time_s"] - t0) * 1000.0
            transfer["end"] = end
            transfer["duration"] = max(0.0, end - transfer["start"])
            transfer["complete_line"] = event["line"]
            transfer["status"] = "complete"
            transfer["completion_status"] = event["fields"].get("status")
            transfer["age_ms"] = event["fields"].get("age_ms")
    return transfers


def parse_worker_log(path: Path) -> Dict[str, Any]:
    worker: Dict[str, Any] = {
        "file": path.name,
        "worker": path.stem.removeprefix("worker-"),
        "pid": None,
        "start_unix_ms": None,
        "end_unix_ms": None,
        "elapsed_ms": None,
        "transport_complete": False,
        "process_status": "unknown",
        "output": {},
        "result": {},
    }
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        prefix = WORKER_PREFIX_RE.match(raw_line)
        if prefix:
            worker["worker"] = prefix.group("worker")
            worker["pid"] = int(prefix.group("pid"))
            message = raw_line[prefix.end() :]
        else:
            message = raw_line

        if message.startswith("inference-start "):
            fields = parse_key_values(message)
            worker["start_unix_ms"] = fields.get("start_unix_ms")
        elif message.startswith("output-stream-start "):
            worker["output"] = parse_key_values(message)
        elif message.startswith("inference-result-summary "):
            worker["result"] = parse_key_values(message)
        elif message.startswith("inference-transport-complete "):
            worker["transport_complete"] = True
        elif message.startswith("inference-complete "):
            fields = parse_key_values(message)
            worker["process_status"] = "complete"
            worker["end_unix_ms"] = fields.get("end_unix_ms")
            worker["elapsed_ms"] = fields.get("elapsed_ms")
        elif message.startswith("inference-failed "):
            fields = parse_key_values(message)
            worker["process_status"] = "failed"
            worker["end_unix_ms"] = fields.get("end_unix_ms")
            worker["elapsed_ms"] = fields.get("elapsed_ms")
            worker["failure_status"] = fields.get("status")
    return worker


def lane_sort_key(lane: Dict[str, Any]) -> Tuple[int, int, int]:
    return (lane["vctx"], lane["engine"], lane["channel"])


def summarize_events(events: Sequence[Dict[str, Any]], transfers: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    counts = Counter(event["type"] for event in events)
    closed_quantums = [
        event
        for event in events
        if event["type"] == "VCTX_QUANTUM_BEGIN"
        and isinstance(event["fields"].get("previous_commits"), int)
        and event["fields"].get("previous", 0) != 0
    ]
    quantum_commits = [event["fields"]["previous_commits"] for event in closed_quantums]
    quantum_ages_ms = [
        event["fields"]["previous_age_ms"]
        for event in closed_quantums
        if isinstance(event["fields"].get("previous_age_ms"), int)
    ]
    return {
        "events": len(events),
        "device_switches": counts["DEVICE_SWITCH"],
        "quantum_begins": counts["VCTX_QUANTUM_BEGIN"],
        "quantum_requests": counts["VCTX_QUANTUM_REQUEST"],
        "quantum_commit_avg": round(sum(quantum_commits) / len(quantum_commits), 3)
        if quantum_commits
        else 0,
        "quantum_commit_max": max(quantum_commits, default=0),
        "quantum_age_avg_ms": round(sum(quantum_ages_ms) / len(quantum_ages_ms), 3)
        if quantum_ages_ms
        else 0,
        "rebases": counts["CHANNEL_CURSOR_REBASE"],
        "commits": counts["TRANSFER_COMMIT"],
        "completes": counts["TRANSFER_COMPLETE"],
        "logical_wraps": sum(bool(transfer.get("logical_wrap")) for transfer in transfers),
        "physical_wraps": sum(bool(transfer.get("physical_wrap")) for transfer in transfers),
        "rebase_failures": sum(
            event["type"] == "CHANNEL_CURSOR_REBASE"
            and event["fields"].get("physical_idle_failed") == 1
            for event in events
        ),
        "stalls": counts["TRANSFER_STALL_WARN"],
        "rejects": counts["TRANSFER_REJECT"] + counts["TRANSFER_CURSOR_REJECT"],
        "aborts": counts["TRANSFER_ABORT"],
        "open_transfers": sum(transfer["status"] != "complete" for transfer in transfers),
    }


def parse_run(run_dir: Path, display_name: str, include_wait_events: bool) -> Dict[str, Any]:
    dmesg_path = run_dir / "dmesg-vctx.log"
    events, ignored_lines = parse_dmesg(dmesg_path, include_wait_events)
    if not events:
        raise ValueError(f"no VCTX events found in {dmesg_path}")

    t0 = events[0]["time_s"]
    t1 = events[-1]["time_s"]
    for event in events:
        event["t"] = round((event.pop("time_s") - t0) * 1000.0, 6)

    # build_transfers expects the original seconds. Reconstruct a minimal view
    # from relative milliseconds to keep a single representation in the HTML.
    transfer_events: List[Dict[str, Any]] = []
    for event in events:
        cloned = dict(event)
        cloned["time_s"] = t0 + (event["t"] / 1000.0)
        transfer_events.append(cloned)
    transfers = build_transfers(transfer_events, t0)

    lanes_by_key: Dict[Tuple[int, int, int], Dict[str, Any]] = {}
    for transfer in transfers:
        key = (transfer["vctx"], transfer["engine"], transfer["channel"])
        lanes_by_key.setdefault(
            key,
            {
                "vctx": key[0],
                "engine": key[1],
                "channel": key[2],
                "label": f"VCTX {key[0]} · E{key[1]}/C{key[2]}",
            },
        )

    switches = [
        {
            "t": event["t"],
            "vctx": event["vctx"],
            "epoch": event["fields"].get("dispatch_epoch"),
            "line": event["line"],
            "message": event["message"],
        }
        for event in events
        if event["type"] == "DEVICE_SWITCH"
    ]
    duration_ms = max(0.001, (t1 - t0) * 1000.0)
    for index, switch in enumerate(switches):
        switch["end"] = switches[index + 1]["t"] if index + 1 < len(switches) else duration_ms

    worker_logs = sorted(run_dir.glob("worker-*.log"))
    workers = [parse_worker_log(path) for path in worker_logs]
    vctxs = sorted({event["vctx"] for event in events if event["vctx"] > 0})
    return {
        "name": display_name,
        "directory": str(run_dir),
        "dmesg_file": str(dmesg_path),
        "kernel_t0_s": t0,
        "kernel_t1_s": t1,
        "duration_ms": duration_ms,
        "events": events,
        "transfers": transfers,
        "switches": switches,
        "lanes": sorted(lanes_by_key.values(), key=lane_sort_key),
        "vctxs": vctxs,
        "stats": summarize_events(events, transfers),
        "summary": read_key_value_file(run_dir / "summary.txt"),
        "configuration": read_key_value_file(run_dir / "configuration.txt"),
        "workers": workers,
        "ignored_non_vctx_lines": ignored_lines,
    }


def discover_run_directories(input_path: Path) -> Tuple[Path, List[Path]]:
    input_path = input_path.resolve()
    if input_path.is_file():
        if input_path.name != "dmesg-vctx.log":
            raise ValueError("input file must be named dmesg-vctx.log")
        return input_path.parent, [input_path.parent]
    if not input_path.is_dir():
        raise ValueError(f"input does not exist: {input_path}")
    if (input_path / "dmesg-vctx.log").is_file():
        return input_path, [input_path]
    run_dirs = sorted({path.parent for path in input_path.rglob("dmesg-vctx.log")})
    if not run_dirs:
        raise ValueError(f"no dmesg-vctx.log found under {input_path}")
    return input_path, run_dirs


def relative_display_name(root: Path, run_dir: Path) -> str:
    try:
        relative = run_dir.relative_to(root)
    except ValueError:
        return run_dir.name
    return str(relative) if str(relative) != "." else run_dir.name


HTML_TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__</title>
<style>
:root {
  color-scheme: dark;
  --bg: #0a0f1d;
  --panel: #121a2b;
  --panel2: #182238;
  --text: #e6edf7;
  --muted: #93a4bd;
  --line: #2a3853;
  --good: #3ddc97;
  --bad: #ff667a;
  --warn: #ffcc66;
  --accent: #6aa9ff;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 14px/1.45 Inter, system-ui, sans-serif; }
header { padding: 22px 26px 12px; border-bottom: 1px solid var(--line); background: #0d1424; }
h1 { margin: 0 0 5px; font-size: 23px; }
.subtitle, .muted { color: var(--muted); }
main { padding: 18px 24px 36px; max-width: 1800px; margin: 0 auto; }
.toolbar, .filters { display: flex; flex-wrap: wrap; align-items: center; gap: 10px 16px; }
.toolbar { margin-bottom: 14px; }
select, input, button { background: var(--panel2); color: var(--text); border: 1px solid var(--line); border-radius: 6px; padding: 7px 9px; }
button { cursor: pointer; }
button:hover { border-color: var(--accent); }
label { color: var(--muted); }
label.check { display: inline-flex; gap: 6px; align-items: center; color: var(--text); }
input[type=checkbox] { accent-color: var(--accent); }
input[type=range] { padding: 0; width: 150px; }
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 9px; margin: 12px 0; }
.card { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; min-height: 66px; }
.card .key { color: var(--muted); font-size: 12px; }
.card .value { font-size: 19px; margin-top: 4px; overflow-wrap: anywhere; }
.PASS, .good { color: var(--good); }
.FAIL, .bad { color: var(--bad); }
.warn { color: var(--warn); }
.workers { display: grid; grid-template-columns: repeat(auto-fit, minmax(270px, 1fr)); gap: 9px; margin: 12px 0 16px; }
.worker { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 11px 13px; }
.worker h3 { margin: 0 0 7px; font-size: 15px; }
.worker-grid { display: grid; grid-template-columns: auto 1fr; gap: 3px 10px; }
.worker-grid span:nth-child(odd) { color: var(--muted); }
.legend { display: flex; flex-wrap: wrap; gap: 8px 14px; color: var(--muted); margin: 9px 0; }
.swatch { display: inline-block; width: 13px; height: 8px; border-radius: 2px; margin-right: 5px; }
.timeline-panel, .table-panel { background: var(--panel); border: 1px solid var(--line); border-radius: 9px; overflow: hidden; }
.timeline-head { padding: 10px 13px; background: var(--panel2); border-bottom: 1px solid var(--line); }
#canvasWrap { position: relative; overflow: hidden; }
#timeline { display: block; width: 100%; }
#tooltip { display: none; position: absolute; z-index: 5; max-width: 560px; pointer-events: none; background: rgba(4,8,16,.96); border: 1px solid #52698f; border-radius: 6px; padding: 8px 10px; white-space: pre-wrap; font: 12px/1.35 ui-monospace, monospace; box-shadow: 0 8px 30px #0009; }
.table-panel { margin-top: 16px; }
.filters { padding: 10px 12px; border-bottom: 1px solid var(--line); }
.table-wrap { max-height: 520px; overflow: auto; }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid #202d46; vertical-align: top; }
th { position: sticky; top: 0; background: #182238; z-index: 1; }
td.message { font-family: ui-monospace, monospace; white-space: nowrap; }
.event-error { color: var(--bad); }
.event-wrap { color: var(--warn); }
.footnote { margin-top: 10px; color: var(--muted); font-size: 12px; }
@media (max-width: 720px) { main { padding: 12px; } header { padding: 16px; } }
</style>
</head>
<body>
<header>
  <h1>__TITLE__</h1>
  <div class="subtitle">KMD monotonic time · standalone report · generated __GENERATED__</div>
</header>
<main>
  <div class="toolbar">
    <label>Case <select id="caseSelect"></select></label>
    <button id="resetView">Reset view</button>
    <label>Zoom <input id="zoom" type="range" min="1" max="100" value="1" step="1"> <span id="zoomValue">1×</span></label>
    <label>Pan <input id="pan" type="range" min="0" max="1000" value="0" step="1"></label>
    <label class="check"><input id="showTransfers" type="checkbox" checked> transfers</label>
    <label class="check"><input id="showSwitches" type="checkbox" checked> device owner</label>
    <label class="check"><input id="showRebases" type="checkbox"> rebases</label>
    <label class="check"><input id="showCompletes" type="checkbox"> completion points</label>
  </div>

  <div id="summaryCards" class="cards"></div>
  <div id="workerCards" class="workers"></div>

  <div class="legend" id="legend"></div>
  <section class="timeline-panel">
    <div class="timeline-head">
      Drag to pan · mouse wheel to zoom · hover for details · red outline means logical ring-wrap
    </div>
    <div id="canvasWrap">
      <canvas id="timeline"></canvas>
      <div id="tooltip"></div>
    </div>
  </section>

  <section class="table-panel">
    <div class="filters">
      <strong>Events</strong>
      <label>Type <select id="eventType"><option value="">all</option></select></label>
      <label>VCTX <select id="vctxFilter"><option value="">all</option></select></label>
      <label>Search <input id="search" type="search" placeholder="ring_wrap=1, channel=2 …"></label>
      <label class="check"><input id="currentViewOnly" type="checkbox" checked> current view only</label>
      <span id="eventCount" class="muted"></span>
    </div>
    <div class="table-wrap">
      <table>
        <thead><tr><th>t (ms)</th><th>VCTX</th><th>type</th><th>line</th><th>message</th></tr></thead>
        <tbody id="eventsBody"></tbody>
      </table>
    </div>
  </section>
  <div class="footnote">Worker wall-clock intervals are shown as metadata only. Kernel dmesg uses monotonic time and is not falsely aligned to Unix wall-clock time.</div>
</main>
<script>
"use strict";
const DATA = __DATA__;
const COLORS = ["#6aa9ff", "#d481ff", "#3ddc97", "#ff9f5a", "#58d5e8", "#f56fb3", "#b1d66b", "#ffcc66"];
const ERROR_TYPES = new Set(["TRANSFER_STALL_WARN", "TRANSFER_REJECT", "TRANSFER_CURSOR_REJECT", "TRANSFER_ABORT"]);
const $ = id => document.getElementById(id);
const canvas = $("timeline");
const ctx = canvas.getContext("2d");
const tooltip = $("tooltip");
let caseIndex = 0;
let viewStart = 0;
let viewEnd = 1;
let hitRegions = [];
let dragging = false;
let dragX = 0;
let dragStartView = 0;

function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
}
function currentCase() { return DATA.cases[caseIndex]; }
function colorFor(vctx) {
  const ids = currentCase().vctxs;
  const index = Math.max(0, ids.indexOf(Number(vctx)));
  return COLORS[index % COLORS.length];
}
function statusClass(value) { return value === "PASS" ? "PASS" : value === "FAIL" ? "FAIL" : ""; }
function formatMs(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return "—";
  if (Math.abs(number) >= 1000) return number.toFixed(1);
  if (Math.abs(number) >= 10) return number.toFixed(3);
  return number.toFixed(6);
}
function card(key, value, cls="") {
  return `<div class="card"><div class="key">${esc(key)}</div><div class="value ${cls}">${esc(value)}</div></div>`;
}

function renderSummary() {
  const c = currentCase(), s = c.summary, k = c.stats;
  const classification = s.classification_result ?? s.score_result ?? "n/a";
  const items = [
    ["overall", s.result ?? "n/a", statusClass(s.result)],
    ["transport", s.transport_result ?? "n/a", statusClass(s.transport_result)],
    ["classification", classification, statusClass(classification)],
    ["duration", `${formatMs(c.duration_ms)} ms`, ""],
    ["VCTX", c.vctxs.join(", ") || "none", ""],
    ["switches", k.device_switches, ""],
    ["quantums / requests", `${k.quantum_begins} / ${k.quantum_requests}`, ""],
    ["commits / quantum", `${k.quantum_commit_avg} avg · ${k.quantum_commit_max} max`, ""],
    ["commit / complete", `${k.commits} / ${k.completes}`, k.commits === k.completes ? "good" : "bad"],
    ["logical wraps", k.logical_wraps, k.logical_wraps ? "warn" : ""],
    ["rebase failures", k.rebase_failures, k.rebase_failures ? "bad" : "good"],
    ["stall / reject / abort", `${k.stalls} / ${k.rejects} / ${k.aborts}`, (k.stalls+k.rejects+k.aborts) ? "bad" : "good"],
  ];
  $("summaryCards").innerHTML = items.map(item => card(...item)).join("");
  $("workerCards").innerHTML = c.workers.map(worker => {
    const result = worker.result || {}, output = worker.output || {};
    const classification = result.classification_result ?? result.score_validation ?? "n/a";
    return `<div class="worker">
      <h3>Worker ${esc(worker.worker)} · pid ${esc(worker.pid ?? "?")}</h3>
      <div class="worker-grid">
        <span>transport</span><span class="${worker.transport_complete ? "good" : "bad"}">${worker.transport_complete ? "complete" : "incomplete"}</span>
        <span>process</span><span>${esc(worker.process_status)}</span>
        <span>elapsed</span><span>${esc(worker.elapsed_ms ?? "?")} ms</span>
        <span>classification</span><span class="${statusClass(classification)}">${esc(classification)}</span>
        <span>frames</span><span>${esc(result.completed_frames ?? "?")} / ${esc(result.expected_frames ?? "?")}</span>
        <span>output</span><span>${esc(output.user_format ?? "?")} ← ${esc(output.native_format ?? "?")}</span>
        <span>top1</span><span>${esc(result.dominant_top1_index ?? "?")} ${esc(result.dominant_top1_label ?? "")} (score ${esc(result.first_top1_score ?? "?")})</span>
        <span>one-hot frames</span><span>${esc(result.one_hot_score_frames ?? result.saturated_score_frames ?? 0)}</span>
      </div></div>`;
  }).join("");
  $("legend").innerHTML = c.vctxs.map(vctx => `<span><i class="swatch" style="background:${colorFor(vctx)}"></i>VCTX ${vctx}</span>`).join("") +
    `<span><i class="swatch" style="background:#ff667a"></i>wrap/error</span>`;
}

function rebuildFilters() {
  const c = currentCase();
  const types = [...new Set(c.events.map(e => e.type))].sort();
  $("eventType").innerHTML = `<option value="">all</option>` + types.map(t => `<option>${esc(t)}</option>`).join("");
  $("vctxFilter").innerHTML = `<option value="">all</option>` + c.vctxs.map(v => `<option>${v}</option>`).join("");
}

function resetView() {
  viewStart = 0;
  viewEnd = currentCase().duration_ms;
  $("zoom").value = "1";
  $("pan").value = "0";
  updateZoomLabel();
  draw();
  renderEvents();
}
function updateZoomLabel() {
  const factor = currentCase().duration_ms / Math.max(0.001, viewEnd - viewStart);
  $("zoomValue").textContent = `${factor.toFixed(factor < 10 ? 1 : 0)}×`;
}
function clampView() {
  const duration = currentCase().duration_ms;
  let span = Math.min(duration, Math.max(duration / 100, viewEnd - viewStart));
  viewStart = Math.max(0, Math.min(duration - span, viewStart));
  viewEnd = viewStart + span;
  const maxStart = Math.max(0.001, duration - span);
  $("pan").value = String(Math.round(1000 * viewStart / maxStart));
  $("zoom").value = String(Math.max(1, Math.min(100, Math.round(duration / span))));
  updateZoomLabel();
}

function niceStep(raw) {
  if (!(raw > 0)) return 1;
  const power = Math.pow(10, Math.floor(Math.log10(raw)));
  const scaled = raw / power;
  const factor = scaled <= 1 ? 1 : scaled <= 2 ? 2 : scaled <= 5 ? 5 : 10;
  return factor * power;
}
function timeToX(t, left, width) { return left + (t - viewStart) * width / (viewEnd - viewStart); }

function draw() {
  const c = currentCase();
  const rect = canvas.getBoundingClientRect();
  const width = Math.max(700, rect.width || 1200);
  const left = 190, right = 18, top = 30, laneHeight = 42;
  const laneCount = 2 + c.lanes.length;
  const height = top + laneCount * laneHeight + 24;
  const dpr = window.devicePixelRatio || 1;
  canvas.style.height = `${height}px`;
  canvas.width = Math.round(width * dpr);
  canvas.height = Math.round(height * dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, width, height);
  hitRegions = [];
  const plotWidth = width - left - right;

  ctx.fillStyle = "#10182a";
  ctx.fillRect(0, 0, width, height);
  ctx.font = "12px system-ui";
  ctx.textBaseline = "middle";

  const labels = ["Device owner", "Events", ...c.lanes.map(l => l.label)];
  labels.forEach((label, index) => {
    const y = top + index * laneHeight;
    ctx.fillStyle = index % 2 ? "#111a2c" : "#0e1727";
    ctx.fillRect(0, y, width, laneHeight);
    ctx.strokeStyle = "#24324d";
    ctx.beginPath(); ctx.moveTo(0, y + laneHeight); ctx.lineTo(width, y + laneHeight); ctx.stroke();
    ctx.fillStyle = "#c3cee0";
    ctx.fillText(label, 10, y + laneHeight / 2);
  });
  ctx.strokeStyle = "#435472";
  ctx.beginPath(); ctx.moveTo(left, top); ctx.lineTo(left, top + laneCount * laneHeight); ctx.stroke();

  const step = niceStep((viewEnd - viewStart) / 10);
  const firstTick = Math.ceil(viewStart / step) * step;
  ctx.textAlign = "center";
  for (let tick = firstTick; tick <= viewEnd + step * .01; tick += step) {
    const x = timeToX(tick, left, plotWidth);
    ctx.strokeStyle = "#263651";
    ctx.beginPath(); ctx.moveTo(x, top); ctx.lineTo(x, top + laneCount * laneHeight); ctx.stroke();
    ctx.fillStyle = "#91a3bd";
    ctx.fillText(formatMs(tick), x, 14);
  }
  ctx.textAlign = "left";

  if ($("showSwitches").checked) {
    c.switches.forEach(segment => {
      if (segment.end < viewStart || segment.t > viewEnd) return;
      const x1 = timeToX(Math.max(segment.t, viewStart), left, plotWidth);
      const x2 = timeToX(Math.min(segment.end, viewEnd), left, plotWidth);
      const y = top + 7;
      ctx.fillStyle = colorFor(segment.vctx) + "aa";
      ctx.fillRect(x1, y, Math.max(1, x2 - x1), laneHeight - 14);
      if (x2 - x1 > 34) {
        ctx.fillStyle = "#08101e";
        ctx.fillText(`V${segment.vctx}`, x1 + 4, y + (laneHeight - 14) / 2);
      }
      hitRegions.push({x1, x2, y1:y, y2:y+laneHeight-14, text:`DEVICE_SWITCH\nVCTX ${segment.vctx}\nepoch=${segment.epoch}\nt=${formatMs(segment.t)} ms\n${segment.message}`});
    });
  }

  const laneIndex = new Map(c.lanes.map((lane, index) => [`${lane.vctx}/${lane.engine}/${lane.channel}`, index + 2]));
  if ($("showTransfers").checked) {
    c.transfers.forEach(transfer => {
      const end = transfer.end ?? transfer.start;
      if (end < viewStart || transfer.start > viewEnd) return;
      const index = laneIndex.get(`${transfer.vctx}/${transfer.engine}/${transfer.channel}`);
      if (index === undefined) return;
      const x1 = timeToX(Math.max(transfer.start, viewStart), left, plotWidth);
      const x2 = timeToX(Math.min(Math.max(end, transfer.start + .01), viewEnd), left, plotWidth);
      const sub = Number(transfer.seq) % 4;
      const y = top + index * laneHeight + 5 + sub * 8;
      const w = Math.max(2, x2 - x1);
      ctx.fillStyle = transfer.status === "complete" ? colorFor(transfer.vctx) : "#ff667a";
      ctx.fillRect(x1, y, w, 6);
      if (transfer.logical_wrap) {
        ctx.strokeStyle = "#ff667a";
        ctx.lineWidth = 2;
        ctx.strokeRect(x1 - 1, y - 2, w + 2, 10);
        ctx.lineWidth = 1;
      }
      const detail = `TRANSFER ${transfer.status}\nVCTX=${transfer.vctx} seq=${transfer.seq} E${transfer.engine}/C${transfer.channel}\n` +
        `t=${formatMs(transfer.start)}..${formatMs(end)} ms duration=${formatMs(transfer.duration)} ms\n` +
        `logical=${transfer.logical_start}..${transfer.logical_last} wrap=${transfer.logical_wrap}\n` +
        `physical=${transfer.physical_start}..${transfer.physical_last} wrap=${transfer.physical_wrap}\n` +
        `descriptors=${transfer.descriptors} quantum_commits=${transfer.quantum_commits ?? "?"} age_ms=${transfer.age_ms ?? "?"}\ncommit line=${transfer.commit_line} complete line=${transfer.complete_line ?? "?"}`;
      hitRegions.push({x1, x2:x1+w, y1:y-3, y2:y+9, text:detail});
    });
  }

  c.events.forEach(event => {
    let show = false, color = "#93a4bd", radius = 2;
    if (ERROR_TYPES.has(event.type)) { show = true; color = "#ff667a"; radius = 5; }
    else if (event.type === "CHANNEL_CURSOR_REBASE" && $("showRebases").checked) { show = true; color = event.fields.physical_idle_failed ? "#ff667a" : "#58d5e8"; radius = 3; }
    else if (event.type === "TRANSFER_COMPLETE" && $("showCompletes").checked) { show = true; color = colorFor(event.vctx); radius = 2; }
    else if (event.type === "DEVICE_SWITCH") { show = true; color = colorFor(event.vctx); radius = 4; }
    else if (event.type === "VCTX_QUANTUM_REQUEST") { show = true; color = "#f6b94a"; radius = 4; }
    if (!show || event.t < viewStart || event.t > viewEnd) return;
    const x = timeToX(event.t, left, plotWidth), y = top + laneHeight + laneHeight / 2;
    ctx.fillStyle = color;
    ctx.beginPath(); ctx.arc(x, y, radius, 0, Math.PI * 2); ctx.fill();
    hitRegions.push({x1:x-radius-2, x2:x+radius+2, y1:y-radius-2, y2:y+radius+2, text:`${event.type}\nt=${formatMs(event.t)} ms VCTX=${event.vctx}\nline=${event.line}\n${event.message}`});
  });
}

function renderEvents() {
  const c = currentCase();
  const type = $("eventType").value;
  const vctx = $("vctxFilter").value;
  const query = $("search").value.trim().toLowerCase();
  const viewOnly = $("currentViewOnly").checked;
  let filtered = c.events.filter(event => {
    if (type && event.type !== type) return false;
    if (vctx && String(event.vctx) !== vctx) return false;
    if (viewOnly && (event.t < viewStart || event.t > viewEnd)) return false;
    if (query && !(event.type + " " + event.message).toLowerCase().includes(query)) return false;
    return true;
  });
  const total = filtered.length;
  filtered = filtered.slice(0, 1000);
  $("eventCount").textContent = `${total} matching${total > 1000 ? " · first 1000 shown" : ""}`;
  $("eventsBody").innerHTML = filtered.map(event => {
    const cls = ERROR_TYPES.has(event.type) ? "event-error" : event.fields.logical_ring_wrap === 1 ? "event-wrap" : "";
    return `<tr class="${cls}"><td>${formatMs(event.t)}</td><td>${event.vctx || "—"}</td><td>${esc(event.type)}</td><td>${event.line}</td><td class="message">${esc(event.message)}</td></tr>`;
  }).join("");
}

function switchCase(index) {
  caseIndex = Number(index);
  rebuildFilters();
  renderSummary();
  resetView();
}

DATA.cases.forEach((item, index) => {
  const option = document.createElement("option");
  option.value = String(index); option.textContent = item.name;
  $("caseSelect").appendChild(option);
});
$("caseSelect").addEventListener("change", event => switchCase(event.target.value));
$("resetView").addEventListener("click", resetView);
$("zoom").addEventListener("input", event => {
  const c = currentCase(), factor = Number(event.target.value), center = (viewStart + viewEnd) / 2;
  const span = c.duration_ms / factor;
  viewStart = center - span / 2; viewEnd = center + span / 2;
  clampView(); draw(); renderEvents();
});
$("pan").addEventListener("input", event => {
  const duration = currentCase().duration_ms, span = viewEnd - viewStart;
  viewStart = (duration - span) * Number(event.target.value) / 1000;
  viewEnd = viewStart + span; draw(); renderEvents();
});
["showTransfers", "showSwitches", "showRebases", "showCompletes"].forEach(id => $(id).addEventListener("change", draw));
["eventType", "vctxFilter", "search", "currentViewOnly"].forEach(id => $(id).addEventListener("input", renderEvents));

canvas.addEventListener("wheel", event => {
  event.preventDefault();
  const rect = canvas.getBoundingClientRect(), left = 190, plotWidth = rect.width - left - 18;
  if (event.clientX - rect.left < left || plotWidth <= 0) return;
  const fraction = Math.max(0, Math.min(1, (event.clientX - rect.left - left) / plotWidth));
  const anchor = viewStart + fraction * (viewEnd - viewStart);
  const factor = event.deltaY < 0 ? .75 : 1.333333;
  const span = (viewEnd - viewStart) * factor;
  viewStart = anchor - fraction * span; viewEnd = viewStart + span;
  clampView(); draw(); renderEvents();
}, {passive:false});
canvas.addEventListener("mousedown", event => {
  dragging = true; dragX = event.clientX; dragStartView = viewStart; canvas.style.cursor = "grabbing";
});
window.addEventListener("mouseup", () => { dragging = false; canvas.style.cursor = "default"; });
window.addEventListener("mousemove", event => {
  if (!dragging) return;
  const rect = canvas.getBoundingClientRect(), plotWidth = Math.max(1, rect.width - 208);
  const delta = (event.clientX - dragX) * (viewEnd - viewStart) / plotWidth;
  const span = viewEnd - viewStart;
  viewStart = dragStartView - delta; viewEnd = viewStart + span;
  clampView(); draw();
});
canvas.addEventListener("mousemove", event => {
  if (dragging) return;
  const rect = canvas.getBoundingClientRect(), x = event.clientX - rect.left, y = event.clientY - rect.top;
  const hit = [...hitRegions].reverse().find(region => x >= region.x1 && x <= region.x2 && y >= region.y1 && y <= region.y2);
  if (!hit) { tooltip.style.display = "none"; return; }
  tooltip.textContent = hit.text;
  tooltip.style.display = "block";
  tooltip.style.left = `${Math.max(4, Math.min(Math.max(4, rect.width - 580), x + 12))}px`;
  tooltip.style.top = `${Math.max(4, y + 12)}px`;
});
canvas.addEventListener("mouseleave", () => { tooltip.style.display = "none"; });

new ResizeObserver(draw).observe($("canvasWrap"));
switchCase(0);
</script>
</body>
</html>
"""


def build_html(title: str, cases: Sequence[Dict[str, Any]]) -> str:
    from datetime import datetime, timezone

    payload = json.dumps({"cases": cases}, ensure_ascii=False, separators=(",", ":"))
    # Avoid closing the script element if a log message happens to contain it.
    payload = payload.replace("</", "<\\/")
    generated = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    return (
        HTML_TEMPLATE.replace("__TITLE__", html.escape(title))
        .replace("__GENERATED__", html.escape(generated))
        .replace("__DATA__", payload)
    )


def default_output_path(root: Path) -> Path:
    return root / "vctx-timeline.html"


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate an interactive standalone HTML timeline from Hailo VCTX logs."
    )
    parser.add_argument("input", type=Path, help="matrix/run directory or dmesg-vctx.log")
    parser.add_argument("-o", "--output", type=Path, help="output HTML path")
    parser.add_argument("--title", default="Hailo KMD VCTX Timeline", help="HTML report title")
    parser.add_argument(
        "--include-wait-events",
        action="store_true",
        help="include WAIT_EVENT/WAIT_DELIVER/WORKER_DRAIN rows (larger HTML)",
    )
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    try:
        root, run_dirs = discover_run_directories(args.input)
        cases = [
            parse_run(
                run_dir,
                relative_display_name(root, run_dir),
                args.include_wait_events,
            )
            for run_dir in run_dirs
        ]
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    output = (args.output or default_output_path(root)).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    report = build_html(args.title, cases)
    output.write_text(report, encoding="utf-8")

    print(f"Generated {output}")
    for case in cases:
        stats = case["stats"]
        print(
            f"  {case['name']}: {case['duration_ms']:.3f} ms, "
            f"switches={stats['device_switches']}, "
            f"quantums/requests={stats['quantum_begins']}/{stats['quantum_requests']}, "
            f"commits/quantum(avg,max)={stats['quantum_commit_avg']}/{stats['quantum_commit_max']}, "
            f"commit/complete={stats['commits']}/{stats['completes']}, "
            f"wraps={stats['logical_wraps']}, stalls={stats['stalls']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
