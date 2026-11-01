--!strict
const HttpService = game:GetService("HttpService")

const ProfileStore = require("@game/ServerScriptService/ProfileStore2")
const Promise = require("@game/ServerScriptService/ProfileStore2/LeanPromise")
const PromiseError = require("@game/ServerScriptService/ProfileStore2/LeanPromise/PromiseError")

const TEST_TEMPLATE = {
	Coins = 0,
	Wins = 0,
	Nested = {
		Level = 1,
	},
}

const TEST_WELCOME_KIT = {
	Coins = 100,
	Wins = 0,
}

local function uniqueKey(prefix: string): string
	const rawGuid = string.gsub(HttpService:GenerateGUID(false), "-", "")
	return `{prefix}_{string.sub(rawGuid, 1, 20)}`
end

local function awaitPromise<T>(promise: Promise.Promise<T>): (boolean, any)
	return pcall(function()
		return promise:await()
	end)
end

local TestSuite = {}

--------------------------------------------------------------------------------
-- LeanPromise Tests
--------------------------------------------------------------------------------

function TestSuite.TestPromiseSyncRejectAndToString()
	const customErr = PromiseError.new({
		error = "Synthetic failure text",
		kind = PromiseError.Kind.TimedOut,
	})
	assert(
		string.find(tostring(customErr), "Synthetic failure text") ~= nil,
		"PromiseError:__tostring() must include the error message"
	)

	const ok, caughtErr = awaitPromise(Promise.reject(customErr))
	assert(not ok, "Promise.reject should reject")
	assert(PromiseError.isKind(caughtErr, PromiseError.Kind.TimedOut), "Expected TimedOut error kind")
end

function TestSuite.TestPromiseFinallyPreservesRejection()
	local finallyRan = false
	const rejectedPromise = Promise.reject("Boom"):finally(function()
		finallyRan = true
	end)

	const ok, reason = awaitPromise(rejectedPromise)
	assert(finallyRan, ":finally() callback did not execute")
	assert(not ok, ":finally() swallowed a rejection instead of forwarding it")
	assert(reason == "Boom", `Expected rejection reason 'Boom', got {tostring(reason)}`)
end

function TestSuite.TestPromiseUpwardCancellation()
	local rootCancelHookFired = false
	const rootPromise = Promise.new(function(_resolve, _reject, onCancel)
		onCancel(function()
			rootCancelHookFired = true
		end)
	end)

	const chained = rootPromise:andThen(function()
		return true
	end)

	chained:cancel()
	task.wait()

	assert(rootCancelHookFired, "Cancelling chained consumer promise should cancel root promise")
	assert(rootPromise:getStatus() == Promise.Status.Cancelled, "Root promise status should be Cancelled")
end

--------------------------------------------------------------------------------
-- Core Functionality Tests
--------------------------------------------------------------------------------

function TestSuite.TestStoreCreation()
	const ok, store = awaitPromise(ProfileStore.create("TestStore_Creation", TEST_TEMPLATE))
	assert(ok, `Store creation failed: {tostring(store)}`)
	assert(typeof(store) == "table", "Store is not a table")
	assert(store.Name == "TestStore_Creation", "Store has incorrect name")
end

function TestSuite.TestNewProfileAndManualReconcile()
	const testKey = uniqueKey("NewProfile")
	const okStore, store = awaitPromise(ProfileStore.create("TestStore_NewProfile", TEST_WELCOME_KIT))
	assert(okStore, `Store creation failed: {tostring(store)}`)

	const okLoad, profile = awaitPromise(store.Mock:LoadProfileAsync(testKey))
	assert(okLoad and profile, `LoadProfileAsync failed: {tostring(profile)}`)
	assert(profile.Data.Coins == 100, "New profile did not copy welcome kit template")
	assert(profile:IsActive(), "New profile should be active")
	-- Simulate a custom schema migration before reconciling missing template fields:
	local rawData: { [string]: any } = profile.Data :: any
	rawData.Coins = nil
	const okEnd1, errEnd1 = awaitPromise(profile:EndSession())
	assert(okEnd1, `EndSession failed: {tostring(errEnd1)}`)

	const okReload, reloaded = awaitPromise(store.Mock:LoadProfileAsync(testKey))
	assert(okReload and reloaded, `Reload failed: {tostring(reloaded)}`)
	assert((reloaded.Data :: any).Coins == nil, "LoadProfileAsync should not auto-reconcile before custom migrations")

	reloaded:Reconcile()
	assert(reloaded.Data.Coins == 100, "Manual :Reconcile() should populate missing template fields")

	awaitPromise(reloaded:EndSession())
	awaitPromise(store.Mock:RemoveAsync(testKey))
