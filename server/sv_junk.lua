local Settings = lib.load('shared.settings')

-- Junk pieces inside owned houses. The server only stores which piece ids exist (metadata.junk_ids) and a seed;
-- clients work out where each piece sits from the seed and the id, so nothing positional is saved.

local TICK_SECONDS = 10
local CLAIM_GRACE_MS = 8000

local Progress = {}   -- [propertyId] = seconds of occupied time since the last piece appeared
local Claims = {}     -- [propertyId] = { [junkId] = { src, startedAt } }
local LastAction = {} -- [src] = GetGameTimer()

local function Cfg()
    return Settings.Cleaning and Settings.Cleaning.Junk or {}
end

local function JunkEnabled()
    return IsCleaningEnabled() and Cfg().Enabled ~= false
end

local function IsOwnedHouse(p)
    return p ~= nil and not p.isApartment and p.owner ~= nil and p.owner ~= ''
end

local function GetJunkIds(p)
    p.metadata = p.metadata or {}
    if type(p.metadata.junk_ids) ~= 'table' then p.metadata.junk_ids = {} end
    return p.metadata.junk_ids
end

local function GetJunkSeed(propertyId, p)
    p.metadata = p.metadata or {}
    if not p.metadata.junk_seed then
        p.metadata.junk_seed = math.random(1, 2147483646)
        MarkCleaningDirty(propertyId)
    end
    return p.metadata.junk_seed
end

local function PushJunk(propertyId, p, target)
    local ids, seed = GetJunkIds(p), GetJunkSeed(propertyId, p)
    if target then
        TriggerClientEvent('LNS_Housing:client:junkChanged', target, propertyId, ids, seed)
        return
    end
    for src in pairs(GetPropertyOccupants(propertyId)) do
        TriggerClientEvent('LNS_Housing:client:junkChanged', src, propertyId, ids, seed)
    end
end

local function AddJunk(propertyId, p)
    local ids = GetJunkIds(p)
    if #ids >= (Cfg().Max or 10) then return false end

    local nextId = tonumber(p.metadata.junk_next) or 1
    p.metadata.junk_next = nextId + 1
    ids[#ids + 1] = nextId

    MarkCleaningDirty(propertyId)
    PushJunk(propertyId, p)
    return true
end

--------------------------------------------------------------------------------
-- Pieces appear while someone is inside an owned house
--------------------------------------------------------------------------------

CreateThread(function()
    while true do
        Wait(TICK_SECONDS * 1000)

        if JunkEnabled() then
            local interval = math.max(1, (Cfg().IntervalMinutes or 10)) * 60
            local max = Cfg().Max or 10

            for _, propertyId in ipairs(GetOccupiedPropertyIds()) do
                local p = Properties[propertyId]
                if IsOwnedHouse(p) then
                    if #GetJunkIds(p) < max then
                        Progress[propertyId] = (Progress[propertyId] or 0) + TICK_SECONDS
                        if Progress[propertyId] >= interval then
                            Progress[propertyId] = 0
                            AddJunk(propertyId, p)
                        end
                    else
                        Progress[propertyId] = 0
                    end
                end
            end
        end
    end
end)

AddEventHandler('LNS_Housing:server:propertyEntered', function(src, propertyId)
    local p = Properties[propertyId]
    if JunkEnabled() and IsOwnedHouse(p) then
        PushJunk(propertyId, p, src)
    end
end)

--------------------------------------------------------------------------------
-- Sweeping a piece: begin (claims it and starts the clock), finish (checks the clock, pays the bag)
--------------------------------------------------------------------------------

local function Validate(src, propertyId, junkId)
    if not JunkEnabled() then return nil end

    local id = tonumber(propertyId)
    junkId = tonumber(junkId)
    local p = id and Properties[id]
    if not junkId or not IsOwnedHouse(p) or not IsInProperty(src, id) then return nil end

    local now = GetGameTimer()
    if LastAction[src] and now - LastAction[src] < (Cfg().Cooldown or 750) then return nil end
    LastAction[src] = now

    if not IsKeyholder(src, id, false) then return nil end

    local ids = GetJunkIds(p)
    for index = 1, #ids do
        if ids[index] == junkId then return id, p, junkId, index end
    end
    return nil
end

lib.callback.register('LNS_Housing:server:junk:begin', function(src, propertyId, junkId)
    local id, _, piece = Validate(src, propertyId, junkId)
    if not id then return false end

    local now = GetGameTimer()
    local claims = Claims[id] or {}
    local existing = claims[piece]
    local window = (Cfg().CleanMs or 3000) + CLAIM_GRACE_MS * 2
    if existing and existing.src ~= src and now - existing.startedAt < window then return false end

    claims[piece] = { src = src, startedAt = now }
    Claims[id] = claims
    return true
end)

lib.callback.register('LNS_Housing:server:junk:finish', function(src, propertyId, junkId)
    local id, p, piece = Validate(src, propertyId, junkId)
    if not id then return false end

    local claim = Claims[id] and Claims[id][piece]
    if not claim or claim.src ~= src then return false end

    local cleanMs = Cfg().CleanMs or 3000
    local elapsed = GetGameTimer() - claim.startedAt
    if elapsed < cleanMs - 500 or elapsed > cleanMs + CLAIM_GRACE_MS * 3 then
        Claims[id][piece] = nil
        return false
    end

    -- The bag remembers which property it came from, so only junk that was really swept here can fill this bin
    local item = Settings.Cleaning.Item or 'trash_bag'
    local metadata = { property = id, description = ('Junk from %s'):format(p.label or ('property ' .. id)) }
    if not exports.ox_inventory:CanCarryItem(src, item, 1, metadata) then
        Claims[id][piece] = nil
        Bridge.Server.Notify(src, 'You cannot carry another trash bag.', 'error')
        return false
    end

    Claims[id][piece] = nil
    if not exports.ox_inventory:AddItem(src, item, 1, metadata) then return false end

    -- Look the piece up again: the list may have changed while the inventory call ran
    local ids = GetJunkIds(p)
    for i = 1, #ids do
        if ids[i] == piece then
            table.remove(ids, i)
            break
        end
    end

    MarkCleaningDirty(id)
    PushJunk(id, p)
    return true
end)

-- A player who walks off mid-sweep releases the piece again
AddEventHandler('playerDropped', function()
    local src = source
    LastAction[src] = nil
    for _, claims in pairs(Claims) do
        for piece, claim in pairs(claims) do
            if claim.src == src then claims[piece] = nil end
        end
    end
end)

AddEventHandler('LNS_Housing:server:propertyLeft', function(src, propertyId)
    local claims = Claims[propertyId]
    if not claims then return end
    for piece, claim in pairs(claims) do
        if claim.src == src then claims[piece] = nil end
    end
end)

---@return integer? count of junk pieces currently inside the property
exports('GetPropertyJunk', function(propertyId)
    local p = Properties[tonumber(propertyId)]
    if not p or p.isApartment then return nil end
    return #GetJunkIds(p)
end)
