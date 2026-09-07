#!/usr/bin/env python3
"""
Check the iOS shell for the mistakes that fail silently.

Runs anywhere — no Mac needed — and is worth running before every archive.
Everything here is something that either produces a broken app with no error
message, or costs a full Xcode round-trip to discover. See
docs/architecture/ios-app.md.

Usage:  python3 scripts/ios-preflight.py     (or: npm run ios:check)
        python3 scripts/ios-preflight.py --native-only

`--native-only` drops the two checks that read `src/`, for the public export
built by scripts/ios-shell-export.sh, which carries no application source.
"""

import json
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "com.raghamapp.app"
NATIVE_ONLY = "--native-only" in sys.argv[1:]

failures: list[str] = []
passes: list[str] = []
skipped: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    """`detail` is remediation advice, so it is shown only when the check fails."""
    if ok:
        passes.append(name)
    else:
        failures.append(f"{name}{f' — {detail}' if detail else ''}")


def read(rel: str) -> str:
    return (ROOT / rel).read_text()


# 1. The bundle-size invariant. A static `import ... from "@capacitor/x"` in
#    src/native ships the SDK to every web visitor, and nothing fails when it is
#    added — the cost is invisible until someone measures the bundle.
if NATIVE_ONLY:
    skipped.append("src/native has no static @capacitor imports")
else:
    static_imports = []
    for f in sorted((ROOT / "src/native").glob("*.ts*")):
        for n, line in enumerate(f.read_text().splitlines(), 1):
            # `import type` is erased by TypeScript and costs the bundle nothing,
            # so only a value import is a problem here.
            if re.match(r'\s*import\s+(?!type\s)[^;]*from\s+["\']@capacitor/', line):
                static_imports.append(f"{f.relative_to(ROOT)}:{n}")
    check(
        "src/native has no static @capacitor imports",
        not static_imports,
        "found: " + ", ".join(static_imports) if static_imports else "",
    )

# 2. Push dies silently without these two AppDelegate methods; Capacitor's
#    template omits them, so regenerating ios/ drops them again.
app_delegate = read("ios/App/App/AppDelegate.swift")
check(
    "AppDelegate forwards APNs registration",
    "capacitorDidRegisterForRemoteNotifications" in app_delegate
    and "capacitorDidFailToRegisterForRemoteNotifications" in app_delegate,
    "add the two methods from @capacitor/push-notifications' README",
)

# 3. The push entitlement, and the build setting that makes it apply.
ent = plistlib.loads((ROOT / "ios/App/App/App.entitlements").read_bytes())
check("App.entitlements declares aps-environment", ent.get("aps-environment") == "production")
pbx = read("ios/App/App.xcodeproj/project.pbxproj")
check(
    "pbxproj wires CODE_SIGN_ENTITLEMENTS (both configs)",
    pbx.count("CODE_SIGN_ENTITLEMENTS = App/App.entitlements;") == 2,
    f"found {pbx.count('CODE_SIGN_ENTITLEMENTS = App/App.entitlements;')} of 2",
)

# 4. Xcode keeps schemes in gitignored xcuserdata, so a fresh clone has none and
#    `xcodebuild -scheme App` fails. The shared scheme must exist AND point at a
#    target id that still exists in the project.
scheme_path = ROOT / "ios/App/App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"
if not scheme_path.exists():
    check("shared App.xcscheme exists", False, "xcodebuild will fail on a fresh clone")
else:
    blueprints = set(re.findall(r'BlueprintIdentifier = "([^"]+)"', scheme_path.read_text()))
    target_ids = set(re.findall(r"([0-9A-F]{24}) /\* App \*/ = \{\s*isa = PBXNativeTarget", pbx))
    check(
        "shared scheme points at the real target",
        bool(blueprints) and blueprints <= target_ids,
        f"scheme={blueprints} project={target_ids}",
    )

# 5. Info.plist. A missing usage string is a crash at the call site, not a
#    denied permission.
info = plistlib.loads((ROOT / "ios/App/App/Info.plist").read_bytes())
for key, why in [
    ("NSCameraUsageDescription", "cheque barcode scanner crashes without it"),
    ("NSPhotoLibraryUsageDescription", "image pickers"),
    ("NSPhotoLibraryAddUsageDescription", "saving invoices"),
]:
    check(f"Info.plist has {key}", bool(info.get(key)), why)

check(
    "Info.plist registers the raghamapp:// scheme",
    any("raghamapp" in t.get("CFBundleURLSchemes", []) for t in info.get("CFBundleURLTypes", [])),
)
check(
    "Info.plist enables remote-notification background mode",
    "remote-notification" in info.get("UIBackgroundModes", []),
)
check("Info.plist display name is Farsi", info.get("CFBundleDisplayName") == "رقم")
check(
    "Info.plist is portrait-only, matching manifest.json",
    info.get("UISupportedInterfaceOrientations") == ["UIInterfaceOrientationPortrait"],
)

# 6. One bundle id, in two places that drift independently.
cap_config = read("capacitor.config.ts")
config_id = re.search(r'appId:\s*"([^"]+)"', cap_config)
check("capacitor.config.ts appId is correct", bool(config_id) and config_id.group(1) == BUNDLE_ID)
check(
    "pbxproj bundle id matches capacitor.config.ts",
    pbx.count(f"PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};") == 2,
)

# 7. iOS rejects an app icon with an alpha channel, and Xcode says so only at
#    archive time.
try:
    from PIL import Image

    icon = Image.open(ROOT / "ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png")
    check(
        "app icon is 1024x1024 and opaque",
        icon.size == (1024, 1024) and icon.mode == "RGB",
        f"got {icon.size} {icon.mode}; re-run npm run ios:icons",
    )
except ImportError:
    passes.append("app icon check skipped (Pillow not installed)")

# 8. Every plugin in package.json must be in the SPM manifest, or its JS calls
#    reject at runtime with no build-time warning. `cap sync` maintains this.
pkg = json.loads(read("package.json"))
plugins = [
    d for d in pkg["dependencies"] if d.startswith("@capacitor/") and d != "@capacitor/core"
]
package_swift = read("ios/App/CapApp-SPM/Package.swift")
missing = [p for p in plugins if f"node_modules/{p}" not in package_swift]
check(
    "Package.swift lists every plugin in package.json",
    not missing,
    f"missing {missing}; run npx cap sync ios" if missing else f"{len(plugins)} plugins",
)

# 9. viewport-fit and the safe-area padding are a pair: the first without the
#    second puts content under the status bar.
if NATIVE_ONLY:
    skipped.append("safe-area tokens are applied where viewport-fit needs them")
else:
    layout = read("src/app/layout.tsx")
    tw = read("tailwind.config.ts")
    check("root layout sets viewportFit: cover", 'viewportFit: "cover"' in layout)
    check("tailwind defines the safe-area tokens", '"safe-t"' in tw and '"safe-b"' in tw)
    check("root layout applies the top inset", "pt-safe-t" in layout)
    check(
        "bottom nav applies the bottom inset",
        "pb-safe-b" in read("src/app/_components/_navigation/index.tsx"),
    )

print("iOS preflight" + (" (native only — no src/ in this tree)" if NATIVE_ONLY else "") + "\n")
for line in passes:
    print(f"  \033[32m✓\033[0m {line}")
for line in failures:
    print(f"  \033[31m✗\033[0m {line}")
for line in skipped:
    print(f"  \033[33m–\033[0m {line} (needs src/)")

print()
if failures:
    print(f"\033[31m{len(failures)} problem(s) to fix before building.\033[0m")
    sys.exit(1)
print(f"\033[32mAll {len(passes)} checks passed.\033[0m")
