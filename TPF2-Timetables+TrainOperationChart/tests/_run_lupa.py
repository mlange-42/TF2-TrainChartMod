import sys
from lupa import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('package.path = "./?.lua;./res/scripts/?.lua;./tests/?.lua;" .. package.path')
lua.execute('dofile("tests/main_tests.lua")')
print("ALL TESTS PASSED")
