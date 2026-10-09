local Settings = lib.load('shared.settings')

local LastAction = {} -- [src] = GetGameTimer()

function IsCleaningEnabled()
    return Settings.Cleaning ~= nil and Settings.Cleaning.Enabled == true
end

local function IsFiniteNumber(n)
    return type(n) == 'number' and n == n and n > -math.huge and n < math.huge
end

---Validates bin coordinates sent from the UI. Returns nil when cleaning is disabled or the data is invalid.
---@return table? { x, y, z, h }
function SanitizeBinCoords(coords)
    if not IsCleaningEnabled() or type(coords) ~= 'table' then return nil end

    local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not (IsFiniteNumber(x) and IsFiniteNumber(y) and IsFiniteNumber(z)) then return nil end
    if math.abs(x) > 10000.0 or math.abs(y) > 10000.0 or z < -500.0 or z > 2500.0 then return nil end

    local h = tonumber(coords.h)
    if not IsFiniteNumber(h) then h = 0.0 end

    return { x = x, y = y, z = z, h = h % 360.0 }
end

local function IsInsidePolygon2D(x, y, points)
    local inside = false
    local j = #points
    for i = 1, #points do
        local xi, yi, xj, yj = points[i].x, points[i].y, points[j].x, points[j].y
        if ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

---A bin has to stand outside: not in shell space, not in an IPL interior and not inside an MLO's interior zone.
---@param zoneData table? property zone_data ({ points, thickness })
---@param shellName string? property shell name ('mlo' for MLO properties)
---@param coords table sanitized bin coords
function IsBinOutside(zoneData, shellName, coords)
    if coords.z < (Settings.ShellSpawningZ or -100.0) + 50.0 then return false end

    local ipl = shellName and Settings.IPLs and Settings.IPLs[shellName]
    if ipl and ipl.coords and #(vec3(coords.x, coords.y, coords.z) - vec3(ipl.coords.x, ipl.coords.y, ipl.coords.z)) < 85.0 then
        return false
    end

    local points = zoneData and zoneData.points
    if type(points) ~= 'table' or #points < 3 then return true end

    local sumZ = 0.0
    for _, point in ipairs(points) do sumZ = sumZ + (tonumber(point.z) or 0.0) end
    local thickness = tonumber(zoneData.thickness) or 10.0
    if math.abs(coords.z - sumZ / #points) > thickness then return true end

    return not IsInsidePolygon2D(coords.x, coords.y, points)
end

---Sanitizes the coords and confirms they are outside the property. Returns nil when either check fails.
function ValidateBin(coords, zoneData, shellName)
    local bin = SanitizeBinCoords(coords)
    if bin and IsBinOutside(zoneData, shellName, bin) then return bin end
    return nil
end

---Checks that a bin is not placed unreasonably far from its property.
---@param property table
---@param coords table sanitized bin coords
function IsBinNearProperty(property, coords)
    local entrance = GetEntranceCoordsServer and GetEntranceCoordsServer(property)
    if not entrance then return true end

    local maxDistance = (Settings.Cleaning.Bin and Settings.Cleaning.Bin.MaxDistanceFromProperty) or 75.0
    return #(vec3(coords.x, coords.y, coords.z) - entrance) <= maxDistance
end

--------------------------------------------------------------------------------
-- Owner placement (property tablet)
--------------------------------------------------------------------------------

local function GetOwnedProperty(src, propertyId)
    local bin = IsCleaningEnabled() and Settings.Cleaning.Bin
    if not bin or bin.OwnerCanPlace ~= true then return nil end

    local id = tonumber(propertyId)
    local property = id and Properties[id]
    if not property or property.isApartment then return nil end
    if not property.owner or property.owner ~= Bridge.Server.GetIdentifier(src) then return nil end

    local now = GetGameTimer()
    if LastAction[src] and now - LastAction[src] < 1500 then return nil end
    LastAction[src] = now

    return id, property
end

local function SaveBin(id, property, bin)
    property.metadata = property.metadata or {}
    property.metadata.bin_coords = bin
    SaveProperty(id)
    TriggerClientEvent('LNS_Housing:client:updateProperties', -1, Properties)
    TriggerEvent('LNS_Housing:server:binChanged', id, bin)
end

RegisterNetEvent('LNS_Housing:server:bin:place', function(propertyId, coords)
    local src = source
    local id, property = GetOwnedProperty(src, propertyId)
    if not id then return end

    if IsInProperty(src, id) then
        Bridge.Server.Notify(src, 'Step outside your property to place the bin.', 'error')
        return
    end

    local bin = ValidateBin(coords, property.zone_data, property.metadata and property.metadata.shell)
    if not bin then
        Bridge.Server.Notify(src, 'The bin has to be placed outside your property.', 'error')
        return
    end

    if not IsBinNearProperty(property, bin) then
        Bridge.Server.Notify(src, 'The bin is too far from your property.', 'error')
        return
    end

    local ped = GetPlayerPed(src)
    if ped == 0 or #(GetEntityCoords(ped) - vec3(bin.x, bin.y, bin.z)) > 40.0 then return end

    SaveBin(id, property, bin)
    Bridge.Server.Notify(src, 'Garbage bin location saved.', 'success')
end)

RegisterNetEvent('LNS_Housing:server:bin:remove', function(propertyId)
    local src = source
    local id, property = GetOwnedProperty(src, propertyId)
    if not id or not (property.metadata and property.metadata.bin_coords) then return end

    SaveBin(id, property, nil)
    Bridge.Server.Notify(src, 'Garbage bin removed.', 'success')
end)

AddEventHandler('playerDropped', function()
    LastAction[source] = nil
end)

--------------------------------------------------------------------------------
-- Junk and bin fill change often, so they are saved in batches instead of on every change
--------------------------------------------------------------------------------

local DirtyProperties = {}

function MarkCleaningDirty(id)
    DirtyProperties[id] = true
end

local function FlushDirtyProperties()
    for id in pairs(DirtyProperties) do
        DirtyProperties[id] = nil
        if Properties[id] then SaveProperty(id) end
    end
end

CreateThread(function()
    while true do
        Wait(30000)
        FlushDirtyProperties()
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then FlushDirtyProperties() end
end)

--------------------------------------------------------------------------------
-- Exports for other resources (for example a garbage collection job)
--------------------------------------------------------------------------------

---@return table? { x, y, z, h }
exports('GetPropertyBin', function(propertyId)
    local property = Properties[tonumber(propertyId)]
    return property and property.metadata and property.metadata.bin_coords or nil
end)

---@return { propertyId: number, label: string, coords: table }[]
exports('GetPropertyBins', function()
    local bins = {}
    if not IsCleaningEnabled() then return bins end

    for id, property in pairs(Properties) do
        local coords = property.metadata and property.metadata.bin_coords
        if coords and not property.isApartment then
            bins[#bins + 1] = { propertyId = id, label = property.label, coords = coords }
        end
    end
    return bins
end)
