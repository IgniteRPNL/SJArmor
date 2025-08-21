local playerArmorData = {} 
local registeredStashes = {} 
local plateInstallBusy = {}
local equipInProgress = {} 

local ContainerConfigs = require('data.containers')

local function clone(tbl)
    if type(tbl) ~= 'table' then return tbl end
    local out = {}
    for k, v in pairs(tbl) do
        out[k] = (type(v) == 'table') and clone(v) or v
    end
    return out
end

local function deepMerge(base, override)
    if type(base) ~= 'table' then return clone(override) end
    local out = clone(base)
    if type(override) == 'table' then
        for k, v in pairs(override) do
            if type(v) == 'table' and type(out[k]) == 'table' then
                out[k] = deepMerge(out[k], v)
            else
                out[k] = clone(v)
            end
        end
    end
    return out
end

local function calculateVirtualArmor(stashInventory)
    local totalArmor = 0
    local plateCount = 0
    
    if not stashInventory or not stashInventory.items then
        return totalArmor, plateCount
    end
    
    for slot, item in pairs(stashInventory.items) do
        if item and Config.Plates[item.name] then
            local plateConfig = Config.Plates[item.name]
            local durability = 100
            if item.metadata and item.metadata.plateDurability ~= nil then
                durability = item.metadata.plateDurability
            elseif item.metadata and item.metadata.durability ~= nil then
                durability = item.metadata.durability
            elseif item.durability ~= nil then
                durability = item.durability
            end
            
            if durability > 0 then
                totalArmor = totalArmor + plateConfig.protection
                plateCount = plateCount + 1
            end
        end
    end
    
    return math.floor(totalArmor), plateCount
end

local function calculatePlateWeight(stashInventory, baseWeight)
    local totalWeight = baseWeight or 0
    
    if not stashInventory or not stashInventory.items then
        return totalWeight
    end
    
    for slot, item in pairs(stashInventory.items) do
        if item and Config.Plates[item.name] then
            local plateConfig = Config.Plates[item.name]
            totalWeight = totalWeight + (plateConfig.weight * item.count)
        end
    end
    
    return totalWeight
end

local function updatePlateCarrierWeight(playerId, carrierSlot, stashId)
    local carrierItem = exports.ox_inventory:GetSlot(playerId, carrierSlot)
    if not carrierItem then 
        return 
    end
    
    local carrierConfig = ContainerConfigs[carrierItem.name]
    if not carrierConfig then 
        return 
    end
    
    local stashInv = exports.ox_inventory:GetInventory(stashId, false)
    local newWeight = calculatePlateWeight(stashInv, carrierConfig.baseWeight)
    
    local updatedMetadata = {}
    
    if carrierItem.metadata then
        for key, value in pairs(carrierItem.metadata) do
            updatedMetadata[key] = value
        end
    end
    
    updatedMetadata.weight = newWeight
    
    exports.ox_inventory:SetMetadata(playerId, carrierSlot, updatedMetadata)
end

local function getNextPlateToBreak(stashInventory)
    if not stashInventory or not stashInventory.items then return nil end
    
    local bestPlate = nil
    local bestTier = 999 -- Lower tier number = higher priority
    
    for slot, item in pairs(stashInventory.items) do
        if item and Config.Plates[item.name] then
            local plateConfig = Config.Plates[item.name]
            local durability = 100
            if item.metadata and item.metadata.plateDurability ~= nil then
                durability = item.metadata.plateDurability
            elseif item.metadata and item.metadata.durability ~= nil then
                durability = item.metadata.durability
            elseif item.durability ~= nil then
                durability = item.durability
            end
            
            if durability > 0 and plateConfig.tier < bestTier then
                bestTier = plateConfig.tier
                bestPlate = {
                    slot = slot,
                    item = item,
                    config = plateConfig
                }
            end
        end
    end
    
    return bestPlate
end

exports.ox_inventory:registerHook('createItem', function(payload)
    local item = payload.item
    local metadata = payload.metadata or {}
    
    if Config.Plates[item.name] then
        local plateConfig = Config.Plates[item.name]
        
        if metadata.sjarmor_processed then
            return metadata
        end
        
        if metadata.plateDurability ~= nil then
            metadata.durability = metadata.plateDurability  
        elseif metadata.durability ~= nil then
            metadata.plateDurability = metadata.durability
        elseif metadata.degrade ~= nil then
            metadata.plateDurability = metadata.degrade
            metadata.durability = metadata.degrade
        else
            metadata.durability = 100
            metadata.plateDurability = 100
        end
        
    end
    
    if ContainerConfigs[item.name] then
        local carrierConfig = ContainerConfigs[item.name]
        
        if not metadata.stashId then
            local timestamp = os.time()
            local stashId = ('%s%d_%d'):format(carrierConfig.stashPrefix, timestamp, math.random(100000, 999999))
            
            exports.ox_inventory:RegisterStash(stashId, carrierConfig.label, carrierConfig.plateSlots, 50000, false, false)
            
            metadata.stashId = stashId
            registeredStashes[stashId] = {
                owner = false,  
                type = item.name,
                created = timestamp
            }
        end
        
        if not metadata.virtualArmor then metadata.virtualArmor = 0 end
        if not metadata.plateCount then metadata.plateCount = 0 end
        if not metadata.weight then metadata.weight = carrierConfig.baseWeight end
        if not metadata.vestDrawable and carrierConfig and carrierConfig.vestDrawable then
            metadata.vestDrawable = carrierConfig.vestDrawable
        end
        if metadata.vestDrawable and metadata.vestTexture == nil and carrierConfig and carrierConfig.vestTexture ~= nil then
            metadata.vestTexture = carrierConfig.vestTexture
        end
    end
    
    return metadata
end, {
    itemFilter = {
        steel_plate = true,
        uhmwpe_plate = true,
        ceramic_plate = true,
        kevlar_plate = true,
        heavypc = true,
        lightpc = true,
        mediumpc = true,
    }
})

exports.ox_inventory:registerHook('swapItems', function(payload)
    local fromInv = payload.fromInventory
    local toInv = payload.toInventory
    local fromSlot = payload.fromSlot
    local toSlot = payload.toSlot
    local item = fromSlot
    local source = payload.source
    local action = payload.action
    
    if action ~= 'move' and action ~= 'swap' then return true end
    
    if type(toInv) == 'number' and toInv == source and toSlot == Config.ArmorSlot then
        if item and ContainerConfigs[item.name] then            
            if playerArmorData[source] then
                TriggerClientEvent('ox_lib:notify', source, {
                    type = 'error',
                    description = 'You already have a plate carrier equipped'
                })
                return false
            end
            
            SetTimeout(100, function()
                TriggerClientEvent('SJArmor:startEquipProgress', source, toSlot, item.metadata, item.name)
            end)
            
            return true  
        end
    end
    
    local movingFromArmorSlot = false
    if type(fromInv) == 'number' and fromInv == source then
        if type(fromSlot) == 'table' and fromSlot.slot == Config.ArmorSlot then
            movingFromArmorSlot = true
        elseif type(fromSlot) == 'number' and fromSlot == Config.ArmorSlot then
            movingFromArmorSlot = true
        end
    end
    
    if movingFromArmorSlot and item and ContainerConfigs[item.name] then
        if playerArmorData[source] and playerArmorData[source].stashId == item.metadata.stashId then
            if not playerArmorData[source].unequipInProgress then
                playerArmorData[source].unequipInProgress = true
                
        SetTimeout(100, function()
                    TriggerClientEvent('SJArmor:startUnequipProgress', source, Config.ArmorSlot, item.metadata, item.name)
                end)
                
                SetTimeout(5000, function()
                    if playerArmorData[source] then
                        playerArmorData[source].unequipInProgress = nil
                    end
                end)
            end
            
            return true
        end
    end
    
    return true
end, {
    itemFilter = {
        heavypc = true,
        lightpc = true,
        mediumpc = true,
    },
    typeFilter = {
        player = true,
        stash = true,
        drop = true,
        trunk = true,
        glovebox = true
    }
})


