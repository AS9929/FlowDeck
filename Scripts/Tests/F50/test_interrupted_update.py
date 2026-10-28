#!/usr/bin/env python3
"""恢复脚本的文件级故障注入。所有路径、进程、核心和包管理器均为本机替身。"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

fixtures = Path(sys.argv[1])


def executable(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)
    path.chmod(0o700)


cases = [
    ('core', 'switched', 'switching', True, True),
    ('core', 'before-switch', 'checking', False, True),
    ('core', 'verify-failed', 'verifying', True, True),
    ('core', 'bad-recovery', 'switching', True, False),
    ('core', 'unknown-current', 'switching', True, False),
    ('core', 'restart-fails', 'switching', True, False),
    ('core', 'preserve-stopped', 'switching', False, True),
    ('ufi', 'applied', 'installing', False, True),
    ('ufi', 'not-applied', 'installing', False, True),
]
for kind, name, stage, running, success in cases:
    with tempfile.TemporaryDirectory(prefix='flowdeck-interrupted-') as temporary:
        root = Path(temporary)
        folder = 'flowdeck-config' if kind == 'core' else 'flowdeck-packages'
        work = root / 'data/local' / folder
        job = work / (kind + '-job')
        job.mkdir(parents=True)
        (job / 'owner').write_text('previous-boot 12 100\n')
        (work / (kind + '-status')).write_text(stage)
        operation = root / 'data/local/flowdeck-config/operation'
        operation.mkdir(parents=True)
        (operation / 'owner').write_text(str(job))
        proc = root / 'proc'
        (proc / 'sys/kernel/random').mkdir(parents=True)
        (proc / 'sys/kernel/random/boot_id').write_text('new-boot\n')
        (proc / 'self').mkdir()
        (proc / 'self/stat').write_text(' '.join(['1'] * 22))
        binary = root / 'bin'
        executable(binary / 'sha256sum', '#!/bin/sh\nexec shasum -a 256 "$@"\n')
        executable(binary / 'timeout', '#!/bin/sh\nshift\nexec "$@"\n')
        executable(binary / 'sleep', '#!/bin/sh\nexit 0\n')
        executable(binary / 'pidof', '#!/bin/sh\ntest -f "$TEST_ROOT/running"\n')
        executable(binary / 'dumpsys', '#!/bin/sh\necho "versionCode=$(cat "$TEST_ROOT/version")"\n')
        executable(root / 'data/clash/Scripts/Clash.Service', '''#!/bin/sh
echo "$1" >> "$TEST_ROOT/calls"
if test "$1" = stop; then rm -f "$TEST_ROOT/running"; exit 0; fi
test "${FAIL_START:-0}" != 1 || exit 1
touch "$TEST_ROOT/running"
''')
        old = '#!/bin/sh\n# previous\nexit 0\n'
        candidate = '#!/bin/sh\n# candidate\nexit 0\n'
        core = root / 'data/clash/Proxy/Clash.Core'
        executable(core, candidate)
        executable(job / 'recovery', old)
        checksum = hashlib.sha256(old.encode()).hexdigest()
        if name == 'bad-recovery':
            checksum = '0' * 64
        if name == 'unknown-current':
            core.write_text('unexpected binary')
        (job / 'recovery.sha256').write_text(checksum + '  recovery\n')
        (job / 'candidate.sha256').write_text(hashlib.sha256(candidate.encode()).hexdigest())
        (job / 'was-running').write_text('1' if running else '0')
        (job / 'expected-code').write_text('416')
        (root / 'version').write_text('416' if name == 'applied' else '415')
        script = (fixtures / (kind + '-restore.sh')).read_text()
        script = script.replace('/data/', str(root / 'data') + '/')
        script = script.replace('/proc/$$/stat', '/proc/self/stat')
        script = script.replace('/proc/', str(proc) + '/')
        environment = dict(os.environ, PATH=str(binary) + ':' + os.environ['PATH'], TEST_ROOT=str(root))
        if name == 'restart-fails':
            environment['FAIL_START'] = '1'
        result = subprocess.run(['sh', '-c', script], env=environment, capture_output=True, text=True, timeout=8)
        assert ('recovery=done' in result.stdout) == success, (name, result)
        assert job.exists() != success, (name, 'recovery material retention')
        assert operation.exists() != success, (name, 'operation lock retention')
        if name in ['bad-recovery', 'unknown-current', 'before-switch']:
            assert not (root / 'calls').exists(), (name, 'unexpected service mutation')
        if kind == 'core' and name not in ['bad-recovery', 'unknown-current', 'before-switch']:
            assert core.read_text() == old, (name, 'restored binary mismatch')
        if kind == 'ufi':
            expected = 'done' if name == 'applied' else 'unconfirmed'
            assert (work / 'ufi-status').read_text().strip() == expected
        print('PASS', kind, name)
print('9 interrupted recovery scenarios passed; no device changes')
