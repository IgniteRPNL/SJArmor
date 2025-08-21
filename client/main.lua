local currentArmorData = {}
local isArmorMonitoringActive = false
local isUnequipping = false
local isServerUpdatingArmor = false
local savedKevlarComponent = nil
local isVestApplied = false

local Utils = {}
function Utils.PlayAnimAdvanced(wait, dict, name, posX, posY, posZ, rotX, rotY, rotZ, blendIn, blendOut, duration, flag, time)
    if lib and lib.requestAnimDict then
        lib.requestAnimDict(dict)
    else
        if not HasAnimDictLoaded(dict) then
            RequestAnimDict(dict)
            while not HasAnimDictLoaded(dict) do Wait(0) end
        end
    end
    TaskPlayAnimAdvanced(cache.ped or PlayerPedId(), dict, name, posX, posY, posZ, rotX, rotY, rotZ, blendIn, blendOut, duration, flag, time, 0, 0)
    RemoveAnimDict(dict)
    if wait and wait > 0 then Wait(wait) end
end

local function requestAnimDict(dict)
    if not HasAnimDictLoaded(dict) then
        RequestAnimDict(dict)
        while not HasAnimDictLoaded(dict) do
            Wait(0)
        end
    end
end

local function playOnce(ped, dict, clip)
    requestAnimDict(dict)
    ClearPedSecondaryTask(ped)
    local duration = 1000
    TaskPlayAnim(ped, dict, clip, 8.0, -8.0, duration, 49, 0.0, false, false, false)
    Wait(100)
    if not IsEntityPlayingAnim(ped, dict, clip, 3) then
        TaskPlayAnim(ped, dict, clip, 8.0, -8.0, duration, 0, 0.0, false, false, false)
        Wait(100)
    end
    Wait(duration - 200)
    StopAnimTask(ped, dict, clip, 1.0)
end

local function playIntroThenConfig(settings)
    local ped = cache.ped or PlayerPedId()
    if not DoesEntityExist(ped) then return end
    local x, y, z = table.unpack(GetEntityCoords(ped))
    local heading = GetEntityHeading(ped)
    local introDict, introClip = 'reaction@intimidation@1h', 'intro'
    local introDur = math.floor(((GetAnimDuration(introDict, introClip) or 1.0) * 1000))
    if introDur < 500 then introDur = 1000 end
    Utils.PlayAnimAdvanced(introDur, introDict, introClip, x, y, z, 0.0, 0.0, heading, 8.0, 3.0, introDur, 50, 0.1)

    if settings and settings.animation and settings.animation.dict and settings.animation.clip then
        local cfgDict, cfgClip = settings.animation.dict, settings.animation.clip
        local cfgDur = math.floor(((GetAnimDuration(cfgDict, cfgClip) or 1.0) * 1000))
        if cfgDur < 500 then cfgDur = 1000 end
        Utils.PlayAnimAdvanced(cfgDur, cfgDict, cfgClip, x, y, z, 0.0, 0.0, heading, 8.0, 3.0, cfgDur, 50, 0.1)
    end
end

function openPlateCarrier(slot, carrierType)
    lib.notify({
        type = 'inform',
        description = 'Opening plate carrier...'
    })
    exports.ox_inventory:closeInventory()

    SetTimeout(100, function()
        TriggerServerEvent('SJArmor:openPlateCarrier', slot, carrierType)
    end)
end

function equipPlateCarrier(slot, carrierType)
    local success = lib.progressCircle({
        label = Config.EquipSettings.progressText,
        duration = Config.EquipSettings.useTime,
        position = 'bottom',
        canCancel = true,
        disable = { move = false, combat = true, mouse = false },
        anim = { dict = Config.EquipSettings.animation.dict, clip = Config.EquipSettings.animation.clip },
    })

    if success then
        local ped = cache.ped or PlayerPedId()
        local kevlarComponentId = 9
        local prevDrawable = GetPedDrawableVariation(ped, kevlarComponentId)
        local prevTexture  = GetPedTextureVariation(ped, kevlarComponentId)
        local prevPalette  = GetPedPaletteVariation(ped, kevlarComponentId)
        TriggerServerEvent('SJArmor:equipPlateCarrier', slot, carrierType, prevDrawable, prevTexture, prevPalette)
    end
end

function unequipPlateCarrier()
    local success = lib.progressCircle({
        label = Config.UnequipSettings.progressText,
        duration = Config.UnequipSettings.useTime,
        position = 'bottom',
        canCancel = true,
        disable = { move = false, combat = true, mouse = false },
        anim = { dict = Config.UnequipSettings.animation.dict, clip = Config.UnequipSettings.animation.clip },
    })

    if success then
        TriggerServerEvent('SJArmor:unequipPlateCarrier')
    end
end

