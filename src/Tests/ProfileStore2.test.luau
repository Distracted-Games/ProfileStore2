--!strict
-- ServerScriptService/Source/Tests/ProfileStore2.test.luau
local ServerScriptService = game:GetService("ServerScriptService")

-- Corrected require paths
local ProfileStore = require(ServerScriptService.ProfileStore2)
local Signal = require(ServerScriptService.ProfileStore2.Signal)

local TestSuite = {}

-- Defined templates for use in tests
local TEST_TEMPLATE = { Coins = 0, Wins = 0 }
local TEST_WELCOME_KIT = { Coins = 100, Wins = 0 }

--================--------------------------------================
-- Core Functionality Tests
--================================================================

function TestSuite.TestStoreCreation()
	local doneSignal = Signal.new()
	ProfileStore.create("TestStore_Creation", TEST_TEMPLATE)
		:andThen(function(store)
			assert(typeof(store) == "table", "Store is not a table")
			assert(store.Name == "TestStore_Creation", "Store has incorrect name")
			doneSignal:Fire(true)
		end)
		:catch(function(err)
			doneSignal:Fire(false, `Store creation failed: {tostring(err)}`)
		end)

	local success, err = doneSignal:Wait()
	assert(success, `TestStoreCreation failed: {err}`)
end

function TestSuite.TestNewProfileLoad()
	local testKey = "TestPlayer_NewProfile"
	local doneSignal = Signal.new()

	ProfileStore.create("TestStore_NewProfile", TEST_WELCOME_KIT)
		:andThen(function(store)
			store:LoadProfileAsync(testKey)
				:andThen(function(profile)
					assert(profile, "Profile is nil for a new player")
					assert(profile.Data.Coins == 100, "Profile did not load with welcome kit data")
					assert(profile:IsActive(), "New profile is not active")
					profile:EndSession()
					doneSignal:Fire(true)
				end)
				:catch(function(err)
					doneSignal:Fire(false, `LoadProfileAsync failed: {tostring(err)}`)
				end)
		end)
	
	local success, err = doneSignal:Wait()
	assert(success, `New profile load failed: {err}`)
end

function TestSuite.TestSaveAndReload()
	local testKey = "TestPlayer_SaveReload"
	local doneSignal = Signal.new()

	ProfileStore.create("TestStore_SaveReload", TEST_TEMPLATE)
		:andThen(function(store)
			-- Step 1: Load, modify, and save
			store:LoadProfileAsync(testKey)
				:andThen(function(profile)
					profile.Data.Coins = 123
					profile.Data.Wins = 5
					profile:EndSession()
					return profile.OnSessionEnd:Wait()
				end)
				-- Step 2: Reload and verify
				:andThen(function()
					return store:LoadProfileAsync(testKey)
				end)
				:andThen(function(reloadedProfile)
					assert(reloadedProfile.Data.Coins == 123, "Saved coin data did not match")
					assert(reloadedProfile.Data.Wins == 5, "Saved win data did not match")
					reloadedProfile:EndSession()
					return reloadedProfile.OnSessionEnd:Wait()
				end)
				-- Step 3: Cleanup and signal success
				:andThen(function()
					return store:RemoveAsync(testKey)
				end)
				:andThen(function()
					doneSignal:Fire(true)
				end)
				:catch(function(err)
					doneSignal:Fire(false, tostring(err))
				end)
		end)

	local success, err = doneSignal:Wait()
	assert(success, `Save and Reload failed: {err}`)
end

--================--------------------------------================
-- Session Locking Tests
--================================================================

function TestSuite.TestSessionLocking()
	local testKey = "TestPlayer_SessionLock"
	local doneSignal = Signal.new()
	local firstProfile

	ProfileStore.create("TestStore_SessionLock", TEST_TEMPLATE)
		:andThen(function(store)
			store:LoadProfileAsync(testKey)
				:andThen(function(profile)
					firstProfile = profile
					assert(profile:IsActive(), "First profile is not active")
					return store:LoadProfileAsync(testKey)
				end)
				:andThen(function(secondProfile)
					assert(false, "Session locking failed! A second profile was loaded.")
				end)
				:catch(function(err)
					assert(string.find(tostring(err), "Timed out"), "Expected a timeout error for session lock")
					doneSignal:Fire(true)
				end)
		end)
		
	local success, err = doneSignal:Wait()
	assert(success, `Session locking test failed logic: {err}`)
	
	if firstProfile then firstProfile:EndSession() end
end

--================--------------------------------================
-- Other API Tests
--================================================================

function TestSuite.TestMocking()
	local testKey = "TestPlayer_Mocking"
	local doneSignal = Signal.new()

	ProfileStore.create("TestStore_Mocking", TEST_TEMPLATE)
		:andThen(function(store)
			store.Mock:LoadProfileAsync(testKey)
				:andThen(function(mockProfile)
					mockProfile.Data.Coins = 999
					mockProfile:EndSession()
					return mockProfile.OnSessionEnd:Wait()
				end)
				:andThen(function()
					return store.Mock:LoadProfileAsync(testKey)
				end)
				:andThen(function(reloadedMockProfile)
					assert(reloadedMockProfile.Data.Coins == 999, "Mock data did not save")
					reloadedMockProfile:EndSession()
					return reloadedMockProfile.OnSessionEnd:Wait()
				end)
				:andThen(function()
					return store:LoadProfileAsync(testKey)
				end)
				:andThen(function(realProfile)
					assert(realProfile.Data.Coins == 0, "Real datastore was affected by mock operation")
					realProfile:EndSession()
					return realProfile.OnSessionEnd:Wait()
				end)
				:andThen(function()
					return store:RemoveAsync(testKey)
				end)
				:andThen(function()
					doneSignal:Fire(true)
				end)
				:catch(function(err)
					doneSignal:Fire(false, tostring(err))
				end)
		end)
		
	local success, err = doneSignal:Wait()
	assert(success, `Mocking test failed: {err}`)
end

function TestSuite.TestGetAsyncIsViewMode()
	local testKey = "TestPlayer_GetAsync"
	local doneSignal = Signal.new()

	ProfileStore.create("TestStore_GetAsync", TEST_TEMPLATE)
		:andThen(function(store)
			return store:GetAsync(testKey)
		end)
		:andThen(function(profile)
			assert(profile, "GetAsync returned nil for a new profile")
			assert(profile._viewMode == true, "Profile from GetAsync is not in view mode")
			doneSignal:Fire(true)
		end)
		:catch(function(err)
			doneSignal:Fire(false, tostring(err))
		end)
		
	local success, err = doneSignal:Wait()
	assert(success, `GetAsync test failed: {err}`)
end

return TestSuite