exports.ox_inventory:registerHook('swapItems', function(payload)
    local toInv = payload.toInventory
    local item = payload.fromSlot
    
    if type(toInv) == 'string' then
        local baseStashId = toInv:match('([^:]+)')
        if registeredStashes[baseStashId] then
            local allowedItems = {
                steel_plate = true,
                uhmwpe_plate = true,
                ceramic_plate = true,
                kevlar_plate = true
            }
            
            if item and not allowedItems[item.name] then
                return false 
            end
        end
    end
    
    return true 
end, {
    typeFilter = {
        player = true,
        stash = true
    }
})

exports.ox_inventory:registerHook('swapItems', function(payload)
    local fromInv = payload.fromInventory
    local toInv = payload.toInventory  
    local source = payload.source
    local action = payload.action
    local item = payload.fromSlot
    
    if action ~= 'move' and action ~= 'swap' then return true end
    
    if type(fromInv) == 'number' and fromInv == source and type(toInv) ~= 'number' then
        if item and ContainerConfigs[item.name] then
            if playerArmorData[source] and playerArmorData[source].stashId == item.metadata.stashId then
                if playerArmorData[source].unequipInProgress or equipInProgress[source] then
                    return true
                end
                
                SetTimeout(100, function()
                    if playerArmorData[source] and playerArmorData[source].stashId == item.metadata.stashId then
                        local playerInv = exports.ox_inventory:GetInventory(source)
                        local stillInPlayerInv = false
                        
                        if playerInv and playerInv.items then
                            for slot, playerItem in pairs(playerInv.items) do
                                if playerItem and playerItem.metadata and playerItem.metadata.stashId == item.metadata.stashId then
                                    stillInPlayerInv = true
                                    break
                                end
                            end
                        end
                        
                        if not stillInPlayerInv then
                            local prevComponent = nil
                            if playerArmorData[source] and playerArmorData[source].prevVestDrawable ~= nil then
                                prevComponent = {
                                    drawable = playerArmorData[source].prevVestDrawable,
                                    texture = playerArmorData[source].prevVestTexture or 0,
                                    palette = playerArmorData[source].prevVestPalette or 0
                                }
                            end
                            playerArmorData[source] = nil
                            TriggerClientEvent('SJArmor:forceUnequip', source, prevComponent)
                            TriggerClientEvent('ox_lib:notify', source, {
                                type = 'inform',
                                icon = 'shield-halved',
                                iconColor = 'orange',
                                description = 'Plate carrier unequipped - item moved to different inventory'
                            })
                        end
                    end
                end)
            end
        end
    end
    
    if type(fromInv) == 'number' and fromInv == source and type(toInv) == 'number' and toInv ~= source then
        if item and ContainerConfigs[item.name] then
            if playerArmorData[source] and playerArmorData[source].stashId == item.metadata.stashId then
                if playerArmorData[source].unequipInProgress or equipInProgress[source] then
                    return true
                end
                
                SetTimeout(100, function()
                    if playerArmorData[source] and playerArmorData[source].stashId == item.metadata.stashId then
                        local prevComponent = nil
                        if playerArmorData[source] and playerArmorData[source].prevVestDrawable ~= nil then
                            prevComponent = {
                                drawable = playerArmorData[source].prevVestDrawable,
                                texture = playerArmorData[source].prevVestTexture or 0,
                                palette = playerArmorData[source].prevVestPalette or 0
                            }
                        end
                        playerArmorData[source] = nil
                        TriggerClientEvent('SJArmor:forceUnequip', source, prevComponent)
                        TriggerClientEvent('ox_lib:notify', source, {
                            type = 'inform',
                            icon = 'shield-halved',
                            iconColor = 'orange',
                            description = 'Plate carrier unequipped - item given to another player'
                        })
                    end
                end)
            end
        end
    end
    
    if type(fromInv) == 'number' and fromInv == source and type(toInv) ~= 'number' then
        if item and ContainerConfigs[item.name] then
            if playerArmorData[source] and playerArmorData[source].stashId == item.metadata.stashId then
                if playerArmorData[source].unequipInProgress or equipInProgress[source] then
                    return true
                end
                
                SetTimeout(100, function()
                    if playerArmorData[source] and playerArmorData[source].stashId == item.metadata.stashId then
                        local prevComponent = nil
                        if playerArmorData[source] and playerArmorData[source].prevVestDrawable ~= nil then
                            prevComponent = {
                                drawable = playerArmorData[source].prevVestDrawable,
                                texture = playerArmorData[source].prevVestTexture or 0,
                                palette = playerArmorData[source].prevVestPalette or 0
                            }
                        end
                        playerArmorData[source] = nil
                        TriggerClientEvent('SJArmor:forceUnequip', source, prevComponent)
                        TriggerClientEvent('ox_lib:notify', source, {
                            type = 'inform',
                            icon = 'shield-halved',
                            iconColor = 'orange',
                            description = 'Plate carrier unequipped - moved to storage'
                        })
                    end
                end)
            end
        end
    end
    
    return true
end, {
    itemFilter = {
        heavypc = true,
        lightpc = true,
        mediumpc = true,
    },
    typeFilter = {
        player = true,
        stash = true,
        drop = true,
        trunk = true,
        glovebox = true
    }
})

