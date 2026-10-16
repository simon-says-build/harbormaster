#!/usr/bin/env python3
"""A project's own suite env (harbormaster.env, see project_env). Pure: loads
the script as a module, writes a temp project, no daemon, no ports.

    python3 test/project_env.py
"""
import importlib.machinery, importlib.util, os, pathlib, sys, tempfile

HM = pathlib.Path(__file__).resolve().parent.parent / "harbormaster"
loader = importlib.machinery.SourceFileLoader("harbormaster", str(HM))
spec = importlib.util.spec_from_loader("harbormaster", loader)
hm = importlib.util.module_from_spec(spec)
loader.exec_module(hm)

failed = 0
def check(name, ok):
    global failed
    print(("  ok  " if ok else "FAIL  ") + name)
    if not ok:
        failed += 1

with tempfile.TemporaryDirectory() as d:
    proj = pathlib.Path(d) / "app" / "functions"
    proj.mkdir(parents=True)
    check("no harbormaster.env is no env", hm.project_env(proj) == {})
    (proj / "harbormaster.env").write_text(
        "# the emulator runs under the test key\n"
        "\n"
        "GOOGLE_APPLICATION_CREDENTIALS=./impulse-test-bq.json\n"
        "UP=../shared/key.json\n"
        "QUOTED=\"two words\"\n"
        "PLAIN=impulse-mode-test\n"
        "ABS=/etc/key.json\n"
        "not a pair\n")
    env = hm.project_env(proj)
    real = proj.resolve()
    check("./ paths are absolute, against the project",
          env.get("GOOGLE_APPLICATION_CREDENTIALS") == str(real / "impulse-test-bq.json"))
    check("../ paths too", env.get("UP") == str((real / ".." / "shared" / "key.json").resolve()))
    check("quotes are stripped", env.get("QUOTED") == "two words")
    check("plain values are kept", env.get("PLAIN") == "impulse-mode-test")
    check("absolute paths are kept", env.get("ABS") == "/etc/key.json")
    check("comments, blanks and junk are skipped", set(env) == {"GOOGLE_APPLICATION_CREDENTIALS", "UP", "QUOTED", "PLAIN", "ABS"})

sys.exit(1 if failed else 0)
