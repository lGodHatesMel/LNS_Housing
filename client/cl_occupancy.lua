local currentId = nil

AddEventHandler('LNS_Housing:client:enteredProperty', function(propertyId)
    if not propertyId or currentId == propertyId then return end
    currentId = propertyId
    TriggerServerEvent('LNS_Housing:server:occupancy:enter', propertyId)
end)

AddEventHandler('LNS_Housing:client:exitedProperty', function(propertyId)
    if not currentId or (propertyId and propertyId ~= currentId) then return end
    currentId = nil
    TriggerServerEvent('LNS_Housing:server:occupancy:leave')
end)
