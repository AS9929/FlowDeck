#!/usr/bin/env python3
"""隔离执行 App 生成的 UFI 更新事务；pm/app_process 全部替身，不访问 F50。"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

fixtures = Path(sys.argv[1])


def executable(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o700)


cases = [
    ('success', {}, 'done', True),
    ('bad-digest', {'BAD_DIGEST': '1'}, 'rejected', False),
    ('bad-signature', {'BAD_SIGNATURE': '1'}, 'rejected', False),
    ('stale-version', {'STALE': '1'}, 'rejected', False),
    ('concurrent-operation', {'BUSY': '1'}, 'rejected', False),
    ('install-rejected', {'INSTALL_FAIL': '1'}, 'rejected', True),
    ('version-not-applied', {'NO_APPLY': '1'}, 'unconfirmed', True),
    ('rollback', {'ROLLBACK': '1'}, 'done', True),
    ('rollback-refused', {'ROLLBACK': '1', 'INSTALL_FAIL': '1'}, 'rejected', True),
]
for name, flags, status, invokes_install in cases:
    with tempfile.TemporaryDirectory(prefix='flowdeck-service-test-') as temporary:
        root = Path(temporary)
        work = root / 'data/local/flowdeck-packages'
        (work / 'ufi-job').mkdir(parents=True)
        locks = root / 'data/local/flowdeck-config'
        locks.mkdir()
        if flags.get('BUSY'):
            (locks / 'operation').mkdir()
        binary = root / 'bin'
        binary.mkdir()
        # Android /proc 的启动标识与进程时钟由固定文件模拟。
        proc = root / 'proc'
        proc.mkdir()
        (proc / 'boot').write_text('boot-fixture')
        (proc / 'stat').write_text(' '.join(['1'] * 22))
        payload = b'public apk fixture'
        checksum = hashlib.sha256(payload).hexdigest()
        (work / checksum).write_bytes(payload)
        (root / 'installed.apk').write_bytes(b'old apk')
        (root / 'version').write_text('415')
        rollback = flags.get('ROLLBACK') == '1'
        if rollback:
            (work / 'ufi.previous.apk').write_bytes(payload)
            (work / 'ufi.previous.sha256').write_text(checksum + '  ufi.previous.apk\n')
        script = (fixtures / ('rollback.sh' if rollback else 'install.sh')).read_text()
        script = script.replace('/data/', str(root / 'data') + '/')
        script = script.replace('a' * 64, '0' * 64 if flags.get('BAD_DIGEST') else checksum)
        script = script.replace('/proc/sys/kernel/random/boot_id', str(proc / 'boot')).replace('/proc/$$/stat', str(proc / 'stat'))
        executable(root / 'job.sh', script)
        executable(binary / 'sha256sum', '#!/bin/sh\nexec shasum -a 256 "$@"\n')
        executable(binary / 'sleep', '#!/bin/sh\nexit 0\n')
        executable(binary / 'am', '#!/bin/sh\nexit 0\n')
        executable(binary / 'app_process', '''#!/bin/sh
if test "${BAD_SIGNATURE:-0}" = 1; then echo status=rejected; exit 0; fi
if test "${ROLLBACK:-0}" = 1; then code=414; else code=416; fi
if test "${STALE:-0}" = 1; then code=415; fi
printf 'status=verified\\ncode=%s\\ninstalled_code=415\\n' "$code"
''')
        executable(binary / 'pm', '''#!/bin/sh
if test "$1" = path; then echo "package:$TEST_ROOT/installed.apk"; exit 0; fi
touch "$TEST_ROOT/invoked"
if test "${INSTALL_FAIL:-0}" = 1; then exit 1; fi
if test "${NO_APPLY:-0}" != 1; then
 if test "${ROLLBACK:-0}" = 1; then echo 414; else echo 416; fi > "$TEST_ROOT/version"
fi
exit 0
''')
        executable(binary / 'dumpsys', '#!/bin/sh\necho "versionCode=$(cat "$TEST_ROOT/version")"\n')
        environment = dict(os.environ, PATH=str(binary) + ':' + os.environ['PATH'], TEST_ROOT=str(root), **flags)
        subprocess.run(['sh', str(root / 'job.sh')], env=environment, capture_output=True, timeout=10)
        assert (work / 'ufi-status').read_text().strip() == status, name
        assert (root / 'invoked').exists() == invokes_install, name
        assert not (work / 'ufi-job').exists(), name
        assert (locks / 'operation').exists() == bool(flags.get('BUSY')), name
        if rollback:
            assert (work / 'ufi.previous.apk').read_bytes() == payload, name
        print('PASS', name)
print('9 isolated service update scenarios passed')
