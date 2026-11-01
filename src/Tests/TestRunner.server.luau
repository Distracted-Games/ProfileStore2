--!strict
const TestSuite = require("./ProfileStore2.test")

local testNames: { string } = {}
for testName in TestSuite :: { [string]: () -> () } do
	table.insert(testNames, testName)
end
table.sort(testNames)

local totalTests = 0
local passedTests = 0

print("=====================================")
print("  Running tests for ProfileStore2 Library  ")
print("=====================================")

for _, testName in testNames do
	const testFunction = (TestSuite :: { [string]: () -> () })[testName]
	totalTests += 1

	const success, err = pcall(testFunction)
	if success then
		passedTests += 1
		print(`  [PASS] {testName}`)
	else
		warn(`  [FAIL] {testName} - {tostring(err)}`)
	end
end

task.wait(0.25)

print("=====================================")
print(`  Test Summary: {passedTests}/{totalTests} passed.  `)
print("=====================================")
