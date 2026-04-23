--[[
    autopeek/Movement.lua
    Predictive, no-overshoot WalkTo for AutoPeek.
    Physics: predict where the player coasts to after passive drag this tick,
    compute the delta-V needed to land exactly on dest, clamp to sv_accelerate,
    and add an overshoot guard so we never command more speed than the
    remaining distance divided by one tick.

    Imported by: AutoPeek.lua
]]

local Movement = {}

-- Constants
local MAX_SPEED        = 450     -- u/s cap for wishspeed inputs
local TWO_PI           = 2 * math.pi
local DEG_TO_RAD       = math.pi / 180
local DEFAULT_FRICTION = 4
local DEFAULT_ACCEL    = 10

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

-- Converts a world-space direction (pos -> dirEnd) into forward/side move
-- values relative to the player's view yaw, scaled to MAX_SPEED.
local function computeMove(pCmd, pos, dirEnd)
assert(pCmd   ~= nil, "computeMove: pCmd missing")
assert(pos    ~= nil, "computeMove: pos missing")
assert(dirEnd ~= nil, "computeMove: dirEnd missing")

local dx = dirEnd.x - pos.x
local dy = dirEnd.y - pos.y
local targetYaw = (math.atan(dy, dx) + TWO_PI) % TWO_PI

local _, cYaw, _ = pCmd:GetViewAngles()
local cYawRad = cYaw * DEG_TO_RAD

local yawDiff = (targetYaw - cYawRad + math.pi) % TWO_PI - math.pi

local forward = math.cos(yawDiff)  * MAX_SPEED
local side    = math.sin(-yawDiff) * MAX_SPEED
return forward, side
end

--- Physics-accurate WalkTo with drag prediction and overshoot guard.
---
--- Steps:
---   1. Predict where the player coasts after ground friction this tick.
---   2. Compute deltaV = (dest - predicted_pos) / dt to find needed velocity.
---   3. Clamp deltaV magnitude to sv_accelerate limit (aMax).
---   4. Scale wishSpeed proportionally; add dist/dt overshoot guard.
---   5. Convert acceleration direction to forward/side move inputs.
---
---@param pCmd   userdata CUserCmd
---@param pLocal userdata Local player entity
---@param dest   Vector3  World-space destination (feet)
function Movement.WalkTo(pCmd, pLocal, dest)
assert(pCmd   ~= nil, "Movement.WalkTo: pCmd missing")
assert(pLocal ~= nil, "Movement.WalkTo: pLocal missing")
assert(dest   ~= nil, "Movement.WalkTo: dest missing")

local pos = pLocal:GetAbsOrigin()
assert(pos ~= nil, "Movement.WalkTo: GetAbsOrigin returned nil")

local dt = globals.TickInterval()
if dt <= 0 then
dt = 1 / 66.67
end

-- Current horizontal velocity (ignore Z)
local vel = pLocal:EstimateAbsVelocity()
assert(vel ~= nil, "Movement.WalkTo: EstimateAbsVelocity returned nil")
vel.z = 0

-- 1. Predict position after passive drag this tick
local drag      = math.max(0, 1 - getGroundFriction() * dt)
local velNext   = vel * drag
local predicted = Vector3(pos.x + velNext.x * dt, pos.y + velNext.y * dt, pos.z)

-- 2. Remaining horizontal displacement from predicted pos to dest
local need = dest - predicted
need.z = 0
local dist = need:Length()

if dist < 1.5 then
pCmd:SetForwardMove(0)
pCmd:SetSideMove(0)
return
end

-- 3. deltaV needed to arrive at dest in one tick
local deltaV   = (need / dt) - velNext
local deltaLen = deltaV:Length()

if deltaLen < 0.1 then
pCmd:SetForwardMove(0)
pCmd:SetSideMove(0)
return
end

-- 4. Clamp to sv_accelerate budget and compute wishSpeed
local aMax     = getMaxAccelPerTick(pLocal, dt)
local accelDir = deltaV / deltaLen
local accelLen = math.min(deltaLen, aMax)

-- Proportional wishSpeed, minimum 20 to avoid creeping
local wishSpeed = math.max(MAX_SPEED * (accelLen / aMax), 20)

-- Overshoot guard: never request more speed than dist/dt allows
local maxNoOvershoot = dist / dt
wishSpeed = math.min(wishSpeed, maxNoOvershoot)
if wishSpeed < 5 then
pCmd:SetForwardMove(0)
pCmd:SetSideMove(0)
return
end

-- 5. Convert accelDir into local-space move inputs
local dirEnd = pos + accelDir
local fwdRaw, sideRaw = computeMove(pCmd, pos, dirEnd)
local fwd  = (fwdRaw  / MAX_SPEED) * wishSpeed
local side = (sideRaw / MAX_SPEED) * wishSpeed

pCmd:SetForwardMove(fwd)
pCmd:SetSideMove(side)
end

return Movement
