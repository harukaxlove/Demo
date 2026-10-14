--!strict
local Players = game:GetService("Players")
local Run = game:GetService("RunService")
local Root = game.ReplicatedStorage.ReplicaStudios
local Shared = Root.systems.Combat.Shared
local Config = require(Shared.CombatConfig)
local MovementModel = require(Shared.MovementModel)
local MovementConfig = require(Shared.MovementConfig)
local DashProfile = require(Shared.DashProfile)
local Weapons = require(Shared.WeaponRegistry)
local Access = require(Shared.CombatAccess)
local Definitions = require(Shared.StateDefinitions)
local Scope = require(Root.shared.ResourceScope)
local States = require(script.Parent.StateService)
local Damage = require(script.Parent.DamageService)
local Hitbox = require(script.Parent.HitboxService)
local Validator = require(script.Parent.CombatValidator)
local Demo = require(script.Parent.CombatDemo)
local Service = {}
Service.__index = Service
function Service.new(inventory, deps: any?): any
    local self = setmetatable({
        inventory = inventory,
        states = States.new(),
        guards = {},
        debug = {},
        clock = deps and deps.clock or os.clock,
        scope = nil,
    }, Service)
    self.damage = Damage.new(self.states, function(kind, model, data)
        self:Emit(kind, model, data)
    end, self.clock)
    return self
end
function Service:Emit(kind: string, model: Model, data: any?)
    if self.noise and kind == "Attack" then
        local root = model:FindFirstChild("HumanoidRootPart")
        if root and root:IsA("BasePart") then
            self.noise:Fire(root.Position, 22, model)
        end
    end
    if not self.effect then
        return
    end
    local root = model:FindFirstChild("HumanoidRootPart")
    if not root then
        return
    end
    local payload = data and table.clone(data) or {}
    payload.kind = kind
    payload.model = model
    payload.position = root.Position
    for _, player in ipairs(Players:GetPlayers()) do
        local r = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
        if r and (r.Position - root.Position).Magnitude <= Config.EffectDistance then
            self.effect:FireClient(player, payload)
        end
    end
end
function Service:Weapon(model: Model)
    local player = Players:GetPlayerFromCharacter(model)
    local isNPC = model:GetAttribute("CombatNPC")
    if player or isNPC and not model:FindFirstChild("Training Bow") then
        return Weapons.Get("fists"), nil, "fists"
    end
    for _, tool in ipairs(model:GetChildren()) do
        if tool:IsA("Tool") and tool:GetAttribute("CombatDemoWeapon") and isNPC then
            local weaponId = tool:GetAttribute("WeaponId")
            return Weapons.Get(weaponId), tool, weaponId
        end
    end
    return nil
end
function Service:Attack(model: Model, action: string, requestId: string?): (boolean, string)
    if not Access.Model(model) then
        return false, "Unavailable"
    end
    local state = self.states:Get(model)
    local weapon, tool, weaponId = self:Weapon(model)
    local now = self.clock()
    if not state or not weapon then
        return false, "WeaponRequired"
    end
    if state.lastPosition and (state.root.Position - state.lastPosition).Magnitude > 10 then
        return false, "Unavailable"
    end
    if (state.attackLockedUntil or 0) > now then
        return false, "ComboCooldown"
    end
    if state.blocking or not Definitions.CanAct(state, now) then
        return false, "Busy"
    end
    local combo = action == "Heavy" and 0
        or now - state.comboAt > Config.ComboReset and 1
        or state.combo % 4 + 1
    local def = action == "Heavy" and weapon.heavy or weapon.light[combo]
    if not self.states:Spend(state, def.cost, now) then
        return false, "Stamina"
    end
    state.combo = combo
    state.comboAt = now
    state.sequence += 1
    state.busyUntil = now + def.windup + def.active + def.recovery
    state.attackMovementUntil = state.busyUntil
    state.attackMoveServerUntil = workspace:GetServerTimeNow() + def.windup + def.active + def.recovery
    if combo == 4 then
        state.attackLockedUntil = state.busyUntil + Config.ComboFinisherCooldown
    end
    state.strike = {
        id = state.sequence,
        definition = def,
        weaponId = weaponId,
        tool = tool,
        combo = combo,
        started = now,
        origin = state.root.Position,
        hit = {},
        requestId = requestId,
    }
    self:Emit("Attack", model, {
        combo = combo,
        heavy = action == "Heavy",
        duration = state.busyUntil - now,
        windup = def.windup,
        active = def.active,
        requestId = requestId,
    })
    return true, "Accepted"
