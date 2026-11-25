"""Game Center adapter for the Apple ID signing tools in the installed S2Arm release."""
import hashlib
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
resources = root / "AppleSigning"
if not resources.is_dir():
    resources = root / "Vendor/AppleSigning"
engine = resources / "Engine"
exe = resources / "ThirdParty/Impactor/plumesign-macos-universal"


def run(args, *, include_stderr=False):
    result = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, timeout=300)
    if result.returncode:
        raise ValueError("签名工具执行失败，请检查账号会话、证书有效期和设备注册状态。")
    return result.stdout + result.stderr if include_stderr else result.stdout


def main():
    operation, *args = sys.argv[1:]
    home = Path.home() / "Library/Application Support/Game Center/AppleSigning"
    os.environ.update(S2A_PLUME_HOME=str(home), XDG_CONFIG_HOME=str(home), RUST_LOG="info")
    sys.path[:0] = [str(resources / "Jobs"), str(engine / "pack/orch")]
    import impactor
    import install_win as signing
    if operation == "check":
        for tool in [exe, engine / "Binaries/Prepare/selfsign/s2a-selfsign", engine / "Binaries/Prepare/rcodesign/rcodesign"]:
            if not os.access(tool, os.X_OK):
                raise ValueError("应用缺少 Apple ID 签名工具，请重新安装 Game Center。")
        run([exe, "--version"])
        return
    team, *args = args
    if not re.fullmatch(r'[A-Za-z0-9]{10}', team) or impactor.selected_team() != team:
        raise ValueError("Apple ID 登录状态已变化，请重新选择签名账号。")
    if operation == "ipa":
        source, destination, bundle = args
        # Plume may revoke an existing certificate when Apple's quota is exhausted.
        listing = run([exe, "account", "certificates", "--team", team], include_stderr=True).decode(errors="replace")
        key = signing.plume_key_path(team)
        mine = signing.key_modulus(key.read_text()) if key.is_file() else None
        certs = signing.parse_certs(listing)
        if not certs and not re.search(r'\[\s*\]\s*$', listing):
            raise ValueError("无法确认账号的开发证书状态，未申请新证书。")
        if certs and not any(mine and signing.cert_modulus_and_start(c['der'])[0] == mine
                             and c['machine'] == signing.PLUME_MACHINE_NAME for c in certs):
            raise ValueError("这个 Apple ID 已有其他工具创建的开发证书。为保留现有安装，请用原证书签名，或继续使用 AltStore 安装基础 IPA。")
        run([exe, "sign", "--package", source, "--apple-id", "--custom-identifier", bundle, "-o", destination])
        with tempfile.TemporaryDirectory(dir=home) as d:
            run(["/usr/bin/ditto", "-x", "-k", destination, d])
            app, = (Path(d) / "Payload").glob("*.app")
            run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
            profile = plistlib.loads(run(["/usr/bin/security", "cms", "-D", "-i", app / "embedded.mobileprovision"]))
            from datetime import datetime
            if profile["ExpirationDate"] <= datetime.utcnow():
                raise ValueError("生成的 IPA 描述文件已过期。")
            prefix = str(Path(d) / "signer")
            run(["/usr/bin/codesign", "-d", "--extract-certificates=" + prefix, app])
            if Path(prefix + "0").read_bytes() not in profile["DeveloperCertificates"]:
                raise ValueError("生成的 IPA 使用了描述文件未授权的开发证书。")
            if profile["Entitlements"]["application-identifier"] != team + "." + bundle:
                raise ValueError("生成的 IPA 签名标识与选中的账号不匹配。")
        return
    ident = signing.plume_identity(exe, team)
    if not ident:
        raise ValueError("此 Apple ID 尚无可用于游戏的本机签名私钥或有效证书。请先生成签名 IPA，或使用安装手机 App 时的原证书。")
    validity = subprocess.run(["/usr/bin/openssl", "x509", "-inform", "DER", "-noout", "-checkend", "0"],
                              input=ident["cert"], capture_output=True)
    if validity.returncode:
        raise ValueError("Apple ID 开发证书已过期或无效，请续签后再构建。")
    fp = hashlib.sha1(ident["cert"]).hexdigest().upper()
    if operation == "fingerprint":
        print(fp)
        return
    expected, bundle, target = args
    if fp != expected:
        raise ValueError("构建期间签名证书发生变化，请重新检查手机签名。")
    key = signing.plume_key_path(team)
    with tempfile.TemporaryDirectory(dir=home) as d:
        cert = Path(d) / "cert.der"
        cert.write_bytes(ident["cert"])
        if operation == "dylib":
            run([engine / "Binaries/Prepare/selfsign/s2a-selfsign", "--key", key, "--cert", cert,
                 "--bundle-id", bundle, "--team", team, target])
        elif operation == "framework":
            info = Path(target) / "Info.plist"
            data = plistlib.loads(info.read_bytes())
            data["CFBundleIdentifier"] = bundle
            info.write_bytes(plistlib.dumps(data))
            run([engine / "Binaries/Prepare/rcodesign/rcodesign", "sign", "--pem-file", key,
                 "--certificate-der-file", cert, "--team-name", team, "--timestamp-url", "none", target])
        else:
            raise ValueError("未知签名操作。")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except ValueError as error:
        sys.exit(str(error))
    except Exception:
        sys.exit("无法完成 Apple ID 签名，请检查 S2Arm 安装、账号及网络连接。")
