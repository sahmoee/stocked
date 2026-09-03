"""Native fixture tests only. Never builds, signs, uploads or edits a real project."""
import concurrent.futures
import importlib.util
from pathlib import Path
import plistlib
import re
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('qa_number', Path(__file__).with_name('qa_build_number.py'))
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)


class BuildNumberTests(unittest.TestCase):
    def test_build_only_across_configs(self):
        source = 'CURRENT_PROJECT_VERSION = 5; MARKETING_VERSION = 1.2.3;\nCURRENT_PROJECT_VERSION = 12; MARKETING_VERSION = 4;'
        number, updated = qa.next_number(source)
        self.assertEqual(number, 13)
        self.assertEqual(qa.VERSION.findall(source), qa.VERSION.findall(updated))
        self.assertEqual([v for _, v, _ in qa.BUILD.findall(updated)], ['13', '13'])

    def test_dotted_migration_honors_floor(self):
        self.assertEqual(qa.next_number('CURRENT_PROJECT_VERSION = 4.5;', 89)[0], 90)
        self.assertEqual(qa.next_number('CURRENT_PROJECT_VERSION = 105.2;')[0], 106)

    def test_reject_missing_numeric_settings(self):
        with self.assertRaises(ValueError):
            qa.next_number('MARKETING_VERSION = 1.0;')

    def test_product_stamp_preserves_all_other_values(self):
        with tempfile.TemporaryDirectory(prefix='qa-number-fixture-') as root:
            base = Path(root)
            (base / 'qa-build-number').write_text('91\n')
            for original in [
                {'CFBundleVersion': '90', 'CFBundleShortVersionString': '1.7', 'Nested': {'Flag': True}},
                {'NSExtension': {'Point': 'widget'}},
            ]:
                info = base / 'Info.plist'
                info.write_bytes(plistlib.dumps(original))
                qa.stamp_product(info, base)
                self.assertEqual(plistlib.loads(info.read_bytes()), {**original, 'CFBundleVersion': '91'})

    def test_concurrent_reservations_and_retry_high_water(self):
        with tempfile.TemporaryDirectory(prefix='qa-number-fixture-') as root:
            base = Path(root)
            project = base / 'With Spaces.xcodeproj'
            project.mkdir()
            pbx = project / 'project.pbxproj'
            original = 'CURRENT_PROJECT_VERSION = 3; MARKETING_VERSION = 1.7;\nINFOPLIST_FILE = "Info.plist";'
            pbx.write_text(original)
            info = base / 'Info.plist'
            info.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.7'}))
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                numbers = list(pool.map(lambda _: qa.reserve(project), range(8)))
            self.assertEqual(sorted(numbers), list(range(4, 12)))
            self.assertNotIn('CFBundleVersion', plistlib.loads(info.read_bytes()), 'Reserving never edits source plists')
            pbx.write_text(original)  # emulate restoring an older checkout
            self.assertEqual(qa.reserve(project), 12)
            self.assertEqual(plistlib.loads(info.read_bytes())['CFBundleShortVersionString'], '1.7')

    def test_missing_reservation_fails_instead_of_reusing_old_number(self):
        with tempfile.TemporaryDirectory(prefix='qa-number-fixture-') as root:
            info = Path(root) / 'Info.plist'
            info.write_bytes(plistlib.dumps({'CFBundleVersion': '7'}))
            with self.assertRaises(FileNotFoundError):
                qa.stamp_product(info, root)
            self.assertEqual(plistlib.loads(info.read_bytes())['CFBundleVersion'], '7')

    def test_reservation_is_scoped_to_derived_build_directory(self):
        with tempfile.TemporaryDirectory(prefix='qa-number-fixture-') as root:
            base = Path(root)
            project = base / 'App.xcodeproj'
            project.mkdir()
            (project / 'project.pbxproj').write_text('CURRENT_PROJECT_VERSION = 7;')
            self.assertEqual(qa.reserve(project, reservation_dir=base / 'derived-a'), 8)
            self.assertEqual(qa.reserve(project, reservation_dir=base / 'derived-b'), 9)
            self.assertEqual((base / 'derived-a/qa-build-number').read_text().strip(), '8')
            self.assertEqual((base / 'derived-b/qa-build-number').read_text().strip(), '9')


if __name__ == '__main__':
    unittest.main()
