local Settings = lib.load('shared.settings')

-- Garbage bin fill level. Stored in the property metadata (bin_fill, bin_emptied_at, bin_passive_at) and saved in
-- batches (MarkCleaningDirty). Owners and keyholders dump trash bags into the bin. What happens to a full bin is up to
-- the server: the exports at the bottom let another resource read the fill level and empty or change it.

local LastAction = {} -- [src] = GetGameTimer()

local function Cfg()
    return Settings.Cleaning and Settings.Cleaning.Bin or {}
end

local function Capacity()
    return math.max(1, math.floor(Cfg().Capacity or 12))
end

local function GetBinProperty(propertyId)
    if not IsCleaningEnabled() then return nil end

    local id = tonumber(propertyId)
    local p = id and Properties[id]
    if not p or p.isApartment or not p.owner or p.owner == '' then return nil end
    if not (p.metadata and p.metadata.bin_coords) then return nil end
    return id, p
end

local function GetFill(p)
    return math.min(Capacity(), math.max(0, math.floor(tonumber(p.metadata.bin_fill) or 0)))
end

local function SetFill(id, p, fill)
    fill = math.min(Capacity(), math.max(0, math.floor(fill)))
    if fill == GetFill(p) then return end

    p.metadata.bin_fill = fill
    MarkCleaningDirty(id)
    TriggerClientEvent('LNS_Housing:client:binFill', -1, id, fill)
    TriggerEvent('LNS_Housing:server:binFillChanged', id, fill, Capacity())
end

local function BinPosition(p)
    local c = p.metadata.bin_coords
    return vec3(c.x, c.y, c.z)
end

local function IsNear(src, position, distance)
    local ped = GetPlayerPed(src)
    return ped ~= 0 and #(GetEntityCoords(ped) - position) <= distance
end

local function CanUseBin(src, id, p)
    return p.owner == Bridge.Server.GetIdentifier(src) or IsKeyholder(src, id, false)
end

local function Throttled(src)
    local now = GetGameTimer()
    if LastAction[src] and now - LastAction[src] < (Cfg().Cooldown or 750) then return true end
    LastAction[src] = now
    return false
end

--------------------------------------------------------------------------------
-- Owner side: fill level and dumping
--------------------------------------------------------------------------------

---@return integer fill, integer capacity, integer emptiedAt (unix seconds, 0 = never)
lib.callback.register('LNS_Housing:server:bin:getFill', function(src, propertyId)
    local id, p = GetBinProperty(propertyId)
    if not id then return 0, Capacity(), 0 end
    return GetFill(p), Capacity(), tonumber(p.metadata.bin_emptied_at) or 0
end)