lib.callback.register('SJArmor:plateInstallProgress', function(params)
    params = params or {}
    if params.closeInventory then exports.ox_inventory:closeInventory() end

    local ped = cache.ped or PlayerPedId()
    local propHandle = nil
    local p = params.prop

    if p and (p.enabled ~= false) and p.model then
        local model = (type(p.model) == 'number') and p.model or joaat(p.model)
        if IsModelInCdimage(model) then
            RequestModel(model)
            local t = GetGameTimer() + 5000
            while not HasModelLoaded(model) and GetGameTimer() < t do Wait(10) end

            if HasModelLoaded(model) and DoesEntityExist(ped) then
                local x, y, z = table.unpack(GetEntityCoords(ped))
                propHandle = CreateObject(model, x, y, z, true, true, false)
                SetEntityCollision(propHandle, false, false)
                if SetEntityCompletelyDisableCollision then
                    SetEntityCompletelyDisableCollision(propHandle, true, true)
                end
                FreezeEntityPosition(propHandle, true)
                SetEntityAsMissionEntity(propHandle, true, true)

                local boneIndex = GetPedBoneIndex(ped, p.bone or 57005)
                AttachEntityToEntity(
                    propHandle, ped, boneIndex,
                    (p.pos and p.pos.x) or 0.0, (p.pos and p.pos.y) or 0.0, (p.pos and p.pos.z) or 0.0,
                    (p.rot and p.rot.x) or 0.0, (p.rot and p.rot.y) or 0.0, (p.rot and p.rot.z) or 0.0,
                    true, true, false, true, 1, true
                )
                SetModelAsNoLongerNeeded(model)
            end
        end
    end

    local x, y, z = table.unpack(GetEntityCoords(ped))
    local heading = GetEntityHeading(ped)
    local introDict, introClip = 'reaction@intimidation@1h', 'intro'
    local a = params.anim or { dict = 'clothingshirt', clip = 'try_shirt_negative_a' }
    local animCancel = { cancelled = false }
    CreateThread(function()
        lib.requestAnimDict(introDict)
        if a.dict and a.clip then lib.requestAnimDict(a.dict) end
        local introDurS = GetAnimDuration(introDict, introClip) or 0.0
        local introMs = math.max(1000, math.floor(introDurS * 1000))
        TaskPlayAnim(ped, introDict, introClip, 4.0, -4.0, introMs, 49, 0.0, false, false, false)
        local handoffMs = math.max(250, math.floor(introMs * 0.85))
        local t0 = GetGameTimer()
        local startedNext = false
        local nextEndMs = nil
        while not animCancel.cancelled do
            local elapsed = GetGameTimer() - t0
            if (not startedNext) and a.dict and a.clip and elapsed >= handoffMs then
                local cfgDurS = GetAnimDuration(a.dict, a.clip) or 0.0
                local cfgMs = math.max(2000, math.floor(cfgDurS * 1000))
                ClearPedSecondaryTask(ped)
                TaskPlayAnim(ped, a.dict, a.clip, 4.0, -4.0, cfgMs, 48, 0.0, false, false, false)
                startedNext = true
                nextEndMs = elapsed + cfgMs
            end
            if startedNext and nextEndMs and elapsed >= nextEndMs then break end
            if elapsed > ((nextEndMs or introMs) + 5000) then break end
            Wait(0)
        end
        ClearPedSecondaryTask(ped)
        RemoveAnimDict(introDict)
        if a.dict and a.clip then RemoveAnimDict(a.dict) end
    end)

    local ok = lib.progressCircle({
        label = params.label or 'Installing plate...',
        duration = (params.duration or 6000),
        position = 'bottom',
        canCancel = params.canCancel ~= false,
        disable = params.disable or { move = false, combat = true, mouse = false },
    })

    animCancel.cancelled = true
    ClearPedSecondaryTask(ped)

    if propHandle and DoesEntityExist(propHandle) then
        DeleteObject(propHandle)
        propHandle = nil
    end

    return ok and true or false
end)

exports('openPlateCarrier', openPlateCarrier)
exports('equipPlateCarrier', equipPlateCarrier)
exports('unequipPlateCarrier', unequipPlateCarrier)

