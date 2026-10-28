#!/usr/bin/env python3
"""检查暂存目录中的公开交付边界；不连接设备，不读取或打印凭据内容。

在提交前先 git add，再运行本脚本。工作树内容用于检查；Git 历史另由 Gitleaks 检查。
"""

from pathlib import Path
import re
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parent.parent
    output = subprocess.check_output(["git", "ls-files", "-z"], cwd=root)
    files = [name for name in output.decode().split("\0") if name]
    errors = []
    forbidden = re.compile(
        r"(^|/)(?:Local\.xcconfig|\.env(?:\..*)?|BootstrapWebSSH\.bin|"
        r"Offline-.*\.gz|OfflineDeploymentManifest\.json)$|"
        r"\.(?:p12|p8|mobileprovision|xcresult|zip|tar|gz)$"
    )
    for name in files:
        path = root / name
        if forbidden.search(name):
            errors.append(f"禁止公开的文件: {name}")
        if path.is_symlink():
            errors.append(f"交付文件不能引用本机符号链接: {name}")
        if name.endswith(".dex") and name != "FlowDeck/Resources/F50ConfigBridge.dex":
            errors.append(f"未登记来源的 dex: {name}")
    for required in (
        "LICENSE", "THIRD_PARTY.md", "SECURITY.md", "CONTRIBUTING.md",
        "Config/App.xcconfig", "Config/Local.xcconfig.example",
        "Scripts/F50ConfigBridge/FlowDeckConfig.java",
        "Scripts/F50ConfigBridge/FlowDeckPackage.java",
        "Scripts/F50ConfigBridge/FlowDeckProbe.java",
    ):
        if required not in files:
            errors.append(f"缺少交付文件: {required}")
    project = (root / "project.yml").read_text()
    if re.search(r"DEVELOPMENT_TEAM:\s*[A-Z0-9]{10}", project):
        errors.append("project.yml 仍写死维护者 Team")
    for source in (root / "FlowDeckTests").rglob("*.swift"):
        if "@testable import U60Manager" in source.read_text():
            errors.append(f"过期模块引用: {source.relative_to(root)}")
    flags = root / "DesignResources/Flags"
    if (flags / "CN.svg").read_bytes() != (flags / "TW.svg").read_bytes():
        errors.append("CN/TW 展示资源未保持一致")
    if "<use" in (flags / "CN.svg").read_text():
        errors.append("CN 星形尚未展开，Quick Look 可能显示不完整")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"公开交付边界检查通过：{len(files)} 个 Git 跟踪文件")
    return 0


if __name__ == "__main__":
    sys.exit(main())
