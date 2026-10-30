--!strict
--[[
	Copyright 2025 Distracted Games

	Licensed under the Apache License, Version 2.0 (the "License");
	you may not use this file except in compliance with the License.
	You may obtain a copy of the License at

		http://www.apache.org/licenses/LICENSE-2.0

	Unless required by applicable law or agreed to in writing, software
	distributed under the License is distributed on an "AS IS" BASIS,
	WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
	See the License for the specific language governing permissions and
	limitations under the License.
]]

--[[
	Shared type definitions across ProfileStore2 modules.
]]

export type JSONAcceptable = { JSONAcceptable } | { [string]: JSONAcceptable } | number | string | boolean | buffer

export type LastSaveReason = "Manual" | "External" | "Shutdown"

export type DataStoreState = "NotReady" | "NoInternet" | "NoAccess" | "Access"

export type DictionarySessionLock = {
	PlaceId: number,
	JobId: string,
	UniqueId: string?,
}

export type LegacySessionLock = { any }

export type SessionLock = DictionarySessionLock | LegacySessionLock

export type DictionaryForceLoadLock = {
	PlaceId: number,
	JobId: string,
}

export type ForceLoadLock = DictionaryForceLoadLock | LegacySessionLock

export type SessionInfo = {
	PlaceId: number,
	JobId: string,
}

export type ProfileMetaData = {
	ProfileCreateTime: number,
	SessionLoadCount: number,
	ActiveSession: SessionLock?,
	ForceLoadSession: ForceLoadLock?,
	LastUpdate: number?,
	MetaTags: { [string]: any }?,
}

export type GlobalUpdateEntry = { any }

export type GlobalUpdatesPayload = { any }

export type ProfileData<T> = {
	Data: T,
	MetaData: ProfileMetaData,
	GlobalUpdates: GlobalUpdatesPayload?,
	UserIds: { number },
	RobloxMetaData: { [string]: any },
	WasOverwritten: boolean?,
}

export type LoadProfileParams = {
	Steal: boolean?,
	Cancel: (() -> boolean)?,
}

export type CreateStoreOptions = {
	UseLegacySchema: boolean?,
	Scope: string?,
}

return nil
