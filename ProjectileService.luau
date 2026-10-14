-- Connected Discord-GitHub
--!strict
local Config = require(game.ReplicatedStorage.ProjectileSystem.ProjectileConfig)
local Service = {}
Service.__index = Service
export type Projectile = {
    Id: number,
    Kind: string,
    Position: Vector3,
    Velocity: Vector3,
    Gravity: Vector3,
    Age: number,
    Distance: number,
    Bounces: number,
    Owner: number,
    Character: Model?,
    Params: RaycastParams,
    Definition: Config.Definition,
}
local function finite(n: number): boolean
    return n == n and math.abs(n) < math.huge
end
local function vector(value: any): boolean
    return typeof(value) == "Vector3" and finite(value.X) and finite(value.Y) and finite(value.Z)
end
local function humanoidFrom(part: Instance): Humanoid?
    local node: Instance? = part
    while node and node ~= workspace do
        if node:IsA("Model") then
            local humanoid = node:FindFirstChildOfClass("Humanoid")
            if humanoid then
                return humanoid
            end
        end
        node = node.Parent
    end
    return nil
end
function Service.new(options: any?): any
    options = options or {}
    return setmetatable({
        Active = {} :: { [number]: Projectile },
        Count = 0,
        NextId = 0,
        Players = {},
        Impacts = {},
        Destroyed = false,
        Raycast = options.Raycast or function(origin, displacement, params)
            return workspace:Raycast(origin, displacement, params)
        end,
        CanFire = options.CanFire or function()
            return true
        end,
        CanDamage = options.CanDamage or function()
            return true
        end,
        Clock = options.Clock or os.clock,
    }, Service)
end
function Service:Remove(id: number)
    local shot = self.Active[id]
    if shot then
        self.Active[id] = nil
        self.Count -= 1
    end
end
function Service:RemovePlayer(userId: number)
    self.Players[userId] = nil
    for id, shot in self.Active do
        if shot.Owner == userId then
            self:Remove(id)
        end
    end
end
-- Trusted server-only spawn API; client requests go through Request.
function Service:Spawn(
    kind: string,
    origin: Vector3,
    direction: Vector3,
    owner: number,
    character: Model?
): number?
    local definition = Config.Types[kind]
    if
        self.Destroyed
        or not definition
        or self.Count >= Config.MaxActive
        or not vector(origin)
        or not vector(direction)
        or not finite(direction.Magnitude)
        or direction.Magnitude < 0.001
    then
        return nil
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = if character then { character } else {}
    params.IgnoreWater = false
    self.NextId += 1
    local id = self.NextId
    self.Active[id] = {
        Id = id,
        Kind = kind,
        Position = origin,
        Velocity = direction.Unit * definition.Speed,
        Gravity = Vector3.new(0, -workspace.Gravity * definition.GravityMultiplier, 0),
        Age = 0,
        Distance = 0,
        Bounces = 0,
        Owner = owner,
        Character = character,
        Params = params,
        Definition = definition,
    }
    self.Count += 1
    return id
end
function Service:Request(player: Player, request: any): (boolean, string)
    if self.Destroyed then
        return false, "Stopped"
    end
    local now = self.Clock()
    local state = self.Players[player.UserId]
    if not state then
        state = { Tokens = 8, Updated = now, NextFire = 0, Sequence = 0 }
        self.Players[player.UserId] = state
    end
    state.Tokens = math.min(8, state.Tokens + math.max(0, now - state.Updated) * 12)
    state.Updated = now
    if state.Tokens < 1 then
        return false, "Rate limited"
    end
    state.Tokens -= 1
    if typeof(request) ~= "table" then
        return false, "Invalid request"
    end
    local fields = 0
    for key in request do
        fields += 1
        if fields > 3 or (key ~= "Kind" and key ~= "Direction" and key ~= "Sequence") then
            return false, "Invalid fields"
        end
    end
    if
        type(request.Kind) ~= "string"
        or #request.Kind > 20
        or not Config.Types[request.Kind]
        or not vector(request.Direction)
        or math.abs(request.Direction.Magnitude - 1) > 0.01
        or type(request.Sequence) ~= "number"
        or not finite(request.Sequence)
        or request.Sequence % 1 ~= 0
        or request.Sequence <= state.Sequence
        or request.Sequence > 2 ^ 31
    then
        return false, "Invalid parameters"
    end
    state.Sequence = request.Sequence
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local head = character and character:FindFirstChild("Head")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if
        not humanoid
        or humanoid.Health <= 0
        or not head
        or not head:IsA("BasePart")
        or not root
        or not root:IsA("BasePart")
        or (head.Position - root.Position).Magnitude > 5
        or not self.CanFire(player, request.Kind)
    then
        return false, "Unavailable"
    end
    if now < state.NextFire then
        return false, "Cooldown"
    end
    local owned = 0
    for _, shot in self.Active do
        if shot.Owner == player.UserId then
            owned += 1
        end
    end
    if owned >= Config.MaxPerPlayer or self.Count >= Config.MaxActive then
        return false, "Capacity"
    end
    local id = self:Spawn(request.Kind, head.Position, request.Direction, player.UserId, character)
    if not id then
        return false, "Capacity"
    end
    state.NextFire = now + Config.Types[request.Kind].Cooldown
    return true, "Fired"
