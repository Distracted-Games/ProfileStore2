# ProfileStore2

A robust, modular, and fully asynchronous DataStore library featuring session locking, designed for modern, professional Roblox development. This is a complete, type-safe refactor of the original [ProfileStore](https://github.com/MadStudioRoblox/ProfileStore) library by Mad Studio.

## 🚀 Overview

`ProfileStore2` is architected as a self-contained package. The core logic is broken into several single-responsibility modules, making the system clean, maintainable, and easy to understand.

| Module | Location | Purpose |
| :--- | :--- | :--- |
| `init.luau` | `.../ProfileStore2/` | The main entry point and "Store" manager class. This is what you `require`. |
| `Profile.luau` | `.../ProfileStore2/` | The OOP class for a single "Profile" object, which holds player data. |
| `Promise/init.luau` | `.../ProfileStore2/Promise/` | **Core Dependency**: A refactored Promise library for asynchronous control flow. |
| `Promise/PromiseError.luau` | `.../ProfileStore2/Promise/` | **Core Dependency**: The rich error object used by the Promise library. |
| `Signal.luau` | `.../ProfileStore2/` | A robust, yield-safe Signal implementation used for event handling. |
| `Constants.luau` | `.../ProfileStore2/` | A centralized, read-only table of all configuration values. |
| `Util.luau` | `.../ProfileStore2/` | Shared helper functions like `DeepCopyTable` and `ReconcileTable`. |

## 🧠 Design Philosophy

This refactor was built on three core professional principles:

1.  **Session Locking First**  
    The primary goal is to guarantee data integrity. The library ensures that only **one server can have an active session** for a single player profile at any time. This prevents data loss and corruption caused by race conditions, such as a player rejoining too quickly or being present in two servers at once.

2.  **Asynchronous by Design**  
    All DataStore operations are network calls that can yield. This library embraces that reality by returning a **Promise** for every asynchronous method. This allows you to write clean, non-blocking code that will never lag your game, with clear success (`:andThen`) and failure (`:catch`) paths.

3.  **Lean and Modular Core**  
    The main API is intentionally kept small and focused on the essential 95% use case: loading, managing, and saving profiles. More advanced, power-user features like `MessageAsync` and `VersionQuery` are designed as optional "Addon" modules to keep the core library simple and easy to maintain.

## 📦 How to Use

The intended workflow is **Load → Manage → Save on Exit**. You load a player's profile when they join, manage their data in a cached table during their session, and the library automatically handles saving when they leave or the server shuts down.

Here is a standard implementation in a server-side manager module:

```lua
-- ServerScriptService/Source/PlayerData/PlayerProfileManager.luau
--!strict
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileStore = require(ServerScriptService.Source.Libs.ProfileStore2)
local Profile = require(ServerScriptService.Source.Libs.ProfileStore2.Profile)

-- The PROFILE_TEMPLATE table is what new profile "profile.Data" will default to:
local PROFILE_TEMPLATE = {
	Cash = 100,
	Items = {},
	LoginCount = 0,
}
-- Create a type from our template table for strong type checking and autocompletion.
type PlayerProfile = typeof(PROFILE_TEMPLATE)

-- A cache for active, loaded profiles.
local Profiles: { [Player]: Profile.Profile<PlayerProfile> } = {}
-- The single ProfileStore instance for all player data.
local PlayerStore: ProfileStore.ProfileStore<PlayerProfile> = nil

--[[
    Handles loading and initializing a profile for a single player.
]]
local function onPlayerAdded(player: Player)
	PlayerStore:LoadProfileAsync(`Player_{player.UserId}`)
		:andThen(function(profile: Profile.Profile<PlayerProfile>)
			if player.Parent ~= Players then
				profile:EndSession() -- Player left while loading.
				return
			end
			
            profile:AddUserId(player.UserId) -- GDPR compliance
			profile:Reconcile() -- Fill in new fields from the template.
			
            -- Increment a value for returning players.
            profile.Data.LoginCount += 1
            print(`Welcome back! This is login #{profile.Data.LoginCount}`)
			
			profile.OnSessionEnd:Connect(function()
				Profiles[player] = nil
				player:Kick("Your data session has ended. Please rejoin.")
			end)

			Profiles[player] = profile
			print(`Profile loaded for {player.Name}.`)
		end)
		:catch(function(err)
			warn(`CRITICAL: Failed to load profile for {player.Name}: {tostring(err)}`)
            -- Ideally handle more elegantly than kicking the player.
			player:Kick("A critical error occurred while loading your data. Please try again later.")
		end)
