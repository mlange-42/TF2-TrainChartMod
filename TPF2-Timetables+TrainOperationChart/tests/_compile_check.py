import sys
from lupa import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()
print("LUA VERSION:", g._VERSION)
loadfn = g.loadstring or g.load  # 5.1: loadstring；5.2+: load
pcall = g.pcall

files = [
    "res/scripts/celmi/timetables/timetable.lua",
    "res/scripts/celmi/timetables/timetable_helper.lua",
    "res/scripts/celmi/timetables/diagram_gui.lua",
    "res/config/game_script/timetable_gui.lua",
    "strings.lua",
    "tests/timetable_tests.lua",
    "tests/timetable_helper_tests.lua",
]

failed = 0
for path in files:
    try:
        with open(path, "rb") as fh:
            src = fh.read().decode("utf-8-sig")
    except OSError as e:
        print("READ ERROR", path, e)
        failed += 1
        continue
    res = pcall(loadfn, src, path)
    if isinstance(res, tuple):
        ok = res[0]
        detail = res[1] if len(res) > 1 and not ok else "syntax OK"
    else:
        ok = bool(res)
        detail = "syntax OK" if ok else str(res)
    if not ok:
        failed += 1
        print("COMPILE FAIL:", path)
        print("   ", detail)
    else:
        print("compile OK:", path)

print("RESULT:", "ALL COMPILE OK" if failed == 0 else str(failed) + " FAILED")
sys.exit(1 if failed else 0)