exports.ox_inventory:registerHook('swapItems', function(payload)
    local fromInv = payload.fromInventory
    local toInv = payload.toInventory  
    local source = payload.source
    local action = payload.action
    local item = payload.fromSlot
    
    if action ~= 'move' and action ~= 'swap' then return true end
    
    local stashId = nil
    
    if type(toInv) == 'string' then
        local baseStashId = toInv:match('([^:]+)')
        
        if registeredStashes[baseStashId] then
            stashId = baseStashId
        elseif baseStashId then
            local carrierType = nil
            for configName, config in pairs(ContainerConfigs) do
                if baseStashId:match('^' .. config.stashPrefix) then
                    carrierType = configName
                    break
                end
            end
            
            if carrierType then
                local playerInv = exports.ox_inventory:GetInventory(source)
                local owner = playerInv and playerInv.owner
                
                registeredStashes[baseStashId] = {
                    owner = owner,
                    type = carrierType,
                    created = os.time()
                }
                
                stashId = baseStashId
            end
        end
    end
    
    if type(fromInv) == 'string' then
        local baseStashId = fromInv:match('([^:]+)')
        
        if registeredStashes[baseStashId] then
            stashId = baseStashId
        elseif baseStashId then
            local carrierType = nil
            for configName, config in pairs(ContainerConfigs) do
                if baseStashId:match('^' .. config.stashPrefix) then
                    carrierType = configName
                    break
                end
            end
            
            if carrierType then
                local playerInv = exports.ox_inventory:GetInventory(source)
                local owner = playerInv and playerInv.owner
                
                registeredStashes[baseStashId] = {
                    owner = owner,
                    type = carrierType,
                    created = os.time()
                }
                
                stashId = baseStashId
            end
        end
    end
    
    if stashId then
        SetTimeout(200, function()
            
            local function findPlateCarrierInInventory(invItems, invId, isPlayerInv)
                if not invItems then return nil end
                
                for slot, item in pairs(invItems) do
                    if item and item.metadata and item.metadata.stashId == stashId then
                        
                        if isPlayerInv then
                            updatePlateCarrierWeight(source, slot, stashId)
                            
                            if playerArmorData[source] and playerArmorData[source].stashId == stashId then
                                
                                local stashInv = exports.ox_inventory:GetInventory(stashId, false)
                                if stashInv then
                                    local newVirtualArmor, newPlateCount = calculateVirtualArmor(stashInv)
                                    local oldVirtualArmor = playerArmorData[source].virtualArmor
                                    
                                    local lastPlateDurability = 100
                                    if newPlateCount == 1 then
                                        for slot, item in pairs(stashInv.items) do
                                            if item and Config.Plates[item.name] then
                                                local durability = 100
                                                if item.metadata and item.metadata.plateDurability ~= nil then
                                                    durability = item.metadata.plateDurability
                                                elseif item.metadata and item.metadata.durability ~= nil then
                                                    durability = item.metadata.durability
                                                end
                                                if durability > 0 then
                                                    lastPlateDurability = durability
                                                break
                                                end
                                            end
                                        end
                                    end
                                    
                                    playerArmorData[source].virtualArmor = newVirtualArmor
                                    playerArmorData[source].plateCount = newPlateCount
                                    playerArmorData[source].lastPlateDurability = lastPlateDurability
                                    
                                    local targetArmor = 0
                                    if newVirtualArmor > 0 then
                                        if newPlateCount > 1 then
                                            targetArmor = 100
                                        else
                                            targetArmor = math.floor(lastPlateDurability)
                                        end
                                    end
                                    
                                    if oldVirtualArmor <= 0 and newVirtualArmor > 0 then
                                        TriggerClientEvent('SJArmor:equipArmorResponse', source, true, playerArmorData[source], ('Armor restored! %d plates (%d virtual armor)'):format(newPlateCount, newVirtualArmor), targetArmor)
                                    else
                                        TriggerClientEvent('SJArmor:updateArmor', source, playerArmorData[source], targetArmor)
                                    end
                                end
                            end
                        else
                            local plateStashInv = exports.ox_inventory:GetInventory(stashId, false)
                            if plateStashInv then
                                                            local carrierConfig = ContainerConfigs[item.name]
                                if carrierConfig then
                                    local newWeight = calculatePlateWeight(plateStashInv, carrierConfig.baseWeight)
                                    
                                    local updatedMetadata = {}
                                    if item.metadata then
                                        for key, value in pairs(item.metadata) do
                                            updatedMetadata[key] = value
                                        end
                                    end
                                    updatedMetadata.weight = newWeight
                                    
                                    exports.ox_inventory:SetMetadata(invId, slot, updatedMetadata)
                                end
                            end
                        end
                        return true
                    end
                end
                return nil
            end
            
            local playerItems = exports.ox_inventory:GetInventoryItems(source)
            if findPlateCarrierInInventory(playerItems, source, true) then
                return 
            end
            
            local playerInv = exports.ox_inventory:GetInventory(source)
            if playerInv and playerInv.items and playerInv.items[31] then
                local backpackItem = playerInv.items[31]
                if backpackItem and backpackItem.metadata and backpackItem.metadata.stashId then
                    local backpackStashInv = exports.ox_inventory:GetInventory(backpackItem.metadata.stashId, false)
                    if backpackStashInv and backpackStashInv.items then
                        if findPlateCarrierInInventory(backpackStashInv.items, backpackItem.metadata.stashId, false) then
                            return 
                        end
                    end
                end
            end
            
        end)
    end
    
    return true
end, {
    itemFilter = {
        steel_plate = true,
        uhmwpe_plate = true,
        ceramic_plate = true,
        kevlar_plate = true
    },
    typeFilter = {
        player = true,
        stash = true
    }
})

function fixPlateCarrierStash(source, slot, carrierType)
    local playerInv = exports.ox_inventory:GetInventory(source)
    if not playerInv or not playerInv.items or not playerInv.items[slot] then
        return false, nil
    end
    
    local carrierItem = playerInv.items[slot]
    local carrierConfig = ContainerConfigs[carrierType]
    
    if not carrierConfig then
        return false, nil
    end
    
    local stashId = carrierConfig.stashPrefix .. '_' .. os.time() .. '_' .. math.random(10000, 99999)
    
    local success = pcall(function()
        exports.ox_inventory:RegisterStash(stashId, carrierConfig.label, carrierConfig.plateSlots, 50000, false, false)
    end)
    
    if not success then
        return false, nil
    end
    
    local newMetadata = {}
    if carrierItem.metadata then
        for k, v in pairs(carrierItem.metadata) do
            newMetadata[k] = v
        end
    end
    newMetadata.stashId = stashId
    newMetadata.weight = carrierConfig.baseWeight
    
    local setSuccess = exports.ox_inventory:SetMetadata(source, slot, newMetadata)
    
    if setSuccess then
        registeredStashes[stashId] = {
            owner = false,
            type = carrierType,
            created = os.time()
        }
        
        return true, stashId
    end
    
    return false, nil
end

