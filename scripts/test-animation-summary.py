#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('summary', Path(__file__).with_name('summarize-animation.py'))
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)

class TraceSummaryTests(unittest.TestCase):
    def test_no_attribution_is_inconclusive_and_references_keep_pid(self):
        schema = '<schema><col><mnemonic>duration</mnemonic></col><col><mnemonic>process</mnemonic></col></schema>'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            def write(name, rows):
                (path / name).write_text('<trace-query-result><node>' + schema + rows + '</node></trace-query-result>')
            write('updates.xml', '')
            write('hitches.xml', '')
            self.assertEqual(summary.summarize(path, 42)['frame_verdict'], 'inconclusive_no_attributed_updates')
            row = '<row><duration id="1">1000000</duration><process id="2"><pid id="3">42</pid></process></row>'
            write('updates.xml', row)
            write('hitches.xml', row + '<row><duration ref="1"/><process ref="2"/></row>')
            result = summary.summarize(path, 42)
            self.assertEqual(result['attributed_hitches'], 2)
            self.assertEqual(result['hitch_duration_ms'], 2)
            self.assertEqual(summary.summarize(path, 43)['attributed_hitches'], 0)

if __name__ == '__main__':
    unittest.main()
