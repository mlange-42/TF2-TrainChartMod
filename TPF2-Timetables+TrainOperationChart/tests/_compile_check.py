import sys
from lupa import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()
print("LUA VERSION:", g._VERSION)
loadfn = g.loadstring or g.load  # 5.1: loadstring; 5.2+: load
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
    # pcall(load, ...) returns (true, chunk) on success, but (true, nil, message) on a
    # syntax error, since load reports errors by return value rather than raising them.
    if not isinstance(res, tuple):
        res = (res,)
    ok = bool(res[0]) and len(res) > 1 and res[1] is not None
    if ok:
        detail = "syntax OK"
    else:
        detail = res[2] if len(res) > 2 else (res[1] if len(res) > 1 else str(res))
    if not ok:
        failed += 1
        print("COMPILE FAIL:", path)
        print("   ", detail)
    else:
        print("compile OK:", path)

print("RESULT:", "ALL COMPILE OK" if failed == 0 else str(failed) + " FAILED")
sys.exit(1 if failed else 0)