RegisterNetEvent('SJArmor:equipPlateCarrier', function(slot, carrierType, prevDrawable, prevTexture, prevPalette)
    local source = source
    
    equipInProgress[source] = true
    
    local playerInv = exports.ox_inventory:GetInventory(source)
    
    if not playerInv or not playerInv.items[slot] then
        equipInProgress[source] = nil
        TriggerClientEvent('SJArmor:equipArmorResponse', source, false, nil, 'Invalid plate carrier')
        return
    end
    
    local carrierItem = playerInv.items[slot]
    local metadata = carrierItem.metadata or {}
    
    if not metadata.stashId then
        local success, newStashId = fixPlateCarrierStash(source, slot, carrierType)
        if success then
            metadata.stashId = newStashId
            TriggerClientEvent('ox_lib:notify', source, {
                type = 'success',
                description = 'Plate carrier storage fixed! You can now equip it.'
            })
            local updatedItem = exports.ox_inventory:GetSlot(source, slot)
            if updatedItem and updatedItem.metadata then
                metadata = updatedItem.metadata
            end
        else
            equipInProgress[source] = nil
            TriggerClientEvent('SJArmor:equipArmorResponse', source, false, nil, 'Failed to fix plate carrier storage')
            return
        end
    end
    
    if playerArmorData[source] then
        equipInProgress[source] = nil
        TriggerClientEvent('SJArmor:equipArmorResponse', source, false, nil, 'You already have a plate carrier equipped')
        return
    end
    
    local stashInv = exports.ox_inventory:GetInventory(metadata.stashId, false)
    if not stashInv then
        local carrierConfig = ContainerConfigs[carrierType]
        if carrierConfig then
            local owner = playerInv.owner
            
            local success = pcall(function()
                exports.ox_inventory:RegisterStash(metadata.stashId, carrierConfig.label, carrierConfig.plateSlots, 50000, owner, false)
            end)
            
            if success then
                registeredStashes[metadata.stashId] = {
                    owner = owner,
                    type = carrierType,
                    created = os.time()
                }
                
                stashInv = exports.ox_inventory:GetInventory(metadata.stashId, false)
            end
        end
        
    if not stashInv then
        TriggerClientEvent('SJArmor:equipArmorResponse', source, false, nil, 'Unable to access plate carrier storage')
        return
        end
    end
    
    local virtualArmor, plateCount = calculateVirtualArmor(stashInv)
    
    local lastPlateDurability = 100
    if plateCount == 1 then
        for slotNum, item in pairs(stashInv.items) do
            if item and Config.Plates[item.name] then
                local durability = 100
                if item.metadata and item.metadata.plateDurability ~= nil then
                    durability = item.metadata.plateDurability
                elseif item.metadata and item.metadata.durability ~= nil then
                    durability = item.metadata.durability
                end
                if durability > 0 then
                    lastPlateDurability = durability
                break
                end
            end
        end
    end
    
    local updatedMetadata = {}
    if carrierItem.metadata then
        for key, value in pairs(carrierItem.metadata) do
            updatedMetadata[key] = value
        end
    end
    updatedMetadata.equipped = true 
    updatedMetadata.unequipped = nil 
    if prevDrawable ~= nil then
        updatedMetadata.prevVestDrawable = prevDrawable
        updatedMetadata.prevVestTexture = prevTexture or 0
        updatedMetadata.prevVestPalette = prevPalette or 0
    end
    exports.ox_inventory:SetMetadata(source, slot, updatedMetadata)
    
    local carrierConfig = ContainerConfigs[carrierType]
    playerArmorData[source] = {
        stashId = metadata.stashId,
        carrierType = carrierType,
        carrierSlot = slot,
        virtualArmor = virtualArmor,
        plateCount = plateCount,
        lastPlateDurability = lastPlateDurability,
        equippedAt = os.time(),
        vestDrawable = (carrierItem.metadata and carrierItem.metadata.vestDrawable)
            or (carrierConfig and carrierConfig.vestDrawable),
        vestTexture = (carrierItem.metadata and carrierItem.metadata.vestTexture)
            or (carrierConfig and carrierConfig.vestTexture),
        prevVestDrawable = prevDrawable,
        prevVestTexture = prevTexture,
        prevVestPalette = prevPalette
    }
    
    local targetArmor = 0
    if virtualArmor > 0 then
        if plateCount > 1 then
            targetArmor = 100
        else
            targetArmor = math.floor(lastPlateDurability)
        end
    end
    
    local message = ('Plate carrier equipped with %d plates (%d virtual armor)'):format(plateCount, virtualArmor)
    
    equipInProgress[source] = nil
    
    TriggerClientEvent('SJArmor:equipArmorResponse', source, true, playerArmorData[source], message, targetArmor)
end)

RegisterNetEvent('SJArmor:equipPlateCarrierFromSlot', function(targetSlot, metadata, carrierType)
    local source = source
    
    equipInProgress[source] = true
    
    if playerArmorData[source] then
        equipInProgress[source] = nil
        TriggerClientEvent('SJArmor:equipArmorResponse', source, false, nil, 'You already have a plate carrier equipped')
        return
    end
    
    if targetSlot ~= Config.ArmorSlot then
        equipInProgress[source] = nil
        TriggerClientEvent('SJArmor:equipArmorResponse', source, false, nil, 'Invalid armor slot')
        return
    end
    
    if not metadata or not metadata.stashId then
        equipInProgress[source] = nil
        TriggerClientEvent('SJArmor:equipArmorResponse', source, false, nil, 'Plate carrier has no storage')
        return
    end
    
    local stashInv = exports.ox_inventory:GetInventory(metadata.stashId, false)
    if not stashInv then
        
        local carrierConfig = ContainerConfigs[carrierType]
        if carrierConfig then
            local playerInv = exports.ox_inventory:GetInventory(source)
            local owner = playerInv and playerInv.owner
            
            local success = pcall(function()
                exports.ox_inventory:RegisterStash(metadata.stashId, carrierConfig.label, carrierConfig.plateSlots, 50000, owner, false)
            end)
            
            if success then
                registeredStashes[metadata.stashId] = {
                    owner = owner,
                    type = carrierType,
                    created = os.time()
                }
                
                stashInv = exports.ox_inventory:GetInventory(metadata.stashId, false)
            end
        end
        
        if not stashInv then
            equipInProgress[source] = nil
            TriggerClientEvent('SJArmor:equipArmorResponse', source, false, nil, 'Unable to access plate carrier storage')
            return
        end
    end
    
    local virtualArmor, plateCount = calculateVirtualArmor(stashInv)
    
    local lastPlateDurability = 100
    if plateCount == 1 then
        for slotNum, item in pairs(stashInv.items) do
            if item and Config.Plates[item.name] then
                local durability = 100
                if item.metadata and item.metadata.plateDurability ~= nil then
                    durability = item.metadata.plateDurability
                elseif item.metadata and item.metadata.durability ~= nil then
                    durability = item.metadata.durability
                end
                if durability > 0 then
                    lastPlateDurability = durability
                break
                end
            end
        end
    end
    
    local playerInv = exports.ox_inventory:GetInventory(source)
    if playerInv and playerInv.items[targetSlot] then
        local item = playerInv.items[targetSlot]
        local updatedMetadata = {}
        if item.metadata then
            for key, value in pairs(item.metadata) do
                updatedMetadata[key] = value
            end
        end
        updatedMetadata.equipped = true 
        updatedMetadata.unequipped = nil 
        if metadata and metadata.prevVestDrawable ~= nil then
            updatedMetadata.prevVestDrawable = metadata.prevVestDrawable
            updatedMetadata.prevVestTexture = metadata.prevVestTexture or 0
            updatedMetadata.prevVestPalette = metadata.prevVestPalette or 0
        end
        exports.ox_inventory:SetMetadata(source, targetSlot, updatedMetadata)
    end
    
    local carrierConfig = ContainerConfigs[carrierType]
    playerArmorData[source] = {
        stashId = metadata.stashId,
        carrierType = carrierType,
        carrierSlot = targetSlot,
        virtualArmor = virtualArmor,
        plateCount = plateCount,
        lastPlateDurability = lastPlateDurability,
        equippedAt = os.time(),
        vestDrawable = (metadata and metadata.vestDrawable)
            or (carrierConfig and carrierConfig.vestDrawable),
        vestTexture = (metadata and metadata.vestTexture)
            or (carrierConfig and carrierConfig.vestTexture),
        prevVestDrawable = metadata and metadata.prevVestDrawable,
        prevVestTexture = metadata and metadata.prevVestTexture,
        prevVestPalette = metadata and metadata.prevVestPalette
    }
    
    local targetArmor = 0
    if virtualArmor > 0 then
        if plateCount > 1 then
            targetArmor = 100
        else
            targetArmor = math.floor(lastPlateDurability)
        end
    end
    
    local message = ('Plate carrier equipped with %d plates (%d virtual armor)'):format(plateCount, virtualArmor)
    
    equipInProgress[source] = nil
    
    TriggerClientEvent('SJArmor:equipArmorResponse', source, true, playerArmorData[source], message, targetArmor)
end)