RegisterNetEvent('SJArmor:equipArmorResponse', function(success, armorData, message, targetArmor)
    if success then
        isUnequipping = false

        local newVirtualArmor = armorData.virtualArmor
        currentArmorData = armorData
        isServerUpdatingArmor = true

        SetPlayerMaxArmour(cache.serverId, 100)
        SetPedArmour(cache.ped, targetArmor or 0)

        local ped = cache.ped or PlayerPedId()
        if DoesEntityExist(ped) then
            local kevlarComponentId = 9
            local desiredDrawable = armorData and armorData.vestDrawable
            local desiredTexture  = (armorData and armorData.vestTexture) or 0
            if desiredDrawable then
                if not isVestApplied then
                    local currentDrawable = GetPedDrawableVariation(ped, kevlarComponentId)
                    local currentTexture  = GetPedTextureVariation(ped, kevlarComponentId)
                    local currentPalette  = GetPedPaletteVariation(ped, kevlarComponentId)
                    savedKevlarComponent = {
                        drawable = currentDrawable,
                        texture  = currentTexture,
                        palette  = currentPalette
                    }
                end
                SetPedComponentVariation(ped, kevlarComponentId, desiredDrawable, desiredTexture, 0)
                isVestApplied = true
            end
        end

        SetTimeout(1000, function() isServerUpdatingArmor = false end)

        if newVirtualArmor > 0 then
            startArmorMonitoring()
        else
            stopArmorMonitoring()
        end

        lib.notify({
            type = 'success',
            description = message or ('Plate carrier equipped! Virtual armor: %d'):format(newVirtualArmor)
        })
    else
        lib.notify({
            type = 'error',
            description = message or 'Failed to equip plate carrier'
        })
    end
end)

RegisterNetEvent('SJArmor:unequipArmorResponse', function(success, message, targetArmor, prevComponent)
    if success then
        isUnequipping = true
        isServerUpdatingArmor = true

        currentArmorData = {}
        stopArmorMonitoring()

        SetPlayerMaxArmour(cache.serverId, 100)
        SetPedArmour(cache.ped, targetArmor or 0)

        local ped = cache.ped or PlayerPedId()
        if DoesEntityExist(ped) then
            if prevComponent then
                SetPedComponentVariation(ped, 9, prevComponent.drawable or 0, prevComponent.texture or 0, prevComponent.palette or 0)
            elseif isVestApplied and savedKevlarComponent then
                SetPedComponentVariation(ped, 9, savedKevlarComponent.drawable or 0, savedKevlarComponent.texture or 0, savedKevlarComponent.palette or 0)
            end
        end
        savedKevlarComponent = nil
        isVestApplied = false

        SetTimeout(100, function() isUnequipping = false end)
        SetTimeout(1000, function() isServerUpdatingArmor = false end)

        lib.notify({
            type = 'success',
            description = message or 'Plate carrier removed'
        })
    else
        lib.notify({
            type = 'error',
            description = message or 'Failed to remove plate carrier'
        })
    end
end)

RegisterNetEvent('SJArmor:updateArmor', function(armorData, targetArmor)
    if armorData.virtualArmor > 0 then
        isUnequipping = false
    end

    isServerUpdatingArmor = true
    currentArmorData = armorData

    SetPlayerMaxArmour(cache.serverId, 100)
    SetPedArmour(cache.ped, targetArmor or 0)

    SetTimeout(1000, function() isServerUpdatingArmor = false end)

    if armorData.virtualArmor > 0 then
        if not isArmorMonitoringActive then
            startArmorMonitoring()
        end
    else
        stopArmorMonitoring()
    end
end)

RegisterNetEvent('SJArmor:plateBroken', function(plateName)
    lib.notify({
        type = 'inform',
        icon = 'shield-crack',
        iconColor = 'orange',
        description = ('A %s has shattered'):format(plateName)
    })
end)

RegisterNetEvent('SJArmor:allPlatesBroken', function()
    lib.notify({
        type = 'inform',
        icon = 'shield-halved',
        iconColor = 'red',
        description = 'All armor plates have shattered.'
    })
end)

RegisterNetEvent('SJArmor:forceUnequip', function(prevComponent)
    isUnequipping = true

    currentArmorData = {}
    stopArmorMonitoring()

    SetPlayerMaxArmour(cache.serverId, 100)
    SetPedArmour(cache.ped, 0)

    local ped = cache.ped or PlayerPedId()
    if DoesEntityExist(ped) then
        if isVestApplied and savedKevlarComponent then
            SetPedComponentVariation(ped, 9, savedKevlarComponent.drawable or 0, savedKevlarComponent.texture or 0, savedKevlarComponent.palette or 0)
        elseif prevComponent then
            SetPedComponentVariation(ped, 9, prevComponent.drawable or 0, prevComponent.texture or 0, prevComponent.palette or 0)
        end
    end
    savedKevlarComponent = nil
    isVestApplied = false

    SetTimeout(100, function() isUnequipping = false end)

    lib.notify({
        type = 'inform',
        icon = 'shield-halved',
        iconColor = 'orange',
        description = 'Plate carrier was removed improperly - armor disabled.'
    })
end)

