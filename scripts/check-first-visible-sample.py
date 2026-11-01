#!/usr/bin/env python3
"""Measure cold, warm and sparse sample rendering in the installed app.

Run on an unlocked desktop with PipePlot stopped. Creates one retained test session
and two streams. It does not close user windows or change notification settings.
The trace measures a visible-window Canvas drawing pass, not display scanout.
"""
import argparse
import json
import os
import pathlib
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--silent-seconds', type=float, default=120)
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    if args.silent_seconds < 0:
        parser.error('--silent-seconds must be nonnegative')
    root = pathlib.Path(__file__).resolve().parent.parent
    output = args.output or root / '.build/first-visible-sample.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    trace = output.with_suffix('.trace.jsonl')
    if subprocess.run(['pgrep', '-x', 'PipePlot'], capture_output=True).returncode == 0:
        raise SystemExit('Quit PipePlot first; the cold measurement requires a stopped app.')
    trace.unlink(missing_ok=True)
    env = dict(os.environ, PIPEPLOT_ACCEPTANCE_TRACE=str(trace.resolve()))
    pp = str(pathlib.Path.home() / '.local/bin/pp')
    result = {'boundary': 'visible-window Canvas drawing pass; physical scanout unmeasured'}
    children = []

    def wait_render(after):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if trace.exists():
                # Ignore a trailing partial line while the app appends.
                records = []
                for line in trace.read_text().splitlines():
                    try:
                        records.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
                matches = [r for r in records if r['event'] == 'visible-sample-render' and r['wall'] >= after]
                if matches:
                    return matches[-1]
            time.sleep(.01)
        raise RuntimeError('No visible sample render within 30 seconds; keep the desktop unlocked and window visible.')

    def start_sample(name, new_session=False):
        started = time.time()
        command = [pp] + (['-s'] if new_session else []) + ['-n', name]
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        children.append(child)
        child.stdin.write('123.456\n')
        child.stdin.flush()
        rendered = wait_render(started)
        return child, {'start': started, 'render': rendered, 'seconds': rendered['wall'] - started}

    def finish(child):
        child.stdin.close()
        code = child.wait(timeout=10)
        stdout, stderr = child.stdout.read(), child.stderr.read()
        if code != 0 or stdout or stderr:
            raise RuntimeError((code, stdout, stderr))

    try:
        cold, result['cold'] = start_sample('Cold sparse acceptance', new_session=True)
        print('COLD', json.dumps(result['cold']), flush=True)
        warm, result['warm'] = start_sample('Warm acceptance')
        print('WARM', json.dumps(result['warm']), flush=True)
        finish(warm)
        time.sleep(args.silent_seconds)
        started = time.time()
        cold.stdin.write('234.567\n')
        cold.stdin.flush()
        rendered = wait_render(started)
        result['sparse'] = {'silentSeconds': args.silent_seconds, 'start': started, 'render': rendered, 'seconds': rendered['wall'] - started}
        print('SPARSE', json.dumps(result['sparse']), flush=True)
        finish(cold)
    except Exception as error:
        result['error'] = str(error)
        raise
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
        output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
