#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 WristDictation.xcodeproj/project.pbxproj。

之所以用脚本而不是手写：pbxproj 里的 24 位对象 ID 必须唯一且格式严格，
手工维护极易出错。这里用 md5(key)[:24] 保证 ID 稳定（重复生成 diff 友好）。

用法：python3 Tools/gen_project.py
"""

import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = "WristDictation.xcodeproj"
PROJECT_NAME = "WristDictation"

IOS_TARGET = "WristDictation"
WATCH_TARGET = "WristDictationWatch"

# 版本号。**升版只改这两个常量**，脚本会把它们写进 pbxproj 的全部配置。
# 之前这里硬编码成 1.0 / 1，导致每次重跑脚本都把版本号退回去，
# 手机端「最近通信」显示的版本随之倒退，排查时极易误判成"装的还是旧包"。
APP_MARKETING_VERSION = "1.7.0"
APP_BUILD_VERSION = "20"

# 签名团队。pbxproj 里**必须**有这一项，否则命令行构建直接报
# "requires a development team"。侧载用的是淘宝那份个人开发者证书。
# 之前这一项只存在于手工改过的 pbxproj 里，一重跑脚本就丢。
DEVELOPMENT_TEAM_ID = os.environ.get("WD_TEAM_ID", "").strip()

# watchOS App 的产品类型。
# 说明：Xcode 27 的 watchapp2 产品类型带有 thin-stub 二进制机制
# （PRODUCT_TYPE_HAS_STUB_BINARY = YES），在命令行构建时会同时产生
# CreateUniversalBinary 与 CopyAndPreserveArchs 两条输出同一可执行文件的命令，
# 直接报 "Multiple commands produce"。改用标准 application 类型后构建正常，
# 而运行期识别手表 App 依据的是 Info.plist 的 WKApplication /
# WKCompanionAppBundleIdentifier，与产品类型无关。
# 若某天需要回到 watchapp2，用 -WATCH_LEGACY_PRODUCT_TYPE 生成即可。
WATCH_PRODUCT_TYPE = os.environ.get(
    "WATCH_LEGACY_PRODUCT_TYPE", "") and "com.apple.product-type.application.watchapp2" \
    or "com.apple.product-type.application"

# ---------------------------------------------------------------- 源文件清单
# Shared 下的文件会同时编入 iOS 与 Watch 两个 target。
SHARED_FILES = [
    "AppLog.swift",
    "Models.swift",
    "Parameters.swift",
    "DictionaryIO.swift",
    "SyncPayload.swift",
]

IOS_FILES = [
    "WristDictationApp.swift",
    "IOSStore.swift",
    "LibraryListView.swift",
    "DictionaryDetailView.swift",
    "WordEditorView.swift",
    "LibrarySettingsView.swift",
    "ImportSheet.swift",
    "SyncView.swift",
    "PhoneRemoteBridge.swift",
]

WATCH_FILES = [
    "WristDictationWatchApp.swift",
    "WatchStore.swift",
    "WatchSyncManager.swift",
    "SpeechService.swift",
    "AudioSessionController.swift",
    "RemoteCommandBridge.swift",
    "PlaybackStateStore.swift",
    "DictationEngine.swift",
    "WatchHomeView.swift",
    "DictationView.swift",
    "AnswerSheetView.swift",
]

CONFIG_FILES = ["Shared.xcconfig", "iOS-Info.plist", "Watch-Info.plist"]


def uid(key):
    """稳定 24 位十六进制对象 ID。"""
    return hashlib.md5(key.encode("utf-8")).hexdigest()[:24].upper()


# 常用对象的固定 ID
IDS = {
    "project": uid("project"),
    "mainGroup": uid("mainGroup"),
    "productsGroup": uid("productsGroup"),
    "sharedGroup": uid("sharedGroup"),
    "iosGroup": uid("iosGroup"),
    "watchGroup": uid("watchGroup"),
    "configGroup": uid("configGroup"),
    "projConfigList": uid("projConfigList"),
    "projDebug": uid("projDebug"),
    "projRelease": uid("projRelease"),
    "iosTarget": uid("iosTarget"),
    "iosConfigList": uid("iosConfigList"),
    "iosDebug": uid("iosDebug"),
    "iosRelease": uid("iosRelease"),
    "iosSources": uid("iosSources"),
    "iosFrameworks": uid("iosFrameworks"),
    "iosResources": uid("iosResources"),
    "iosEmbedWatch": uid("iosEmbedWatch"),
    "iosProduct": uid("iosProduct"),
    "watchTarget": uid("watchTarget"),
    "watchConfigList": uid("watchConfigList"),
    "watchDebug": uid("watchDebug"),
    "watchRelease": uid("watchRelease"),
    "watchSources": uid("watchSources"),
    "watchFrameworks": uid("watchFrameworks"),
    "watchResources": uid("watchResources"),
    "watchProduct": uid("watchProduct"),
    "targetDependency": uid("targetDependency"),
    "containerProxy": uid("containerProxy"),
    "embedBuildFile": uid("embedBuildFile"),
    "xcconfigRef": uid("xcconfigRef"),
    "iosInfoRef": uid("iosInfoRef"),
    "watchInfoRef": uid("watchInfoRef"),
}


def file_ref_id(path_key):
    return uid("fileRef:" + path_key)


def build_file_id(target, path_key):
    return uid("buildFile:%s:%s" % (target, path_key))


def main():
    lines = []

    def w(s=""):
        lines.append(s)

    # 收集所有文件： (path_key, 相对工程根的路径, 父分组, 文件名)
    shared = [("Shared/" + f, "WristDictation/Shared/" + f, "sharedGroup", f) for f in SHARED_FILES]
    ios = [("iOS/" + f, "WristDictation/iOS/" + f, "iosGroup", f) for f in IOS_FILES]
    watch = [("Watch/" + f, "WristDictation/Watch/" + f, "watchGroup", f) for f in WATCH_FILES]
    configs = [("Config/" + f, "WristDictation/Config/" + f, "configGroup", f) for f in CONFIG_FILES]

    w("// !$*UTF8*$!")
    w("{")
    w("\tarchiveVersion = 1;")
    w("\tclasses = {")
    w("\t};")
    w("\tobjectVersion = 56;")
    w("\tobjects = {")

    # ------------------------------------------------------------ BuildFile
    w()
    w("/* Begin PBXBuildFile section */")
    for target, group in (("ios", ios + shared), ("watch", watch + shared)):
        for key, _, _, name in group:
            w("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
              % (build_file_id(target, key), name, file_ref_id(key), name))
    w("\t\t%s /* %s.app in Embed Watch Content */ = {isa = PBXBuildFile; fileRef = %s /* %s.app */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };"
      % (IDS["embedBuildFile"], WATCH_TARGET, IDS["watchProduct"], WATCH_TARGET))
    w("/* End PBXBuildFile section */")

    # --------------------------------------------------------- ContainerProxy
    w()
    w("/* Begin PBXContainerItemProxy section */")
    w("\t\t%s /* PBXContainerItemProxy */ = {" % IDS["containerProxy"])
    w("\t\t\tisa = PBXContainerItemProxy;")
    w("\t\t\tcontainerPortal = %s /* Project object */;" % IDS["project"])
    w("\t\t\tproxyType = 1;")
    w("\t\t\tremoteGlobalIDString = %s;" % IDS["watchTarget"])
    w("\t\t\tremoteInfo = \"%s\";" % WATCH_TARGET)
    w("\t\t};")
    w("/* End PBXContainerItemProxy section */")

    # ------------------------------------------------------------- CopyFiles
    w()
    w("/* Begin PBXCopyFilesBuildPhase section */")
    w("\t\t%s /* Embed Watch Content */ = {" % IDS["iosEmbedWatch"])
    w("\t\t\tisa = PBXCopyFilesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tdstPath = \"$(CONTENTS_FOLDER_PATH)/Watch\";")
    w("\t\t\tdstSubfolderSpec = 16;")
    w("\t\t\tfiles = (")
    w("\t\t\t\t%s /* %s.app in Embed Watch Content */," % (IDS["embedBuildFile"], WATCH_TARGET))
    w("\t\t\t);")
    w("\t\t\tname = \"Embed Watch Content\";")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXCopyFilesBuildPhase section */")

    # ----------------------------------------------------------- FileReference
    w()
    w("/* Begin PBXFileReference section */")
    w("\t\t%s /* %s.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = %s.app; sourceTree = BUILT_PRODUCTS_DIR; };"
      % (IDS["iosProduct"], IOS_TARGET, IOS_TARGET))
    w("\t\t%s /* %s.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = %s.app; sourceTree = BUILT_PRODUCTS_DIR; };"
      % (IDS["watchProduct"], WATCH_TARGET, WATCH_TARGET))
    for key, _, _, name in shared + ios + watch:
        w("\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = %s; sourceTree = \"<group>\"; };"
          % (file_ref_id(key), name, name))
    w("\t\t%s /* Shared.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Shared.xcconfig; sourceTree = \"<group>\"; };"
      % IDS["xcconfigRef"])
    w("\t\t%s /* iOS-Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = \"iOS-Info.plist\"; sourceTree = \"<group>\"; };"
      % IDS["iosInfoRef"])
    w("\t\t%s /* Watch-Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = \"Watch-Info.plist\"; sourceTree = \"<group>\"; };"
      % IDS["watchInfoRef"])
    w("/* End PBXFileReference section */")

    # --------------------------------------------------------- FrameworksPhases
    w()
    w("/* Begin PBXFrameworksBuildPhase section */")
    for target_id in (IDS["iosFrameworks"], IDS["watchFrameworks"]):
        w("\t\t%s /* Frameworks */ = {" % target_id)
        w("\t\t\tisa = PBXFrameworksBuildPhase;")
        w("\t\t\tbuildActionMask = 2147483647;")
        w("\t\t\tfiles = (")
        w("\t\t\t);")
        w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        w("\t\t};")
    w("/* End PBXFrameworksBuildPhase section */")

    # ---------------------------------------------------------------- Groups
    def group(id_, name, children, path=None):
        w("\t\t%s /* %s */ = {" % (id_, name))
        w("\t\t\tisa = PBXGroup;")
        w("\t\t\tchildren = (")
        for cid, cname in children:
            w("\t\t\t\t%s /* %s */," % (cid, cname))
        w("\t\t\t);")
        if path:
            w("\t\t\tpath = %s;" % path)
        w("\t\t\tsourceTree = \"<group>\";")
        w("\t\t};")

    w()
    w("/* Begin PBXGroup section */")
    group(IDS["mainGroup"], "Main", [
        (IDS["sharedGroup"], "Shared"),
        (IDS["iosGroup"], "iOS"),
        (IDS["watchGroup"], "Watch"),
        (IDS["configGroup"], "Config"),
        (IDS["productsGroup"], "Products"),
    ])
    group(IDS["productsGroup"], "Products", [
        (IDS["iosProduct"], IOS_TARGET + ".app"),
        (IDS["watchProduct"], WATCH_TARGET + ".app"),
    ])
    w("\t\t%s /* Shared */ = {" % IDS["sharedGroup"])
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for key, _, _, name in shared:
        w("\t\t\t\t%s /* %s */," % (file_ref_id(key), name))
    w("\t\t\t);")
    w("\t\t\tpath = WristDictation/Shared;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
    w("\t\t%s /* iOS */ = {" % IDS["iosGroup"])
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for key, _, _, name in ios:
        w("\t\t\t\t%s /* %s */," % (file_ref_id(key), name))
    w("\t\t\t);")
    w("\t\t\tpath = WristDictation/iOS;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
    w("\t\t%s /* Watch */ = {" % IDS["watchGroup"])
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for key, _, _, name in watch:
        w("\t\t\t\t%s /* %s */," % (file_ref_id(key), name))
    w("\t\t\t);")
    w("\t\t\tpath = WristDictation/Watch;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
    w("\t\t%s /* Config */ = {" % IDS["configGroup"])
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w("\t\t\t\t%s /* Shared.xcconfig */," % IDS["xcconfigRef"])
    w("\t\t\t\t%s /* iOS-Info.plist */," % IDS["iosInfoRef"])
    w("\t\t\t\t%s /* Watch-Info.plist */," % IDS["watchInfoRef"])
    w("\t\t\t);")
    w("\t\t\tpath = WristDictation/Config;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
    w("/* End PBXGroup section */")

    # ------------------------------------------------------------ NativeTargets
    w()
    w("/* Begin PBXNativeTarget section */")
    w("\t\t%s /* %s */ = {" % (IDS["iosTarget"], IOS_TARGET))
    w("\t\t\tisa = PBXNativeTarget;")
    w("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"%s\" */;"
      % (IDS["iosConfigList"], IOS_TARGET))
    w("\t\t\tbuildPhases = (")
    w("\t\t\t\t%s /* Sources */," % IDS["iosSources"])
    w("\t\t\t\t%s /* Frameworks */," % IDS["iosFrameworks"])
    w("\t\t\t\t%s /* Resources */," % IDS["iosResources"])
    w("\t\t\t\t%s /* Embed Watch Content */," % IDS["iosEmbedWatch"])
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    w("\t\t\t\t%s /* PBXTargetDependency */," % IDS["targetDependency"])
    w("\t\t\t);")
    w("\t\t\tname = %s;" % IOS_TARGET)
    w("\t\t\tproductName = %s;" % IOS_TARGET)
    w("\t\t\tproductReference = %s /* %s.app */;" % (IDS["iosProduct"], IOS_TARGET))
    w("\t\t\tproductType = \"com.apple.product-type.application\";")
    w("\t\t};")
    w("\t\t%s /* %s */ = {" % (IDS["watchTarget"], WATCH_TARGET))
    w("\t\t\tisa = PBXNativeTarget;")
    w("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"%s\" */;"
      % (IDS["watchConfigList"], WATCH_TARGET))
    w("\t\t\tbuildPhases = (")
    w("\t\t\t\t%s /* Sources */," % IDS["watchSources"])
    w("\t\t\t\t%s /* Frameworks */," % IDS["watchFrameworks"])
    w("\t\t\t\t%s /* Resources */," % IDS["watchResources"])
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    w("\t\t\t);")
    w("\t\t\tname = %s;" % WATCH_TARGET)
    w("\t\t\tproductName = %s;" % WATCH_TARGET)
    w("\t\t\tproductReference = %s /* %s.app */;" % (IDS["watchProduct"], WATCH_TARGET))
    w("\t\t\tproductType = \"%s\";" % WATCH_PRODUCT_TYPE)
    w("\t\t};")
    w("/* End PBXNativeTarget section */")

    # ----------------------------------------------------------------- Project
    w()
    w("/* Begin PBXProject section */")
    w("\t\t%s /* Project object */ = {" % IDS["project"])
    w("\t\t\tisa = PBXProject;")
    w("\t\t\tattributes = {")
    w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    w("\t\t\t\tLastSwiftUpdateCheck = 1620;")
    w("\t\t\t\tLastUpgradeCheck = 1620;")
    w("\t\t\t\tTargetAttributes = {")
    w("\t\t\t\t\t%s = {" % IDS["iosTarget"])
    w("\t\t\t\t\t\tCreatedOnToolsVersion = 16.2;")
    w("\t\t\t\t\t};")
    w("\t\t\t\t\t%s = {" % IDS["watchTarget"])
    w("\t\t\t\t\t\tCreatedOnToolsVersion = 16.2;")
    w("\t\t\t\t\t};")
    w("\t\t\t\t};")
    w("\t\t\t};")
    w("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject \"%s\" */;"
      % (IDS["projConfigList"], PROJECT_NAME))
    w("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    w("\t\t\tdevelopmentRegion = \"zh-Hans\";")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (")
    w("\t\t\t\t\"zh-Hans\",")
    w("\t\t\t\ten,")
    w("\t\t\t\tBase,")
    w("\t\t\t);")
    w("\t\t\tmainGroup = %s;" % IDS["mainGroup"])
    w("\t\t\tproductRefGroup = %s /* Products */;" % IDS["productsGroup"])
    w("\t\t\tprojectDirPath = \"\";")
    w("\t\t\tprojectRoot = \"\";")
    w("\t\t\ttargets = (")
    w("\t\t\t\t%s /* %s */," % (IDS["iosTarget"], IOS_TARGET))
    w("\t\t\t\t%s /* %s */," % (IDS["watchTarget"], WATCH_TARGET))
    w("\t\t\t);")
    w("\t\t};")
    w("/* End PBXProject section */")

    # --------------------------------------------------------------- Resources
    w()
    w("/* Begin PBXResourcesBuildPhase section */")
    for target_id in (IDS["iosResources"], IDS["watchResources"]):
        w("\t\t%s /* Resources */ = {" % target_id)
        w("\t\t\tisa = PBXResourcesBuildPhase;")
        w("\t\t\tbuildActionMask = 2147483647;")
        w("\t\t\tfiles = (")
        w("\t\t\t);")
        w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        w("\t\t};")
    w("/* End PBXResourcesBuildPhase section */")

    # ----------------------------------------------------------------- Sources
    w()
    w("/* Begin PBXSourcesBuildPhase section */")
    for target, phase_id, group in (("ios", IDS["iosSources"], ios + shared),
                                    ("watch", IDS["watchSources"], watch + shared)):
        w("\t\t%s /* Sources */ = {" % phase_id)
        w("\t\t\tisa = PBXSourcesBuildPhase;")
        w("\t\t\tbuildActionMask = 2147483647;")
        w("\t\t\tfiles = (")
        for key, _, _, name in group:
            w("\t\t\t\t%s /* %s in Sources */," % (build_file_id(target, key), name))
        w("\t\t\t);")
        w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        w("\t\t};")
    w("/* End PBXSourcesBuildPhase section */")

    # -------------------------------------------------------------- Dependency
    w()
    w("/* Begin PBXTargetDependency section */")
    w("\t\t%s /* PBXTargetDependency */ = {" % IDS["targetDependency"])
    w("\t\t\tisa = PBXTargetDependency;")
    w("\t\t\ttarget = %s /* %s */;" % (IDS["watchTarget"], WATCH_TARGET))
    w("\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;" % IDS["containerProxy"])
    w("\t\t};")
    w("/* End PBXTargetDependency section */")

    # ------------------------------------------------------------ BuildConfigs
    proj_common = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;
\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tLOCALIZATION_PREFERS_STRING_CATALOGS = YES;"""

    def config(id_, name, base, settings):
        w("\t\t%s /* %s */ = {" % (id_, name))
        w("\t\t\tisa = XCBuildConfiguration;")
        if base:
            w("\t\t\tbaseConfigurationReference = %s /* Shared.xcconfig */;" % IDS["xcconfigRef"])
        w("\t\t\tbuildSettings = {")
        for line in settings.split("\n"):
            if line.strip():
                w(line)
        w("\t\t\t};")
        w("\t\t\tname = %s;" % name)
        w("\t\t};")

    w()
    w("/* Begin XCBuildConfiguration section */")
    config(IDS["projDebug"], "Debug", None, proj_common + """
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";""")
    config(IDS["projRelease"], "Release", None, proj_common + """
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tVALIDATE_PRODUCT = YES;""")

    ios_settings = f"""
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = {APP_BUILD_VERSION};
\t\t\t\tDEVELOPMENT_TEAM = {DEVELOPMENT_TEAM_ID};
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = WristDictation/Config/iOS-Info.plist;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tOTHER_SWIFT_FLAGS = "$(inherited) -disable-sandbox";
\t\t\t\tMARKETING_VERSION = {APP_MARKETING_VERSION};
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_ID)";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";"""
    config(IDS["iosDebug"], "Debug", True, ios_settings + """
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";""")
    config(IDS["iosRelease"], "Release", True, ios_settings + """
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";""")

    watch_settings = f"""
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = {APP_BUILD_VERSION};
\t\t\t\tDEVELOPMENT_TEAM = {DEVELOPMENT_TEAM_ID};
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = WristDictation/Config/Watch-Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tOTHER_SWIFT_FLAGS = "$(inherited) -disable-sandbox";
\t\t\t\tMARKETING_VERSION = {APP_MARKETING_VERSION};
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_ID).watchkitapp";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = watchos;
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tTARGETED_DEVICE_FAMILY = 4;
\t\t\t\tWATCHOS_DEPLOYMENT_TARGET = 10.0;"""
    config(IDS["watchDebug"], "Debug", True, watch_settings + """
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";""")
    config(IDS["watchRelease"], "Release", True, watch_settings + """
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";""")
    w("/* End XCBuildConfiguration section */")

    # -------------------------------------------------------- ConfigurationList
    def cfg_list(id_, name, debug, release):
        w("\t\t%s /* Build configuration list for %s */ = {" % (id_, name))
        w("\t\t\tisa = XCConfigurationList;")
        w("\t\t\tbuildConfigurations = (")
        w("\t\t\t\t%s /* Debug */," % debug)
        w("\t\t\t\t%s /* Release */," % release)
        w("\t\t\t);")
        w("\t\t\tdefaultConfigurationIsVisible = 0;")
        w("\t\t\tdefaultConfigurationName = Release;")
        w("\t\t};")

    w()
    w("/* Begin XCConfigurationList section */")
    cfg_list(IDS["projConfigList"], "PBXProject \"%s\"" % PROJECT_NAME, IDS["projDebug"], IDS["projRelease"])
    cfg_list(IDS["iosConfigList"], "PBXNativeTarget \"%s\"" % IOS_TARGET, IDS["iosDebug"], IDS["iosRelease"])
    cfg_list(IDS["watchConfigList"], "PBXNativeTarget \"%s\"" % WATCH_TARGET, IDS["watchDebug"], IDS["watchRelease"])
    w("/* End XCConfigurationList section */")

    w("\t};")
    w("\trootObject = %s /* Project object */;" % IDS["project"])
    w("}")

    out_dir = os.path.join(ROOT, PROJECT)
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "project.pbxproj"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    print("wrote", os.path.join(out_dir, "project.pbxproj"))
    print("source files:", len(shared) + len(ios) + len(watch))

    write_schemes(out_dir)


