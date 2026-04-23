--[[
    autopeek/Movement.lua
    Predictive, no-overshoot WalkTo for AutoPeek.
    Mirrors the logic from the C++ SDK::WalkTo / SDK::ComputeMove but adds
    counter-velocity steering so the player decelerates into the target
    instead of overshooting.

    Imported by: AutoPeek.lua
]]

local Movement = {}

-- ── Constants ───────────────────────────────────────────────────────────────
local MAX_SPEED        = 300     -- u/s, sniper base speed (used as input cap)
local TWO_PI           = 2 * math.pi
local DEG_TO_RAD       = math.pi / 180
local DEFAULT_FRICTION = 4       -- sv_friction fallback
local DEFAULT_ACCEL    = 10      -- sv_accelerate fallback

-- ── Helpers ─────────────────────────────────────────────────────────────────
local function getGroundFriction()
    local val = client.GetConVar("sv_friction")
    local isValid = val ~= nil and val > 0
    if isValid then
        return val
    end
    return DEFAULT_FRICTION
end

local function getMaxAccelPerTick(pLocal, dt)
    assert(pLocal ~= nil, "getMaxAccelPerTick: pLocal missing")
    assert(dt ~= nil and dt > 0, "getMaxAccelPerTick: dt invalid")

    local svA = client.GetConVar("sv_accelerate")
    local isAccelValid = svA ~= nil and svA > 0
    if not isAccelValid then
        svA = DEFAULT_ACCEL
    end

    local cap = pLocal:GetPropFloat("m_flMaxspeed")
    local isCapValid = cap ~= nil and cap > 0
    if not isCapValid then
        cap = MAX_SPEED
    end

    return svA * cap * dt
end

-- Converts a world-space displacement vector into forward/side move values
-- relative to the player's current view yaw.
local function computeMove(pCmd, displacement)
    assert(pCmd ~= nil, "computeMove: pCmd missing")
    assert(displacement ~= nil, "computeMove: displacement missing")

    local dx = displacement.x
    local dy = displacement.y
    local targetYaw = (math.atan(dy, dx) + TWO_PI) % TWO_PI

    local _, cYaw, _ = pCmd:GetViewAngles()
    local cYawRad = cYaw * DEG_TO_RAD

    local yawDiff = (targetYaw - cYawRad + math.pi) % TWO_PI - math.pi

    local forward = math.cos(yawDiff) * MAX_SPEED
    local side    = math.sin(-yawDiff) * MAX_SPEED
    return forward, side
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Predictive WalkTo. Steers acceleration to counter current velocity so the
--- player arrives at dest without overshooting.
---@param pCmd      userdata  CUserCmd
---@param pLocal    userdata  Local player entity
---@param dest      Vector3   World-space destination (feet)
function Movement.WalkTo(pCmd, pLocal, dest)
    assert(pCmd   ~= nil, "Movement.WalkTo: pCmd missing")
    assert(pLocal ~= nil, "Movement.WalkTo: pLocal missing")
    assert(dest   ~= nil, "Movement.WalkTo: dest missing")

    local pos = pLocal:GetAbsOrigin()
    assert(pos ~= nil, "Movement.WalkTo: GetAbsOrigin returned nil")

    local toDest = dest - pos
    toDest.z = 0
    local distToDest = toDest:Length()

    -- Already there – kill inputs
    if distToDest < 1.5 then
        pCmd:SetForwardMove(0)
        pCmd:SetSideMove(0)
        return
    end

    local dt = globals.TickInterval()
    if dt <= 0 then
        dt = 1 / 66.67
    end

    -- Current horizontal velocity (server-side estimate, per tick)
    local vel = pLocal:EstimateAbsVelocity()
    assert(vel ~= nil, "Movement.WalkTo: EstimateAbsVelocity returned nil")
    local velPerTick = Vector3(vel.x * dt, vel.y * dt, 0)

    local maxAccel    = getMaxAccelPerTick(pLocal, dt)

    -- Counter-velocity steering:
    -- Place the "ideal acceleration tip" at (pos + velPerTick) and aim at dest.
    -- This naturally decelerates as we approach.
    local accelVec = toDest - velPerTick
    local accelLen = accelVec:Length()

    local displacement
    if accelLen <= maxAccel * dt then
        -- Close enough – just walk straight to dest this tick
        displacement = toDest
    else
        -- Scale acceleration vector to physics limit
        local accelDir = accelVec / accelLen
        displacement   = accelDir * maxAccel
    end

    local forward, side = computeMove(pCmd, displacement)
    pCmd:SetForwardMove(forward)
    pCmd:SetSideMove(side)
end

return Movement
