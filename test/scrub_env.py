#!/usr/bin/env python3
"""The daemon's environment is nobody's test environment (see harbormaster,
above _spawn_daemon). Pure: loads the script as a module, no daemon, no ports.

    python3 test/scrub_env.py
"""
import importlib.machinery, importlib.util, os, pathlib, sys

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

env = {
    "PATH": "/usr/bin", "HOME": "/Users/x", "FBPORTS_PORT": "4999", "FBPORTS_STATE_DIR": "/tmp/s",
    "TEST_NOW_MS": "1784000000000", "LLM_CACHE": "1", "LLM_CACHE_DIR": "/c", "LLM_CACHE_USAGE_LOG": "/l",
    "FIRESTORE_EMULATOR_HOST": "127.0.0.1:11021", "FIREBASE_AUTH_EMULATOR_HOST": "127.0.0.1:11020",
    "EMULATOR_FIRESTORE_PORT": "11021", "GCLOUD_PROJECT": "impulse-mode", "FUNCTIONS_EMULATOR": "true",
    "METRO_PORT": "11031", "DETOX_UDID": "ABC", "DETOX_SIM_NAME": "run-1", "FBPORTS_LEASE_ID": "x", "FBPORTS_BLOCK_BASE": "11000",
}
out = hm.scrubbed_env(env)
check("daemon config and the basics survive", {"PATH", "HOME", "FBPORTS_PORT", "FBPORTS_STATE_DIR"} <= set(out))
check("the frozen test clock does not", "TEST_NOW_MS" not in out)
check("nor any LLM_CACHE* knob", not any(k.startswith("LLM_CACHE") for k in out))
check("nor anything pointing at an emulator", not any(k.endswith("_EMULATOR_HOST") or k.endswith("_EMULATOR_PORT") or k.startswith("EMULATOR_") for k in out))
check("nor a project / functions-emulator marker", "GCLOUD_PROJECT" not in out and "FUNCTIONS_EMULATOR" not in out)
check("nor what a lease hands out", not ({"METRO_PORT", "DETOX_UDID", "DETOX_SIM_NAME", "FBPORTS_LEASE_ID", "FBPORTS_BLOCK_BASE"} & set(out)))
check("exactly the four survivors", set(out) == {"PATH", "HOME", "FBPORTS_PORT", "FBPORTS_STATE_DIR"})

# _scrub_environ acts on the live process env and reports what it dropped.
os.environ["TEST_NOW_MS"] = "1"; os.environ["LLM_CACHE"] = "1"
dropped = hm._scrub_environ()
check("_scrub_environ removes them from os.environ", "TEST_NOW_MS" not in os.environ and "LLM_CACHE" not in os.environ)
check("…and says which", {"TEST_NOW_MS", "LLM_CACHE"} <= set(dropped))

print(f"\n{'all passed' if not failed else f'{failed} failed'}")
sys.exit(1 if failed else 0)
