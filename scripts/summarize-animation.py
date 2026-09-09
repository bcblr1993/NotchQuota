#!/usr/bin/env python3
"""Summarize exported Instruments tables; empty attribution is inconclusive, not PASS."""
import argparse
import json
import xml.etree.ElementTree as ET
from pathlib import Path


def read_rows(path):
    tree = ET.parse(path)
    refs = {e.get('id'): e for e in tree.iter() if e.get('id')}
    def resolve(e):
        return refs[e.get('ref')] if e.get('ref') else e
    result = []
    for node in tree.findall('node'):
        schema = node.find('schema')
        columns = [c.findtext('mnemonic') for c in schema.findall('col')]
        for row in node.findall('row'):
            record = {}
            for key, value in zip(columns, row):
                value = resolve(value)
                if key == 'process':
                    pid = value.find('pid')
                    record[key] = int(resolve(pid).text) if pid is not None else None
                else:
                    record[key] = value.text or value.get('fmt')
            result.append(record)
    return result


def summarize(directory, pid):
    updates = [r for r in read_rows(directory / 'updates.xml') if r.get('process') == pid]
    hitches = [r for r in read_rows(directory / 'hitches.xml') if r.get('process') == pid]
    return {
        'target_pid': pid, 'attributed_updates': len(updates),
        'attributed_hitches': len(hitches),
        'hitch_duration_ms': sum(float(r['duration']) / 1e6 for r in hitches),
        'frame_verdict': 'requires_review' if hitches else 'no_hitches_in_captured_updates' if updates else 'inconclusive_no_attributed_updates',
        'limits': 'Desktop frame lifetimes are not app FPS. No attributed updates cannot prove zero dropped frames. Capture overhead and other applications affect results.',
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--pid', type=int, required=True)
    args = parser.parse_args()
    result = summarize(args.directory, args.pid)
    (args.directory / 'animation-summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
