import os
import sqlite3
import tempfile
import time
from pathlib import Path

SCHEMA = '''
CREATE TABLE samples(stream_id TEXT NOT NULL,timestamp REAL NOT NULL,sequence INTEGER NOT NULL,value REAL NOT NULL,segment_id TEXT,PRIMARY KEY(stream_id,sequence));
CREATE INDEX samples_by_time ON samples(stream_id,timestamp,sequence);
CREATE TABLE stream_meta(stream_id TEXT PRIMARY KEY,sample_count INTEGER NOT NULL DEFAULT 0,first_time REAL,last_time REAL,next_sequence INTEGER NOT NULL DEFAULT 0);
CREATE TABLE fit_versions(stream_id TEXT PRIMARY KEY,revision INTEGER NOT NULL DEFAULT 0,mutation INTEGER NOT NULL DEFAULT 0);
CREATE TRIGGER fit_insert AFTER INSERT ON samples BEGIN
 INSERT INTO fit_versions(stream_id,revision) VALUES(NEW.stream_id,1)
 ON CONFLICT(stream_id) DO UPDATE SET revision=revision+1;
END;
CREATE TABLE metadata_payload(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,payload BLOB NOT NULL);
CREATE TABLE session_state(id INTEGER PRIMARY KEY CHECK(id=1),last_time REAL);
'''

def trial(mode, rows, size, root):
    path = root / f'{mode}-{size}-{rows}.sqlite'
    con = sqlite3.connect(path, isolation_level=None)
    con.execute('PRAGMA journal_mode=WAL')
    con.execute('PRAGMA synchronous=NORMAL')
    con.executescript(SCHEMA)
    con.execute("INSERT INTO stream_meta(stream_id) VALUES('stream')")
    con.execute('INSERT INTO session_state(id,last_time) VALUES(1,NULL)')
    con.execute('INSERT INTO metadata_payload(id,version,payload) VALUES(1,1,?)', (b'x'*size,))
    json_path = root / f'{mode}-{size}-{rows}.json'
    payload = bytearray(b'x'*size)
    started = time.perf_counter()
    for index in range(rows):
        payload[:8] = index.to_bytes(8, 'little')
        con.execute('BEGIN IMMEDIATE')
        con.execute('INSERT INTO samples(stream_id,timestamp,sequence,value,segment_id) VALUES(?,?,?,?,?)', ('stream',float(index),index,float(index),'segment'))
        con.execute('UPDATE stream_meta SET sample_count=sample_count+1,first_time=COALESCE(first_time,?),last_time=?,next_sequence=? WHERE stream_id=?',(float(index),float(index),index+1,'stream'))
        if mode == 'payload':
            con.execute('UPDATE metadata_payload SET payload=? WHERE id=1', (bytes(payload),))
        if mode == 'normalized':
            con.execute('UPDATE session_state SET last_time=? WHERE id=1',(float(index),))
        con.execute('COMMIT')
        if mode == 'split':
            temp_path = root / f'{mode}-{size}-{rows}.tmp'
            temp_path.write_bytes(payload)
            os.replace(temp_path, json_path)
    elapsed = time.perf_counter()-started
    count = con.execute('SELECT COUNT(*) FROM samples').fetchone()[0]
    con.close()
    return elapsed,count

with tempfile.TemporaryDirectory(prefix='pipeplot32-models-') as temp:
    root = Path(temp)
    for rows in (1000,5000):
        for size in (878, 11883, 125657):
            for mode in ('split','payload','normalized'):
                elapsed,count=trial(mode,rows,size,root)
                print(f'model={mode} rows={rows} bytes={size} elapsed={elapsed:.6f}s raw_count={count}',flush=True)
