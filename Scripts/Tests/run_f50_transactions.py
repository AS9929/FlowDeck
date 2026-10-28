#!/usr/bin/env python3
"""运行从 Swift 单元测试导出的 F50 事务脚本；仅使用临时目录，不连接设备。

参数为模拟器 App 的 Documents 目录，须先运行完整单元测试导出三个 fixture 目录。
任一子测试失败立即退出；不在本脚本中重新生成或替换生产脚本。
"""

import argparse
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixtures", type=Path, help="包含 CoreScriptFixtures、ServiceScriptFixtures 和 JournalFixtures 的目录")
    arguments = parser.parse_args()
    scripts = Path(__file__).resolve().parent / "F50"
    cases = [
        ("test_core_update.py", "CoreScriptFixtures"),
        ("test_service_update.py", "ServiceScriptFixtures"),
        ("test_job_journal.py", "JournalFixtures"),
        ("test_interrupted_update.py", "JournalFixtures"),
    ]
    for filename, directory in cases:
        fixtures = arguments.fixtures / directory
        if not fixtures.is_dir():
            parser.error(f"缺少 {fixtures}，请先运行 Swift 单元测试导出 fixture")
        subprocess.run([sys.executable, str(scripts / filename), str(fixtures)], check=True)


if __name__ == "__main__":
    main()
