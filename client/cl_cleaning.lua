local Settings = lib.load('shared.settings')

local function IsEnabled()
    return Settings.Cleaning ~= nil and Settings.Cleaning.Enabled == true
end

local function BinConfig()
    return (Settings.Cleaning and Settings.Cleaning.Bin) or {}
end

--------------------------------------------------------------------------------
-- Placement tool (used by the creator and the listing editor)
--------------------------------------------------------------------------------

local function Raycast(distance)
    local origin = GetGameplayCamCoord()
    local direction = RotationToDirection(GetGameplayCamRot(2))
    local target = origin + direction * distance
    local handle = StartShapeTestRay(origin.x, origin.y, origin.z, target.x, target.y, target.z, -1, cache.ped, 0)
    local _, hit, coords, normal = GetShapeTestResult(handle)
    return hit == 1, coords, normal
end

local function IsOutdoors(coords)
    return coords.z > (Settings.ShellSpawningZ or -100.0) + 50.0
        and GetInteriorAtCoords(coords.x, coords.y, coords.z + 0.5) == 0
end

---Lets the player aim a ghost prop at the ground and returns { x, y, z, h }, or nil when cancelled.
---Shared by the garbage bin and the for-sale sign placement.
---@param modelName string
---@param placement table? { MaxDistance, RotateStep }
---@param title string? what is being placed, for the prompts ('Bin', 'Sign')
function PickGhostPlacement(modelName, placement, title)
    placement = placement or {}
    title = title or 'Prop'
    local model = joaat(modelName)

    if not IsModelValid(model) or not pcall(lib.requestModel, model, 3000) then
        Bridge.Client.Notify(('The %s model is invalid. Contact an admin.'):format(title:lower()), 'error')
        return nil
    end

    local pedCoords = GetEntityCoords(cache.ped)
    local ghost = CreateObjectNoOffset(model, pedCoords.x, pedCoords.y, pedCoords.z, false, false, false)
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)

    local heading = GetEntityHeading(cache.ped)
    local step = placement.RotateStep or 5.0
    local reach = placement.MaxDistance or 12.0
    local result = nil

    lib.showTextUI(('[E] Place %s  \n[Scroll] Rotate  \n[BACKSPACE] Cancel'):format(title), { position = 'top-center' })

    while true do
        Wait(0)
        DisableControlAction(0, 14, true)
        DisableControlAction(0, 15, true)

        local hit, coords, normal = Raycast(reach)
        local outdoors = hit and IsOutdoors(coords)
        local valid = hit and outdoors and normal.z > 0.7

        if hit then
            SetEntityCoordsNoOffset(ghost, coords.x, coords.y, coords.z, false, false, false)
            SetEntityHeading(ghost, heading)
            PlaceObjectOnGroundProperly(ghost)
        end
        SetEntityAlpha(ghost, valid and 190 or 70, false)

        if IsDisabledControlJustPressed(0, 14) then
            heading = (heading + step) % 360.0
        elseif IsDisabledControlJustPressed(0, 15) then
            heading = (heading - step) % 360.0
        end

        if IsControlJustPressed(0, 38) then
            if valid then
                local placed = GetEntityCoords(ghost)
                result = { x = placed.x, y = placed.y, z = placed.z, h = heading }
                break
            end
            Bridge.Client.Notify(hit and not outdoors and ('The %s has to be outside the property.'):format(title:lower()) or ('Aim at flat ground to place the %s.'):format(title:lower()), 'error')
        elseif IsControlJustPressed(0, 194) then
            break
        end
    end

    lib.hideTextUI()
    DeleteEntity(ghost)
    SetModelAsNoLongerNeeded(model)
    return result
end

local function PickBinPlacement()
    local config = BinConfig()
    return PickGhostPlacement(config.Model or 'prop_bin_07d', config.Placement, 'Bin')
end

