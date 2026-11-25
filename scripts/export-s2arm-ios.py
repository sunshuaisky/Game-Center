"""Bridge the S2Arm universal-shell job to Game Center's import layout."""
import sys
from pathlib import Path

entry = Path(sys.argv[1])
sys.path.insert(0, str(entry.parent))
import ipa
import layout
import main
import program_pack


def require_space(budget):
    """Game Center stops before expensive work instead of treating shortage as advice."""
    from core import Failure
    for volume in budget["volumes"]:
        need, free = volume["needBytes"], volume["freeBytes"]
        # Leave room for export metadata, signing and unrelated system writes.
        reserve = max(2_000_000_000, need // 10)
        required = need + reserve
        if free < required:
            role = "游戏存放位置" if volume.get("role") == "library" else "构建缓存"
            raise Failure(
                f"磁盘空间不足，已在耗时构建前停止：{role}所在磁盘需要约 {required / 1e9:.1f} GB"
                f"（含 {reserve / 1e9:.1f} GB 余量），当前只有 {free / 1e9:.1f} GB。"
                "请释放空间或把游戏目录移到空间充足的磁盘后重试。存档和上次成功的游戏包会保留。",
                code="disk_full",
            )


def build_with_space_guard(context):
    import library
    original = library.check_pack_space
    def check(*args, **kwargs):
        budget = original(*args, **kwargs)
        require_space(budget)
        return budget
    library.check_pack_space = check
    try:
        return ipa.build(context)
    finally:
        library.check_pack_space = original


def export(context):
    gid = context.r["gameId"].upper()
    # The universal shell is installed independently of individual games.
    ipa.refresh_library_ipa = lambda _: None
    result = build_with_space_guard(context)
    package = program_pack.build(context, gid)
    identity = context.r.get("signIdentity", "-")
    team = context.r.get("teamID", "")
    bundle = context.r["bundleID"]
    if identity == "-" or not team:
        raise RuntimeError("iOS 游戏需要有效的开发证书签名，请配置 iOS 签名后重试。")
    import subprocess
    import json
    import plistlib
    def signer(dylib, _team, _bundle):
        if context.r.get("appleAccountSigning") is True:
            subprocess.run(["/usr/bin/python3", "-I", "-B", str(Path(__file__).with_name("apple-id-sign.py")),
                            "dylib", team, identity, bundle, str(dylib)], check=True)
            return
        import tempfile
        with tempfile.TemporaryDirectory() as staging:
            entitlements = Path(staging) / "game.plist"
            entitlements.write_bytes(plistlib.dumps({
                "application-identifier": team + "." + bundle,
                "com.apple.developer.team-identifier": team,
            }))
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, "--identifier", bundle,
                            "--force-library-entitlements", "--entitlements", str(entitlements),
                            "--generate-entitlement-der", str(dylib)], check=True)
    signer.kind = ("apple-id:" if context.r.get("appleAccountSigning") else "keychain-entitlements-v2:") + identity
    package = program_pack.sign(context, gid, team, bundle, signer, pkg=package)
    image = package / program_pack.image_name(gid)
    if not hasattr(program_pack, "_signer_tag"):
        signer(image, team, bundle)  # Older engines omit the certificate from the cache key.
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(image)], check=True)
    entitlements = subprocess.check_output(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(image)])
    grants = plistlib.loads(entitlements) if entitlements else {}
    if grants.get("application-identifier") != team + "." + bundle or grants.get("com.apple.developer.team-identifier") != team:
        raise RuntimeError("游戏程序未签入手机描述文件对应的应用和团队权限。")
    details = subprocess.run(["/usr/bin/codesign", "-dv", str(image)], capture_output=True, text=True, check=True)
    if "Identifier=" + bundle not in details.stderr.splitlines():
        raise RuntimeError("游戏程序签名标识校验失败")
    if "TeamIdentifier=" + team not in details.stderr.splitlines():
        raise RuntimeError("游戏程序签名团队校验失败")
    catalogue = package / "catalogue.json"
    info = json.loads(catalogue.read_text(encoding="utf-8"))
    info.update(team=team, signing_identifier=bundle, image_sha256=program_pack._sha(image))
    temp = catalogue.with_suffix(".json.tmp")
    temp.write_text(json.dumps(info, ensure_ascii=False), encoding="utf-8")
    temp.replace(catalogue)
    result["programPath"] = str(package)
    result["contentPath"] = str(layout.image_ios(context, gid) / layout.IOS_PACK)
    return result


sys.exit(main.run_request(Path(sys.argv[2]), operation_overrides={"ipa": export}))
