import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", pathlib.Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

class ReleaseChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.app = self.root / "Products/Applications/Fixture.app"
        self.info = {"CFBundleVersion": "34", "CFBundleShortVersionString": "1.0", "CFBundleIdentifier": "fixture.app", "DTXcodeBuild": "27A266a", "DTPlatformName": "iphoneos", "DTSDKName": "iphoneos26.2"}
        self.write(self.app)
    def tearDown(self): self.temp.cleanup()
    def write(self, path, changes=None, mac=False):
        path = path / ("Contents" if mac else "")
        path.mkdir(parents=True, exist_ok=True)
        (path / "Info.plist").write_bytes(plistlib.dumps(self.info | (changes or {})))
        manifest_dir = path / "Resources" if mac else path
        manifest_dir.mkdir(exist_ok=True)
        (manifest_dir / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({
            "NSPrivacyAccessedAPITypes": [{"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                                          "NSPrivacyAccessedAPITypeReasons": ["1C8F.1"]}]}))
    @patch.object(release.subprocess, "run")
    def testValidArchiveChecksSignature(self, run):
        release.validate_archive(self.root, ["27A266a"])
        run.assert_called_once()
    def testEmbeddedVersionMismatch(self):
        self.write(self.app / "PlugIns/Widget.appex", {"CFBundleVersion": "33"})
        with self.assertRaisesRegex(ValueError, "build numbers"): release.validate_archive(self.root, ["27A266a"])
    def testUnapprovedToolchain(self):
        with self.assertRaisesRegex(ValueError, "unapproved"): release.validate_archive(self.root, ["27A999"])
    def testSimulatorRejected(self):
        self.write(self.app, {"DTPlatformName": "iphonesimulator"})
        with self.assertRaisesRegex(ValueError, "Simulator"): release.validate_archive(self.root, ["27A266a"])
    def testMissingVersionRejected(self):
        self.write(self.app, {"CFBundleVersion": ""})
        with self.assertRaisesRegex(ValueError, "Missing"): release.validate_archive(self.root, ["27A266a"])
    @patch.object(release.subprocess, "run")
    def testMacBundleLayout(self, run):
        (self.app / "Info.plist").unlink()
        self.write(self.app, {"DTPlatformName": "macosx", "DTSDKName": "macosx26.2"}, mac=True)
        release.validate_archive(self.root, ["27A266a"])
        run.assert_called_once()

    @patch.object(release.subprocess, "run")
    def testUnresolvedVersionRejected(self, run):
        for key in ("CFBundleVersion", "CFBundleShortVersionString"):
            with self.subTest(key=key):
                self.write(self.app, {key: "$(MARKETING_VERSION)"})
                with self.assertRaisesRegex(ValueError, "Invalid"): release.validate_archive(self.root, ["27A266a"])
    @patch.object(release.subprocess, "run")
    def testMalformedVersionRejected(self, run):
        for value in ("1.0a", "1..0", "1.2.3.4", " 1.0", "-1"):
            with self.subTest(value=value):
                self.write(self.app, {"CFBundleShortVersionString": value})
                with self.assertRaisesRegex(ValueError, "Invalid"): release.validate_archive(self.root, ["27A266a"])
    @patch.object(release.subprocess, "run")
    def testForeignEmbeddedIdentifierRejected(self, run):
        for identifier in ("other.widget", "fixture.appwidget", "fixture.app"):
            with self.subTest(identifier=identifier):
                self.write(self.app / "PlugIns/Widget.appex", {"CFBundleIdentifier": identifier})
                with self.assertRaisesRegex(ValueError, "identifier"): release.validate_archive(self.root, ["27A266a"])
    @patch.object(release.subprocess, "run")
    def testNestedWatchAppAccepted(self, run):
        self.write(self.app / "PlugIns/Widget.appex", {"CFBundleIdentifier": "fixture.app.widget"})
        self.write(self.app / "Watch/Watch.app", {"CFBundleIdentifier": "fixture.app.watch",
                                                  "DTPlatformName": "watchos", "DTSDKName": "watchos26.2"})
        release.validate_archive(self.root, ["27A266a"])
        run.assert_called_once()
    @patch.object(release.subprocess, "run")
    def testMissingOrWrongPlatformRejected(self, run):
        for changes in ({"DTPlatformName": ""}, {"DTPlatformName": "macosx"}):
            with self.subTest(changes=changes):
                self.write(self.app / "PlugIns/Widget.appex", {"CFBundleIdentifier": "fixture.app.widget"} | changes)
                with self.assertRaisesRegex(ValueError, "platform"): release.validate_archive(self.root, ["27A266a"])
    @patch.object(release.subprocess, "run")
    def testMissingOrMismatchedSDKRejected(self, run):
        for sdk in ("", "iphonesimulator26.2", "watchos26.2"):
            with self.subTest(sdk=sdk):
                self.write(self.app, {"DTSDKName": sdk})
                with self.assertRaisesRegex(ValueError, "SDK"): release.validate_archive(self.root, ["27A266a"])

    @patch.object(release.subprocess, "run")
    def testCredentialValueRejectedWithoutDisclosure(self, run):
        self.write(self.app, {"SpoonacularAPIKey": "fixture-sensitive-value"})
        with self.assertRaisesRegex(ValueError, "Nonempty credential field") as error:
            release.validate_archive(self.root, ["27A266a"])
        self.assertNotIn("fixture-sensitive-value", str(error.exception))
        run.assert_not_called()

    @patch.object(release.subprocess, "run")
    def testBlankCredentialAllowed(self, run):
        self.write(self.app, {"SpoonacularAPIKey": ""})
        release.validate_archive(self.root, ["27A266a"])

    def testCredentialFileRejected(self):
        (self.app / "Secrets.xcconfig").write_text("fixture only")
        with self.assertRaisesRegex(ValueError, "Credential/configuration file"):
            release.validate_archive(self.root, ["27A266a"])

    def testMissingExtensionPrivacyRejected(self):
        extension = self.app / "PlugIns/Widget.appex"
        self.write(extension, {"CFBundleIdentifier": "fixture.app.widget"})
        (extension / "PrivacyInfo.xcprivacy").unlink()
        with self.assertRaisesRegex(ValueError, "Missing privacy manifest"):
            release.validate_archive(self.root, ["27A266a"])

    def testMissingAppGroupReasonRejected(self):
        (self.app / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({"NSPrivacyAccessedAPITypes": []}))
        with self.assertRaisesRegex(ValueError, "App Group defaults"):
            release.validate_archive(self.root, ["27A266a"])

    def testLocalCredentialPreflightRejectsWithoutDisclosure(self):
        config = self.root / "Secrets.xcconfig"
        config.write_text("STOCKED_WORKER_KEY = fixture-sensitive-value\n")
        with self.assertRaisesRegex(ValueError, "STOCKED_WORKER_KEY") as error:
            release.validate_local_credentials(config)
        self.assertNotIn("fixture-sensitive-value", str(error.exception))

    def testLocalCredentialPreflightAllowsBlankAndComments(self):
        config = self.root / "Secrets.xcconfig"
        config.write_text("// STOCKED_WORKER_KEY = ignored\nSTOCKED_WORKER_KEY = \n")
        release.validate_local_credentials(config)

    def testCheckedInExampleHasNoReleaseCredentials(self):
        release.validate_local_credentials(release.ROOT / "Secrets.example.xcconfig")

    @patch.object(release.subprocess, "check_output")
    def testIsolatedDeinitsReportedExceptGeneratedAccessor(self, check_output):
        check_output.side_effect = ["_$sA CfZ _$sB CfZ _other", "Stocked.(Box in _1A2B).__isolated_deallocating_deinit\n"
                                    "Stocked.(ResourceBundleClass in _3C).__isolated_deallocating_deinit\n"]
        self.assertEqual(release.isolated_deinits("Fixture"), ["Stocked.Box"])

if __name__ == "__main__": unittest.main()