function startArmorMonitoring()
    if isArmorMonitoringActive then return end
    isArmorMonitoringActive = true

    CreateThread(function()
        local lastCheckedArmor = GetPedArmour(cache.ped)
        local lastDamageTime = 0

        while isArmorMonitoringActive do
            Wait(300)

            local currentGtaArmor = GetPedArmour(cache.ped)
            local currentTime = GetGameTimer()

            if currentGtaArmor < lastCheckedArmor and (currentTime - lastDamageTime) > 500 and not isServerUpdatingArmor then
                local damageAmount = lastCheckedArmor - currentGtaArmor
                if damageAmount >= math.max(Config.DamageSettings.minimumDamageThreshold, 5) then
                    TriggerServerEvent('SJArmor:armorDamaged', damageAmount)
                    lastDamageTime = currentTime
                end
            elseif isServerUpdatingArmor then
                lastCheckedArmor = currentGtaArmor
            end

            lastCheckedArmor = currentGtaArmor

            if not currentArmorData.virtualArmor or currentArmorData.virtualArmor <= 0 then
                isArmorMonitoringActive = false
                break
            end
        end
    end)
end

function stopArmorMonitoring()
    isArmorMonitoringActive = false
    if isUnequipping then
        currentArmorData = {}
    end
end

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        stopArmorMonitoring()
    end
end)

RegisterNetEvent('ox_inventory:armorSlotChanged', function(item, action)
    if action == 'equipped' and item then
        local carrierType = item.name
        if carrierType then
            local success = lib.progressCircle({
                label = Config.EquipSettings.progressText,
                duration = Config.EquipSettings.useTime,
                position = 'bottom',
                canCancel = true,
                disable = { move = false, combat = true, mouse = false },
                anim = { dict = Config.EquipSettings.animation.dict, clip = Config.EquipSettings.animation.clip },
            })

            if success then
                TriggerServerEvent('SJArmor:equipPlateCarrierFromSlot', item.slot, item.metadata, carrierType)
            else
                TriggerServerEvent('SJArmor:cancelEquip', item.slot)
            end
        end

    elseif action == 'unequipped' then
        local success = lib.progressCircle({
            label = Config.UnequipSettings.progressText,
            duration = Config.UnequipSettings.useTime,
            position = 'bottom',
            canCancel = true,
            disable = { move = false, combat = true, mouse = false },
            anim = { dict = Config.UnequipSettings.animation.dict, clip = Config.UnequipSettings.animation.clip },
        })

        if success then
            TriggerServerEvent('SJArmor:unequipPlateCarrier')
        end
    end
end)

RegisterNetEvent('SJArmor:startEquipProgress', function(targetSlot, metadata, carrierType)
    exports.ox_inventory:closeInventory()

    local success = lib.progressCircle({
        label = Config.EquipSettings.progressText,
        duration = Config.EquipSettings.useTime,
        position = 'bottom',
        canCancel = true,
        disable = { move = false, combat = true, mouse = false },
        anim = { dict = Config.EquipSettings.animation.dict, clip = Config.EquipSettings.animation.clip },
    })

    if success then
        local ped = cache.ped or PlayerPedId()
        if DoesEntityExist(ped) then
            local kevlarComponentId = 9
            metadata = metadata or {}
            metadata.prevVestDrawable = GetPedDrawableVariation(ped, kevlarComponentId)
            metadata.prevVestTexture  = GetPedTextureVariation(ped, kevlarComponentId)
            metadata.prevVestPalette  = GetPedPaletteVariation(ped, kevlarComponentId)
        end
        TriggerServerEvent('SJArmor:equipPlateCarrierFromSlot', targetSlot, metadata, carrierType)
    else
        TriggerServerEvent('SJArmor:cancelEquipAndMoveBack', targetSlot, metadata, carrierType)
    end
end)

RegisterNetEvent('SJArmor:startUnequipProgress', function(fromSlot, metadata, carrierType)
    exports.ox_inventory:closeInventory()

    local success = lib.progressCircle({
        label = Config.UnequipSettings.progressText,
        duration = Config.UnequipSettings.useTime,
        position = 'bottom',
        canCancel = true,
        disable = { move = false, combat = true, mouse = false },
        anim = { dict = Config.UnequipSettings.animation.dict, clip = Config.UnequipSettings.animation.clip },
    })

    if success then
        TriggerServerEvent('SJArmor:unequipPlateCarrier')
    else
        TriggerServerEvent('SJArmor:cancelUnequipAndMoveBack', fromSlot, metadata, carrierType)
    end
end)

RegisterNetEvent('SJArmor:forceVestUpdate', function(vestDrawable, vestTexture)
    local ped = cache.ped or PlayerPedId()
    if DoesEntityExist(ped) and vestDrawable then
        local kevlarComponentId = 9
        SetPedComponentVariation(ped, kevlarComponentId, vestDrawable, vestTexture or 0, 0)
        isVestApplied = true
    end
end)
