local Settings = lib.load('shared.settings')

-- Junk pieces inside the property the player is in. The server sends the piece ids and a seed; each piece's spot is
-- worked out here from the seed and its id on a ring around the interior entry point, so every visit looks the same.

local current = nil     -- { propertyId, ids, seed }
local anchor = nil      -- vec3 on the floor where the player entered
local pieces = {}       -- [junkId] = { entity, zone }
local busy = false
local building = false
local rebuildAgain = false

local function Cfg()
    return Settings.Cleaning and Settings.Cleaning.Junk or {}
end

local function IsEnabled()
    return Settings.Cleaning ~= nil and Settings.Cleaning.Enabled == true and Cfg().Enabled ~= false
end

---Small seeded generator (Park-Miller) so a piece lands in the same spot on every client and every visit.
local function Seeded(seed, junkId)
    local state = (seed * 7919 + junkId * 104729) % 2147483647
    if state <= 0 then state = state + 2147483646 end
    return function()
        state = (state * 48271) % 2147483647
        return state / 2147483647
    end
end

local function Probe(from, to)
    local handle = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 17, cache.ped, 4)
    local _, hit, coords = GetShapeTestResult(handle)
    return hit == 1, coords
end

---Finds a floor spot for a piece: on the ring, same floor level as the entry point, with nothing solid in between.
local function FindSpot(seed, junkId)
    local rand = Seeded(seed, junkId)
    local minRadius, maxRadius = Cfg().MinRadius or 1.5, Cfg().MaxRadius or 6.0
    local fallback = nil

    for _ = 1, 20 do
        local angle = rand() * math.pi * 2.0
        local distance = minRadius + rand() * (maxRadius - minRadius)
        local x, y = anchor.x + math.cos(angle) * distance, anchor.y + math.sin(angle) * distance

        fallback = fallback or vec3(x, y, anchor.z)

        local hit, ground = Probe(vec3(x, y, anchor.z + 1.2), vec3(x, y, anchor.z - 1.0))
        if hit and math.abs(ground.z - anchor.z) <= 0.45 then
            local blocked = Probe(vec3(anchor.x, anchor.y, anchor.z + 0.9), vec3(x, y, anchor.z + 0.9))
            if not blocked then return vec3(x, y, ground.z) end
        end
    end

    return fallback
end

local function DestroyPiece(junkId)
    local piece = pieces[junkId]
    if not piece then return end
    pieces[junkId] = nil

    if piece.zone then exports.ox_target:removeZone(piece.zone) end
    if piece.entity and DoesEntityExist(piece.entity) then DeleteEntity(piece.entity) end
end

local function DestroyAll()
    for junkId in pairs(pieces) do DestroyPiece(junkId) end
end

local function Sweep(junkId)
    if busy or not current then return end
    local propertyId = current.propertyId
    busy = true

    if not lib.callback.await('LNS_Housing:server:junk:begin', false, propertyId, junkId) then
        Bridge.Client.Notify('You cannot sweep that up right now.', 'error')
        busy = false
        return
    end

    local dict, clip = 'amb@world_human_janitor@male@idle_a', 'idle_a'
    local broomModel = joaat('prop_tool_broom')
    local broom = nil

    if pcall(lib.requestModel, broomModel, 3000) then
        local pos = GetOffsetFromEntityInWorldCoords(cache.ped, 0.0, 0.0, -5.0)
        broom = CreateObject(broomModel, pos.x, pos.y, pos.z, true, true, true)
        SetModelAsNoLongerNeeded(broomModel)
        AttachEntityToEntity(broom, cache.ped, GetPedBoneIndex(cache.ped, 28422), -0.005, 0.0, 0.0, 360.0, 360.0, 0.0, true, true, false, true, 0, true)
    end

    if pcall(lib.requestAnimDict, dict, 3000) then
        TaskPlayAnim(cache.ped, dict, clip, 8.0, -8.0, -1, 0, 0, false, false, false)
    end

    local completed = lib.progressCircle({
        duration = Cfg().CleanMs or 3000,
        label = 'Sweeping up junk',
        position = 'bottom',
        useWhileDead = false,
        canCancel = true,
        disable = { car = true, move = true, combat = true },
    })

    ClearPedTasks(cache.ped)
    if broom and DoesEntityExist(broom) then DeleteEntity(broom) end

    if completed then
        if lib.callback.await('LNS_Housing:server:junk:finish', false, propertyId, junkId) then
            Bridge.Client.Notify('You bagged up the junk. Take the trash bag to your bin outside.', 'success')
        else
            Bridge.Client.Notify('That did not work.', 'error')
        end
    end

    busy = false
