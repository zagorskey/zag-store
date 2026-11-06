#!/usr/bin/env bash
# Real-tap UI tests for the shared install control (XCUITest on a simulator).
#
# Builds a small host app from the control's real source files plus
# scripts/ZagInstallControlTapHarness.swift, generates a throwaway Xcode
# project in a temporary directory, and runs
# scripts/ZagInstallControlTapUITests.swift against it.
#
#   SIMULATOR_ID=<udid>   simulator to use (default: first booted iPhone)
#   BODY_FILE=<path>      control implementation to test (default: current)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/zag-install-control-taps"
BODY_FILE="${BODY_FILE:-$ROOT/Feather/Views/ZagInstallControlBody.swift}"
SIMULATOR_ID="${SIMULATOR_ID:-$(xcrun simctl list devices booted | grep -m1 -oE 'iPhone[^(]*\(([0-9A-F-]{36})\)' | grep -oE '[0-9A-F-]{36}' || true)}"
if [ -z "$SIMULATOR_ID" ]; then
	echo "No booted iPhone simulator; set SIMULATOR_ID" >&2
	exit 2
fi

rm -rf "$WORK"
mkdir -p "$WORK/TapHarness.xcodeproj/xcshareddata/xcschemes"

python3 -I - "$WORK" "$ROOT" "$BODY_FILE" <<'PY'
import sys, hashlib
work, root, body = sys.argv[1:4]
def oid(name): return hashlib.md5(name.encode()).hexdigest()[:24].upper()
app_sources = [f"{root}/Feather/Utilities/ZagInstallControlModel.swift",
               f"{root}/Feather/Views/ZagInstallControlMeasure.swift",
               body,
               f"{root}/scripts/ZagInstallControlTapHarness.swift"]
test_sources = [f"{root}/scripts/ZagInstallControlTapUITests.swift"]
objs = []
def add(o): objs.append(o)
files = {}
for path in app_sources + test_sources:
    files[path] = (oid("ref" + path), oid("build" + path))
    add(f'{files[path][0]} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path}"; sourceTree = "<absolute>"; }};')
for path in app_sources:
    add(f'{oid("app"+path)} = {{isa = PBXBuildFile; fileRef = {files[path][0]}; }};')
for path in test_sources:
    add(f'{oid("test"+path)} = {{isa = PBXBuildFile; fileRef = {files[path][0]}; }};')
APP, TEST, PROJ = oid("app-target"), oid("test-target"), oid("project")
APPREF, TESTREF = oid("app-product"), oid("test-product")
add(f'{APPREF} = {{isa = PBXFileReference; explicitFileType = wrapper.application; path = TapHarness.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
add(f'{TESTREF} = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = TapHarnessUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};')
refs = ", ".join(files[p][0] for p in files)
add(f'{oid("products")} = {{isa = PBXGroup; children = ({APPREF}, {TESTREF}); name = Products; sourceTree = "<group>"; }};')
add(f'{oid("main")} = {{isa = PBXGroup; children = ({refs}, {oid("products")}); sourceTree = "<group>"; }};')
add(f'{oid("app-src")} = {{isa = PBXSourcesBuildPhase; files = ({", ".join(oid("app"+p) for p in app_sources)}); }};')
add(f'{oid("test-src")} = {{isa = PBXSourcesBuildPhase; files = ({", ".join(oid("test"+p) for p in test_sources)}); }};')
common = '''CODE_SIGN_STYLE = Manual; CODE_SIGN_IDENTITY = "-"; DEVELOPMENT_TEAM = ""; GENERATE_INFOPLIST_FILE = YES;
 IPHONEOS_DEPLOYMENT_TARGET = 16.4; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
 SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = 1; ENABLE_USER_SCRIPT_SANDBOXING = NO;'''
add(f'{oid("app-debug")} = {{isa = XCBuildConfiguration; buildSettings = {{ {common} PRODUCT_NAME = TapHarness; PRODUCT_BUNDLE_IDENTIFIER = local.zagstore.tapharness; INFOPLIST_KEY_UILaunchScreen_Generation = YES; }}; name = Debug; }};')
add(f'{oid("test-debug")} = {{isa = XCBuildConfiguration; buildSettings = {{ {common} PRODUCT_NAME = TapHarnessUITests; PRODUCT_BUNDLE_IDENTIFIER = local.zagstore.tapharness.uitests; TEST_TARGET_NAME = TapHarness; }}; name = Debug; }};')
add(f'{oid("proj-debug")} = {{isa = XCBuildConfiguration; buildSettings = {{ SDKROOT = iphoneos; }}; name = Debug; }};')
for n in ["app", "test", "proj"]:
    add(f'{oid(n+"-list")} = {{isa = XCConfigurationList; buildConfigurations = ({oid(n+"-debug")}); defaultConfigurationName = Debug; }};')
add(f'{oid("proxy")} = {{isa = PBXContainerItemProxy; containerPortal = {PROJ}; proxyType = 1; remoteGlobalIDString = {APP}; remoteInfo = TapHarness; }};')
add(f'{oid("dep")} = {{isa = PBXTargetDependency; target = {APP}; targetProxy = {oid("proxy")}; }};')
add(f'{APP} = {{isa = PBXNativeTarget; buildConfigurationList = {oid("app-list")}; buildPhases = ({oid("app-src")}); dependencies = (); name = TapHarness; productName = TapHarness; productReference = {APPREF}; productType = "com.apple.product-type.application"; }};')
add(f'{TEST} = {{isa = PBXNativeTarget; buildConfigurationList = {oid("test-list")}; buildPhases = ({oid("test-src")}); dependencies = ({oid("dep")}); name = TapHarnessUITests; productName = TapHarnessUITests; productReference = {TESTREF}; productType = "com.apple.product-type.bundle.ui-testing"; }};')
add(f'{PROJ} = {{isa = PBXProject; buildConfigurationList = {oid("proj-list")}; compatibilityVersion = "Xcode 14.0"; mainGroup = {oid("main")}; productRefGroup = {oid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({APP}, {TEST}); }};')
open(f"{work}/TapHarness.xcodeproj/project.pbxproj", "w").write(
    "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n" + "\n".join(objs) + f"\n}}; rootObject = {PROJ}; }}\n")
def ref(target, product, name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:TapHarness.xcodeproj"/>'
open(f"{work}/TapHarness.xcodeproj/xcshareddata/xcschemes/TapHarness.xcscheme", "w").write(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{ref(APP, "TapHarness.app", "TapHarness")}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.PosixSpawn" shouldUseLaunchSchemeArgsEnv="YES">
<Testables><TestableReference skipped="NO">{ref(TEST, "TapHarnessUITests.xctest", "TapHarnessUITests")}</TestableReference></Testables>
</TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.PosixSpawn" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
<BuildableProductRunnable runnableDebuggingMode="0">{ref(APP, "TapHarness.app", "TapHarness")}</BuildableProductRunnable>
</LaunchAction>
</Scheme>
''')
PY

xcodebuild test \
	-project "$WORK/TapHarness.xcodeproj" -scheme TapHarness \
	-destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
	-derivedDataPath "$WORK/DerivedData" \
	-resultBundlePath "$WORK/Result.xcresult" \
	CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$WORK/xcodebuild.log" \
	| grep -E "Test Case .*(passed|failed)|error:|XCTAssert|\*\* TEST" || true

if grep -q '\*\* TEST SUCCEEDED \*\*' "$WORK/xcodebuild.log"; then
	echo "Install control tap tests passed"
else
	echo "Install control tap tests FAILED (log: $WORK/xcodebuild.log)"
	exit 1
fi
