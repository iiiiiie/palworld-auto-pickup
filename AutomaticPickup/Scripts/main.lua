local config = require("config")

local MOD_NAME = "AutomaticPickup"
local BOUND_RECORD_TTL_SECONDS = 30.0

local palUtility = nil
local palMonsterCharacterClass = nil
local deathContextStack = {}
local pendingDeathContexts = {}
local boundDropModelsByObject = {}
local boundDropModelsByKey = {}
local unboundDropDebugKeys = {}

-- __DEPRECATED_20260712__ The old implementation used recent kill records plus
-- time/distance matching. It is retained only as disabled diagnostic state; the
-- strict implementation binds drops created by validated Pal death contexts.
local deprecatedRecentKills = {}
local deprecatedHandledModels = {}

local function log(message)
    print(string.format("[%s] %s", MOD_NAME, message))
end

local function debug_log(message)
    if config.DEBUG then
        log(message)
    end
end

local function source_debug_log(message)
    if config.DEBUG or config.DEBUG_SOURCE_BINDING then
        log(message)
    end
end

local function unwrap(value)
    if value == nil then
        return nil
    end

    if type(value) == "userdata" and value.get ~= nil then
        local ok, result = pcall(function()
            return value:get()
        end)
        if ok then
            return result
        end
    end

    return value
end

local function is_valid(object)
    if object == nil then
        return false
    end

    if type(object) == "userdata" and object.IsValid ~= nil then
        local ok, result = pcall(function()
            return object:IsValid()
        end)
        return ok and result
    end

    return true
end

local function get_now()
    return os.time() + (os.clock() % 1)
end

local function guid_equals(a, b)
    if a == nil or b == nil then
        return false
    end

    local okDirect, directResult = pcall(function()
        return a == b
    end)
    if okDirect and directResult == true then
        return true
    end

    local okA, textA = pcall(function()
        return tostring(a)
    end)
    local okB, textB = pcall(function()
        return tostring(b)
    end)
    if okA and okB then
        return textA == textB
    end

    return false
end

local function guid_looks_empty(value)
    if value == nil then
        return true
    end

    local ok, text = pcall(function()
        return tostring(value)
    end)
    if not ok or text == nil then
        return false
    end

    if text == "" or text == "FGuid{}" or text == "00000000-0000-0000-0000-000000000000" then
        return true
    end

    local compact = text:gsub("[^0-9A-Fa-f]", "")
    if compact == "00000000000000000000000000000000" then
        return true
    end

    return false
end

local function get_async_bind_window_seconds()
    local value = tonumber(config.ASYNC_BIND_WINDOW_SECONDS)
    if value == nil or value <= 0 then
        return 2.0
    end
    return value
end

local function get_async_bind_radius()
    -- __DEPRECATED_20260713__ Location fallback is disabled. The retained config
    -- value is not read by strict source binding.
    return nil
end

local function get_pal_utility()
    if is_valid(palUtility) then
        return palUtility
    end

    palUtility = StaticFindObject("/Script/Pal.Default__PalUtility")
    if not is_valid(palUtility) then
        palUtility = nil
    end

    return palUtility
end

local function is_server_context(worldContext)
    local utility = get_pal_utility()
    if not is_valid(utility) or not is_valid(worldContext) then
        return false
    end

    local ok, result = pcall(function()
        return utility:IsServer(worldContext)
    end)
    if not ok then
        return false
    end

    return result
end

local function is_model_server_context(model)
    if is_server_context(model) then
        return true
    end

    -- __DEPRECATED_20260713__ Do not fall back through model:GetActor() here.
    -- Drop models can be constructed/enabled while their backing actor is not in
    -- a safe state for UE4SS-side UFunction calls. Bound records already carry a
    -- server-validated death context, so caller code should prefer that context.

    return false
end

