#!/usr/bin/env python3
"""Correlate cold/warm/sparse Canvas presentation with isolated persisted samples.

Requires an unlocked desktop and built release app/CLI. The cold timing includes
explicit isolated app process launch, not LaunchServices discovery. Drawing-pass
completion is measured; physical display scanout is not. Artifacts are retained.
"""
import argparse
import importlib.util
import json
import pathlib
import platform
import subprocess
import time

spec = importlib.util.spec_from_file_location('isolated_capture', pathlib.Path(__file__).with_name('isolated-capture.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--silent-seconds', type=float, default=120)
    parser.add_argument('--output', type=pathlib.Path, default=fixture.ROOT / '.build/first-visible-sample.json')
    parser.add_argument('--app', type=pathlib.Path)
    parser.add_argument('--pp', type=pathlib.Path)
    args = parser.parse_args()
    if args.silent_seconds < 0:
        parser.error('--silent-seconds must be nonnegative')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    capture = fixture.Capture(app=args.app, pp=args.pp)
    result = {'boundary': 'visible Canvas pass, not scanout', 'database': str(capture.database),
              'trace': str(capture.trace), 'coldLaunch': 'explicit isolated app process plus CLI',
              'macOS': platform.mac_ver()[0],
              'hardware': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip()}
    try:
        started = time.time()
        capture.launch()
        cold = capture.producer('-s', '-n', 'Cold sparse acceptance')
        cold.stdin.write('123.456\n')
        cold.stdin.flush()
        render = capture.wait_render('Cold sparse acceptance', 123.456, started)
        assert cold.poll() is None, 'First sample must appear before EOF'
        result['cold'] = {'start': started, 'render': render, 'seconds': render['wall'] - started}
        print('COLD', json.dumps(result['cold']), flush=True)
        started = time.time()
        warm = capture.producer('-c', '-n', 'Warm concurrent acceptance')
        warm.stdin.write('987.654\n')
        warm.stdin.flush()
        render = capture.wait_render('Warm concurrent acceptance', 987.654, started)
        result['warm'] = {'start': started, 'render': render, 'seconds': render['wall'] - started}
        print('WARM', json.dumps(result['warm']), flush=True)
        time.sleep(args.silent_seconds)
        # An unrelated chart renders during the intended sparse update.
        started = time.time()
        warm.stdin.write('876.543\n')
        warm.stdin.flush()
        cold.stdin.write('234.567\n')
        cold.stdin.flush()
        render = capture.wait_render('Cold sparse acceptance', 234.567, started)
        assert cold.poll() is None, 'Sparse update must appear before EOF'
        assert render['stream'] == result['cold']['render']['stream']
        competing = capture.wait_render('Warm concurrent acceptance', 876.543, started)
        assert competing['stream'] != render['stream']
        result['competingRender'] = competing
        result['sparse'] = {'silentSeconds': args.silent_seconds, 'start': started,
                            'render': render, 'seconds': render['wall'] - started}
        cold.stdin.write('345.678')
        capture.finish(cold)
        capture.finish(warm)
        for name, expected in [('Cold sparse acceptance', [123.456, 234.567, 345.678]),
                               ('Warm concurrent acceptance', [987.654, 876.543])]:
            rows = capture.rows(capture.stream(name))
            assert [value for _, value in rows] == expected, rows
        result['storedRows'] = {'cold': 3, 'warm': 2}
        result['passed'] = True
        print(json.dumps(result, indent=2))
    except Exception as error:
        result['error'] = str(error)
        raise
    finally:
        capture.close()
        args.output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