end
function Service:Block(model: Model, enabled: boolean): (boolean, string)
    local state = self.states:Get(model)
    local now = self.clock()
    if not state then
        return false, "Unavailable"
    end
    if not enabled then
        if state.blocking then
            state.cooldowns.Block = now + 0.25
        end
        state.blocking = false
        self:Emit("BlockEnd", model)
        return true, "Accepted"
    end
    if
        not Definitions.CanAct(state, now)
        or state.blocking
        or (state.cooldowns.Block or 0) > now
        or not self:Weapon(model)
    then
        return false, "Busy"
    end
    if state.stamina < 8 then
        return false, "Stamina"
    end
    state.blocking = true
    state.blockStarted = now
    state.parryUsed = (state.cooldowns.Parry or 0) > now
    self:Emit("BlockStart", model)
    return true, "Accepted"
end
function Service:Dash(model: Model, direction: Vector3, requestId: string?): (boolean, string)
    local state = self.states:Get(model)
    local now = self.clock()
    if
        not state
        or state.root.Anchored
        or state.blocking
        or not Definitions.CanAct(state, now)
        or (state.cooldowns.Movement or 0) > now
    then
        return false, "Busy"
    end
    if not self.states:Spend(state, Config.DashCost, now) then
        return false, "Stamina"
    end
    local d = Vector3.new(direction.X, 0, direction.Z).Unit
    state.cooldowns.Movement = now + Config.DashCooldown
    state.busyUntil = now + Config.DashDuration
    state.invulnerableUntil = now + Config.DashIFrames
    local velocity = state.root.AssemblyLinearVelocity
    local start = math.min(Vector3.new(velocity.X, 0, velocity.Z).Magnitude, MovementConfig.MaxSpeed)
    local boost = MovementModel.new()
    local profile = DashProfile.Build(d, start)
    MovementModel.beginBoost(boost, profile)
    state.dash = {
        direction = d,
        origin = state.root.Position,
        expires = now + Config.DashDuration,
        boost = boost,
        requestId = requestId,
        playerOwned = Players:GetPlayerFromCharacter(model) ~= nil,
        distance = profile.Distance,
    }
    self:Emit("Move", model, { direction = d, duration = Config.DashDuration, requestId = requestId })
    return true, "Accepted"
end
function Service:Handle(player: Player, r: any)
    if not Validator.Intent(r) then
        return
    end
    local now = self.clock()
    local guard = self.guards[player]
    if not guard then
        guard = { tokens = Config.Burst, time = now, seen = {}, order = {} }
        self.guards[player] = guard
    end
    guard.tokens = math.min(Config.Burst, guard.tokens + (now - guard.time) * Config.RequestsPerSecond)
    guard.time = now
    if guard.tokens < 1 then
        return
    end
    guard.tokens -= 1
    if guard.seen[r.requestId] then
        return
    end
    guard.seen[r.requestId] = true
    table.insert(guard.order, r.requestId)
    if #guard.order > 128 then
        guard.seen[table.remove(guard.order, 1)] = nil
    end
    local model = player.Character
    local movementAction = r.action == "Dash"
    if not model or (not movementAction and not Access.Model(model)) then
        return
    end
    local ok, code
    if r.action == "Debug" then
        local allowed = Run:IsStudio()
            or table.find(Config.DebugUserIds, player.UserId) ~= nil
            or game.CreatorType == Enum.CreatorType.User and game.CreatorId == player.UserId
        if allowed then
            self.debug[player] = r.enabled
            ok, code = true, "Accepted"
        else
            ok, code = false, "Denied"
        end
    elseif r.action == "Light" or r.action == "Heavy" then
        ok, code = self:Attack(model, r.action, r.requestId)
    elseif r.action == "BlockStart" or r.action == "BlockEnd" then
        ok, code = self:Block(model, r.action == "BlockStart")
    else
        ok, code = self:Dash(model, r.direction, r.requestId)
    end
    local state = self.states.records[model]
    self.result:FireClient(player, {
        requestId = r.requestId,
        ok = ok,
        code = code,
        attackReadyAt = workspace:GetServerTimeNow()
            + math.max(0, (state and state.attackLockedUntil or 0) - now),
    })
