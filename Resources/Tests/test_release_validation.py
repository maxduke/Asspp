import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tarfile
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("release_validation", Path(__file__).parents[1] / "Scripts/validate-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseValidationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.commit = "a" * 40
        self.pins = {"ipatool": "pinned", "unicorn_tci": "pinned"}
        self.configuration = self.root / "Version.xcconfig"
        self.configuration.write_text("MARKETING_VERSION = 4.2.1\nCURRENT_PROJECT_VERSION = 1\n")
        self.apps()
        self.sources()

    def apps(self, version="4.2.1", bundle="wiki.qaq.Asspp", license=True):
        info = plistlib.dumps({"CFBundleIdentifier": bundle, "CFBundleShortVersionString": version, "CFBundleVersion": "1"})
        for filename, path in [("Asspp.ipa", "Payload/Asspp.app/Info.plist"), ("Asspp.zip", "Asspp.app/Contents/Info.plist")]:
            with zipfile.ZipFile(self.root / filename, "w") as archive:
                archive.writestr(path, info)
                if filename.endswith("ipa") and license:
                    archive.writestr("Payload/Asspp.app/SAPRuntimeLicenses.txt", "GNU GENERAL PUBLIC LICENSE")

    def sources(self, commit=None):
        files = {
            "SOURCE_COMMIT": commit or self.commit,
            "Configuration/Version.xcconfig": self.configuration.read_text(),
            "Packages/SAPRuntime/source-pins.json": json.dumps(self.pins),
            "Packages/SAPRuntime/Licenses/ipatool-MIT.txt": "MIT",
            "Packages/SAPRuntime/Licenses/Unicorn-GPL-2.0.txt": "GPL",
            "Packages/SAPRuntime/Scripts/prepare-source.py": "source",
            "Packages/SAPRuntime/Scripts/build.sh": "source",
            "Packages/SAPRuntime/UnicornTCISource/uc.c": "#if !defined(CONFIG_TCG_INTERPRETER)",
        }
        with tarfile.open(self.root / "Asspp-sources.tar.gz", "w:gz") as archive:
            for name, content in files.items():
                data = content.encode()
                entry = tarfile.TarInfo(f"asspp-sources/{name}")
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))

    def validate(self, tag="v4.2.1"):
        return release.validate(self.root, self.configuration, tag, self.commit, self.pins)

    def test_matching_apps_and_source_generate_checksums(self):
        self.assertEqual(self.validate(), ("4.2.1", "1"))
        lines = (self.root / "SHA256SUMS").read_text().splitlines()
        self.assertEqual(len(lines), 3)
        self.assertTrue(all(len(line.split()[0]) == 64 for line in lines))

    def test_wrong_version_bundle_license_or_source_cannot_be_published(self):
        for changes in [{"version": "4.2.0"}, {"bundle": "other.app"}, {"license": False}]:
            with self.subTest(changes=changes):
                self.apps(**changes)
                with self.assertRaises(ValueError):
                    self.validate()
        self.apps()
        self.sources(commit="b" * 40)
        with self.assertRaises(ValueError):
            self.validate()
        self.assertFalse((self.root / "SHA256SUMS").exists())

    def test_wrong_release_tag_is_rejected(self):
        with self.assertRaises(ValueError):
            self.validate(tag="v4.2.0")