---Trash bags in the player's inventory that were swept up in this property.
---@return { slot: integer, count: integer }[] slots, integer matching, integer total
local function GetPropertyBags(src, propertyId)
    local item = Settings.Cleaning.Item or 'trash_bag'
    local slots, matching, total = {}, 0, 0

    for _, slot in pairs(exports.ox_inventory:Search(src, 'slots', item) or {}) do
        total = total + slot.count
        if slot.metadata and tonumber(slot.metadata.property) == propertyId then
            matching = matching + slot.count
            slots[#slots + 1] = { slot = slot.slot, count = slot.count }
        end
    end
    return slots, matching, total
end

---Moves the trash bags the player swept up in this property into the bin, as many as fit.
---Bags from another property, or bags that never came from sweeping, are ignored.
lib.callback.register('LNS_Housing:server:bin:dump', function(src, propertyId)
    if Throttled(src) then return { ok = false } end

    local id, p = GetBinProperty(propertyId)
    if not id then return { ok = false } end
    if not CanUseBin(src, id, p) then return { ok = false, reason = 'This is not your bin.' } end
    if not IsNear(src, BinPosition(p), (Cfg().InteractDistance or 3.0) + 1.5) then return { ok = false } end

    local item = Settings.Cleaning.Item or 'trash_bag'
    local slots, carried, total = GetPropertyBags(src, id)
    if carried < 1 then
        return { ok = false, reason = total > 0 and 'These trash bags are not from this property.' or 'You have no trash bags.' }
    end

    local fill = GetFill(p)
    local room = Capacity() - fill
    if room < 1 then
        return { ok = false, reason = 'The bin is full. Wait for the garbage crew to empty it.' }
    end

    local wanted = math.min(carried, room)
    local removed = 0
    for _, entry in ipairs(slots) do
        if removed >= wanted then break end
        local take = math.min(entry.count, wanted - removed)
        if exports.ox_inventory:RemoveItem(src, item, take, nil, entry.slot) then
            removed = removed + take
        end
    end
    if removed < 1 then return { ok = false } end

    SetFill(id, p, fill + removed)
    return { ok = true, added = removed, fill = fill + removed, capacity = Capacity() }
end)

--------------------------------------------------------------------------------
-- Household waste: owned bins slowly gain a few bags on their own
--------------------------------------------------------------------------------

CreateThread(function()
    while true do
        Wait(60000)

        local perHour, cap = Cfg().PassiveBagsPerHour or 0, math.min(Cfg().PassiveCap or 0, Capacity())
        if IsCleaningEnabled() and perHour > 0 and cap > 0 then
            local now = os.time()
            for id, p in pairs(Properties) do
                if GetBinProperty(id) then
                    local last = tonumber(p.metadata.bin_passive_at)
                    if not last then
                        p.metadata.bin_passive_at = now
                        MarkCleaningDirty(id)
                    elseif GetFill(p) >= cap then
                        -- Do not bank time while the bin is already as full as the trickle goes
                        p.metadata.bin_passive_at = now
                    else
                        local gain = math.floor((now - last) * perHour / 3600)
                        if gain >= 1 then
                            p.metadata.bin_passive_at = last + math.floor(gain * 3600 / perHour)
                            SetFill(id, p, math.min(cap, GetFill(p) + gain))
                        end
                    end
                end
            end
        end
    end
end)

-- Removing the bin takes its contents and last-emptied time with it, so a moved bin starts fresh
AddEventHandler('LNS_Housing:server:binChanged', function(id, bin)
    local p = Properties[id]
    if not p or bin then return end

    if p.metadata then
        p.metadata.bin_fill = nil
        p.metadata.bin_passive_at = nil
        p.metadata.bin_emptied_at = nil
        MarkCleaningDirty(id)
    end
    TriggerClientEvent('LNS_Housing:client:binFill', -1, id, 0)
end)

AddEventHandler('playerDropped', function()
    LastAction[source] = nil
end)

--------------------------------------------------------------------------------
-- Exports for other resources
-- These trust the calling resource: it has to do its own checks (job, distance, cooldowns) before calling them.
--------------------------------------------------------------------------------

local function BinInfo(id, p)
    return {
        propertyId = id,
        label = p.label,
        coords = p.metadata.bin_coords,
        fill = GetFill(p),
        capacity = Capacity(),
        emptiedAt = tonumber(p.metadata.bin_emptied_at) or 0,
    }
end

---Every bin in service, optionally only those holding at least `minFill` bags.
---@param minFill integer?
---@return { propertyId: number, label: string, coords: table, fill: integer, capacity: integer, emptiedAt: integer }[]
exports('GetPropertyBins', function(minFill)
    local bins = {}
    minFill = tonumber(minFill) or 0

    for id, p in pairs(Properties) do
        if GetBinProperty(id) and GetFill(p) >= minFill then
            bins[#bins + 1] = BinInfo(id, p)
        end
    end
    return bins
end)

---@return { propertyId: number, label: string, coords: table, fill: integer, capacity: integer, emptiedAt: integer }? nil when the property has no bin in service
exports('GetPropertyBin', function(propertyId)
    local id, p = GetBinProperty(propertyId)
    return id and BinInfo(id, p) or nil
end)

---Sets how many bags are in a bin (clamped to the capacity). Players and the bin prop update straight away.
---@return boolean ok
exports('SetBinFill', function(propertyId, fill)
    local id, p = GetBinProperty(propertyId)
    fill = tonumber(fill)
    if not id or not fill then return false end

    SetFill(id, p, fill)
    return true
end)

---Empties a bin and records when. The owner is told.
---@param propertyId number
---@param src number? the player who emptied it, passed on in the binEmptied event
---@return { ok: boolean, bags: integer? }
exports('EmptyBin', function(propertyId, src)
    local id, p = GetBinProperty(propertyId)
    if not id then return { ok = false } end

    local bags = GetFill(p)
    p.metadata.bin_emptied_at = os.time()
    SetFill(id, p, 0)
    MarkCleaningDirty(id)

    TriggerEvent('LNS_Housing:server:binEmptied', id, src, bags)

    local ownerPlayer = Bridge.Server.IsPlayerOnline(p.owner)
    local ownerSrc = ownerPlayer and ownerPlayer.PlayerData and ownerPlayer.PlayerData.source
    if ownerSrc then
        Bridge.Server.Notify(ownerSrc, ('Your bin at %s was emptied.'):format(p.label or 'your property'), 'inform')
    end

    return { ok = true, bags = bags }
end)