end
function Service:PreparePlayer(player: Player)
    local model = player.Character
    local h = model and model:FindFirstChildOfClass("Humanoid")
    if not model or not h or h.Health <= 0 then
        return
    end
    local state = self.states.records[model]
    if state and not state.inCombat then
        h:UnequipTools()
    end
end
function Service:CleanupPlayer(player: Player, preserveMovement: boolean?)
    if player.Character and not preserveMovement then
        self.states:Remove(player.Character)
    elseif player.Character then
        local state = self.states.records[player.Character]
        if state then
            state.blocking = false
            state.strike = nil
            state.combo = 0
        end
    end
    for _, container in ipairs({ player.Character, player:FindFirstChildOfClass("Backpack") }) do
        if container then
            for _, tool in ipairs(container:GetChildren()) do
                if tool:GetAttribute("CombatDemoWeapon") then
                    tool:Destroy()
                end
            end
        end
    end
end
function Service:SampleStrike(state, now: number)
    local model, strike = state.model, state.strike
    if not strike then
        return
    end
    local _, tool = self:Weapon(model)
    local age, def = now - strike.started, strike.definition
    if
        tool ~= strike.tool
        or (state.root.Position - strike.origin).Magnitude > Config.MaxAttackTravel
        or state.stunnedUntil > now
    then
        state.strike = nil
    elseif age > def.windup + def.active then
        state.strike = nil
    elseif age >= def.windup then
        if self.effect then
            for player, enabled in pairs(self.debug) do
                if enabled and player.Character and Access.Model(player.Character) then
                    local cf, size = Hitbox.Geometry(state.root, def)
                    self.effect:FireClient(player, { kind = "Debug", cframe = cf, size = size })
                end
            end
        end
        for _, target in ipairs(Hitbox.Query(model, def)) do
            if state.strike ~= strike then
                break
            end
            if
                not strike.hit[target]
                and Access.Model(target)
                and (Players:GetPlayerFromCharacter(target) or target:GetAttribute("CombatNPC"))
            then
                strike.hit[target] = true
                self.damage:Apply(model, target, def)
            end
        end
    end
end
function Service:BindNPC(npc: Model)
    local scope = Scope.new()
    self.npcScopes[npc] = scope
    local prompt = npc:FindFirstChild("TrainingMode", true)
    local h = npc:FindFirstChildOfClass("Humanoid")
    local times = {}
    scope:Connect(h.HealthChanged, function(health)
        prompt.Enabled = health > 0
    end)
    scope:Connect(Players.PlayerRemoving, function(player)
        times[player.UserId] = nil
    end)
    scope:Connect(prompt.Triggered, function(player)
        local char = player.Character
        local pr = char and char:FindFirstChild("HumanoidRootPart")
        local now = self.clock()
        if
            h.Health <= 0
            or not pr
            or not Access.Model(char)
            or (pr.Position - npc.HumanoidRootPart.Position).Magnitude > 9
            or (times[player.UserId] or 0) > now
        then
            return
        end
        local ray = RaycastParams.new()
        ray.FilterType = Enum.RaycastFilterType.Exclude
        ray.FilterDescendantsInstances = { char, npc }
        ray.RespectCanCollide = true
        if workspace:Raycast(pr.Position, npc.HumanoidRootPart.Position - pr.Position, ray) then
            return
        end
        times[player.UserId] = now + 0.5
        local modes = { "Idle", "Block", "Parry", "Sparring" }
        local mode = modes[(table.find(modes, npc:GetAttribute("CombatMode")) or 1) % 4 + 1]
        npc:SetAttribute("CombatMode", mode)
        prompt.ActionText = mode
    end)