end

function TestSuite.TestSaveAndReload()
	const testKey = uniqueKey("SaveReload")
	const okStore, store = awaitPromise(ProfileStore.create("TestStore_SaveReload", TEST_TEMPLATE))
	assert(okStore, `Store creation failed: {tostring(store)}`)

	const okSaveChain, chainErr = awaitPromise(store.Mock
		:LoadProfileAsync(testKey)
		:andThen(function(profile)
			profile.Data.Coins = 123
			profile.Data.Wins = 5
			assert(profile.LastSavedData.Coins == 0, "LastSavedData mutated before save")
			return profile:Save():andThen(function(lastSaved)
				assert(lastSaved.Coins == 123, "Save() promise did not resolve with updated LastSavedData")
				return profile:EndSession()
			end)
		end)
		:andThen(function()
			return store.Mock:LoadProfileAsync(testKey)
		end)
		:andThen(function(reloadedProfile)
			assert(reloadedProfile.Data.Coins == 123, "Saved coin data did not match")
			assert(reloadedProfile.Data.Wins == 5, "Saved win data did not match")
			return reloadedProfile:EndSession()
		end)
		:andThen(function()
			return store.Mock:RemoveAsync(testKey)
		end))
	assert(okSaveChain, `Save and Reload chain failed: {tostring(chainErr)}`)
end

--------------------------------------------------------------------------------
-- Session Locking & Conflict Resolution Tests
--------------------------------------------------------------------------------

function TestSuite.TestSameServerDuplicateLoadRejected()
	const testKey = uniqueKey("DupLoad")
	const okStore, store = awaitPromise(ProfileStore.create("TestStore_SessionLock", TEST_TEMPLATE))
	assert(okStore, `Store creation failed: {tostring(store)}`)

	const okFirst, firstProfile = awaitPromise(store.Mock:LoadProfileAsync(testKey))
	assert(okFirst and firstProfile, `First load failed: {tostring(firstProfile)}`)
	assert(firstProfile:IsActive(), "First profile should be active")

	const okSecond, secondErr = awaitPromise(store.Mock:LoadProfileAsync(testKey))
	assert(not okSecond, "Duplicate same-server LoadProfileAsync should reject")
	assert(
		PromiseError.isKind(secondErr, ProfileStore.ErrorKind.SessionConflict),
		`Expected SessionConflict error kind, got {tostring(secondErr)}`
	)

	awaitPromise(firstProfile:EndSession())
	awaitPromise(store.Mock:RemoveAsync(testKey))
end

function TestSuite.TestConcurrentLoadCoalescing()
	const testKey = uniqueKey("Coalesce")
	const okStore, store = awaitPromise(ProfileStore.create("TestStore_Coalesce", TEST_TEMPLATE))
	assert(okStore, `Store creation failed: {tostring(store)}`)

	const p1 = store.Mock:LoadProfileAsync(testKey)
	const p2 = store.Mock:LoadProfileAsync(testKey)
	const p3 = store.Mock:LoadProfileAsync(testKey)

	const ok1, res1 = awaitPromise(p1)
	const ok2, res2 = awaitPromise(p2)
	const ok3, res3 = awaitPromise(p3)

	assert(
		not ok1 and PromiseError.isKind(res1, ProfileStore.ErrorKind.Cancelled),
		"First concurrent load should cancel"
	)
	assert(
		not ok2 and PromiseError.isKind(res2, ProfileStore.ErrorKind.Cancelled),
		"Second concurrent load should cancel"
	)
	assert(ok3 and res3 ~= nil, "Latest concurrent load should succeed")

	awaitPromise(res3:EndSession())
	awaitPromise(store.Mock:RemoveAsync(testKey))
end