end
function Service:Impact(shot: Projectile, hit: any, bounced: boolean)
    if #self.Impacts < 256 then
        table.insert(self.Impacts, {
            Position = hit.Position,
            Normal = hit.Normal,
            Material = hit.Material.Name,
            Bounced = bounced,
            Kind = shot.Kind,
        })
    end
end
function Service:Advance(shot: Projectile, dt: number)
    local remaining = dt
    local contacts = 0
    while remaining > 1e-7 and self.Active[shot.Id] do
        local definition = shot.Definition
        local time = math.min(remaining, definition.Lifetime - shot.Age)
        if time <= 1e-7 then
            self:Remove(shot.Id)
            break
        end
        local displacement = shot.Velocity * time + shot.Gravity * (0.5 * time * time)
        local length = displacement.Magnitude
        local rangeLeft = definition.Range - shot.Distance
        if rangeLeft <= 1e-6 then
            self:Remove(shot.Id)
            break
        end
        -- Short chords approximate the ballistic curve; every chord is swept by a ray.
        local rangeFraction = if length > 0 then math.min(1, rangeLeft / length) else 1
        displacement *= rangeFraction
        local hit = if displacement.Magnitude > 1e-8
            then self.Raycast(shot.Position, displacement, shot.Params)
            else nil
        local fraction = if hit
            then math.clamp(hit.Distance / math.max(length, 1e-8), 0, 1)
            else rangeFraction
        local used = time * fraction
        shot.Age += used
        shot.Distance += if hit then hit.Distance else displacement.Magnitude
        shot.Velocity += shot.Gravity * used
        remaining -= used
        if not hit then
            shot.Position += displacement
            if rangeFraction < 1 or shot.Age >= definition.Lifetime - 1e-7 then
                self:Remove(shot.Id)
            end
            break
        end
        shot.Position = hit.Position
        local humanoid = humanoidFrom(hit.Instance)
        if
            humanoid
            and humanoid.Health > 0
            and humanoid.Parent ~= shot.Character
            and self.CanDamage(shot, humanoid)
        then
            humanoid:TakeDamage(definition.Damage)
        end
        -- Grazing angle is measured from the surface plane (0 = parallel, 90 = head-on).
        local speed = shot.Velocity.Magnitude
        local dot = if speed > 0 then shot.Velocity.Unit:Dot(hit.Normal) else 0
        local grazing = math.deg(math.asin(math.clamp(math.abs(dot), 0, 1)))
        local bounce = grazing <= definition.MaxGrazingAngle
            and shot.Bounces < definition.MaxRicochets
            and speed * definition.BounceRetention >= Config.MinBounceSpeed
        self:Impact(shot, hit, bounce)
        contacts += 1
        if not bounce or contacts >= 4 then
            self:Remove(shot.Id)
            break
        end
        -- Reflect v about n: v' = v - 2(v·n)n, then dissipate energy.
        shot.Velocity = (shot.Velocity - 2 * shot.Velocity:Dot(hit.Normal) * hit.Normal)
            * definition.BounceRetention
        shot.Position += hit.Normal * Config.SurfaceOffset
        shot.Distance += Config.SurfaceOffset
        shot.Bounces += 1
    end
end
function Service:Step(dt: number)
    if self.Destroyed or not finite(dt) or dt <= 0 then
        return
    end
    if dt > Config.MaxFrameTime then
        -- Fail closed after a long stall instead of skipping collision checks.
        table.clear(self.Active)
        self.Count = 0
        return
    end
    local steps = math.ceil(dt / Config.Step)
    local step = dt / steps
    for _ = 1, steps do
        for _, shot in self.Active do
            self:Advance(shot, step)
        end
    end
end
function Service:Snapshot(): any
    local list = {}
    for _, shot in self.Active do
        table.insert(list, {
            Id = shot.Id,
            Kind = shot.Kind,
            Position = shot.Position,
            Velocity = shot.Velocity,
            Gravity = shot.Gravity,
        })
    end
    local impacts = self.Impacts
    self.Impacts = {}
    return { Shots = list, Impacts = impacts }
end
function Service:Destroy()
    if self.Destroyed then
        return
    end
    self.Destroyed = true
    table.clear(self.Active)
    table.clear(self.Players)
    table.clear(self.Impacts)
    self.Count = 0
end
return Service