end
function Service:RespawnNPC(index: number)
    local old = self.npcs[index]
    local mode = old:GetAttribute("CombatMode") or "Idle"
    local name = old.Name
    local position = self.npcSpawns[index]
    self.states:Remove(old)
    self.npcDead[old] = nil
    self.npcAttack[old] = nil
    if self.npcScopes[old] then
        self.npcScopes[old]:Destroy()
        self.npcScopes[old] = nil
    end
    old:Destroy()
    local npc = Demo.Rig(self.demo, name, position, mode)
    npc:SetAttribute("CombatTrainingDummy", true)
    npc:PivotTo(npc:GetPivot() * CFrame.Angles(0, math.pi, 0))
    self.npcs[index] = npc
    self:BindNPC(npc)
end
function Service:Step(dt: number)
    local now = self.clock()
    for _, player in ipairs(Players:GetPlayers()) do
        local model = player.Character
        local h = model and model:FindFirstChildOfClass("Humanoid")
        local state = model and h and h.Health > 0 and self.states:Get(model)
        if state and Access.Model(model) then
            self:PreparePlayer(player)
            state.inCombat = true
        elseif state and state.inCombat then
            self:CleanupPlayer(player, true)
            state.inCombat = false
        end
    end
    for index, npc in ipairs(self.npcs or {}) do
        local h, root = npc:FindFirstChildOfClass("Humanoid"), npc:FindFirstChild("HumanoidRootPart")
        if not h or not root then
            continue
        end
        if h.Health <= 0 then
            self.npcDead[npc] = self.npcDead[npc] or now + Config.DummyRespawnSeconds
            if now >= self.npcDead[npc] then
                self:RespawnNPC(index)
            end
            continue
        end
        local mode = npc:GetAttribute("CombatMode")
        local state = self.states:Get(npc)
        if mode == "Block" or mode == "Parry" then
            if not state.blocking then
                self:Block(npc, true)
            end
        elseif state.blocking then
            self:Block(npc, false)
        end
        if mode == "Sparring" and (self.npcAttack[npc] or 0) <= now then
            local nearest, distance = nil, 8
            for _, player in ipairs(Players:GetPlayers()) do
                local char = player.Character
                local pr = char and char:FindFirstChild("HumanoidRootPart")
                if pr and Access.Model(char) and (pr.Position - root.Position).Magnitude < distance then
                    nearest = pr
                    distance = (pr.Position - root.Position).Magnitude
                end
            end
            if nearest then
                local target = Vector3.new(nearest.Position.X, root.Position.Y, nearest.Position.Z)
                if (target - root.Position).Magnitude > 0.1 then
                    root.CFrame = CFrame.lookAt(root.Position, target)
                end
                local ok = self:Attack(npc, "Light")
                if ok then
                    self.npcAttack[npc] = now + 1.25
                end
            end
        end
    end
    local removals = {}
    for model, state in pairs(self.states.records) do
        if
            not model.Parent
            or state.humanoid.Health <= 0
            or (not Players:GetPlayerFromCharacter(model) and not Access.Model(model))
        then
            table.insert(removals, model)
            continue
        end
        if state.lastPosition and (state.root.Position - state.lastPosition).Magnitude > 10 then
            self.states:Stun(state, 0.5, now)
        end
        state.lastPosition = state.root.Position
        self.states:Step(state, dt, now)
        if state.blocking and not self:Weapon(model) then
            self:Block(model, false)
        end
        if state.dash then
            local dash = state.dash
            MovementModel.stepBoost(dash.boost, dt)
            local speed = dash.boost.outputSpeed
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = { model }
            params.RespectCanCollide = true
            local blocked =
                workspace:Raycast(state.root.Position, dash.direction * (speed * dt + 1.5), params)
            local travel = state.root.Position - dash.origin
            local distance = Vector3.new(travel.X, 0, travel.Z).Magnitude
            if now >= dash.expires or distance >= dash.distance + 2 or blocked then
                local cancelled = blocked ~= nil or distance >= dash.distance + 2
                if distance >= dash.distance + 2 then
                    state.root.CFrame += dash.direction * dash.distance - Vector3.new(travel.X, 0, travel.Z)
                end
                self.states:EndDash(state, cancelled)
                self:Emit("MoveEnd", model, { requestId = dash.requestId, cancelled = cancelled })
            elseif not dash.playerOwned then
                state.root.AssemblyLinearVelocity = Vector3.new(
                    dash.direction.X * speed,
                    state.root.AssemblyLinearVelocity.Y,
                    dash.direction.Z * speed
                )
            end
        end
        self:SampleStrike(state, now)
    end
    for _, model in ipairs(removals) do
        self.states:Remove(model)
    end
    self.syncElapsed += dt
    if self.syncElapsed >= Config.SyncInterval then
        self.syncElapsed = 0
        for _, player in ipairs(Players:GetPlayers()) do
            local state = player.Character and self.states.records[player.Character]
            if state then
                self.result:FireClient(player, {
                    state = Definitions.Name(state, now),
                    stamina = state.stamina,
                    combo = state.combo,
                    debug = self.debug[player] == true,
                    attackReadyAt = workspace:GetServerTimeNow()
                        + math.max(0, (state.attackLockedUntil or 0) - now),
                })
            end
        end
    end