function TestSuite.TestExternalForceLoadRelease()
	const testKey = uniqueKey("ForceLoad")
	const storeName = "TestStore_ForceLoad"
	const okStore, store = awaitPromise(ProfileStore.create(storeName, TEST_TEMPLATE))
	assert(okStore, `Store creation failed: {tostring(store)}`)

	const okLoad, profile = awaitPromise(store.Mock:LoadProfileAsync(testKey))
	assert(okLoad and profile, `Load failed: {tostring(profile)}`)

	local lastSaveReason: string? = nil
	local sessionEnded = false
	profile.OnLastSave:Connect(function(reason)
		lastSaveReason = reason
	end)
	profile.OnSessionEnd:Connect(function()
		sessionEnded = true
	end)

	-- Inject a remote server's ForceLoadSession into the mock entry:
	const mockEntry = ProfileStore.Test().UserMockStore[storeName][testKey]
	mockEntry.Data.MetaData.ForceLoadSession = {
		PlaceId = -999,
		JobId = "RemoteServerJobId",
	}

	const okSave, saveErr = awaitPromise(profile:Save())
	assert(okSave, `Save failed: {tostring(saveErr)}`)

	-- Wait briefly for the triggered external release to finish:
	const start = os.clock()
	while not sessionEnded and os.clock() - start < 5 do
		task.wait()
	end

	assert(sessionEnded, "Profile did not end session when ForceLoadSession was detected")
	assert(not profile:IsActive(), "Profile should be inactive after external release")
	assert(lastSaveReason == "External", `Expected OnLastSave reason 'External', got {tostring(lastSaveReason)}`)

	awaitPromise(store.Mock:RemoveAsync(testKey))
end

--------------------------------------------------------------------------------
-- GetAsync, SetAsync, Metadata, Overwrite, & Legacy Schema Tests
--------------------------------------------------------------------------------

function TestSuite.TestGetAsyncAndSetAsyncOverwrite()
	const testKey = uniqueKey("ViewMode")
	const okStore, store = awaitPromise(ProfileStore.create("TestStore_ViewMode", TEST_TEMPLATE))
	assert(okStore, `Store creation failed: {tostring(store)}`)

	-- Missing key should resolve to nil cleanly:
	const okMissing, missingProfile = awaitPromise(store.Mock:GetAsync(testKey))
	assert(okMissing, `GetAsync errored on missing key: {tostring(missingProfile)}`)
	assert(missingProfile == nil, "GetAsync should resolve nil for an empty key")

	-- Create active profile:
	const okActive, activeProfile = awaitPromise(store.Mock:LoadProfileAsync(testKey))
	assert(okActive and activeProfile, "Failed to load active profile")
	activeProfile.Data.Coins = 50
	activeProfile:AddUserId(12345)
	activeProfile.RobloxMetaData = { Tag = "VIP" }
	awaitPromise(activeProfile:Save())

	-- Mutate active profile in-memory (unsaved), then overwrite via view-mode SetAsync:
	activeProfile.Data.Coins = 999999

	const okView, viewProfile = awaitPromise(store.Mock:GetAsync(testKey))
	assert(okView and viewProfile ~= nil, "GetAsync failed for existing key")
	assert(viewProfile._viewMode == true, "GetAsync profile must have _viewMode == true")
	assert(not viewProfile:IsActive(), "View-mode profile IsActive() must return false")
	assert(viewProfile.Data.Coins == 50, "View-mode profile did not read saved Coins")

	viewProfile.Data.Coins = 777
	viewProfile:AddUserId(67890)
	const okSet, setErr = awaitPromise(viewProfile:SetAsync())
	assert(okSet, `SetAsync failed: {tostring(setErr)}`)

	-- Active profile on this server should be deactivated immediately:
	const start = os.clock()
	while activeProfile:IsActive() and os.clock() - start < 5 do
		task.wait()
	end
	assert(not activeProfile:IsActive(), "Active profile should lose session after view-mode SetAsync")

	-- Verify persisted state and KeyInfo:
	const okCheck, checkProfile = awaitPromise(store.Mock:GetAsync(testKey))
	assert(okCheck and checkProfile ~= nil, "Verification GetAsync failed")
	assert(checkProfile.Data.Coins == 777, "SetAsync overwrite did not persist Coins = 777")
	const metadata = checkProfile.KeyInfo:GetMetadata()
	const userIds = checkProfile.KeyInfo:GetUserIds()
	assert(metadata.Tag == "VIP", "KeyInfo:GetMetadata() did not preserve metadata")
	assert(table.find(userIds, 12345) ~= nil and table.find(userIds, 67890) ~= nil, "KeyInfo:GetUserIds() mismatch")

	awaitPromise(store.Mock:RemoveAsync(testKey))