RegisterNetEvent('SJArmor:unequipPlateCarrier', function()
    local source = source
    
    if not playerArmorData[source] then
        TriggerClientEvent('SJArmor:unequipArmorResponse', source, false, 'No plate carrier equipped')
        return
    end
    
    local armorData = playerArmorData[source]
    armorData.unequipInProgress = true
    
    local stashInv = exports.ox_inventory:GetInventory(armorData.stashId, false)
    
    if stashInv then
        for slot, item in pairs(stashInv.items) do
            if item and Config.Plates[item.name] and item.metadata.durability then
                exports.ox_inventory:SetMetadata(armorData.stashId, slot, item.metadata)
            end
        end
    end
    
    local playerInv = exports.ox_inventory:GetInventory(source)
    if playerInv and playerInv.items[armorData.carrierSlot] then
        local item = playerInv.items[armorData.carrierSlot]
        local metadata = item.metadata or {}
        metadata.equipped = false 
        metadata.unequipped = true 
        exports.ox_inventory:SetMetadata(source, armorData.carrierSlot, metadata)
    end
    
    local prevComponent = nil
    if armorData.prevVestDrawable ~= nil then
        prevComponent = {
            drawable = armorData.prevVestDrawable,
            texture = armorData.prevVestTexture or 0,
            palette = armorData.prevVestPalette or 0
        }
    end
    playerArmorData[source] = nil
    
    TriggerClientEvent('SJArmor:unequipArmorResponse', source, true, 'Plate carrier removed', 0, prevComponent)
end)

RegisterNetEvent('SJArmor:cancelEquip', function(slot)
    local source = source
    playerArmorData[source] = nil
end)

RegisterNetEvent('SJArmor:cancelEquipAndMoveBack', function(targetSlot, metadata, carrierType)
    local source = source
    playerArmorData[source] = nil
    
    local playerInv = exports.ox_inventory:GetInventory(source)
    if playerInv and playerInv.items[targetSlot] then
        local item = playerInv.items[targetSlot]
        
        if item and item.metadata and item.metadata.stashId == metadata.stashId then
            for slot = 1, playerInv.slots do
                if slot ~= Config.ArmorSlot and not playerInv.items[slot] then
                    local success = exports.ox_inventory:SwapSlots(playerInv, playerInv, targetSlot, slot)
                    if success then
                    else
                    end
                    break
                end
            end
        end
    end
end)

RegisterNetEvent('SJArmor:cancelUnequipAndMoveBack', function(originalSlot, metadata, carrierType)
    local source = source
    
    local playerInv = exports.ox_inventory:GetInventory(source)
    if playerInv and playerInv.items then
        for slot, item in pairs(playerInv.items) do
            if item and item.metadata and item.metadata.stashId == metadata.stashId then
                if slot ~= originalSlot then
                    local success = exports.ox_inventory:SwapSlots(playerInv, playerInv, slot, originalSlot)
                    if success then
                    else
                    end
                end
                break
            end
        end
    end
end)

RegisterNetEvent('SJArmor:armorDamaged', function(damageAmount)
    local source = source
    local armorData = playerArmorData[source]
    
    if not armorData then return end
        
    local stashInv = exports.ox_inventory:GetInventory(armorData.stashId, false)
    if not stashInv then return end
    
    local plateToBreak = getNextPlateToBreak(stashInv)
    if not plateToBreak then 
        return 
    end
    
    local remainingDamage = damageAmount
    local brokenPlates = {}
    
    while remainingDamage > 0 do
        local currentPlate = getNextPlateToBreak(stashInv)
        if not currentPlate then 
            break 
        end
        
        local maxDurability = currentPlate.config.durability or 100
        local durabilityLoss = remainingDamage * Config.DamageSettings.durabilityLossPerDamage / (maxDurability / 100)
        
        local currentDurabilityPercent = 100
        if currentPlate.item.metadata and currentPlate.item.metadata.plateDurability ~= nil then
            currentDurabilityPercent = currentPlate.item.metadata.plateDurability
        elseif currentPlate.item.metadata and currentPlate.item.metadata.durability ~= nil then
            currentDurabilityPercent = currentPlate.item.metadata.durability
        end
        
        local newDurabilityPercent = currentDurabilityPercent - durabilityLoss
        
        if newDurabilityPercent <= 0 then
            local damageAbsorbed = currentDurabilityPercent / (Config.DamageSettings.durabilityLossPerDamage / (maxDurability / 100))
            remainingDamage = remainingDamage - damageAbsorbed
            
            local brokenItemName = currentPlate.config.brokenItem
            local brokenMetadata = {
                originalPlate = currentPlate.item.name,
                originalWeight = currentPlate.config.weight,
                weight = currentPlate.config.weight
            }
            
            local removeSuccess = exports.ox_inventory:RemoveItem(armorData.stashId, currentPlate.item.name, 1, nil, currentPlate.slot)
            if removeSuccess then
                exports.ox_inventory:AddItem(armorData.stashId, brokenItemName, 1, brokenMetadata, currentPlate.slot)
            end
            
            table.insert(brokenPlates, {
                label = Config.Plates[currentPlate.item.name].label,
                broken = true
            })
            
            stashInv = exports.ox_inventory:GetInventory(armorData.stashId, false)
        else
            local finalDurabilityPercent = math.max(0, newDurabilityPercent)
            currentPlate.item.metadata.plateDurability = finalDurabilityPercent
            currentPlate.item.metadata.durability = finalDurabilityPercent
            exports.ox_inventory:SetMetadata(armorData.stashId, currentPlate.slot, currentPlate.item.metadata)
            exports.ox_inventory:SetDurability(armorData.stashId, currentPlate.slot, math.floor(finalDurabilityPercent))
            
            remainingDamage = 0 
        end
    end
    

    
    local newVirtualArmor, newPlateCount = calculateVirtualArmor(stashInv)
    armorData.virtualArmor = newVirtualArmor
    armorData.plateCount = newPlateCount
    
    local lastPlateDurability = 100
    if newPlateCount == 1 then
        for slot, item in pairs(stashInv.items) do
            if item and Config.Plates[item.name] then
                local durability = 100
                if item.metadata and item.metadata.plateDurability ~= nil then
                    durability = item.metadata.plateDurability
                elseif item.metadata and item.metadata.durability ~= nil then
                    durability = item.metadata.durability
                end
                if durability > 0 then
                    lastPlateDurability = durability
                break
                end
            end
        end
    end
    armorData.lastPlateDurability = lastPlateDurability
    
    for _, plateBroken in ipairs(brokenPlates) do
        if newVirtualArmor <= 0 then
            TriggerClientEvent('SJArmor:allPlatesBroken', source)
            break 
        else
            TriggerClientEvent('SJArmor:plateBroken', source, plateBroken.label)
        end
    end
    
    local targetArmor = 0
    if newVirtualArmor > 0 then
        if newPlateCount > 1 then
            targetArmor = 100
        elseif newPlateCount == 1 then
            targetArmor = math.floor(lastPlateDurability)
        else
            targetArmor = 0
        end
    end
    
    
    TriggerClientEvent('SJArmor:updateArmor', source, armorData, targetArmor)
    
    updatePlateCarrierWeight(source, armorData.carrierSlot, armorData.stashId)
end)