RegisterNUICallback('pickBinCoords', function(_, cb)
    if not IsEnabled() then return cb(nil) end

    SendNUIMessage({ action = 'toggleVisibility', data = { visible = false } })
    SetNuiFocus(false, false)
    Wait(300)

    local result = PickBinPlacement()

    SendNUIMessage({ action = 'toggleVisibility', data = { visible = true } })
    SetNuiFocus(true, true)

    if result then Bridge.Client.Notify('Garbage bin location registered.', 'success') end
    cb(result)
end)

--------------------------------------------------------------------------------
-- Owner placement (property tablet)
--------------------------------------------------------------------------------

local pendingPlacement = nil -- propertyId waiting for the owner to step outside

local function IsPlayerOutside()
    return InsidePropertyId == nil and GetInteriorFromEntity(cache.ped) == 0
end

local function StartOwnerPlacement(propertyId, property)
    local config = BinConfig()
    local placement = config.Placement or {}
    local deadline = GetGameTimer() + (placement.WaitTimeout or 300000)
    local maxDistance = config.MaxDistanceFromProperty or 75.0

    pendingPlacement = propertyId
    Bridge.Client.Notify('Walk outside your property to place the bin.', 'inform')
    lib.showTextUI('[BACKSPACE] Cancel bin placement', { position = 'top-center' })

    local nextCheck = 0
    while pendingPlacement == propertyId do
        Wait(0)

        if IsControlJustPressed(0, 194) then
            Bridge.Client.Notify('Bin placement cancelled.', 'inform')
            break
        end

        local now = GetGameTimer()
        if now >= nextCheck then
            nextCheck = now + 250

            if now > deadline then
                Bridge.Client.Notify('Bin placement timed out.', 'inform')
                break
            end

            if IsPlayerOutside() then
                local entrance = GetEntranceCoords(property)
                local nearProperty = not entrance
                    or #(GetEntityCoords(cache.ped) - vec3(entrance.x, entrance.y, entrance.z)) <= maxDistance

                if nearProperty then
                    lib.hideTextUI()
                    pendingPlacement = nil
                    local result = PickBinPlacement()
                    if result then
                        TriggerServerEvent('LNS_Housing:server:bin:place', propertyId, result)
                    end
                    return
                end
            end
        end
    end

    if pendingPlacement == propertyId then pendingPlacement = nil end
    lib.hideTextUI()
end

RegisterNUICallback('startOwnerBinPlacement', function(data, cb)
    local propertyId = tonumber(data and data.propertyId)
    local property = propertyId and Properties[propertyId]

    if not IsEnabled() or BinConfig().OwnerCanPlace ~= true or pendingPlacement
        or not property or property.isApartment or property.owner ~= Bridge.Client.GetIdentifier() then
        cb(false)
        return
    end

    SendNUIMessage({ action = 'closeUI' })
    SetNuiFocus(false, false)
    cb(true)

    CreateThread(function() StartOwnerPlacement(propertyId, property) end)
end)

RegisterNUICallback('removeOwnerBin', function(data, cb)
    TriggerServerEvent('LNS_Housing:server:bin:remove', tonumber(data and data.propertyId))
    cb('ok')
end)

--------------------------------------------------------------------------------
-- Bin props
--------------------------------------------------------------------------------

local Bins = {} -- [propertyId] = { propertyId, point, coords, entity, inRange, fill, bags }

local BAG_MODEL = 'prop_cs_rub_binbag_01'
local BAG_SPOTS = { vec2(0.75, 0.15), vec2(-0.7, 0.3), vec2(0.15, -0.8), vec2(-0.55, -0.6) }

local function ClearBags(entry)
    for _, bag in ipairs(entry.bags or {}) do
        if DoesEntityExist(bag) then DeleteEntity(bag) end
    end
    entry.bags = {}
end