end

function TestSuite.TestCorruptionOverwriteSignal()
	const testKey = uniqueKey("Corrupt")
	const storeName = "TestStore_Corrupt"
	const okStore, store = awaitPromise(ProfileStore.create(storeName, TEST_TEMPLATE))
	assert(okStore, `Store creation failed: {tostring(store)}`)

	-- Seed malformed non-profile data into mock store:
	ProfileStore.Test().UserMockStore[storeName] = {
		[testKey] = {
			Data = { "InvalidLegacyArray" },
			CreatedTime = 1000,
			UpdatedTime = 1000,
			VersionId = 1,
			UserIds = {},
			MetaData = {},
		},
	}

	local overwriteTriggered = false
	const conn = ProfileStore.OnOverwrite:Connect(function(triggeredStore, triggeredKey)
		if triggeredStore == storeName and triggeredKey == testKey then
			overwriteTriggered = true
		end
	end)

	const okLoad, profile = awaitPromise(store.Mock:LoadProfileAsync(testKey))
	conn:Disconnect()

	assert(okLoad and profile ~= nil, "Failed to recover and load corrupted key")
	assert(overwriteTriggered, "OnOverwrite did not fire when overwriting malformed data")
	assert(profile.Data.Coins == 0, "Recovered profile did not initialize from template")

	awaitPromise(profile:EndSession())
	awaitPromise(store.Mock:RemoveAsync(testKey))
end

function TestSuite.TestLegacySchemaOption()
	const testKey = uniqueKey("Legacy")
	const storeName = "TestStore_Legacy"
	const okStore, store = awaitPromise(ProfileStore.create(storeName, TEST_TEMPLATE, {
		UseLegacySchema = true,
	}))
	assert(okStore, `Legacy store creation failed: {tostring(store)}`)

	const okLoad, profile = awaitPromise(store.Mock:LoadProfileAsync(testKey))
	assert(okLoad and profile ~= nil, "Legacy profile load failed")

	const rawActiveSession = ProfileStore.Test().UserMockStore[storeName][testKey].Data.MetaData.ActiveSession
	assert(typeof(rawActiveSession[1]) == "number", "UseLegacySchema should store PlaceId at index [1]")
	assert(typeof(rawActiveSession[2]) == "string", "UseLegacySchema should store JobId at index [2]")
	assert(typeof(rawActiveSession[3]) == "string", "UseLegacySchema should store UniqueId at index [3]")
	assert(
		profile.Session ~= nil and profile.Session.PlaceId == game.PlaceId,
		"Profile.Session should still normalize to { PlaceId, JobId }"
	)

	awaitPromise(profile:EndSession())
	awaitPromise(store.Mock:RemoveAsync(testKey))
end

function TestSuite.TestRemoveWhileActiveDoesNotResurrect()
	const testKey = uniqueKey("RemoveActive")
	const okStore, store = awaitPromise(ProfileStore.create("TestStore_RemoveActive", TEST_TEMPLATE))
	assert(okStore, `Store creation failed: {tostring(store)}`)

	const okLoad, profile = awaitPromise(store.Mock:LoadProfileAsync(testKey))
	assert(okLoad and profile ~= nil, "Failed to load profile")
	profile.Data.Coins = 42

	-- Wipe the profile while the session is still active (e.g., GDPR erasure):
	const okRemove, removed = awaitPromise(store.Mock:RemoveAsync(testKey))
	assert(okRemove and removed == true, "RemoveAsync failed")

	-- EndSession should complete cleanly without resurrecting a tombstone entry:
	const okEnd, endErr = awaitPromise(profile:EndSession())
	assert(okEnd, `EndSession after RemoveAsync should succeed cleanly: {tostring(endErr)}`)
	assert(not profile:IsActive(), "Profile should be inactive after EndSession")

	const okAfter, afterProfile = awaitPromise(store.Mock:GetAsync(testKey))
	assert(okAfter and afterProfile == nil, "EndSession should not resurrect an externally deleted key")
end

