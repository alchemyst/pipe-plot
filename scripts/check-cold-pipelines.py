#!/usr/bin/env python3
"""Verify concurrent cold pipelines against exact isolated persisted observations."""
import importlib.util
import pathlib
import time

spec = importlib.util.spec_from_file_location('isolated_capture', pathlib.Path(__file__).with_name('isolated-capture.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def main():
    capture = fixture.Capture()
    try:
        capture.launch()
        producers = [capture.producer('-n', f'Concurrent {index}') for index in range(2)]
        for index, process in enumerate(producers):
            process.stdin.write(f'{index + 1}\n')
            process.stdin.flush()
        capture.wait(lambda: len(capture.streams()) == 2, 'two registered streams')
        for index, process in enumerate(producers):
            # Final valid rows intentionally have no newline.
            process.stdin.write(str(index + 11))
            capture.finish(process)
        streams = capture.streams()
        assert len(streams) == 2, streams
        assert len({session['id'] for session, _, _ in streams}) == 1
        assert len({chart['id'] for _, chart, _ in streams}) == 1
        assert len({stream['id'] for _, _, stream in streams}) == 2
        for index in range(2):
            rows = capture.rows(capture.stream(f'Concurrent {index}'))
            assert [value for _, value in rows] == [index + 1, index + 11], rows
        print(f'Passed: one session/chart, two distinct streams, exact rows; {capture.database}')
    finally:
        capture.close()


if __name__ == '__main__':
    main()