AddEventHandler('playerDropped', function(reason)
    local source = source
    if playerArmorData[source] then
        playerArmorData[source] = nil
    end
end)

local function restorePlayerArmor(playerId, eventType)
    eventType = eventType or "join"
    
    if playerArmorData[playerId] then
        return
    end
    
    if equipInProgress[playerId] then
        return
    end
    
    local playerInv = exports.ox_inventory:GetInventory(playerId)
    if not playerInv or not playerInv.items then
        return
    end
    
                for slot, item in pairs(playerInv.items) do
                    if item and ContainerConfigs[item.name] and item.metadata and item.metadata.stashId then
                        
                        local stashInv = exports.ox_inventory:GetInventory(item.metadata.stashId, false)
                        if stashInv then
                            local virtualArmor, plateCount = calculateVirtualArmor(stashInv)
                
                local shouldRestore = false
                if item.metadata.equipped then
                    if Config.UseDragAndDrop then
                        shouldRestore = (slot == Config.ArmorSlot)
                    else
                        shouldRestore = true
                    end
                end
                            
                            if shouldRestore then
                                local lastPlateDurability = 100
                                if plateCount == 1 then
                                    for slotNum, stashItem in pairs(stashInv.items) do
                            if stashItem and Config.Plates[stashItem.name] then
                                local durability = 100
                                if stashItem.metadata and stashItem.metadata.plateDurability ~= nil then
                                    durability = stashItem.metadata.plateDurability
                                elseif stashItem.metadata and stashItem.metadata.durability ~= nil then
                                    durability = stashItem.metadata.durability
                                end
                                if durability > 0 then
                                    lastPlateDurability = durability
                                            break
                                end
                                        end
                                    end
                                end
                                
                                local carrierConfig = ContainerConfigs[item.name]
                    playerArmorData[playerId] = {
                                    stashId = item.metadata.stashId,
                                    carrierType = item.name,
                                    carrierSlot = slot,
                                    virtualArmor = virtualArmor,
                                    plateCount = plateCount,
                                    lastPlateDurability = lastPlateDurability,
                                    equippedAt = os.time(),
                                    vestDrawable = (item.metadata and item.metadata.vestDrawable)
                                        or (carrierConfig and carrierConfig.vestDrawable),
                                    vestTexture = (item.metadata and item.metadata.vestTexture)
                                        or (carrierConfig and carrierConfig.vestTexture),
                                    prevVestDrawable = item.metadata and item.metadata.prevVestDrawable,
                                    prevVestTexture = item.metadata and item.metadata.prevVestTexture,
                                    prevVestPalette = item.metadata and item.metadata.prevVestPalette
                                }
                                
                                local targetArmor = 0
                                if virtualArmor > 0 then
                                    if plateCount > 1 then
                                        targetArmor = 100
                                    else
                                        targetArmor = math.floor(lastPlateDurability)
                                    end
                                end
                                
                                local message = virtualArmor > 0 
                        and (eventType == "startup" and 'Plate carrier restored! %d plates (%d virtual armor)' or 'Welcome back! Plate carrier restored: %d plates (%d virtual armor)'):format(plateCount, virtualArmor)
                        or (eventType == "startup" and 'Empty plate carrier restored - add plates to activate armor' or 'Welcome back! Empty plate carrier restored - add plates to activate armor')
                    
                    TriggerClientEvent('SJArmor:equipArmorResponse', playerId, true, playerArmorData[playerId], message, targetArmor)
                    
                    if playerArmorData[playerId].vestDrawable then
                        SetTimeout(1000, function()
                            TriggerClientEvent('SJArmor:forceVestUpdate', playerId, playerArmorData[playerId].vestDrawable, playerArmorData[playerId].vestTexture or 0)
                        end)
                    end
                    
                    return true 
                        end
                    end
                end
            end
    
    return false 
end

RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
    local source = source
    SetTimeout(500, function()
        restorePlayerArmor(source, "qbcore_onplayerloaded")
    end)
end)

AddEventHandler('playerSpawned', function()
    local source = source
    SetTimeout(2000, function()
        restorePlayerArmor(source, "spawned")
    end)
end)

exports.ox_inventory:registerHook('swapItems', function(payload)
    local fromInv = payload.fromInventory
    local toInv = payload.toInventory
    local toSlot = payload.toSlot
    local source = payload.source
    local action = payload.action
    local item = payload.fromSlot
    
    if action ~= 'move' and action ~= 'swap' then return true end
    
    if type(toInv) == 'number' and toInv == source and toSlot ~= Config.ArmorSlot and 
       item and ContainerConfigs[item.name] and item.metadata and item.metadata.equipped then
        
        if equipInProgress[source] then
            return true
        end
        
        if not Config.UseDragAndDrop then
        else
            return true
        end
        
        SetTimeout(100, function()
            if equipInProgress[source] then
                return
            end
            
            local playerInv = exports.ox_inventory:GetInventory(source)
            if playerInv and playerInv.items and playerInv.items[toSlot] then
                local movedItem = playerInv.items[toSlot]
                if movedItem.metadata and movedItem.metadata.stashId == item.metadata.stashId then
                    local updatedMetadata = {}
                    for k, v in pairs(movedItem.metadata) do updatedMetadata[k] = v end
                    updatedMetadata.equipped = false
                    updatedMetadata.unequipped = true
                    exports.ox_inventory:SetMetadata(source, toSlot, updatedMetadata)
                    
                    if playerArmorData[source] and playerArmorData[source].stashId == movedItem.metadata.stashId then
                        playerArmorData[source] = nil
                        TriggerClientEvent('SJArmor:forceUnequip', source)
                            end
                        end
                    end
        end)
    end
    
    return true
end)

local function detectEquippedCarriers()
    local players = GetPlayers()    
    for _, playerId in ipairs(players) do
        local playerIdNum = tonumber(playerId)
        restorePlayerArmor(playerIdNum, "startup")
    end
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        SetTimeout(2000, function()
            detectEquippedCarriers()
        end)
        
        CreateThread(function()
            while true do
                Wait(30000) 
                
                for playerId, armorData in pairs(playerArmorData) do
                    local playerPed = GetPlayerPed(playerId)
                    if not DoesEntityExist(playerPed) then
                        playerArmorData[playerId] = nil
                    end
                end
            end
        end)
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        playerArmorData = {}
    end
end)

