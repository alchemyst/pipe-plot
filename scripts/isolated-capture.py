"""Shared isolated native-app fixture. Never uses the installed app or user store."""
import json
import os
import pathlib
import sqlite3
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent


class Capture:
    def __init__(self, app=None, pp=None, trace=None):
        self.directory = pathlib.Path(tempfile.mkdtemp(prefix='pipeplot-acceptance-', dir='/tmp'))
        self.database = self.directory / 'acceptance.sqlite'
        self.trace = trace or self.directory / 'render.jsonl'
        self.socket = self.directory / 'capture.sock'
        self.pp = str(pp or ROOT / '.build/release/pp')
        self.app = str(app or ROOT / '.build/xcode/Build/Products/Release/PipePlot.app/Contents/MacOS/PipePlot')
        self.env = dict(os.environ, PIPEPLOT_ACCEPTANCE_DATABASE=str(self.database),
                        PIPEPLOT_ACCEPTANCE_SOCKET=str(self.socket), PIPEPLOT_SOCKET=str(self.socket))
        self.children = []
        self.process = None

    def launch(self):
        self.process = subprocess.Popen([self.app, '--pipeplot-launched-by-cli', '--acceptance-trace', str(self.trace)],
                                        env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def producer(self, *arguments):
        child = subprocess.Popen([self.pp, *arguments], env=self.env, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(child)
        return child

    def streams(self):
        try:
            data = json.loads(self.database.with_suffix('.sqlite.metadata.json').read_text())
            return [(session, chart, stream) for session in data['sessions']
                    for chart in session['charts'] for stream in chart['streams']]
        except (FileNotFoundError, json.JSONDecodeError):
            return []

    def stream(self, name):
        matches = [stream for _, _, stream in self.streams() if stream['name'] == name]
        return matches[0] if len(matches) == 1 else None

    def rows(self, stream):
        if not self.database.exists():
            return []
        with sqlite3.connect(f'file:{self.database}?mode=ro', uri=True) as connection:
            return connection.execute('SELECT timestamp,value FROM samples WHERE stream_id=? ORDER BY sequence',
                                      (stream['id'].lower(),)).fetchall()

    @staticmethod
    def wait(check, description, seconds=30):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = check()
            if value:
                return value
            time.sleep(.01)
        raise RuntimeError(f'Timed out: {description}')

    def wait_render(self, name, value, after):
        def match():
            stream = self.stream(name)
            if not stream:
                return None
            timestamps = {timestamp for timestamp, observed in self.rows(stream) if observed == value}
            if not timestamps or not self.trace.exists():
                return None
            for line in self.trace.read_text().splitlines():
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if (record.get('event') == 'visible-sample-render' and record['wall'] >= after
                        and record.get('stream') == stream['id'].lower()
                        and record.get('sampleWall') in timestamps):
                    return record
            return None
        return self.wait(match, f'render of {name} value {value}')

    @staticmethod
    def finish(child):
        child.stdin.close()
        code = child.wait(timeout=15)
        stdout, stderr = child.stdout.read(), child.stderr.read()
        if code or stdout or stderr:
            raise RuntimeError((code, stdout, stderr))

    def close(self):
        for child in self.children + ([self.process] if self.process else []):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