local function get_pal_monster_character_class()
    if is_valid(palMonsterCharacterClass) then
        return palMonsterCharacterClass
    end

    palMonsterCharacterClass = StaticFindObject("/Script/Pal.PalMonsterCharacter")
    if not is_valid(palMonsterCharacterClass) then
        palMonsterCharacterClass = nil
    end

    return palMonsterCharacterClass
end

local function get_object_name(object)
    if not is_valid(object) then
        return "<invalid>"
    end

    local okFullName, fullName = pcall(function()
        return object:GetFullName()
    end)
    if okFullName and fullName ~= nil then
        return tostring(fullName)
    end

    local okName, name = pcall(function()
        return object:GetName()
    end)
    if okName and name ~= nil then
        return tostring(name)
    end

    return tostring(object)
end

local function is_pal_monster_character(actor)
    if not is_valid(actor) then
        return false
    end

    local monsterClass = get_pal_monster_character_class()
    if not is_valid(monsterClass) then
        source_debug_log("ignored death: APalMonsterCharacter class was unavailable")
        return false
    end

    if actor.IsA == nil then
        source_debug_log("ignored death: actor does not expose IsA: " .. get_object_name(actor))
        return false
    end

    local ok, result = pcall(function()
        return actor:IsA(monsterClass)
    end)
    if not ok then
        source_debug_log("ignored death: IsA check failed for " .. get_object_name(actor))
        return false
    end

    return result == true
end