RegisterNetEvent('SJArmor:openPlateCarrier', function(slot, carrierType)
    local source = source
    local playerInv = exports.ox_inventory:GetInventory(source)
    
    if not playerInv or not playerInv.items[slot] then
        TriggerClientEvent('ox_lib:notify', source, {
            type = 'error',
            description = 'No item found in slot'
        })
        return
    end
    
    local carrierItem = playerInv.items[slot]
    local metadata = carrierItem.metadata or {}
    local stashId = metadata.stashId
    
    if not stashId then
        local success, newStashId = fixPlateCarrierStash(source, slot, carrierType)
        if success then
            stashId = newStashId
            TriggerClientEvent('ox_lib:notify', source, {
                type = 'success',
                description = 'Plate carrier storage fixed! Opening...'
            })
        else
            TriggerClientEvent('ox_lib:notify', source, {
                type = 'error',
                description = 'Failed to fix plate carrier storage'
            })
            return
        end
    end
    
    local playerInv = exports.ox_inventory:GetInventory(source)
    local currentOwner = playerInv and playerInv.owner
    
    local function tryOpenStash()
        local existingStash = exports.ox_inventory:GetInventory(stashId, false)
        if existingStash then
            TriggerClientEvent('ox_inventory:openInventory', source, 'stash', stashId)
            return true
        end
        
        local stashData = registeredStashes[stashId]
        local carrierConfig = nil
        
        if stashData then
            carrierConfig = ContainerConfigs[stashData.type]
        else
            carrierConfig = ContainerConfigs[carrierType]
            if carrierConfig then
                registeredStashes[stashId] = {
                    owner = false,
                    type = carrierType,
                    created = os.time()
                }
            end
        end
        
        if not carrierConfig then
            TriggerClientEvent('ox_lib:notify', source, {
                type = 'error',
                description = 'Unable to open plate carrier storage'
            })
            return false
        end
        
        local registerSuccess = pcall(function()
            exports.ox_inventory:RegisterStash(stashId, carrierConfig.label, carrierConfig.plateSlots, 50000, false, false)
        end)
        
        if registerSuccess then
            if registeredStashes[stashId] then
                registeredStashes[stashId].owner = false
            end
            
            TriggerClientEvent('ox_inventory:openInventory', source, 'stash', stashId)
            return true
        else
            TriggerClientEvent('ox_lib:notify', source, {
                type = 'error',
                description = 'Failed to access plate carrier storage'
            })
            return false
        end
    end
    
    if not tryOpenStash() then
        SetTimeout(100, function()
            if not tryOpenStash() then
                TriggerClientEvent('ox_lib:notify', source, {
                    type = 'error',
                    description = 'Unable to access plate carrier storage. Try closing and reopening the inventory.'
                })
            end
        end)
    end
end)

exports('getPlayerArmorData', function(playerId)
    return playerArmorData[playerId]
end)

exports('setPlayerVirtualArmor', function(playerId, amount)
    if playerArmorData[playerId] then
        playerArmorData[playerId].virtualArmor = amount
        TriggerClientEvent('SJArmor:updateArmor', playerId, playerArmorData[playerId])
        return true
    end
    return false
end)

exports('getRegisteredStashes', function()
    return registeredStashes
end)

exports('GetContainerConfig', function(itemName)
    return ContainerConfigs[itemName]
end)

exports('RegisterPlateCarrierStash', function(stashId, carrierType, owner)
    
    if registeredStashes[stashId] then
        return true
    end
    
    registeredStashes[stashId] = {
        owner = owner,
        type = carrierType,
        created = os.time()
    }
    
    local count = 0
    for id, data in pairs(registeredStashes) do
        count = count + 1
    end
    
    return true
end)

lib.callback.register('SJArmor:checkStashExists', function(source, stashId)
    
    local isRegistered = registeredStashes[stashId] ~= nil
    
    local oxInventory = exports.ox_inventory:GetInventory(stashId, false)
    local existsInOx = oxInventory ~= nil

    return {
        registered = isRegistered,
        existsInOx = existsInOx,
        details = oxInventory and {
            type = oxInventory.type,
            slots = oxInventory.slots,
            maxWeight = oxInventory.maxWeight,
            itemCount = oxInventory.items and #oxInventory.items or 0
        } or nil
    }
end)

local function countActivePlates(stashInv)
    if not stashInv or not stashInv.items then return 0 end
    local count = 0
    for _, itm in pairs(stashInv.items) do
        if itm and Config.Plates[itm.name] then
            local d = 100
            if itm.metadata and itm.metadata.plateDurability ~= nil then
                d = itm.metadata.plateDurability
            elseif itm.metadata and itm.metadata.durability ~= nil then
                d = itm.metadata.durability
            end
            if d > 0 then count = count + 1 end
        end
    end
    return count
end

local function getInstallParamsForPlate(plateName)
    local cfg = Config.PlateInstall or {}
    if cfg.enabled == false then return nil end

    local base = clone(cfg)
    base.perPlate = nil

    local per = (cfg.perPlate and cfg.perPlate[plateName]) or {}
    local params = deepMerge(base, per)

    if Config.Plates[plateName] and Config.Plates[plateName].label then
        params.label = ("Installing %s"):format(Config.Plates[plateName].label)
    end

    return params
end

