# ProfileStore2

A robust, modular, and fully asynchronous DataStore library featuring session locking, designed for modern, professional Roblox development. This is a complete, type-safe refactor of the original [ProfileStore](https://github.com/MadStudioRoblox/ProfileStore) library by Mad Studio.

## 🚀 Overview

`ProfileStore2` is architected as a self-contained package. The core logic is partitioned into single-responsibility modules, keeping the codebase maintainable, strongly typed, and easy to audit:

| Module | Location | Purpose |
| :--- | :--- | :--- |
| `init.luau` | `.../ProfileStore2/` | Main entry point, store factory, and session coordinator. |
| `Profile.luau` | `.../ProfileStore2/` | OOP class representing an individual player's data session. |
| `LeanPromise/init.luau` | `.../ProfileStore2/LeanPromise/` | **Core Dependency**: Lightweight, cancellation-safe Promise implementation. |
| `LeanPromise/PromiseError.luau` | `.../ProfileStore2/LeanPromise/` | **Core Dependency**: Structured error object with typed error kinds (`DataStoreError`, etc.). |
| `Signal.luau` | `.../ProfileStore2/` | Yield-safe Signal implementation for event subscriptions. |
| `Constants.luau` | `.../ProfileStore2/` | Centralized, read-only timings, retry bounds, and configuration thresholds. |
| `Types.luau` | `.../ProfileStore2/` | Shared Luau type definitions, session states, and error kinds. |
| `Util.luau` | `.../ProfileStore2/` | Deep copying, table reconciliation, and error classification helpers. |
| `Addons/Messaging.luau` | `.../ProfileStore2/Addons/` | GlobalUpdates queue management and cross-server/offline messaging. |
| `Addons/Versioning.luau` | `.../ProfileStore2/Addons/` | Historical version querying and rollback iteration. |

## ⬇️ Installation
Here are some easy ways to install `ProfileStore2`:

1. **Releases** 
	If you simply want to drop the library into your game in Roblox Studio, simply download the latest release `.rbxm` file from [Releases](https://github.com/Distracted-Games/ProfileStore2/releases/) and insert it into your project (typically under `ServerScriptService > Libs` or `Pacakages`).

2. **Git Subtree**
	Uf you prefer to directly import the library into your project and are using Git, run the following command:
   ```bash
   git subtree add --prefix=src/ServerScriptService/Source/Libs/ProfileStore2 https://github.com/Distracted-Games/ProfileStore2 dist --squash
   ```
   💡 *Note: Replace the location after `prefix=` to where you want the library to be imported to. Make sure to end the path with `ProfileStore2`*

## 🧠 Design Philosophy

1. **Session Locking First**  
   Guarantees that only **one server holds an active session** for a key at any time, preventing data corruption or race conditions from rapid server hops. This is something shared by the original `ProfileStore` library.

2. **Asynchronous by Design**  
   All DataStore network calls return a **`Promise`**, giving you explicit `:andThen()` and `:catch()` pipelines with cooperative cancellation and bounded retries. This allows you to write clean, non-blocking code that will never lag your game, with clear success (`:andThen`) and failure (`:catch`) paths. This is one of the major differences from the original `ProfileStore`.

3. **Modular Submodules with Unified API**  
   Internal features like `Messaging` and `Versioning` are encapsulated in modular submodules while exposed directly on `ProfileStore` and `store.Mock`.

4. **Backward Compatibility & Safe Schema Migrations**  
   Supports legacy MadStudio `ProfileStore` schemas via `UseLegacySchema = true`, as well as custom `SchemaMigration` transform functions during profile loading.

## 📦 How to Use

The standard lifecycle is **Load → Manage → Save on Exit**. You acquire a session lock on join, mutate cached table data in `profile.Data`, and let ProfileStore2 manage auto-saving and clean shutdown.

**Example:**
```lua
--!strict
const Players = game:GetService("Players")
const ServerScriptService = game:GetService("ServerScriptService")

const ProfileStore = require(ServerScriptService.Source.Libs.ProfileStore2)
const Profile = require(ServerScriptService.Source.Libs.ProfileStore2.Profile)

-- The PROFILE_TEMPLATE table is what new profile "profile.Data" will default to:
const PROFILE_TEMPLATE = {
	Cash = 100,
	Items = {} :: { string },
	LoginCount = 0,
}
-- Create a type from our template table for strong type checking and autocompletion.
type PlayerProfile = typeof(PROFILE_TEMPLATE)

-- A cache for active, loaded profiles.
local profiles: { [Player]: Profile.Profile<PlayerProfile> } = {}
-- The single ProfileStore2 instance for all player data.
local playerStore: ProfileStore.ProfileStore<PlayerProfile>

--[[
    Handles loading and initializing a profile for a single player.
]]
local function onPlayerAdded(player: Player)
	playerStore:LoadProfileAsync(`Player_{player.UserId}`)
		:andThen(function(profile: Profile.Profile<PlayerProfile>)
			if player.Parent ~= Players then
				profile:EndSession() -- Player left while loading.
				return
			end

			profile:AddUserId(player.UserId) -- GDPR compliance
			profile:Reconcile() -- Populate missing template fields

			-- Increment a value for returning players.
			profile.Data.LoginCount += 1
			print(`Welcome back {player.Name}! Login #{profile.Data.LoginCount}`)

			profile.OnSessionEnd:Connect(function()
				profiles[player] = nil
				player:Kick("Your data session has ended. Please rejoin.")
			end)

			profiles[player] = profile
			print(`Profile loaded for {player.Name}.`)
		end)
		:catch(function(err)
			warn(`CRITICAL: Failed to load profile for {player.Name}: {err}`)
			-- Ideally, you should handle this more elegantly than kicking the player.
			player:Kick("Could not load data. Please rejoin later.")
		end)
end

--[[
    Handles saving a player's profile when they leave.
]]
local function onPlayerRemoving(player: Player)
	const profile = profiles[player]
	if profile then
		profile:EndSession()
	end
end

-- Initialize the entire profile management system.
ProfileStore.create("PlayerProfiles_V1", PROFILE_TEMPLATE)
	:andThen(function(store)
		playerStore = store
		print("[ProfileStore2]: Store ready.")

		Players.PlayerAdded:Connect(onPlayerAdded)
		Players.PlayerRemoving:Connect(onPlayerRemoving)

		for _, player in Players:GetPlayers() do
			task.spawn(onPlayerAdded, player)
		end
	end)
	:catch(function(err)
		warn("[ProfileStore2]: Critical initialization failure:", err)
	end)
```

## 🛠️ API Reference

### Store Factory
- `ProfileStore.create(name: string, template: T, options?: StoreOptions): Promise<ProfileStore<T>>`  
  Creates and initializes a store. Options include:
  - `UseLegacySchema?: boolean`: Persists data using the legacy MadStudio schema structure (`{ Data, MetaData, MetaTags, ... }`) for backward compatibility with pre-existing databases. Defaults to `false` (clean dictionary format).
  - `SchemaMigration?: (loadedData: ProfileData<T>) -> ()`: Optional callback to transform or migrate legacy schema fields before session acquisition.

### ProfileStore Methods
| Method | Returns | Description |
| :--- | :--- | :--- |
| `store:LoadProfileAsync(key, options?)` | `Promise<Profile<T>>` | Loads a profile with a session lock (`options.Steal`, `options.Cancel`). |
| `store:GetAsync(key, version?)` | `Promise<Profile<T>?>` | Loads a read-only "view mode" snapshot (or specific version) without locking. |
| `store:SetAsync(profile)` | `Promise<nil>` | Overwrites saved data with a view snapshot and clears active remote locks. |
| `store:RemoveAsync(key)` | `Promise<boolean>` | Permanently deletes a profile from the DataStore. |
| `store:MessageAsync(key, message)` | `Promise<boolean>` | Sends an offline or cross-server message to a profile's `GlobalUpdates` queue. |
| `store:VersionQuery(key, sortDir?, minDate?, maxDate?)` | `VersionQuery<T>` | Returns a cursor for iterating through historical version snapshots. |
| `store.Mock` | `MockStore<T>` | In-memory mock store for testing offline or in simulated test runners. |

### Profile Methods
| Method | Returns | Description |
| :--- | :--- | :--- |
| `profile:IsActive()` | `boolean` | Returns `true` if the session lock is currently held. |
| `profile:Reconcile()` | `()` | Recursively populates missing fields in `profile.Data` from the template. |
| `profile:Save()` | `Promise<nil>` | Manually flushes cached data without releasing the session lock. |
| `profile:EndSession()` | `Promise<nil>` | Releases the session lock and performs a final guaranteed save. |
| `profile:AddUserId(userId)` | `()` | Associates a Roblox `UserId` for GDPR compliance. |
| `profile:RemoveUserId(userId)` | `()` | Removes an associated `UserId`. |
| `profile:SetMetaTag(name, val)` | `()` | Sets an arbitrary metadata tag stored alongside the profile. |
| `profile:GetMetaTag(name)` | `any` | Retrieves a metadata tag value. |
| `profile.OnSessionEnd` | `Signal<()>` | Fires when the session lock is terminated or stolen. |
| `profile.OnAfterSave` | `Signal<(T)>` | Fires after a successful DataStore save with the saved payload. |
| `profile.OnGlobalUpdate` | `Signal<(number, any)>` | Fires when a new message from `MessageAsync` is received. |

### VersionQuery Methods
- `query:NextAsync(): Promise<Profile<T>?>`  
  Fetches the next historical version snapshot, or resolves to `nil` when iteration is complete.

## ✨ Key Features

- **Robust Session Locking:** Deadlock prevention, automatic heartbeat refreshes, and graceful session stealing.
- **Promise-Based Asynchronous Flow:** Bounded retries for transient DataStore errors, fast-fail on permanent serialization errors.
- **Offline Mock Fallback:** Automatically switches to an in-memory mock store in Studio when API services are disabled.
- **Graceful Server Shutdown:** Integrates with `game:BindToClose` to flush and release all active sessions before shutdown.
- **Strict Luau Typing:** Full `--!strict` typing throughout the library for strong autocomplete and static analysis.

## 📁 Package Structure

```
ServerScriptService/
└── Source/
    └── Libs/
        └── ProfileStore2/
            ├── init.luau
            ├── Constants.luau
            ├── Profile.luau
            ├── Signal.luau
            ├── Types.luau
            ├── Util.luau
            ├── Addons/
            │   ├── Messaging.luau
            │   └── Versioning.luau
            └── LeanPromise/
                ├── init.luau
                └── PromiseError.luau
```

---

`ProfileStore2` is licensed under the Apache 2.0 License. See [LICENSE](LICENSE) for details.
