"""scan.py 的单元测试：python3 -m unittest tools/apple/privacy/test_scan.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import scan  # noqa: E402


class ScanTest(unittest.TestCase):
    def test_normalize(self):
        self.assertEqual(scan.normalize("_stat"), "stat")
        self.assertEqual(scan.normalize("_stat$INODE64"), "stat")
        self.assertEqual(scan.normalize("fstatfs64@GLIBC_2.33"), "fstatfs")
        self.assertEqual(scan.normalize("__fxstat64"), "fstat")
        self.assertEqual(scan.normalize("_OBJC_CLASS_$_NSUserDefaults"), "OBJC_CLASS_$_NSUserDefaults")
        self.assertEqual(scan.normalize("_malloc"), "malloc")

    def test_check(self):
        declared = {scan.FILE_TIMESTAMP, scan.BOOT_TIME}
        symbols = {"lib.a": {"_stat", "_statfs", "_getattrlist", "_malloc", "_mach_absolute_time"}}
        problems = scan.check(symbols, declared)
        # getattrlist 声明了文件时间戳就算；statfs 是磁盘空间，没声明。
        self.assertEqual(problems, [("lib.a", "_statfs", [scan.DISK_SPACE])])
        self.assertEqual(scan.check(symbols, declared | {scan.DISK_SPACE}), [])

    def test_manifest_declares_what_the_rust_core_uses(self):
        root = os.path.join(os.path.dirname(__file__), "..", "..", "..")
        manifest = os.path.join(root, "apps/apple/Thinktin/Resources/PrivacyInfo.xcprivacy")
        declared = scan.declared_categories(manifest)
        for category in (scan.FILE_TIMESTAMP, scan.BOOT_TIME, scan.DISK_SPACE, scan.USER_DEFAULTS):
            self.assertIn(category, declared)


if __name__ == "__main__":
    unittest.main()