SCHEME_TMPL = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2700"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            %(ref)s
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         %(ref)s
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         %(ref)s
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def write_schemes(out_dir):
    """写共享 scheme。Xcode 靠它决定 Run/Archive 用哪个 target，
    缺了会退化成自动生成的 scheme，手表端尤其容易选错。"""
    d = os.path.join(out_dir, "xcshareddata", "xcschemes")
    os.makedirs(d, exist_ok=True)
    targets = [
        (IOS_TARGET, IDS["iosTarget"], IOS_TARGET + ".app"),
        (WATCH_TARGET, IDS["watchTarget"], WATCH_TARGET + ".app"),
    ]
    for name, blueprint, product in targets:
        ref = ('<BuildableReference\n               BuildableIdentifier = "primary"\n'
               '               BlueprintIdentifier = "%s"\n'
               '               BuildableName = "%s"\n'
               '               BlueprintName = "%s"\n'
               '               ReferencedContainer = "container:%s">\n'
               '            </BuildableReference>' % (blueprint, product, name, PROJECT))
        path = os.path.join(d, name + ".xcscheme")
        with open(path, "w", encoding="utf-8") as f:
            f.write(SCHEME_TMPL % {"ref": ref})
    print("wrote schemes:", ", ".join(n for n, _, _ in targets))


if __name__ == "__main__":
    main()
