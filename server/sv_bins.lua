local Settings = lib.load('shared.settings')

-- Garbage bin fill level. Stored in the property metadata (bin_fill, bin_emptied_at, bin_passive_at) and saved in
-- batches (MarkCleaningDirty). Owners and keyholders dump trash bags into the bin; ghm-garbagejob workers empty it
-- through the exports at the bottom. The job never changes the fill itself.

local LastAction = {} -- [src] = GetGameTimer()
local Claims = {}     -- [propertyId] = { owner = string, expires = os.time() }

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

-- Removing the bin takes its contents with it, so moving it cannot be used to dodge the collection cooldown
AddEventHandler('LNS_Housing:server:binChanged', function(id, bin)
    local p = Properties[id]
    if not p or bin then return end

    Claims[id] = nil
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
-- Garbage job exports (ghm-garbagejob)
--------------------------------------------------------------------------------

local function WorkerCanCollect(src)
    if GetResourceState('ghm-garbagejob') ~= 'started' then return false end
    local ok, result = pcall(function() return exports['ghm-garbagejob']:CanCollectBin(src) end)
    return ok and result == true
end

local function IsCollectable(id, p, minFill, now)
    if GetFill(p) < minFill then return false end

    local cooldown = (Cfg().CollectCooldownMinutes or 60) * 60
    return now - (tonumber(p.metadata.bin_emptied_at) or 0) >= cooldown
end

local function ClaimFor(id, now)
    local claim = Claims[id]
    if claim and claim.expires <= now then
        Claims[id] = nil
        return nil
    end
    return claim
end

---Bins that are full enough to empty and not reserved by another crew.
---@param minFill integer? defaults to Bin.MinFillToCollect
---@return { propertyId: number, label: string, coords: table, fill: integer }[]
exports('GetCollectableBins', function(minFill)
    local list = {}
    minFill = tonumber(minFill) or Cfg().MinFillToCollect or 7

    local now = os.time()
    for id, p in pairs(Properties) do
        if GetBinProperty(id) and IsCollectable(id, p, minFill, now) and not ClaimFor(id, now) then
            list[#list + 1] = { propertyId = id, label = p.label, coords = p.metadata.bin_coords, fill = GetFill(p) }
        end
    end
    return list
end)

---Reserves a bin for a crew for Bin.ClaimSeconds so two crews do not chase the same one.
---@param owner string any id that names the crew; the same value is passed to CollectBin and ReleaseBin
---@return boolean
exports('ClaimBin', function(src, propertyId, owner)
    local id, p = GetBinProperty(propertyId)
    if not id or not owner then return false end

    local now = os.time()
    local claim = ClaimFor(id, now)
    if claim and claim.owner ~= tostring(owner) then return false end
    if not IsCollectable(id, p, Cfg().MinFillToCollect or 7, now) then return false end
    if CanUseBin(src, id, p) then return false end

    Claims[id] = { owner = tostring(owner), expires = now + (Cfg().ClaimSeconds or 600) }
    return true
end)

exports('ReleaseBin', function(propertyId, owner)
    local id = tonumber(propertyId)
    local claim = id and Claims[id]
    if claim and claim.owner == tostring(owner) then Claims[id] = nil end
end)

local function RollLoot(p, bags)
    local cfg = Cfg()
    local rolls = 1 + math.floor(bags / math.max(1, cfg.RollsPerBags or 4))
    local price = tonumber(p.price) or 0
    local boost = 1.0 + (cfg.ValueBonus or 0) * math.min(1.0, price / math.max(1, cfg.ValueBonusPrice or 1))

    local totals, order = {}, {}
    for _ = 1, rolls do
        for _, entry in ipairs(cfg.Loot or {}) do
            if math.random() * 100.0 < (entry.chance or 0) * boost and exports.ox_inventory:Items(entry.item) then
                local count = math.random(entry.min or 1, entry.max or entry.min or 1)
                if not totals[entry.item] then
                    totals[entry.item] = 0
                    order[#order + 1] = entry.item
                end
                totals[entry.item] = totals[entry.item] + count
            end
        end
    end

    local loot = {}
    for _, name in ipairs(order) do loot[#loot + 1] = { item = name, count = totals[name] } end
    return loot
end

---Empties a bin for a garbage worker. All checks happen here; the job only passes who is asking.
---@param src number the worker
---@param propertyId number
---@param owner string the crew id used with ClaimBin
---@return { ok: boolean, reason: string?, bags: integer?, credit: integer?, loot: { item: string, count: integer }[]?, label: string? }
exports('CollectBin', function(src, propertyId, owner)
    local id, p = GetBinProperty(propertyId)
    if not id then return { ok = false, reason = 'This bin is not in service.' } end

    if not WorkerCanCollect(src) then return { ok = false, reason = 'You are not on a garbage run.' } end
    if not IsNear(src, BinPosition(p), Cfg().CollectDistance or 4.0) then return { ok = false, reason = 'Too far from the bin.' } end
    if CanUseBin(src, id, p) then return { ok = false, reason = 'You cannot empty your own bin.' } end

    local now = os.time()
    local claim = ClaimFor(id, now)
    if claim and claim.owner ~= tostring(owner) then return { ok = false, reason = 'Another crew is on this bin.' } end

    if not IsCollectable(id, p, Cfg().MinFillToCollect or 7, now) then
        return { ok = false, reason = 'This bin is not full enough to empty yet.' }
    end

    local bags = GetFill(p)
    local credit = math.min(Cfg().MaxCredit or 3, math.max(1, math.ceil(bags / math.max(1, Cfg().BagsPerCredit or 4))))
    local loot = RollLoot(p, bags)

    Claims[id] = nil
    p.metadata.bin_emptied_at = now
    SetFill(id, p, 0)
    MarkCleaningDirty(id)

    TriggerEvent('LNS_Housing:server:binEmptied', id, src, bags)

    local ownerPlayer = Bridge.Server.IsPlayerOnline(p.owner)
    local ownerSrc = ownerPlayer and ownerPlayer.PlayerData and ownerPlayer.PlayerData.source
    if ownerSrc then
        Bridge.Server.Notify(ownerSrc, ('The garbage crew emptied the bin at %s.'):format(p.label or 'your property'), 'inform')
    end

    return { ok = true, bags = bags, credit = credit, loot = loot, label = p.label }
end)