end

--[[
    Handles saving a player's profile when they leave.
]]
local function onPlayerRemoving(player: Player)
	local profile = Profiles[player]
	if profile then
		profile:EndSession()
	end
end

-- Initialize the entire profile management system.
ProfileStore.create("PlayerProfiles_V1", PROFILE_TEMPLATE)
	:andThen(function(store)
		PlayerStore = store
		print("[PlayerProfileManager]: ProfileStore is ready.")

		Players.PlayerAdded:Connect(onPlayerAdded)
		Players.PlayerRemoving:Connect(onPlayerRemoving)

		for _, player in ipairs(Players:GetPlayers()) do
			task.spawn(onPlayerAdded, player)
		end
	end)
	:catch(function(err)
		warn("[PlayerProfileManager] CRITICAL: ProfileStore could not be created. Data will not save.", err)
	end)
```

## 🛠️ API Reference

### Core `ProfileStore` Functions
| Function | Description |
| :--- | :--- |
| `ProfileStore.create(name, template)` | Asynchronously creates and initializes a store. Returns a `Promise`. |
| `store:LoadProfileAsync(key, params)` | Loads a profile with a session lock. Returns a `Promise`. |
| `store:GetAsync(key, version)` | Loads a read-only "view mode" profile. Returns a `Promise`. |
| `store:RemoveAsync(key)` | Permanently deletes a profile. Returns a `Promise`. |

### Key `Profile` Methods
| Method | Description |
| :--- | :--- |
| `profile:IsActive()` | Returns `true` if the session is currently active. |
| `profile:Reconcile()` | Fills `profile.Data` with any new fields from the template. |
| `profile:Save()` | Manually triggers a save of the profile's data without ending the session. |
| `profile:EndSession()` | Ends the session and triggers a final, guaranteed save. |

> 💡 For a more in-depth API reference, please see the upcoming Wiki.

## ✨ Features
- **Guaranteed Session Locking:** Prevents data corruption from simultaneous server access.
- **Promise-Based Asynchronous API:** Keeps your game fast and responsive with non-blocking code.
- **Modular & Clean Architecture:** Easy to read, maintain, and understand.
- **Strictly Type-Safe:** Provides unparalleled developer experience with full autocomplete and error checking.
- **Integrated Mocking:** Test your data logic offline with `store.Mock:LoadProfileAsync()`.
- **Automatic Saving:** Periodically auto-saves profiles and guarantees a final save on server shutdown via `BindToClose`.

## ⚠️ Important Notes
- **The Golden Rule:** Follow the **Load → Manage → Save on Exit** pattern. The library is a persistence tool, not a real-time database. Manage your gameplay data in the session cache (`profile.Data`) and avoid calling save methods frequently.
- **Enable API Services:** For `ProfileStore2` to work in a live game or Studio test, you must enable **"Enable Studio Access to API Services"** in Game Settings > Security.

## 📁 Folder Placement
To keep your project organized, we recommend placing the `ProfileStore2` package in:

```
ServerScriptService/
└── Source/
    └── Libs/
        └── ProfileStore2/
            ├── init.luau
            ├── Profile.luau
            ├── Signal.luau
            ├── Constants.luau
            └── Util.luau
            └── Promise/
                ├── init.luau
                └── PromiseError.luau
```

---

`ProfileStore2` is designed to provide a rock-solid foundation for your game's data persistence, allowing you to focus on building great gameplay with confidence. Feel free to adapt it to your needs or contribute improvements.