local function add_candidate(candidates, seen, candidate)
    candidate = unwrap(candidate)
    if not is_valid(candidate) then
        return
    end

    local key = tostring(candidate)
    if seen[key] then
        return
    end

    seen[key] = true
    candidates[#candidates + 1] = candidate
end

local function try_add_call_result(candidates, seen, object, methodName)
    if not is_valid(object) or object[methodName] == nil then
        return
    end

    local ok, result = pcall(function()
        return object[methodName](object)
    end)
    if ok then
        add_candidate(candidates, seen, result)
    end
end

local function try_add_property(candidates, seen, object, propertyName)
    if not is_valid(object) then
        return
    end

    local ok, result = pcall(function()
        return object[propertyName]
    end)
    if ok then
        add_candidate(candidates, seen, result)
    end
end

local function get_character_parameter_component(character)
    if not is_valid(character) then
        return nil
    end

    if character.GetCharacterParameterComponent ~= nil then
        local ok, result = pcall(function()
            return character:GetCharacterParameterComponent()
        end)
        if ok and is_valid(result) then
            return result
        end
    end

    local ok, result = pcall(function()
        return character.CharacterParameterComponent
    end)
    if ok and is_valid(result) then
        return result
    end

    return nil
end

local function try_get_individual_parameter(object)
    if not is_valid(object) then
        return nil
    end

    if object.GetIndividualParameter ~= nil then
        local ok, result = pcall(function()
            return object:GetIndividualParameter()
        end)
        if ok and is_valid(result) then
            return result
        end
    end

    if object.TryGetIndividualParameter ~= nil then
        local ok, result = pcall(function()
            return object:TryGetIndividualParameter()
        end)
        if ok and is_valid(result) then
            return result
        end
    end

    local parameterComponent = get_character_parameter_component(object)
    if is_valid(parameterComponent) then
        return try_get_individual_parameter(parameterComponent)
    end

    local okHandle, handle = pcall(function()
        return object.IndividualHandle
    end)
    if okHandle and is_valid(handle) then
        return try_get_individual_parameter(handle)
    end

    return nil
end

local function get_individual_id(object)
    if not is_valid(object) then
        return nil
    end

    if object.GetPalId ~= nil then
        local ok, result = pcall(function()
            return object:GetPalId()
        end)
        if ok and result ~= nil then
            return result
        end
    end

    if object.GetIndividualID ~= nil then
        local ok, result = pcall(function()
            return object:GetIndividualID()
        end)
        if ok and result ~= nil then
            return result
        end
    end

    local individualParameter = try_get_individual_parameter(object)
    if is_valid(individualParameter) and individualParameter ~= object then
        return get_individual_id(individualParameter)
    end

    return nil
end

local function add_related_candidates(candidates, seen, utility, candidate)
    if is_valid(utility) then
        local okOwnerActor, ownerActor = pcall(function()
            return utility:FindOwnerActor(candidate)
        end)
        if okOwnerActor then
            add_candidate(candidates, seen, ownerActor)
        end

        local okOwnerPal, ownerPal = pcall(function()
            return utility:FindOwnerPalCharacter(candidate)
        end)
        if okOwnerPal then
            add_candidate(candidates, seen, ownerPal)
        end
    end

    try_add_call_result(candidates, seen, candidate, "GetOwner")
    try_add_call_result(candidates, seen, candidate, "GetInstigator")
    try_add_call_result(candidates, seen, candidate, "GetInstigatorController")
    try_add_call_result(candidates, seen, candidate, "GetController")
    try_add_call_result(candidates, seen, candidate, "GetPawn")
    try_add_call_result(candidates, seen, candidate, "GetOwnerCharacter")

    local parameterComponent = get_character_parameter_component(candidate)

    if is_valid(parameterComponent) then
        try_add_property(candidates, seen, parameterComponent, "Trainer")
        try_add_property(candidates, seen, parameterComponent, "NPCSpawnedOtomoTrainer")
        try_add_property(candidates, seen, parameterComponent, "OtomoPal")
        try_add_property(candidates, seen, parameterComponent, "IndividualHandle")
    end
end

local function get_player_id(playerState)
    if not is_valid(playerState) then
        return nil
    end

    local ok, playerId = pcall(function()
        if playerState.GetPlayerId ~= nil then
            return playerState:GetPlayerId()
        end
        return playerState.PlayerId
    end)

    if ok then
        return playerId
    end

    return nil
end

local function looks_like_player_state(candidate)
    if not is_valid(candidate) then
        return false
    end
    if candidate.GetInventoryData ~= nil then
        return true
    end

    local ok, inventoryData = pcall(function()
        return candidate.InventoryData
    end)
    return ok and is_valid(inventoryData)
end

local function get_player_uid(playerState)
    if not is_valid(playerState) then
        return nil
    end

    local accessors = {
        "GetPlayerUId",
        "GetPlayerUID",
        "GetPlayerUid",
    }

    for _, accessor in ipairs(accessors) do
        if playerState[accessor] ~= nil then
            local ok, result = pcall(function()
                return playerState[accessor](playerState)
            end)
            if ok and result ~= nil then
                return result
            end
        end
    end

    local properties = {
        "PlayerUId",
        "PlayerUID",
        "PlayerUid",
    }

    for _, propertyName in ipairs(properties) do
        local ok, result = pcall(function()
            return playerState[propertyName]
        end)
        if ok and result ~= nil then
            return result
        end
    end

    return nil
end

local function resolve_player_state_from_player_uid(playerUid, worldContext)
    if playerUid == nil then
        return nil
    end

    local utility = get_pal_utility()
    if not is_valid(utility) or utility.GetPlayerStateByPlayerUid == nil then
        return nil
    end

    if not is_valid(worldContext) then
        worldContext = utility
    end

    local ok, playerState = pcall(function()
        return utility:GetPlayerStateByPlayerUid(worldContext, playerUid)
    end)
    if ok and is_valid(playerState) then
        return playerState
    end

    return nil
end

local function resolve_player_id_from_player_uid(playerUid, worldContext)
    local playerState = resolve_player_state_from_player_uid(playerUid, worldContext)
    if not is_valid(playerState) then
        return nil
    end

    return get_player_id(playerState)
end

local function resolve_player_id_from_player_uid_candidates(playerUid, ...)
    local seen = {}

    for index = 1, select("#", ...) do
        local worldContext = select(index, ...)
        if is_valid(worldContext) then
            local key = tostring(worldContext)
            if not seen[key] then
                seen[key] = true

                local playerId = resolve_player_id_from_player_uid(playerUid, worldContext)
                if playerId ~= nil then
                    return playerId
                end
            end
        end
    end

    return nil
end

local function try_get_player_state_from_candidate(utility, candidate)
    if not is_valid(candidate) then
        return nil
    end

    if looks_like_player_state(candidate) and get_player_id(candidate) ~= nil then
        return candidate
    end

    if is_valid(utility) then
        local ok, playerState = pcall(function()
            return utility:GetPlayerState(candidate)
        end)
        if ok and is_valid(playerState) then
            return playerState
        end
    end

    if candidate.GetCachedPlayerState ~= nil then
        local ok, playerState = pcall(function()
            return candidate:GetCachedPlayerState()
        end)
        if ok and is_valid(playerState) then
            return playerState
        end
    end

    if candidate.GetPlayerState ~= nil then
        local ok, playerState = pcall(function()
            return candidate:GetPlayerState()
        end)
        if ok and is_valid(playerState) then
            return playerState
        end
    end

    local okProperty, propertyState = pcall(function()
        return candidate.PlayerState
    end)
    if okProperty and is_valid(propertyState) then
        return propertyState
    end

    if is_valid(utility) and utility.GetPlayerStateByPlayerUid ~= nil then
        local individualId = get_individual_id(candidate)
        if individualId ~= nil and individualId.PlayerUId ~= nil then
            local ok, playerState = pcall(function()
                return utility:GetPlayerStateByPlayerUid(candidate, individualId.PlayerUId)
            end)
            if ok and is_valid(playerState) then
                source_debug_log("resolved attacker via individual PlayerUId: " .. get_object_name(candidate))
                return playerState
            end
        end
    end

    return nil
end

local function resolve_player_state_from_attacker(attacker)
    if not is_valid(attacker) then
        return nil
    end

    local utility = get_pal_utility()
    if not is_valid(utility) then
        return nil
    end

    local candidates = {}
    local seen = {}
    add_candidate(candidates, seen, attacker)

    local index = 1
    while index <= #candidates and index <= 32 do
        local candidate = candidates[index]
        local playerState = try_get_player_state_from_candidate(utility, candidate)
        if is_valid(playerState) then
            return playerState
        end

        add_related_candidates(candidates, seen, utility, candidate)
        index = index + 1
    end

    return nil
end

local function vector_distance_squared(a, b)
    -- __DEPRECATED_20260713__ Retained only for diagnosing the old location
    -- fallback path. Strict source binding no longer calls this function.
    local dx = (a.X or 0.0) - (b.X or 0.0)
    local dy = (a.Y or 0.0) - (b.Y or 0.0)
    local dz = (a.Z or 0.0) - (b.Z or 0.0)
    return dx * dx + dy * dy + dz * dz
end

local function get_actor_location(actor)
    if not is_valid(actor) then
        return nil
    end

    local ok, location = pcall(function()
        if actor.K2_GetActorLocation ~= nil then
            return actor:K2_GetActorLocation()
        end
        return actor:GetActorLocation()
    end)

    if ok then
        return location
    end

    return nil
end

local function get_model_location(model)
    if not is_valid(model) then
        return nil
    end

    -- __DEPRECATED_20260713__ Location fallback is disabled. Do not call
    -- model:GetActor() here; Palworld can fatal if the map object model is not
    -- fully registered or has already been destroyed.
    -- __DEPRECATED_20260713__ Do not call model:GetTransform() here. Palworld
    -- can fatal if the map object model is not registered yet or has already
    -- been destroyed, especially while loading a save.

    return nil
end

local function get_instance_key(model)
    if not is_valid(model) then
        return nil
    end

    -- __DEPRECATED_20260713__ Do not call model:GetInstanceId() for routine
    -- binding. It is a Pal map-object UFunction, not needed for object identity,
    -- and may run while the model lifecycle is unstable.
    local okName, fullName = pcall(function()
        return model:GetFullName()
    end)
    if okName then
        return tostring(fullName)
    end

    return tostring(model)
end

local function add_model_keys(keys, seen, model)
    if not is_valid(model) then
        return
    end

    local function add_key(value)
        if value == nil then
            return
        end

        local key = tostring(value)
        if key == "" or seen[key] then
            return
        end

        seen[key] = true
        keys[#keys + 1] = key
    end

    add_key(tostring(model))

    -- __DEPRECATED_20260713__ Instance-id UFunctions are intentionally not used
    -- for matching. Object identity plus UObject full name are sufficient for
    -- this UE4SS process, and avoiding map-object lifecycle calls reduces crash
    -- risk around newly spawned or already-picked drops.

    local okFullName, fullName = pcall(function()
        return model:GetFullName()
    end)
    if okFullName then
        add_key(fullName)
    end
end

local function get_model_keys(model)
    local keys = {}
    add_model_keys(keys, {}, model)
    return keys
end

local function get_model_pickupable_player_uid(model)
    if not is_valid(model) then
        return nil
    end

    local accessors = {
        "GetPickupablePlayerUid",
        "GetPickupablePlayerUID",
        "GetPickupablePlayerUid_BP",
    }

    for _, accessor in ipairs(accessors) do
        if model[accessor] ~= nil then
            local ok, result = pcall(function()
                return model[accessor](model)
            end)
            if ok and result ~= nil then
                return result
            end
        end
    end

    local ok, result = pcall(function()
        return model.PickupablePlayerUid
    end)
    if ok and result ~= nil then
        return result
    end

    return nil
end

local cleanup_pending_death_contexts

local function find_pending_context_by_player_uid(playerUid, worldContext)
    if playerUid == nil or guid_looks_empty(playerUid) then
        return nil, nil
    end

    cleanup_pending_death_contexts()

    local resolvedPlayerId = nil
    local utility = get_pal_utility()

    for _, context in ipairs(pendingDeathContexts) do
        if context ~= nil
            and context.active
            and context.playerId ~= nil
        then
            if guid_equals(playerUid, context.playerUid) then
                return context, context.playerId
            end

            local playerId = resolve_player_id_from_player_uid_candidates(
                playerUid,
                worldContext,
                context.enemyActor,
                context.playerState,
                utility
            )
            if playerId ~= nil then
                resolvedPlayerId = playerId
                if playerId == context.playerId then
                    return context, playerId
                end
            end
        end
    end

    return nil, resolvedPlayerId
end

cleanup_pending_death_contexts = function()
    local now = get_now()
    local window = get_async_bind_window_seconds()

    for index = #pendingDeathContexts, 1, -1 do
        local context = pendingDeathContexts[index]
        if context == nil
            or not context.active
            or context.enemyLocation == nil
            or now - context.createdAt > window
        then
            table.remove(pendingDeathContexts, index)
        end
    end
end

local function cleanup_bound_records()
    local now = get_now()

    for model, record in pairs(boundDropModelsByObject) do
        if record == nil
            or record.completed
            or now - record.boundAt > BOUND_RECORD_TTL_SECONDS
        then
            boundDropModelsByObject[model] = nil
        end
    end

    for key, record in pairs(boundDropModelsByKey) do
        if record == nil
            or record.completed
            or now - record.boundAt > BOUND_RECORD_TTL_SECONDS
        then
            boundDropModelsByKey[key] = nil
        end
    end

    for key, seenAt in pairs(unboundDropDebugKeys) do
        if seenAt == nil or now - seenAt > BOUND_RECORD_TTL_SECONDS then
            unboundDropDebugKeys[key] = nil
        end
    end

    cleanup_pending_death_contexts()
end

local function get_current_active_death_context()
    local frame = deathContextStack[#deathContextStack]
    if frame ~= nil and frame.active then
        return frame
    end

    return nil
end

local get_bound_record

local function bind_drop_model_to_context(model, context)
    if not is_valid(model) or context == nil or not context.active then
        return
    end

    cleanup_bound_records()

    local existingRecord = boundDropModelsByObject[model]
    if existingRecord ~= nil and not existingRecord.completed then
        return existingRecord
    end

    local record = {
        boundAt = get_now(),
        contextId = context.contextId,
        playerState = context.playerState,
        playerId = context.playerId,
        playerUid = context.playerUid,
        enemyName = context.enemyName,
        model = model,
        scheduled = false,
        completed = false,
        retryCount = 0,
    }

    boundDropModelsByObject[model] = record

    local keys = get_model_keys(model)
    for _, key in ipairs(keys) do
        boundDropModelsByKey[key] = record
    end

    context.boundCount = context.boundCount + 1
    source_debug_log(string.format(
        "bound drop model to context %s for player id %s: %s",
        tostring(context.contextId),
        tostring(context.playerId),
        get_object_name(model)
    ))

    return record
end

local function queue_pending_death_context(context)
    if context == nil or not context.active then
        return
    end

    if context.enemyLocation == nil and is_valid(context.enemyActor) then
        context.enemyLocation = get_actor_location(context.enemyActor)
    end

    if context.enemyLocation == nil then
        source_debug_log(string.format(
            "cannot queue async death context %s: enemy location unavailable",
            tostring(context.contextId)
        ))
        return
    end

    context.pending = true
    pendingDeathContexts[#pendingDeathContexts + 1] = context
    cleanup_pending_death_contexts()

    source_debug_log(string.format(
        "queued async death context %s for %.2fs using pickupable player uid binding",
        tostring(context.contextId),
        get_async_bind_window_seconds()
    ))
end

local function find_pending_death_context_for_model(model)
    cleanup_pending_death_contexts()

    local pickupablePlayerUid = get_model_pickupable_player_uid(model)
    if pickupablePlayerUid ~= nil then
        -- __DEPRECATED_20260713__ Direct FGuid userdata comparison via tostring
        -- returns wrapper addresses in UE4SS. Resolve to PlayerState/playerId first.
        local uidContext, resolvedPlayerId = find_pending_context_by_player_uid(pickupablePlayerUid, nil)
        if uidContext ~= nil then
            source_debug_log(string.format(
                "matched async drop by pickupable player uid/player id %s to context %s",
                tostring(resolvedPlayerId),
                tostring(uidContext.contextId)
            ))
            return uidContext, nil
        end

        if resolvedPlayerId ~= nil then
            return nil, string.format(
                "pickupable player uid resolved to player id %s but no pending Pal death context matched",
                tostring(resolvedPlayerId)
            )
        else
            return nil, "pickupable player uid did not resolve; location fallback disabled"
        end
    end

    if #pendingDeathContexts == 0 then
        return nil, "no pending Pal death context active"
    end

    -- __DEPRECATED_20260713__ The old async location fallback matched a drop
    -- to the closest validated Pal death context by spawn distance. Live testing
    -- showed this can overlap with mining/logging drops and can request pickup
    -- for an unrelated model. Strict source binding now fails closed unless the
    -- drop exposes a PickupablePlayerUid that resolves to the killer player.
    return nil, "drop has no resolvable pickupable player uid; location fallback disabled"
end

local function bind_drop_model_to_pending_context(model)
    local context, reason = find_pending_death_context_for_model(model)
    if context == nil then
        return nil, reason
    end

    return bind_drop_model_to_context(model, context), nil
end

function get_bound_record(model)
    if not is_valid(model) then
        return nil
    end

    cleanup_bound_records()

    local record = boundDropModelsByObject[model]
    if record ~= nil then
        return record
    end

    local keys = get_model_keys(model)
    for _, key in ipairs(keys) do
        record = boundDropModelsByKey[key]
        if record ~= nil then
            boundDropModelsByObject[model] = record
            record.model = model
            return record
        end
    end

    return nil
end

local function cleanup_recent_kills()
    deprecatedRecentKills = {}
    deprecatedHandledModels = {}
end

-- __DEPRECATED_20260712__ Disabled by default. Time/distance matching can pick
-- unrelated map drops near a kill, so strict source binding does not call this.
local function remember_kill(enemyActor, lastAttacker)
    local _ = enemyActor
    local __ = lastAttacker
    debug_log("__DEPRECATED_20260712__ remember_kill is disabled")
end

-- __DEPRECATED_20260712__ Disabled by default. Kept for diagnostics only.
local function find_matching_kill(dropLocation)
    local _ = dropLocation
    debug_log("__DEPRECATED_20260712__ find_matching_kill is disabled")
    return nil
end

local function request_pickup(model, record)
    local ok, err = pcall(function()
        model:RequestPickup_ServerInternal(record.playerId, true)
    end)

    if not ok then
        debug_log("pickup request failed: " .. tostring(err))
        return false
    end

    source_debug_log(string.format("requested pickup for player id %s", tostring(record.playerId)))
    return true
end

local function source_debug_unbound_once(model, reason)
    local key = get_object_name(model)
    if key ~= nil and unboundDropDebugKeys[key] then
        return
    end
    if key ~= nil then
        unboundDropDebugKeys[key] = get_now()
    end

    local pickupablePlayerUid = get_model_pickupable_player_uid(model)
    local pickupablePlayerUidText = pickupablePlayerUid ~= nil and tostring(pickupablePlayerUid) or "<nil>"
    local autoPickupText = "<unknown>"
    local okAutoPickup, autoPickup = pcall(function()
        return model.bAutoPickedUp
    end)
    if okAutoPickup and autoPickup ~= nil then
        autoPickupText = tostring(autoPickup)
    end

    if reason ~= nil then
        source_debug_log(string.format(
            "ignored unbound drop model (%s, pickupableUid=%s, autoPickedUp=%s): %s",
            reason,
            pickupablePlayerUidText,
            autoPickupText,
            get_object_name(model)
        ))
    else
        source_debug_log(string.format(
            "ignored unbound drop model (pickupableUid=%s, autoPickedUp=%s): %s",
            pickupablePlayerUidText,
            autoPickupText,
            get_object_name(model)
        ))
    end
end

local function schedule_pickup(model, record, retry)
    retry = retry or 0

    local function run()
        if not is_valid(model) or not is_valid(record.playerState) then
            return
        end

        if request_pickup(model, record) then
            record.completed = true
            return
        end

        if retry < config.MAX_PICKUP_RETRIES then
            schedule_pickup(model, record, retry + 1)
        else
            source_debug_log(string.format(
                "pickup request failed after retries for context %s",
                tostring(record.contextId)
            ))
        end
    end

    local delay = retry == 0 and config.PICKUP_DELAY_MS or config.RETRY_DELAY_MS
    if ExecuteWithDelay ~= nil then
        ExecuteWithDelay(delay, run)
    else
        run()
    end
end

-- __DEPRECATED_20260712__ Disabled by default. The hook now calls
-- try_auto_pickup_bound_drop instead.
local function try_auto_pickup_drop(model)
    local _ = model
    debug_log("__DEPRECATED_20260712__ try_auto_pickup_drop is disabled")
end

local function build_death_context(enemyActor, lastAttacker)
    local frame = {
        active = false,
        reason = nil,
        boundCount = 0,
        createdAt = get_now(),
    }

    if not config.ENABLED then
        frame.reason = "mod disabled"
        return frame
    end
    if not config.STRICT_SOURCE_BINDING then
        frame.reason = "strict source binding disabled"
        return frame
    end
    if not is_valid(enemyActor) then
        frame.reason = "enemy actor was invalid"
        return frame
    end
    if not is_valid(lastAttacker) then
        frame.reason = "last attacker was invalid"
        return frame
    end
    if not is_server_context(enemyActor) then
        frame.reason = "not server context"
        return frame
    end
    if not is_pal_monster_character(enemyActor) then
        frame.reason = "enemy actor was not APalMonsterCharacter"
        return frame
    end

    local playerState = resolve_player_state_from_attacker(lastAttacker)
    if not is_valid(playerState) then
        frame.reason = "attacker did not resolve to a player"
        return frame
    end

    local playerId = get_player_id(playerState)
    if playerId == nil then
        frame.reason = "player id was unavailable"
        return frame
    end

    frame.active = true
    frame.contextId = string.format("%s:%s", tostring(get_now()), tostring(#deathContextStack + 1))
    frame.enemyActor = enemyActor
    frame.playerState = playerState
    frame.playerId = playerId
    frame.playerUid = get_player_uid(playerState)
    frame.enemyName = get_object_name(enemyActor)
    frame.attackerName = get_object_name(lastAttacker)
    frame.enemyLocation = get_actor_location(enemyActor)

    return frame
end

local function on_enemy_death_pre(_, EnemyActor, LastAttacker)
    local enemyActor = unwrap(EnemyActor)
    local lastAttacker = unwrap(LastAttacker)

    local frame = build_death_context(enemyActor, lastAttacker)
    deathContextStack[#deathContextStack + 1] = frame

    if frame.active then
        source_debug_log(string.format(
            "opened death context %s for player id %s enemy=%s attacker=%s",
            tostring(frame.contextId),
            tostring(frame.playerId),
            frame.enemyName,
            frame.attackerName
        ))
    elseif frame.reason ~= nil then
        source_debug_log("ignored death: " .. frame.reason)
    end
end

local function on_enemy_death_post()
    local frame = deathContextStack[#deathContextStack]
    if frame == nil then
        source_debug_log("death context stack was empty on post hook")
        return
    end

    deathContextStack[#deathContextStack] = nil

    if frame.active then
        source_debug_log(string.format(
            "closed death context %s with %d bound drop model(s)",
            tostring(frame.contextId),
            frame.boundCount or 0
        ))
        queue_pending_death_context(frame)
    end
end

local function on_drop_model_constructed(ConstructedObject)
    local model = unwrap(ConstructedObject)
    local context = get_current_active_death_context()
    if context ~= nil then
        bind_drop_model_to_context(model, context)
        return
    end

    bind_drop_model_to_pending_context(model)
end

local function try_auto_pickup_bound_drop(model)
    if not config.ENABLED or not is_valid(model) then
        return
    end

    local record = get_bound_record(model)
    if record == nil then
        local reason = nil
        record, reason = bind_drop_model_to_pending_context(model)
        if record == nil then
            source_debug_unbound_once(model, reason)
            return
        end
    end
    if record.scheduled or record.completed then
        return
    end

    record.scheduled = true
    schedule_pickup(model, record, 0)
end

local function on_drop_enable_interact(Context)
    local model = unwrap(Context)
    try_auto_pickup_bound_drop(model)
end

local function register_hook_safely(path, preCallback, postCallback)
    local ok, preId, postId = pcall(function()
        return RegisterHook(path, preCallback, postCallback)
    end)

    if not ok then
        log(string.format("failed to register hook %s: %s", path, tostring(preId)))
        return nil, nil
    end

    source_debug_log(string.format("registered hook %s", path))
    return preId, postId
end

local function notify_on_new_object_safely(className, callback)
    if NotifyOnNewObject == nil then
        log("NotifyOnNewObject is unavailable; strict source binding cannot bind drops")
        return false
    end

    local ok, err = pcall(function()
        NotifyOnNewObject(className, callback)
    end)

    if not ok then
        log(string.format("failed to register object notification %s: %s", className, tostring(err)))
        return false
    end

    source_debug_log(string.format("registered object notification %s", className))
    return true
end

notify_on_new_object_safely("/Script/Pal.PalMapObjectDropItemModel", on_drop_model_constructed)
register_hook_safely("/Script/Pal.PalUtility:DropItem_FromEnemyDeath", on_enemy_death_pre, on_enemy_death_post)
register_hook_safely("/Script/Pal.PalMapObjectDropItemModel:OnEnableTriggerInteract", on_drop_enable_interact)

log("loaded")
