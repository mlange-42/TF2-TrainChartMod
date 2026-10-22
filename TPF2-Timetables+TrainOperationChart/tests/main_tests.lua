local timetableTests = require "tests.timetable_tests"
local timetableHelperTests = require "tests.timetable_helper_tests"
local diagramTrainsTests = require "tests.diagram_trains_tests"


print("running timetable tests")
timetableTests.test()

print("running timetable helper tests")
timetableHelperTests.test()

print("running diagram trains tests")
diagramTrainsTests.test()
