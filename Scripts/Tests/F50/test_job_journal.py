#!/usr/bin/env python3
"""执行 App 导出的任务检查和恢复脚本，验证重启、PID 复用与锁归属；不访问设备。"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

fixtures = Path(sys.argv[1])


def stat(ticks):
    return ' '.join(['1'] * 21 + [str(ticks)])


def run(script, root):
    script = script.replace('/data/', str(root / 'data') + '/')
    script = script.replace('/proc/$$/stat', '/proc/self/stat')
    script = script.replace('/proc/', str(root / 'proc') + '/')
    return subprocess.run(['sh', '-c', script], capture_output=True, text=True, timeout=5)


cases = [
    ('alive', 'now 12 100', True, 100, 'alive', 'restart-required'),
    ('pid-reused', 'now 12 99', True, 100, 'orphaned', 'restart-required'),
    ('dead-process', 'now 12 100', False, 100, 'orphaned', 'restart-required'),
    ('rebooted', 'previous 12 100', False, 100, 'interrupted', 'done'),
    ('legacy-no-owner', None, False, 100, 'unknown', 'unknown-owner'),
]
for kind in ['core', 'ufi']:
    for name, owner, live, ticks, health, recovery in cases:
        with tempfile.TemporaryDirectory(prefix='flowdeck-journal-') as temporary:
            root = Path(temporary)
            work = root / ('data/local/flowdeck-config' if kind == 'core' else 'data/local/flowdeck-packages')
            job = work / (kind + '-job')
            job.mkdir(parents=True)
            proc = root / 'proc'
            (proc / 'sys/kernel/random').mkdir(parents=True)
            (proc / 'sys/kernel/random/boot_id').write_text('now\n')
            (proc / 'self').mkdir()
            (proc / 'self/stat').write_text(stat(123))
            if owner:
                (job / 'owner').write_text(owner + '\n')
            if live:
                (proc / '12').mkdir()
                (proc / '12/stat').write_text(stat(ticks))
            operation = root / 'data/local/flowdeck-config/operation'
            operation.mkdir(parents=True)
            (operation / 'owner').write_text(str(job))
            result = run((fixtures / (kind + '-inspect.sh')).read_text(), root)
            assert 'job_health=' + health in result.stdout, (name, result)
            result = run((fixtures / (kind + '-recover.sh')).read_text(), root)
            assert 'recovery=' + recovery in result.stdout, (name, result)
            assert job.exists() == (recovery != 'done'), name
            assert operation.exists() == (recovery != 'done'), name
            print('PASS', kind, name)

    # 另一事务持锁时，只报告冲突，不能把锁删除。
    with tempfile.TemporaryDirectory(prefix='flowdeck-journal-') as temporary:
        root = Path(temporary)
        work = root / ('data/local/flowdeck-config' if kind == 'core' else 'data/local/flowdeck-packages')
        job = work / (kind + '-job')
        job.mkdir(parents=True)
        (job / 'owner').write_text('previous 12 100\n')
        proc = root / 'proc'
        (proc / 'sys/kernel/random').mkdir(parents=True)
        (proc / 'sys/kernel/random/boot_id').write_text('now\n')
        (proc / 'self').mkdir()
        (proc / 'self/stat').write_text(stat(123))
        operation = root / 'data/local/flowdeck-config/operation'
        operation.mkdir(parents=True)
        (operation / 'owner').write_text('another-task')
        result = run((fixtures / (kind + '-recover.sh')).read_text(), root)
        assert 'recovery=foreign-lock' in result.stdout, result
        assert (operation / 'owner').read_text() == 'another-task'
        assert job.exists()
        print('PASS', kind, 'foreign-lock')

print('12 isolated journal scenarios passed; no device changes')