function TestSuite.TestMockAndLiveIsolationAndCacheClean()
	const testKey = uniqueKey("Isolation")
	const okStore, store = awaitPromise(ProfileStore.create("TestStore_Isolation", TEST_TEMPLATE))
	assert(okStore, `Store creation failed: {tostring(store)}`)

	const okMock, mockProfile = awaitPromise(store.Mock:LoadProfileAsync(testKey))
	assert(okMock and mockProfile ~= nil, "Mock load failed")
	mockProfile.Data.Coins = 999
	awaitPromise(mockProfile:EndSession())

	const okLive, liveProfile = awaitPromise(store:LoadProfileAsync(testKey))
	assert(okLive and liveProfile ~= nil, `Live/AutoMock load failed: {tostring(liveProfile)}`)
	assert(liveProfile.Data.Coins == 0, "Live/AutoMock store was affected by UserMock operation")
	awaitPromise(liveProfile:EndSession())

	awaitPromise(store.Mock:RemoveAsync(testKey))
	awaitPromise(store:RemoveAsync(testKey))

	const state = ProfileStore.Test()
	assert(next(state.ActiveSessionCheck) == nil, "ActiveSessionCheck leaked entries")
	assert(#state.AutoSaveList == 0, "AutoSaveList leaked entries")
	assert(state.ActiveProfileLoadJobs == 0, "ActiveProfileLoadJobs did not return to 0")
	assert(state.ActiveProfileSaveJobs == 0, "ActiveProfileSaveJobs did not return to 0")
	assert(next(state.UpdateQueue) == nil, "UpdateQueue leaked entries")
end

--------------------------------------------------------------------------------
-- Add-ons: Messaging & Versioning Tests
--------------------------------------------------------------------------------

function TestSuite.TestMessageAsyncOfflineAndLiveDelivery()
	const testKey = uniqueKey("Messaging")
	const okStore, store = awaitPromise(ProfileStore.create("TestStore_Messaging", TEST_TEMPLATE))
	assert(okStore, `Store creation failed: {tostring(store)}`)

	-- 1. Send an offline message before the profile has ever been created:
	const okMsg1, sent1 = awaitPromise(store.Mock:MessageAsync(testKey, {
		Type = "Gift",
		Coins = 50,
	}))
	assert(okMsg1 and sent1 == true, `Offline MessageAsync failed: {tostring(sent1)}`)

	-- 2. Load the profile and register two handlers (first does not mark processed, second does):
	const okLoad, profile = awaitPromise(store.Mock:LoadProfileAsync(testKey))
	assert(okLoad and profile ~= nil, `LoadProfileAsync after offline message failed: {tostring(profile)}`)

	local seenByObserver = 0
	local processedCount = 0

	profile:MessageHandler(function(_message, _processed)
		seenByObserver += 1
	end)

	profile:MessageHandler(function(message, processed)
		if typeof(message) == "table" and message.Type == "Gift" and typeof(message.Coins) == "number" then
			profile.Data.Coins += message.Coins
			processedCount += 1
			processed()
		end
	end)

	task.wait()
	assert(seenByObserver == 1, `Expected observer handler to see 1 offline message, saw {seenByObserver}`)
	assert(processedCount == 1 and profile.Data.Coins == 50, "Offline message was not processed into profile.Data")

	-- 3. Send a live message while the profile session is active on this server:
	const okMsg2, sent2 = awaitPromise(store.Mock:MessageAsync(testKey, {
		Type = "Gift",
		Coins = 25,
	}))
	assert(okMsg2 and sent2 == true, `Live MessageAsync failed: {tostring(sent2)}`)

	const waitStart = os.clock()
	while processedCount < 2 and os.clock() - waitStart < 5 do
		task.wait()
	end
	assert(processedCount == 2 and profile.Data.Coins == 75, "Live message was not delivered to active profile")

	-- 4. End session, reload, and verify processed messages were pruned from GlobalUpdates:
	awaitPromise(profile:EndSession())

	const okReload, reloaded = awaitPromise(store.Mock:LoadProfileAsync(testKey))
	assert(okReload and reloaded ~= nil, "Reload after messaging failed")

	local reprocessedCount = 0
	reloaded:MessageHandler(function(_message, processed)
		reprocessedCount += 1
		processed()
	end)
	task.wait()
	assert(reprocessedCount == 0, `Processed messages should be pruned on save, got {reprocessedCount}`)
	assert(reloaded.Data.Coins == 75, `Expected persisted Coins == 75, got {reloaded.Data.Coins}`)

	awaitPromise(reloaded:EndSession())
	awaitPromise(store.Mock:RemoveAsync(testKey))
end

function TestSuite.TestMessageAsyncQueueCap()
	const testKey = uniqueKey("MsgQueueCap")
	const okStore, store = awaitPromise(ProfileStore.create("TestStore_MsgCap", TEST_TEMPLATE))
	assert(okStore, `Store creation failed: {tostring(store)}`)

	ProfileStore.SetConstant("MAX_MESSAGE_QUEUE", 3)

	for index = 1, 5 do
		const okMsg, sent = awaitPromise(store.Mock:MessageAsync(testKey, {
			Order = index,
		}))
		assert(okMsg and sent == true, `MessageAsync #{index} failed`)
	end

	ProfileStore.SetConstant("MAX_MESSAGE_QUEUE", 1000)

	const okLoad, profile = awaitPromise(store.Mock:LoadProfileAsync(testKey))
	assert(okLoad and profile ~= nil, "Load failed")

	local receivedOrders: { number } = {}
	profile:MessageHandler(function(message, processed)
		if typeof(message) == "table" and typeof(message.Order) == "number" then
			table.insert(receivedOrders, message.Order)
		end
		processed()
	end)
	task.wait()

	assert(#receivedOrders == 3, `Expected 3 capped messages, got {#receivedOrders}`)
	assert(
		receivedOrders[1] == 3 and receivedOrders[2] == 4 and receivedOrders[3] == 5,
		"MAX_MESSAGE_QUEUE did not evict oldest messages in FIFO order"
	)

	awaitPromise(profile:EndSession())
	awaitPromise(store.Mock:RemoveAsync(testKey))
end

function TestSuite.TestVersionQueryAndRollback()
	const testKey = uniqueKey("VersionQuery")
	const okStore, store = awaitPromise(ProfileStore.create("TestStore_Versioning", TEST_TEMPLATE))
	assert(okStore, `Store creation failed: {tostring(store)}`)

	-- 1. Mock VersionQuery resolves nil cleanly:
	const mockQuery = store.Mock:VersionQuery(testKey)
	const okMockNext, mockResult = awaitPromise(mockQuery:NextAsync())
	assert(okMockNext and mockResult == nil, "Mock VersionQuery:NextAsync() should resolve nil")

	-- 2. If live DataStore access is active, verify full multi-version iteration and rollback:
	if ProfileStore.DataStoreState == "Access" then
		const okLoad, profile = awaitPromise(store:LoadProfileAsync(testKey))
		assert(okLoad and profile ~= nil, "Failed to load live profile for VersionQuery test")

		profile.Data.Coins = 10
		awaitPromise(profile:Save())

		profile.Data.Coins = 20
		awaitPromise(profile:Save())

		profile.Data.Coins = 30
		awaitPromise(profile:EndSession())

		const query = store:VersionQuery(testKey, Enum.SortDirection.Descending)

		const okV1, v1 = awaitPromise(query:NextAsync())
		const okV2, v2 = awaitPromise(query:NextAsync())
		const okV3, v3 = awaitPromise(query:NextAsync())
		const okV4, v4 = awaitPromise(query:NextAsync())
		const okV5, v5 = awaitPromise(query:NextAsync())

		assert(okV1 and v1 ~= nil and v1.Data.Coins == 30, "Expected latest version Coins == 30")
		assert(okV2 and v2 ~= nil and v2.Data.Coins == 20, "Expected second version Coins == 20")
		assert(okV3 and v3 ~= nil and v3.Data.Coins == 10, "Expected third version Coins == 10")
		assert(okV4 and v4 ~= nil and v4.Data.Coins == 0, "Expected initial load version Coins == 0")
		assert(okV5 and v5 == nil, "Expected VersionQuery to resolve nil after exhausting versions")

		-- Roll back to v3 (Coins == 10) using view-mode :SetAsync():
		assert(v3 ~= nil, "v3 must not be nil")
		const okRollback, rollbackErr = awaitPromise(v3:SetAsync())
		assert(okRollback, `Rollback SetAsync failed: {tostring(rollbackErr)}`)

		const okVerify, currentView = awaitPromise(store:GetAsync(testKey))
		assert(
			okVerify and currentView ~= nil and currentView.Data.Coins == 10,
			"Rollback via VersionQuery snapshot :SetAsync() did not persist Coins == 10"
		)

		awaitPromise(store:RemoveAsync(testKey))
	end
end

return TestSuite
