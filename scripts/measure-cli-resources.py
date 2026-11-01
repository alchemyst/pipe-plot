#!/usr/bin/env python3
"""Read-only process counters around idle and five-second CLI capture phases.
Creates one retained session in the installed app; does not close user sessions.
"""
import argparse
import json
import pathlib
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=float, default=60, help='duration of each phase')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error('--seconds must be positive')
    root = pathlib.Path(__file__).resolve().parent.parent
    output = args.output or root/'.build/cli-resources.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    helper = root/'.build/process-resources'
    subprocess.run(['clang', '-O2', '-Wall', '-Wextra', str(root/'scripts/process-resources.c'), '-o', str(helper)], check=True)
    pids = subprocess.check_output(['pgrep', '-x', 'PipePlot'], text=True).split()
    if len(pids) != 1:
        raise SystemExit('Run the installed PipePlot app first; expected exactly one production process.')
    app_pid = pids[0]
    pp = pathlib.Path.home()/'.local/bin/pp'
    child = subprocess.Popen([str(pp), '-s', '-n', 'Resource acceptance'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    result = {'phaseSeconds': args.seconds, 'appPid': int(app_pid), 'cliPid': child.pid, 'phases': []}

    def counters(pid):
        return json.loads(subprocess.check_output([str(helper), str(pid)], text=True))

    try:
        child.stdin.write('0\n'); child.stdin.flush()
        time.sleep(2)
        for name in ['idle-connected', 'ingest-five-seconds']:
            before = {'app': counters(app_pid), 'cli': counters(child.pid)}
            started = time.monotonic(); next_sample = started; samples = 0
            peaks = {'app': before['app']['rss'], 'cli': before['cli']['rss']}
            while time.monotonic() - started < args.seconds:
                now = time.monotonic()
                if name == 'ingest-five-seconds' and now >= next_sample:
                    samples += 1; child.stdin.write(f'{samples}\n'); child.stdin.flush(); next_sample = now + 5
                for label, pid in [('app', app_pid), ('cli', child.pid)]:
                    peaks[label] = max(peaks[label], counters(pid)['rss'])
                time.sleep(.25)
            elapsed = time.monotonic() - started
            after = {'app': counters(app_pid), 'cli': counters(child.pid)}
            phase = {'name': name, 'elapsed': elapsed, 'newRows': samples, 'before': before, 'after': after, 'peakRSS': peaks}
            for label in ['app', 'cli']:
                a,b = before[label],after[label]
                phase[label+'CPUPercentOneCore'] = 100*(b['userNanoseconds']+b['systemNanoseconds']-a['userNanoseconds']-a['systemNanoseconds'])/1e9/elapsed
                phase[label+'InterruptWakeupsPerSecond'] = (b['interruptWakeups']-a['interruptWakeups'])/elapsed
            result['phases'].append(phase)
            output.write_text(json.dumps(result, indent=2)+'\n')
            print(json.dumps(phase), flush=True)
        child.stdin.close()
        result['exitCode'] = child.wait(timeout=10)
        result['stdout'] = child.stdout.read(); result['stderr'] = child.stderr.read()
        if result['exitCode'] or result['stdout'] or result['stderr']:
            raise RuntimeError((result['exitCode'], result['stdout'], result['stderr']))
    finally:
        if child.poll() is None:
            child.terminate(); child.wait(timeout=5)
        output.write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
