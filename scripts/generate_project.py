#!/usr/bin/env python3
"""Generate a dependency-free Xcode project deterministically, using only Python's stdlib."""
from pathlib import Path
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def add(key_name, isa, **values):
    key = identifier(key_name)
    objects[key] = dict(isa=isa, **values)
    return key

def serialize(value, level=0):
    indent = "\t" * level
    if isinstance(value, dict):
        return "{\n" + "".join(f"{indent}\t{json.dumps(k)} = {serialize(v, level + 1)};\n" for k, v in value.items()) + indent + "}"
    if isinstance(value, list):
        return "(\n" + "".join(f"{indent}\t{serialize(v, level + 1)},\n" for v in value) + indent + ")"
    return json.dumps(str(value))

app_sources, test_sources, source_refs, test_refs, resource_refs, resources = [], [], [], [], [], []
for path in sorted(ROOT.glob("Focal/**/*.swift")) + sorted(ROOT.glob("FocalTests/*.swift")):
    relative = str(path.relative_to(ROOT))
    reference = add(relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="SOURCE_ROOT")
    build = add("build:" + relative, "PBXBuildFile", fileRef=reference)
    (test_sources if "FocalTests/" in relative else app_sources).append(build)
    (test_refs if "FocalTests/" in relative else source_refs).append(reference)

for path, kind in [("Focal/Resources/Assets.xcassets", "folder.assetcatalog"), ("Focal/Resources/Fonts", "folder"), ("Focal/Resources/PrivacyInfo.xcprivacy", "text.xml")]:
    reference = add(path, "PBXFileReference", lastKnownFileType=kind, path=path, sourceTree="SOURCE_ROOT")
    resource_refs.append(reference)
    resources.append(add("build:" + path, "PBXBuildFile", fileRef=reference))
