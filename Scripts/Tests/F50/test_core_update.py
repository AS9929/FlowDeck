#!/usr/bin/env python3
"""在临时目录模拟核心事务失败点；不访问网络或设备，不执行真实 Mihomo。"""
import gzip
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

fixtures = Path(sys.argv[1])
install = (fixtures / 'install.sh').read_text()
rollback = (fixtures / 'rollback.sh').read_text()


def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o700)


def core(version):
    return f'''#!/bin/sh
# {version}
if test "$1" = -v; then echo 'Mihomo Meta {version} android arm64'; exit 0; fi
if test "$1" = -t && test "${{FAIL_VALIDATION:-0}}" = 1 && test '{version}' = v1.19.32; then exit 1; fi
exit 0
'''


cases = [
    ('success', {}, 'done', True, True),
    ('offline', {'OFFLINE': '1'}, 'done', True, True),
    ('download-failure', {'FAIL_DOWNLOAD': '1'}, 'failed-before-switch', False, True),
    ('digest-failure', {'FAIL_DIGEST': '1'}, 'failed-before-switch', False, True),
    ('validation-failure', {'FAIL_VALIDATION': '1'}, 'failed-before-switch', False, True),
    ('start-failure', {'FAIL_START': '1'}, 'rolled-back', False, True),
    ('egress-failure', {'FAIL_EGRESS': '1'}, 'rolled-back', False, True),
    ('preserve-stopped', {}, 'done', True, False),
    ('rollback', {'ROLLBACK': '1'}, 'done', False, True),
    ('rollback-stopped', {'ROLLBACK': '1'}, 'done', False, False),
    ('invalid-backup', {'ROLLBACK': '1', 'BAD_BACKUP': '1'}, 'failed-before-switch', True, True),
]
for name, flags, expected_status, expect_new, was_running in cases:
    with tempfile.TemporaryDirectory(prefix='flowdeck-core-test-') as temporary:
        root = Path(temporary)
        runtime = root / 'data/clash/Proxy'
        runtime.mkdir(parents=True)
        work = root / 'data/local/flowdeck-config'
        (work / 'core-job').mkdir(parents=True)
        binary = root / 'bin'
        binary.mkdir()
        # Android /proc 的启动标识与进程时钟由固定文件模拟。
        proc = root / 'proc'
        proc.mkdir()
        (proc / 'boot').write_text('boot-fixture')
        (proc / 'stat').write_text(' '.join(['1'] * 22))
        old = core('v1.19.31')
        new = core('v1.19.32')
        executable(runtime / 'Clash.Core', new if flags.get('ROLLBACK') else old)
        (runtime / 'config.yaml').write_text('rules: []\n')
        if flags.get('ROLLBACK'):
            executable(runtime / '.flowdeck-core.previous', old)
            digest = '0' * 64 if flags.get('BAD_BACKUP') else hashlib.sha256(old.encode()).hexdigest()
            (runtime / '.flowdeck-core.previous.sha256').write_text(digest + '  .flowdeck-core.previous\n')
        compressed = gzip.compress(new.encode())
        (root / 'payload.gz').write_bytes(compressed)
        digest = '0' * 64 if flags.get('FAIL_DIGEST') else hashlib.sha256(compressed).hexdigest()
        if flags.get('OFFLINE'):
            packages = root / 'data/local/flowdeck-packages'
            packages.mkdir()
            (packages / digest).write_bytes(compressed)
            text = (fixtures / 'offline.sh').read_text()
        else:
            text = rollback if flags.get('ROLLBACK') else install
        text = text.replace('/data/', str(root / 'data') + '/')
        text = text.replace('a' * 64, digest).replace('--max-filesize 100 ', '--max-filesize ' + str(len(compressed)) + ' ')
        text = text.replace("= '100'", "= '" + str(len(compressed)) + "'")
        text = text.replace('/proc/sys/kernel/random/boot_id', str(proc / 'boot')).replace('/proc/$$/stat', str(proc / 'stat'))
        executable(root / 'transaction.sh', text)
        if was_running:
            (root / 'running').touch()
        executable(binary / 'getprop', '#!/bin/sh\necho arm64-v8a\n')
        executable(binary / 'sleep', '#!/bin/sh\nexit 0\n')
        executable(binary / 'pidof', '#!/bin/sh\ntest -f "$TEST_ROOT/running"\n')
        executable(binary / 'timeout', '#!/bin/sh\nshift\nexec "$@"\n')
        executable(binary / 'stat', '#!/bin/sh\n/usr/bin/stat -f %z "$3"\n')
        executable(binary / 'sha256sum', '''#!/usr/bin/env python3
import hashlib,sys,pathlib
if sys.argv[1] == '-c':
    lines = sys.stdin.read() if sys.argv[2] == '-' else pathlib.Path(sys.argv[2]).read_text()
    for line in lines.splitlines():
        digest, name = line.split(None, 1)
        if hashlib.sha256(pathlib.Path(name.strip()).read_bytes()).hexdigest() != digest:
            sys.exit(1)
else:
    path = pathlib.Path(sys.argv[1])
    print(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + str(path))
''')
        executable(root / 'data/data/com.minikano.f50_sms/files/curl', '''#!/bin/sh
case "$*" in
    *--write-out*)
        if test "${FAIL_EGRESS:-0}" = 1; then echo 503; else echo 204; fi ;;
    *)
        test "${FAIL_DOWNLOAD:-0}" != 1 || exit 1
        while test "$#" -gt 0; do
            if test "$1" = -o; then cp "$TEST_ROOT/payload.gz" "$2"; exit 0; fi
            shift
        done
        exit 1 ;;
esac
''')
        executable(root / 'data/clash/Scripts/Clash.Service', '''#!/bin/sh
echo "$1" >> "$TEST_ROOT/service-calls"
if test "$1" = stop; then rm -f "$TEST_ROOT/running"; exit 0; fi
if test "${FAIL_START:-0}" = 1 && head -2 "$TEST_ROOT/data/clash/Proxy/Clash.Core" | grep -q v1.19.32; then exit 1; fi
touch "$TEST_ROOT/running"
''')
        environment = dict(os.environ, TEST_ROOT=str(root), PATH=str(binary) + ':' + os.environ['PATH'], **flags)
        subprocess.run(['/bin/sh', '-n', str(root / 'transaction.sh')], check=True)
        result = subprocess.run(['/bin/sh', str(root / 'transaction.sh')], env=environment,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        status = (work / 'core-status').read_text().strip()
        assert status == expected_status, (name, status, result.stderr.decode(), (runtime / "Clash.Core").read_text(), (root / "service-calls").read_text() if (root / "service-calls").exists() else "", (root / "running").exists())
        assert (runtime / 'Clash.Core').read_text() == (new if expect_new else old), name
        assert (root / 'running').exists() == (was_running or (bool(flags.get('ROLLBACK')) and expected_status == 'done')), name
        assert not (work / 'operation').exists(), name
        if expected_status == 'failed-before-switch':
            assert not (root / 'service-calls').exists(), name
        print('PASS', name)
print('11 core transaction scenarios passed; no device changes')
