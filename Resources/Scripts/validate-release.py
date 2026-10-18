#!/usr/bin/env python3
"""Check release identity and corresponding source before publishing assets."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import tarfile
import zipfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version_settings(text):
    values = {}
    for name in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        match = re.search(rf"^{name}\s*=\s*([0-9.]+)\s*$", text, re.MULTILINE)
        require(match is not None, f"Missing version setting: {name}")
        values[name] = match.group(1)
    return values["MARKETING_VERSION"], values["CURRENT_PROJECT_VERSION"]


def validate_app(path, platform, version, build):
    info_path = {"ios": "Payload/Asspp.app/Info.plist", "macos": "Asspp.app/Contents/Info.plist"}[platform]
    with zipfile.ZipFile(path) as archive:
        require(archive.testzip() is None, f"Corrupt archive: {path.name}")
        info = plistlib.loads(archive.read(info_path))
        require(info.get("CFBundleIdentifier") == "wiki.qaq.Asspp", f"Wrong bundle ID: {path.name}")
        require(info.get("CFBundleShortVersionString") == version, f"Wrong app version: {path.name}")
        require(str(info.get("CFBundleVersion")) == build, f"Wrong build number: {path.name}")
        if platform == "ios":
            notices = [name for name in archive.namelist() if name.endswith("/SAPRuntimeLicenses.txt")]
            require(len(notices) == 1, "iOS runtime license notice is missing")
            require(b"GNU GENERAL PUBLIC LICENSE" in archive.read(notices[0]), "iOS GPL license is missing")


def validate(artifacts, configuration, tag, commit, pins):
    version, build = version_settings(configuration.read_text())
    require(tag == f"v{version}", "Tag does not match the app version")
    require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, "Invalid source commit")
    for filename, platform in (("Asspp.ipa", "ios"), ("Asspp.zip", "macos")):
        validate_app(artifacts / filename, platform, version, build)

    with tarfile.open(artifacts / "Asspp-sources.tar.gz", "r:gz") as archive:
        def source(name):
            entry = archive.extractfile(f"asspp-sources/{name}")
            require(entry is not None, f"Missing source: {name}")
            return entry.read()

        require(source("SOURCE_COMMIT").decode().strip() == commit, "Source commit does not match the tag")
        require(version_settings(source("Configuration/Version.xcconfig").decode()) == (version, build),
                "Source version does not match the apps")
        require(json.loads(source("Packages/SAPRuntime/source-pins.json")) == pins, "Runtime source pins do not match")
        source("Packages/SAPRuntime/Licenses/ipatool-MIT.txt")
        source("Packages/SAPRuntime/Licenses/Unicorn-GPL-2.0.txt")
        source("Packages/SAPRuntime/Scripts/prepare-source.py")
        source("Packages/SAPRuntime/Scripts/build.sh")
        require(b"!defined(CONFIG_TCG_INTERPRETER)" in source("Packages/SAPRuntime/UnicornTCISource/uc.c"),
                "Source archive does not contain the interpreter patch")

    filenames = ("Asspp.ipa", "Asspp.zip", "Asspp-sources.tar.gz")
    checksums = []
    for filename in filenames:
        with (artifacts / filename).open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        checksums.append(f"{digest}  {filename}\n")
    (artifacts / "SHA256SUMS").write_text("".join(checksums))
    return version, build


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", type=Path)
    parser.add_argument("--platform", choices=("ios", "macos"), help="Validate a single app archive during CI")
    parser.add_argument("--tag")
    parser.add_argument("--commit")
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[2]
    configuration = repository / "Configuration/Version.xcconfig"
    if args.platform:
        version, build = version_settings(configuration.read_text())
        validate_app(args.artifacts, args.platform, version, build)
        print(f"Validated {args.platform} app identity: Asspp {version} ({build}).")
    else:
        if not args.tag or not args.commit:
            parser.error("--tag and --commit are required for a complete release")
        version, build = validate(args.artifacts, configuration, args.tag, args.commit,
                                  json.loads((repository / "Packages/SAPRuntime/source-pins.json").read_text()))
        print(f"Validated Asspp {version} ({build}) and corresponding source at {args.commit}.")
