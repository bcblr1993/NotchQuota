#!/usr/bin/env python3
"""Bounded synthetic sidebar validation; no credentials, account logs or persistent settings."""
import argparse
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--trace', action='store_true', help='Record Instruments separately from resource sampling')
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
app = root / 'build/NotchQuota.app/Contents/MacOS/NotchQuota'
env = {key: os.environ[key] for key in ('HOME', 'PATH', 'TMPDIR') if key in os.environ}
env['NOTCHQUOTA_SMOKE_DIR'] = str(out)
children = []
try:
    with (out / 'scenarios.log').open('w') as log:
        process = subprocess.Popen([str(app), '--sidebar-test', '--benchmark'], stdout=log, stderr=subprocess.STDOUT, env=env)
    children.append(process)
    (out / 'pid.txt').write_text(str(process.pid))
    if args.trace:
        with (out / 'trace.log').open('w') as log:
            recorder = subprocess.Popen(['xcrun', 'xctrace', 'record', '--template', 'Animation Hitches', '--attach', str(process.pid), '--time-limit', '60s', '--output', str(out / 'animation.trace')], stdout=log, stderr=subprocess.STDOUT)
    else:
        probe = root / '.build/performance/probe'
        with (out / 'resources.jsonl').open('w') as log:
            recorder = subprocess.Popen([str(probe), '110', '5', str(process.pid)], stdout=log)
    children.append(recorder)
    print(f'Sidebar test PID {process.pid}; output {out}', flush=True)
    result = process.wait(timeout=125)
    recorder.wait(timeout=240 if args.trace else 25)
    text = (out / 'scenarios.log').read_text()
    assert result == 0 and 'SIDEBAR COMPLETE: PASS' in text and ': FAIL' not in text, 'Sidebar interaction checks failed'
    if args.trace:
        assert recorder.returncode == 0, 'Instruments failed to save a complete trace; frame result is inconclusive'
    summary = {'uiChecksPassed': text.count(': PASS'), 'trace': args.trace}
    if not args.trace:
        samples = [json.loads(line) for line in (out / 'resources.jsonl').read_text().splitlines() if line]
        phases = [(name, float(stamp)) for name, stamp in re.findall(r'BENCH (idle_start|switching_start|idle_after_switching) ([\d.]+)', text)]
        for index, (name, start) in enumerate(phases):
            end = phases[index + 1][1] if index + 1 < len(phases) else float('inf')
            # Exclude the entry/folding transition and intervals crossing phase boundaries.
            selected = [s for s in samples if s.get('event') == 'sample' and s['timestamp'] - s['interval_s'] >= start + (4 if name.startswith('idle') else 0) and s['timestamp'] < end]
            assert selected, f'No complete samples for {name}'
            summary[name] = {'samples': len(selected), 'meanCPUPercentOneCore': statistics.mean(s['cpu_percent_one_core'] for s in selected),
                             'maxCPUPercentOneCore': max(s['cpu_percent_one_core'] for s in selected), 'maxFootprintMiB': max(s['footprint_mib'] for s in selected),
                             'maxRSSMiB': max(s['rss_mib'] for s in selected), 'meanIdleWakeupsPerSecond': statistics.mean(s['idle_wakeups_per_s'] for s in selected)}
        summary['selectionMainThreadMS'] = dict(zip(('p50', 'p95', 'max'), map(float, re.search(r'selection_main_thread_ms p50=([\d.]+) p95=([\d.]+) max=([\d.]+)', text).groups())))
    summary['limits'] = 'Synthetic seven-account cached data. Selection work time is not rendered frame time. Instruments is captured separately to avoid inflating resource measurements.'
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2), flush=True)
finally:
    for child in children:
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: child.kill(); child.wait()