exports('useArmorPlate', function(event, item, inventory, slot, data)
    local src = inventory.id
    if plateInstallBusy[src] then
        lib.notify(src, { type = 'inform', description = 'You are already installing a plate.' })
        return false
    end

    local actualItem = exports.ox_inventory:GetSlot(src, slot)
    if not actualItem then
        lib.notify(src, { type = 'error', description = 'Item not found in inventory.' })
        return false
    end
    
    local armorData = playerArmorData[src]

    if not armorData then
        lib.notify(src, { type = 'error', description = 'You need to equip a plate carrier first.' })
        return false
    end
    
    local playerInv = exports.ox_inventory:GetInventory(src)
    if not playerInv or not playerInv.items or not playerInv.items[armorData.carrierSlot] then
        playerArmorData[src] = nil 
        lib.notify(src, { type = 'error', description = 'Plate carrier is no longer equipped.' })
        return false
    end
    
    local carrierItem = playerInv.items[armorData.carrierSlot]
    if not carrierItem or not ContainerConfigs[carrierItem.name] or 
       not carrierItem.metadata or carrierItem.metadata.stashId ~= armorData.stashId then
        playerArmorData[src] = nil 
        lib.notify(src, { type = 'error', description = 'Plate carrier is no longer valid.' })
        return false
    end

    local carrierType = armorData.carrierType
    local carrierCfg = ContainerConfigs[carrierType]
    if not carrierCfg then
        lib.notify(src, { type = 'error', description = 'Invalid plate carrier.' })
        return false
    end

    if not Config.Plates[item.name] then
        lib.notify(src, { type = 'error', description = 'That item is not a plate.' })
        return false
    end

    local allowed = false
    for _, v in ipairs(carrierCfg.whitelist or {}) do
        if v == item.name then allowed = true break end
    end
    if not allowed then
        lib.notify(src, { type = 'error', description = 'This plate type doesn\'t fit your carrier.' })
        return false
    end

    local stashId = armorData.stashId
    local stashInv = exports.ox_inventory:GetInventory(stashId, false)
    if not stashInv then
        lib.notify(src, { type = 'error', description = 'Carrier storage not found.' })
        return false
    end

    local used = countActivePlates(stashInv)
    if used >= (carrierCfg.plateSlots or 0) then
        lib.notify(src, { type = 'error', description = 'Your carrier is full.' })
        return false
    end

    plateInstallBusy[src] = true

    local function finish()
        plateInstallBusy[src] = nil
    end

    local function fail(msg, ntype)
        ntype = ntype or 'error'
        local restoreMetadata = actualItem.metadata or item.metadata
        exports.ox_inventory:AddItem(src, actualItem.name, 1, restoreMetadata)
        finish()
        return lib.notify(src, { type = ntype, description = msg })
    end

    local durability = 100
    if actualItem.metadata and actualItem.metadata.plateDurability ~= nil then
        durability = actualItem.metadata.plateDurability
    elseif actualItem.metadata and actualItem.metadata.durability ~= nil then
        durability = actualItem.metadata.durability
    elseif actualItem.metadata and actualItem.metadata.degrade ~= nil then
        durability = actualItem.metadata.degrade
    elseif actualItem.durability ~= nil then
        durability = actualItem.durability
    elseif item.metadata and item.metadata.plateDurability ~= nil then
        durability = item.metadata.plateDurability
    elseif item.metadata and item.metadata.durability ~= nil then
        durability = item.metadata.durability
    elseif item.metadata and item.metadata.degrade ~= nil then
        durability = item.metadata.degrade
    elseif item.durability ~= nil then
        durability = item.durability
    else
    end
    durability = math.max(0, math.min(100, math.floor(tonumber(durability) or 100)))
    
    if durability <= 0 then
        return fail('This plate is broken.')
    end

    local params = getInstallParamsForPlate(item.name)
    if params then
        local ok = lib.callback.await('SJArmor:plateInstallProgress', src, params)
        if not ok then
            return fail('Plate install cancelled.', 'inform')
        end
    end

    local newMeta = {}
    if actualItem.metadata then
        for k, v in pairs(actualItem.metadata) do newMeta[k] = v end
    elseif item.metadata then
        for k, v in pairs(item.metadata) do newMeta[k] = v end
    end
    
    newMeta.plateDurability = durability 
    newMeta.durability = durability       
    newMeta.weight     = Config.Plates[item.name].weight
    newMeta.sjarmor_processed = true      
    
    local addOk = exports.ox_inventory:AddItem(stashId, item.name, 1, newMeta, nil)
    if not addOk then
        return fail('Could not install the plate.')
    end

    SetTimeout(50, function()
        local stashInv = exports.ox_inventory:GetInventory(stashId, false)
        if stashInv and stashInv.items then
            for slot, stashItem in pairs(stashInv.items) do
                if stashItem and stashItem.name == item.name and stashItem.metadata and stashItem.metadata.sjarmor_processed then
                    local cleanMeta = {}
                    for k, v in pairs(stashItem.metadata) do
                        if k ~= 'sjarmor_processed' then
                            cleanMeta[k] = v
                        end
                    end
                    exports.ox_inventory:SetMetadata(stashId, slot, cleanMeta)
                    break
                end
            end
        end
    end)
    
    local stashInvAfterAdd = exports.ox_inventory:GetInventory(stashId, false)
    if stashInvAfterAdd and stashInvAfterAdd.items then
        for slot, stashItem in pairs(stashInvAfterAdd.items) do
            if stashItem and stashItem.name == item.name then
                local stashDurability = stashItem.metadata and stashItem.metadata.plateDurability or stashItem.metadata and stashItem.metadata.durability or "nil"
                
                if stashDurability ~= durability then
                    local fixedMeta = stashItem.metadata or {}
                    fixedMeta.plateDurability = durability  
                    fixedMeta.durability = durability       
                    exports.ox_inventory:SetMetadata(stashId, slot, fixedMeta)
                    
                    local fixedItem = exports.ox_inventory:GetSlot(stashId, slot)
                    if fixedItem and fixedItem.metadata and fixedItem.metadata.plateDurability == durability then
                    else
                    end
                end
                break
            end
        end
    end
    
    SetTimeout(100, function()
        local finalCheck = exports.ox_inventory:GetInventory(stashId, false)
        if finalCheck and finalCheck.items then
            for slot, stashItem in pairs(finalCheck.items) do
                if stashItem and stashItem.name == item.name then
                    local finalDurability = stashItem.metadata and stashItem.metadata.plateDurability or stashItem.metadata and stashItem.metadata.durability or "nil"
                    if finalDurability ~= durability then
                        local finalMeta = stashItem.metadata or {}
                        finalMeta.plateDurability = durability
                        finalMeta.durability = durability
                        exports.ox_inventory:SetMetadata(stashId, slot, finalMeta)
                    end
                    break
                end
            end
        end
    end)

    local metadataToRemove = actualItem and actualItem.metadata or item.metadata
    
    local removed = exports.ox_inventory:RemoveItem(src, item.name, 1, metadataToRemove, slot)
    if not removed then
        exports.ox_inventory:RemoveItem(stashId, item.name, 1, newMeta)
        return fail('Could not remove the plate from your inventory. Try again.')
    end

    local invNow = exports.ox_inventory:GetInventory(stashId, false)
    local newVirtualArmor, newPlateCount = calculateVirtualArmor(invNow)
    armorData.virtualArmor = newVirtualArmor
    armorData.plateCount   = newPlateCount

    if invNow and invNow.items then
        for slot, stashItem in pairs(invNow.items) do
            if stashItem and stashItem.name == item.name then
                local finalDurability = stashItem.metadata and stashItem.metadata.plateDurability or stashItem.metadata and stashItem.metadata.durability or "nil"
                break
            end
    end
    end


    local lastPlateDurability = 100
    if newPlateCount == 1 and invNow and invNow.items then
        for _, it in pairs(invNow.items) do
            if it and Config.Plates[it.name] then
                local d = Config.Plates[it.name].durability or 100
                if it.metadata and it.metadata.plateDurability ~= nil then
                    d = it.metadata.plateDurability
                elseif it.metadata and it.metadata.durability ~= nil then
                    d = it.metadata.durability
                end
                if d > 0 then lastPlateDurability = d break end
            end
        end
    end
    armorData.lastPlateDurability = lastPlateDurability

    local targetArmor = 0
    if newVirtualArmor > 0 then
        if newPlateCount > 1 then targetArmor = 100 else targetArmor = math.floor(lastPlateDurability) end
    end

    TriggerClientEvent('SJArmor:updateArmor', src, armorData, targetArmor)

    updatePlateCarrierWeight(src, armorData.carrierSlot, armorData.stashId)


    TriggerClientEvent('ox_lib:notify', source, {
            type = 'success',
            description = ('Installed %s. Plates: %d/%d.'):format(item.label, newPlateCount, carrierCfg.plateSlots or 0)
        })
    finish()
end)

exports('usePlateCarrier', function(event, item, inventory, slot, data)
    local source = inventory.id
    local metadata = item.metadata
    
    if metadata.stashId then
        local stashInv = exports.ox_inventory:GetInventory(metadata.stashId, false)
        local virtualArmor, plateCount = calculateVirtualArmor(stashInv)
        TriggerClientEvent('ox_lib:notify', source, {
            type = 'inform',
            description = ('Plate carrier: %d plates, %d virtual armor'):format(plateCount, virtualArmor)
        })
    else
        TriggerClientEvent('ox_lib:notify', source, {
            type = 'error',
            description = 'Plate carrier has no storage assigned'
        })
    end
end) 