end
function Service:Start()
    if self.scope then
        return
    end
    for _, name in { "CombatIntent", "CombatResult", "CombatEffect" } do
        if not Root.Network:FindFirstChild(name) then
            local remote = Instance.new("RemoteEvent")
            remote.Name = name
            remote.Parent = Root.Network
        end
    end
    local scope = Scope.new()
    self.scope = scope
    self.noise = Instance.new("BindableEvent")
    scope:Add(function()
        self.noise:Destroy()
        self.noise = nil
    end)
    self.syncElapsed = 0
    self.npcDead = {}
    self.npcAttack = {}
    self.npcScopes = {}
    self.npcSpawns = {}
    self.result = Root.Network.CombatResult
    self.effect = Root.Network.CombatEffect
    local platform = Access.Platform()
    if platform then
        Demo.EnsureAvatar()
        if not scope.alive then
            return
        end
        self.demo, self.npcs = Demo.Create(platform)
        scope:Add(function()
            self.demo:Destroy()
        end)
        for index, npc in ipairs(self.npcs) do
            self.npcSpawns[index] = npc.HumanoidRootPart.Position
            self:BindNPC(npc)
        end
    end
    scope:Connect(Root.Network.CombatIntent.OnServerEvent, function(p, r)
        self:Handle(p, r)
    end)
    scope:Connect(Players.PlayerRemoving, function(p)
        self:CleanupPlayer(p)
        self.guards[p] = nil
        self.debug[p] = nil
    end)
    local elapsed = 0
    scope:Connect(Run.Heartbeat, function(dt)
        elapsed += dt
        if elapsed >= Config.Tick then
            local step = math.min(elapsed, 0.1)
            elapsed = 0
            self:Step(step)
        end
    end)
end
function Service:Stop()
    if not self.scope then
        return
    end
    for _, scope in pairs(self.npcScopes) do
        scope:Destroy()
    end
    table.clear(self.npcScopes)
    self.scope:Destroy()
    self.scope = nil
    for _, p in ipairs(Players:GetPlayers()) do
        self:CleanupPlayer(p)
    end
    self.states:Stop()
    table.clear(self.guards)
    table.clear(self.debug)
end
return Service
