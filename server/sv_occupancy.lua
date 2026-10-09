local Occupants = {} -- [propertyId] = { [src] = true }
local Where = {}     -- [src] = propertyId

function GetPropertyOccupants(propertyId)
    return Occupants[propertyId] or {}
end

function GetOccupiedPropertyIds()
    local ids = {}
    for propertyId in pairs(Occupants) do ids[#ids + 1] = propertyId end
    return ids
end

function IsInProperty(src, propertyId)
    return propertyId ~= nil and Where[src] == propertyId
end

local function RemovePlayer(src)
    local propertyId = Where[src]
    if not propertyId then return end

    Where[src] = nil
    local set = Occupants[propertyId]
    if set then
        set[src] = nil
        if not next(set) then Occupants[propertyId] = nil end
    end
    TriggerEvent('LNS_Housing:server:propertyLeft', src, propertyId)
end

RegisterNetEvent('LNS_Housing:server:occupancy:enter', function(propertyId)
    local src = source
    propertyId = tonumber(propertyId)
    if not propertyId or not Properties[propertyId] then return end
    if Where[src] == propertyId then return end

    RemovePlayer(src)
    Where[src] = propertyId
    Occupants[propertyId] = Occupants[propertyId] or {}
    Occupants[propertyId][src] = true
    TriggerEvent('LNS_Housing:server:propertyEntered', src, propertyId)
end)

RegisterNetEvent('LNS_Housing:server:occupancy:leave', function()
    RemovePlayer(source)
end)

AddEventHandler('playerDropped', function()
    RemovePlayer(source)
end)

exports('GetPropertyOccupants', function(propertyId)
    local list = {}
    for src in pairs(GetPropertyOccupants(tonumber(propertyId))) do list[#list + 1] = src end
    return list
end)
