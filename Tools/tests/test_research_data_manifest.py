"""The dataset manifest behind Tools/research-data/fetch.sh stays well-formed and honest.

Pure stdlib; reads only the manifest and the README beside it. Discovered by the core `tools-python`
step like every other test in this package.
"""
import pathlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent.parent / "research-data"
KINDS = {"physionet", "zenodo", "uci", "ora", "manual"}


def rows():
    out = []
    for line in (HERE / "datasets.tsv").read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        out.append(line.split("\t"))
    return out


class ManifestTests(unittest.TestCase):
    def test_every_row_has_six_fields(self):
        for r in rows():
            self.assertEqual(len(r), 6, r)
            self.assertTrue(all(f.strip() for f in r), r)

    def test_names_are_unique_and_kinds_known(self):
        names = [r[0] for r in rows()]
        self.assertEqual(len(names), len(set(names)))
        for r in rows():
            self.assertIn(r[1], KINDS, r[0])

    def test_urls_are_https_and_verify_modes_valid(self):
        for name, kind, url, verify, _licence, _note in rows():
            self.assertTrue(url.startswith("https://"), name)
            if verify.startswith("md5:"):
                self.assertRegex(verify, r"^md5:[0-9a-f]{32}$", name)
            else:
                self.assertIn(verify, {"sha256sums", "none"}, name)
            if kind == "physionet":
                self.assertEqual(verify, "sha256sums", name)
                self.assertRegex(url, r"^https://physionet\.org/content/[a-z0-9-]+/get-zip/[0-9.]+/$", name)
            if kind == "manual":
                self.assertEqual(verify, "none", name)

    def test_fetch_script_is_executable_and_reads_the_manifest(self):
        script = HERE / "fetch.sh"
        self.assertTrue(script.stat().st_mode & 0o111, "fetch.sh must be executable")
        text = script.read_text(encoding="utf-8")
        self.assertIn("datasets.tsv", text)
        self.assertIn("research-data", text)
        self.assertNotIn("git add", text)

    def test_folder_is_git_ignored(self):
        gitignore = (HERE.parent.parent / ".gitignore").read_text(encoding="utf-8").splitlines()
        self.assertIn("/research-data/", [l.strip() for l in gitignore], "root-anchored so Tools/research-data stays tracked")


if __name__ == "__main__":
    unittest.main()
