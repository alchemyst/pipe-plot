#!/usr/bin/env python3
"""Verify two short concurrent cold pipelines without touching existing sessions.
Quit PipePlot first. This creates one new session and leaves it available for inspection.
"""
import json
import pathlib
import subprocess
import time

home = pathlib.Path.home()
pp = home / '.local/bin/pp'
metadata = home / 'Library/Application Support/PipePlot/pipeplot.sqlite.metadata.json'
if subprocess.run(['pgrep', '-x', 'PipePlot'], capture_output=True).returncode == 0:
    raise SystemExit('Quit PipePlot before running the cold-start check.')
before = len(json.loads(metadata.read_text())['sessions']) if metadata.exists() else 0
producers = [subprocess.Popen([str(pp)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True) for _ in range(2)]
try:
    for process in producers:
        process.stdin.write('1\n')
        process.stdin.flush()
    time.sleep(2)
    for process in producers:
        process.stdin.write('2\n')
        process.stdin.close()
    for process in producers:
        code = process.wait(timeout=20)
        assert code == 0, (code, process.stderr.read())
        assert process.stdout.read() == '', 'Capture wrote to stdout'
    sessions = json.loads(metadata.read_text())['sessions']
    assert len(sessions) == before + 1, (before, len(sessions))
    session = max(sessions, key=lambda value: value['number'])
    assert len(session['charts']) == 1, session['charts']
    streams = session['charts'][0]['streams']
    assert len(streams) == 2 and all(stream['sampleCount'] == 2 for stream in streams), streams
    assert len({stream['id'] for stream in streams}) == 2
    print(f"Passed: session {session['number']}, one chart, two distinct streams, two rows each")
finally:
    for process in producers:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
