--!strict
--[[
    Contains generic table utility function used by the ProfileStore system.
]]

local Util = {}

--[[
        Recursively creates a deep copy of a table, ensuring that nested tables
        are also copied instead of referenced.
]]
function Util.DeepCopyTable<T>(original: T): T
    local copy = {} :: any
    for key, value in pairs(original :: any) do
        if typeof(value) == "table" then
            copy[key] = Util.DeepCopyTable(value :: any)
        else
            copy[key] = value
        end
    end
    return copy
end

--[[
    Recursively fills in missing string-keyed fields in a `target` table from a `template table.
    This is used to safely update saved data with new default values.
]]
function Util.ReconcileTable(target: { [string]: any }, template: { [string]: any })
    for key, templateValue in pairs(template) do
        if typeof(key) ~= "string" then
            continue
        end

        local targetValue = target[key]
        if targetValue == nil then
            if typeof(templateValue) == "table" then
                target[key] = Util.DeepCopyTable(templateValue)
            else
                target[key] = templateValue
            end
        elseif typeof(targetValue) == "table" and typeof(templateValue) == "table" then
            -- If the key exists in both and both are tables, recurse.
            Util.ReconcileTable(targetValue, templateValue)
        end
    end
end

return table.freeze(Util)