resource_refs.append(add("info", "PBXFileReference", lastKnownFileType="text.plist.xml", path="Focal/Resources/Info.plist", sourceTree="SOURCE_ROOT"))
app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex="0", path="Focal.app", sourceTree="BUILT_PRODUCTS_DIR")
test_product = add("test-product", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex="0", path="FocalTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
products = add("products", "PBXGroup", children=[app_product, test_product], name="Products", sourceTree="<group>")
main_group = add("main-group", "PBXGroup", children=[
    add("source-group", "PBXGroup", children=source_refs, name="Focal", sourceTree="<group>"),
    add("resource-group", "PBXGroup", children=resource_refs, name="Resources", sourceTree="<group>"),
    add("test-group", "PBXGroup", children=test_refs, name="FocalTests", sourceTree="<group>"), products
], sourceTree="<group>")

common = dict(SDKROOT="iphoneos", IPHONEOS_DEPLOYMENT_TARGET="17.0", SWIFT_VERSION="5.0",
              CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES", ENABLE_STRICT_OBJC_MSGSEND="YES",
              GCC_C_LANGUAGE_STANDARD="gnu17", SWIFT_STRICT_CONCURRENCY="minimal")
app = dict(PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER="com.example.focal",
           INFOPLIST_FILE="Focal/Resources/Info.plist", GENERATE_INFOPLIST_FILE="NO",
           ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon", TARGETED_DEVICE_FAMILY="1",
           CODE_SIGN_STYLE="Automatic", CURRENT_PROJECT_VERSION="6", MARKETING_VERSION="1.5", VERSIONING_SYSTEM="apple-generic",
           SUPPORTED_PLATFORMS="iphoneos iphonesimulator", SUPPORTS_MACCATALYST="NO",
           LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks"],
           ENABLE_PREVIEWS="YES")
test = dict(PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER="com.example.focal.tests",
            GENERATE_INFOPLIST_FILE="YES", TARGETED_DEVICE_FAMILY="1", CODE_SIGN_STYLE="Automatic",
            TEST_HOST="$(BUILT_PRODUCTS_DIR)/Focal.app/Focal", BUNDLE_LOADER="$(TEST_HOST)",
            LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"])

def configurations(name, settings):
    ids = []
    for config in ["Debug", "Release"]:
        values = settings.copy()
        if name == "project":
            values.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if config == "Debug" else "-O",
                          DEBUG_INFORMATION_FORMAT="dwarf" if config == "Debug" else "dwarf-with-dsym",
                          ENABLE_TESTABILITY="YES" if config == "Debug" else "NO",
                          SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG $(inherited)" if config == "Debug" else "$(inherited)")
        ids.append(add(f"{name}-{config}", "XCBuildConfiguration", buildSettings=values, name=config))
    return add(name + "-configs", "XCConfigurationList", buildConfigurations=ids, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")

def phase(name, kind, files):
    return add(name, kind, buildActionMask="2147483647", files=files, runOnlyForDeploymentPostprocessing="0")

app_target = add("app-target", "PBXNativeTarget", buildConfigurationList=configurations("app", app),
                 buildPhases=[phase("app-sources", "PBXSourcesBuildPhase", app_sources), phase("app-frameworks", "PBXFrameworksBuildPhase", []), phase("app-resources", "PBXResourcesBuildPhase", resources)],
                 buildRules=[], dependencies=[], name="Focal", productName="Focal", productReference=app_product, productType="com.apple.product-type.application")
proxy = add("test-proxy", "PBXContainerItemProxy", containerPortal=identifier("project"), proxyType="1", remoteGlobalIDString=app_target, remoteInfo="Focal")
dependency = add("test-dependency", "PBXTargetDependency", target=app_target, targetProxy=proxy)
test_target = add("test-target", "PBXNativeTarget", buildConfigurationList=configurations("test", test),
                  buildPhases=[phase("test-sources", "PBXSourcesBuildPhase", test_sources), phase("test-frameworks", "PBXFrameworksBuildPhase", [])],
                  buildRules=[], dependencies=[dependency], name="FocalTests", productName="FocalTests", productReference=test_product, productType="com.apple.product-type.bundle.unit-test")
project = add("project", "PBXProject", attributes=dict(BuildIndependentTargetsInParallel="YES", LastUpgradeCheck="1600", TargetAttributes={app_target: dict(CreatedOnToolsVersion="16.0"), test_target: dict(CreatedOnToolsVersion="16.0", TestTargetID=app_target)}),
              buildConfigurationList=configurations("project", common), compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings="0", knownRegions=["en", "Base"], mainGroup=main_group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[app_target, test_target])
project_path = ROOT / "Focal.xcodeproj"
project_path.mkdir(exist_ok=True)
(project_path / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(dict(archiveVersion="1", classes={}, objectVersion="56", objects=objects, rootObject=project)) + "\n")

def buildable(target, name, product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:Focal.xcodeproj"/>'

app_ref, test_ref = buildable(app_target, "Focal", "Focal.app"), buildable(test_target, "FocalTests", "FocalTests.xctest")
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
scheme_path = project_path / "xcshareddata/xcschemes"
scheme_path.mkdir(parents=True, exist_ok=True)
(scheme_path / "Focal.xcscheme").write_text(scheme)

info = dict(CFBundleDevelopmentRegion="$(DEVELOPMENT_LANGUAGE)", CFBundleDisplayName="Focal",
            CFBundleExecutable="$(EXECUTABLE_NAME)", CFBundleIdentifier="$(PRODUCT_BUNDLE_IDENTIFIER)",
            CFBundleInfoDictionaryVersion="6.0", CFBundleName="$(PRODUCT_NAME)", CFBundlePackageType="APPL",
            CFBundleShortVersionString="$(MARKETING_VERSION)", CFBundleVersion="$(CURRENT_PROJECT_VERSION)",
            NSLocalNetworkUsageDescription="Focal connects only to the Sony camera address you choose for real wireless live view and advertised camera controls.",
            NSAppTransportSecurity=dict(NSAllowsLocalNetworking=True,
                NSExceptionDomains={address:dict(NSExceptionAllowsInsecureHTTPLoads=True)
                    for address in ["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16"]}),
            LSRequiresIPhoneOS=True, UILaunchScreen={}, UIAppFonts=["Fonts/EBGaramond-Italic.ttf"],
            UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait"],
            UIApplicationSceneManifest=dict(UIApplicationSupportsMultipleScenes=False),
            NSCameraUsageDescription="Focal uses your camera to help you compose and capture photos. Frames are analyzed only on your iPhone.",
            NSLocationWhenInUseUsageDescription="Focal uses your location only when you request it to estimate golden-hour light. Location is not uploaded or added to photos.",
            NSMotionUsageDescription="Focal uses phone motion to wait for a steady hold before automatic framing and to provide an optional level guide.",
            NSPhotoLibraryAddUsageDescription="Save the photos you choose from Focal to your iPhone photo library.")
(ROOT / "Focal/Resources/Info.plist").write_bytes(plistlib.dumps(info))
privacy = dict(NSPrivacyTracking=False, NSPrivacyTrackingDomains=[], NSPrivacyCollectedDataTypes=[],
               NSPrivacyAccessedAPITypes=[
                   dict(NSPrivacyAccessedAPIType="NSPrivacyAccessedAPICategoryUserDefaults", NSPrivacyAccessedAPITypeReasons=["CA92.1"]),
                   dict(NSPrivacyAccessedAPIType="NSPrivacyAccessedAPICategorySystemBootTime", NSPrivacyAccessedAPITypeReasons=["35F9.1"]),
                   dict(NSPrivacyAccessedAPIType="NSPrivacyAccessedAPICategoryFileTimestamp", NSPrivacyAccessedAPITypeReasons=["C617.1"])
               ])
(ROOT / "Focal/Resources/PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(privacy))
assets = ROOT / "Focal/Resources/Assets.xcassets"
(assets / "Contents.json").write_text(json.dumps(dict(info=dict(author="xcode", version=1)), indent=2))
(assets / "DemoScene.imageset/Contents.json").write_text(json.dumps(dict(images=[dict(filename="scene.jpg", idiom="universal")], info=dict(author="xcode", version=1)), indent=2))
(assets / "AppIcon.appiconset/Contents.json").write_text(json.dumps(dict(images=[dict(filename="AppIcon.png", idiom="universal", platform="ios", size="1024x1024")], info=dict(author="xcode", version=1)), indent=2))
print(f"Generated project: {len(app_sources)} app sources, {len(test_sources)} test sources.")