end

local function CreatePiece(junkId)
    local spot = FindSpot(current.seed, junkId)
    if not spot or not current or pieces[junkId] then return end

    local rand = Seeded(current.seed, junkId + 500000)
    local models = Cfg().Models or {}
    local modelName = models[math.floor(rand() * #models) + 1]
    if not modelName then return end

    local model = joaat(modelName)
    if not IsModelInCdimage(model) or not pcall(lib.requestModel, model, 3000) then return end
    if not current or InsidePropertyId ~= current.propertyId then return end

    local entity = CreateObjectNoOffset(model, spot.x, spot.y, spot.z, false, false, false)
    SetModelAsNoLongerNeeded(model)
    if not DoesEntityExist(entity) then return end

    SetEntityHeading(entity, rand() * 360.0)
    FreezeEntityPosition(entity, true)
    SetEntityCollision(entity, false, false)

    local piece = { entity = entity }
    piece.zone = exports.ox_target:addSphereZone({
        coords = spot + vec3(0.0, 0.0, 0.2),
        radius = 0.7,
        debug = Settings.Debug and Settings.Debug.Zones,
        options = {
            {
                name = ('lns_junk_%s'):format(junkId),
                label = 'Sweep up',
                icon = 'fa-solid fa-broom',
                distance = Cfg().InteractDistance or 2.0,
                onSelect = function() Sweep(junkId) end,
            },
        },
    })
    pieces[junkId] = piece
end

---Makes the spawned pieces match the server's list. Only pieces that are missing or gone get touched.
local function Rebuild()
    if not IsEnabled() or not current or not anchor then return end
    if InsidePropertyId ~= current.propertyId then return end

    -- An update that arrives while pieces are still being created is picked up by another pass
    if building then
        rebuildAgain = true
        return
    end
    building = true

    repeat
        rebuildAgain = false

        local ids = current and current.ids or {}
        local wanted = {}
        for _, junkId in ipairs(ids) do wanted[junkId] = true end

        for junkId in pairs(pieces) do
            if not wanted[junkId] then DestroyPiece(junkId) end
        end

        for _, junkId in ipairs(ids) do
            if not current or InsidePropertyId ~= current.propertyId then break end
            if not pieces[junkId] then
                CreatePiece(junkId)
                Wait(0)
            end
        end
    until not rebuildAgain or not current

    building = false
end

local function Reset()
    current, anchor = nil, nil
    DestroyAll()
end

RegisterNetEvent('LNS_Housing:client:junkChanged', function(propertyId, ids, seed)
    if not IsEnabled() or type(ids) ~= 'table' or type(seed) ~= 'number' then return end
    if InsidePropertyId ~= propertyId then return end

    -- A different property than before means the old pieces are gone with it
    if current and current.propertyId ~= propertyId then Reset() end

    current = { propertyId = propertyId, ids = ids, seed = seed }
    CreateThread(Rebuild)
end)

AddEventHandler('LNS_Housing:client:enteredProperty', function(propertyId)
    if not IsEnabled() or not propertyId then return end

    CreateThread(function()
        -- Give the interior a moment to stream in; the entry point is the floor under the player
        Wait(1500)
        if InsidePropertyId ~= propertyId then return end

        local ped = GetEntityCoords(cache.ped)
        anchor = vec3(ped.x, ped.y, ped.z - 0.95)
        Rebuild()
    end)
end)

AddEventHandler('LNS_Housing:client:exitedProperty', function()
    Reset()
end)

AddEventHandler('qbx_core:client:onPlayerUnload', Reset)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then DestroyAll() end
end)