---Bags pile up beside the bin as it fills: none when it is quiet, more at half, three quarters and full.
local function ApplyFillVisuals(entry)
    entry.visualsPass = (entry.visualsPass or 0) + 1
    local pass = entry.visualsPass

    ClearBags(entry)
    if not entry.entity or not DoesEntityExist(entry.entity) then return end

    local ratio = (entry.fill or 0) / math.max(1, entry.capacity or BinConfig().Capacity or 12)
    local count = ratio >= 1.0 and 4 or ratio >= 0.75 and 3 or ratio >= 0.5 and 1 or 0
    if count == 0 then return end

    local model = joaat(BAG_MODEL)
    if not pcall(lib.requestModel, model, 3000) then return end

    for index = 1, count do
        -- the bin may have despawned or a newer fill update started while the model streamed in
        if entry.visualsPass ~= pass or not entry.entity or not DoesEntityExist(entry.entity) then break end

        local spot = BAG_SPOTS[index]
        local pos = GetOffsetFromEntityInWorldCoords(entry.entity, spot.x, spot.y, 0.0)
        local bag = CreateObjectNoOffset(model, pos.x, pos.y, pos.z, false, false, false)
        if DoesEntityExist(bag) then
            SetEntityHeading(bag, (index * 67.0) % 360.0)
            PlaceObjectOnGroundProperly(bag)
            FreezeEntityPosition(bag, true)
            SetEntityCollision(bag, false, false)
            entry.bags[#entry.bags + 1] = bag
        end
    end
    SetModelAsNoLongerNeeded(model)
end

local function DespawnBin(entry)
    ClearBags(entry)
    if entry.entity and DoesEntityExist(entry.entity) then
        exports.ox_target:removeLocalEntity(entry.entity)
        DeleteEntity(entry.entity)
    end
    entry.entity = nil
end

local dumping = false

local function DumpTrash(propertyId)
    if dumping then return end
    dumping = true

    local dict, clip = 'mp_common', 'givetake1_a'
    if pcall(lib.requestAnimDict, dict, 3000) then
        TaskPlayAnim(cache.ped, dict, clip, 4.0, -4.0, BinConfig().DumpMs or 1500, 0, 0.0, false, false, false)
    end

    local completed = lib.progressCircle({
        duration = BinConfig().DumpMs or 1500,
        label = 'Emptying trash bags into the bin',
        position = 'bottom',
        useWhileDead = false,
        canCancel = true,
        disable = { car = true, move = true, combat = true },
    })
    ClearPedTasks(cache.ped)

    if completed then
        local result = lib.callback.await('LNS_Housing:server:bin:dump', false, propertyId)
        if result and result.ok then
            if result.capacity then
                Bridge.Client.Notify(('Dumped %d bag(s). The bin is %d/%d full.'):format(result.added, result.fill, result.capacity), 'success')
            else
                Bridge.Client.Notify(('You threw away %d bag(s).'):format(result.added), 'success')
            end
        elseif result and result.reason then
            Bridge.Client.Notify(result.reason, 'error')
        end
    end
    dumping = false
end

local function CheckBin(propertyId)
    local fill, capacity, emptiedAt = lib.callback.await('LNS_Housing:server:bin:getFill', false, propertyId)
    local text = ('The bin is %d/%d full.'):format(fill or 0, capacity or 0)
    if fill and capacity and fill >= capacity then
        text = text .. ' It needs emptying by the garbage crew.'
    elseif emptiedAt and emptiedAt > 0 then
        text = text .. (' Last emptied %d hours ago.'):format(math.floor((GetCloudTimeAsInt() - emptiedAt) / 3600))
    end
    Bridge.Client.Notify(text, 'inform')
end

---True when the player carries a trash bag swept up in this property (the server checks again when dumping)
local function CarriesTrashBag(propertyId)
    local item = Settings.Cleaning.Item or 'trash_bag'
    for _, slot in pairs(Bridge.Client.Search('slots', item) or {}) do
        if slot.metadata and tonumber(slot.metadata.property) == propertyId then return true end
    end
    return false
end

local function SpawnBin(entry)
    if entry.entity and DoesEntityExist(entry.entity) then return end

    local model = joaat(BinConfig().Model or 'prop_bin_07d')
    if not pcall(lib.requestModel, model, 3000) then return end
    if not entry.inRange then
        SetModelAsNoLongerNeeded(model)
        return
    end

    local c = entry.coords
    local entity = CreateObjectNoOffset(model, c.x, c.y, c.z, false, false, false)
    SetModelAsNoLongerNeeded(model)
    if not DoesEntityExist(entity) then return end

    SetEntityHeading(entity, c.h or 0.0)
    FreezeEntityPosition(entity, true)
    entry.entity = entity

    local options = {
        {
            name = ('lns_bin_dump_%s'):format(entry.propertyId),
            label = 'Dump trash bags',
            icon = 'fa-solid fa-dumpster',
            distance = BinConfig().InteractDistance or 3.0,
            canInteract = function() return CarriesTrashBag(entry.propertyId) end,
            onSelect = function() DumpTrash(entry.propertyId) end,
        },
    }
    if BinConfig().KeepContents == true then
        options[#options + 1] = {
            name = ('lns_bin_check_%s'):format(entry.propertyId),
            label = 'Check bin',
            icon = 'fa-solid fa-trash-can',
            distance = BinConfig().InteractDistance or 3.0,
            onSelect = function() CheckBin(entry.propertyId) end,
        }
    end
    exports.ox_target:addLocalEntity(entity, options)

    local fill, capacity = lib.callback.await('LNS_Housing:server:bin:getFill', false, entry.propertyId)
    entry.fill, entry.capacity = fill or 0, capacity or BinConfig().Capacity or 12
    if entry.entity == entity then ApplyFillVisuals(entry) end
end

local function RemoveBin(propertyId)
    local entry = Bins[propertyId]
    if not entry then return end
    Bins[propertyId] = nil
    entry.inRange = false
    entry.point:remove()
    DespawnBin(entry)
end

local function AddBin(propertyId, coords)
    local entry = { propertyId = propertyId, coords = coords, inRange = false, bags = {} }
    entry.point = lib.points.new({
        coords = vec3(coords.x, coords.y, coords.z),
        distance = BinConfig().RenderDistance or 35.0,
        onEnter = function()
            entry.inRange = true
            CreateThread(function() SpawnBin(entry) end)
        end,
        onExit = function()
            entry.inRange = false
            DespawnBin(entry)
        end,
    })
    Bins[propertyId] = entry
end

local function RefreshBins()
    local wanted = {}
    if IsEnabled() then
        for id, p in pairs(Properties or {}) do
            local c = p.metadata and p.metadata.bin_coords
            if c and not p.isApartment then wanted[id] = c end
        end
    end

    for id, entry in pairs(Bins) do
        local c = wanted[id]
        if not c or entry.coords.x ~= c.x or entry.coords.y ~= c.y or entry.coords.z ~= c.z or entry.coords.h ~= c.h then
            RemoveBin(id)
        end
    end

    for id, c in pairs(wanted) do
        if not Bins[id] then AddBin(id, c) end
    end
end

AddEventHandler('LNS_Housing:client:propertiesChanged', RefreshBins)

RegisterNetEvent('LNS_Housing:client:binFill', function(propertyId, fill)
    local entry = Bins[propertyId]
    if not entry or type(fill) ~= 'number' then return end

    entry.fill = fill
    if entry.entity then CreateThread(function() ApplyFillVisuals(entry) end) end
end)

---Client exports: the bin prop model (for targeting) and which property a spawned bin belongs to.
exports('GetBinModel', function()
    return BinConfig().Model or 'prop_bin_07d'
end)

---@return integer? propertyId of the closest spawned bin within maxDistance of the coords
exports('GetNearestBinPropertyId', function(coords, maxDistance)
    if not coords then return nil end

    local closest, closestDistance = nil, maxDistance or 2.0
    for propertyId, entry in pairs(Bins) do
        local distance = #(vec3(coords.x, coords.y, coords.z) - vec3(entry.coords.x, entry.coords.y, entry.coords.z))
        if distance <= closestDistance then
            closest, closestDistance = propertyId, distance
        end
    end
    return closest
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    pendingPlacement = nil
    for id in pairs(Bins) do RemoveBin(id) end
end)
