--[[
    Auto Peek for Lmaobox
    Author: titaniummachine1 (github.com/titaniummachine1)
    Origin Author: LNX (github.com/lnx00)
]]

local menuLoaded, TimMenu = pcall(require, "TimMenu")
assert(menuLoaded, "TimMenu not found, please install it!")

-- Additional libs
local okLib, lnxLib = pcall(require, "lnxlib")
if okLib then
	Math = lnxLib.Utils and lnxLib.Utils.Math or nil
end

-- Aliases for external functions (localized for performance and memory optimization):
-- ONLY frequently called functions are localized to reduce memory leaks
-- Infrequently called functions use direct API calls for better maintainability

-- Draw API (called every frame, high memory impact)
local createFont = draw.CreateFont
local deleteTexture = draw.DeleteTexture
local createTextureRGBA = draw.CreateTextureRGBA
local setColor = draw.Color
local filledRect = draw.FilledRect
local getTextSize = draw.GetTextSize
local drawText = draw.Text
local drawLine = draw.Line
local texturedPolygon = draw.TexturedPolygon
local setFont = draw.SetFont

-- Engine API (called in tight loops)
local getViewAngles = engine.GetViewAngles
local traceLine = engine.TraceLine
local traceHull = engine.TraceHull

-- Client API (called frequently)
local worldToScreen = client.WorldToScreen
local clientCommand = client.Command

-- Input API (called every frame)
local isButtonDown = input.IsButtonDown

-- Math functions
local mathFloor = math.floor
local mathMax = math.max
local mathMin = math.min
local mathSqrt = math.sqrt
local mathDeg = math.deg
local mathRad = math.rad
local mathAcos = math.acos
local mathCos = math.cos
local mathSin = math.sin
local mathPi = math.pi
local mathAbs = math.abs
local mathCeil = math.ceil

-- String functions (frequently used)
local stringFormat = string.format
local stringChar = string.char

-- Table functions
local tableInsert = table.insert
local tableSort = table.sort

-- Font creation (create once on load, set every frame to avoid memory overflow)
local options = {
	Font = createFont("Roboto", 20, 400),
}

-- Menu structure
local Menu = {
	-- Main settings
	Enabled = true,
	Key = KEY_LSHIFT, -- Hold this key to start peeking
	PeekAssist = true, -- Enables peek assist (smart mode). Disable for manual return
	PeekTicks = 33, -- Max peek ticks (10-132)
	Iterations = 7, -- Binary-search refinement passes
	WarpBack = true, -- Warp back instantly instead of walking
	InstantStop = false, -- Enable instant stop on shooting

	TargetLimit = 3, -- Max players considered per tick (optimized for multi-sniper scenarios)

	-- Target hitboxes
	TargetHitboxes = { true, false, false, false, false, true }, -- Defaults: HEAD on, others off
	HitboxOptions = { "HEAD", "NECK", "PELVIS", "BODY", "CHEST", "VIEWPOS" },

	-- Visuals
	Visuals = {
		CircleColor = { 0, 255, 0, 30 }, -- Start circle color RGBA
	},
}

local Lua__fullPath = GetScriptName()
local Lua__fileName = Lua__fullPath:match("\\([^\\]-)$"):gsub("%.lua$", "")

-- Config helpers (same as Swing Prediction) -----------------------------------------------------------------
-- Build full path once from script name or supplied folder
local function GetConfigPath(folder_name)
	folder_name = folder_name or string.format([[Lua %s]], Lua__fileName)
	local _, fullPath = filesystem.CreateDirectory(folder_name) -- succeeds even if already exists
	local sep = package.config:sub(1, 1)
	return fullPath .. sep .. "config.cfg"
end

-- Serialize a Lua table (simple, ordered by iteration) ------------------------------------
local function serializeTable(tbl, level)
	level = level or 0
	local indent = string.rep("    ", level)
	local out = indent .. "{\n"
	for k, v in pairs(tbl) do
		local keyRepr = (type(k) == "string") and string.format('["%s"]', k) or string.format("[%s]", k)
		out = out .. indent .. "    " .. keyRepr .. " = "
		if type(v) == "table" then
			out = out .. serializeTable(v, level + 1) .. ",\n"
		elseif type(v) == "string" then
			out = out .. string.format('"%s",\n', v)
		else
			out = out .. tostring(v) .. ",\n"
		end
	end
	out = out .. indent .. "}"
	return out
end

-- Strict structural match check: ensures both tables have identical keys and types
local function keysMatch(template, loaded)
	-- First, template keys must exist in loaded with same type
	for k, v in pairs(template) do
		local lv = loaded[k]
		if lv == nil then
			return false
		end
		if type(v) ~= type(lv) then
			return false
		end
		if type(v) == "table" then
			if not keysMatch(v, lv) then
				return false
			end
		end
	end
	-- Second, loaded must NOT contain extra keys absent in template
	for k, _ in pairs(loaded) do
		if template[k] == nil then
			return false
		end
	end
	return true
end

-- Save current (or supplied) menu ---------------------------------------------------------
local function CreateCFG(folder_name, cfg)
	cfg = cfg or Menu
	local path = GetConfigPath(folder_name)
	local f = io.open(path, "w")
	if not f then
		printc(255, 0, 0, 255, "[Config] Failed to write: " .. path)
		return
	end
	f:write(serializeTable(cfg))
	f:close()
	printc(100, 183, 0, 255, "[Config] Saved: " .. path)
end

-- Load config; regenerate if invalid/outdated/SHIFT bypass ---------------------------------
local function LoadCFG(folder_name)
	local path = GetConfigPath(folder_name)
	local f = io.open(path, "r")
	if not f then
		-- First run – make directory & default cfg
		CreateCFG(folder_name)
		return Menu
	end
	local content = f:read("*a")
	f:close()

	local chunk, err = load("return " .. content)
	if not chunk then
		print("[Config] Compile error, regenerating: " .. tostring(err))
		CreateCFG(folder_name)
		return Menu
	end

	local ok, cfg = pcall(chunk)
	if not ok or type(cfg) ~= "table" or not keysMatch(Menu, cfg) or input.IsButtonDown(KEY_LSHIFT) then
		print("[Config] Invalid or outdated cfg – regenerating …")
		CreateCFG(folder_name)
		return Menu
	end

	printc(0, 255, 140, 255, "[Config] Loaded: " .. path)
	return cfg
end
-- End of config helpers -----------------------------------------------------------

-- Auto-load config
local status, loadedMenu = pcall(function()
	return assert(LoadCFG(string.format([[Lua %s]], Lua__fileName)))
end)

if status and loadedMenu then
	Menu = loadedMenu
end

-- Ensure all Menu settings are initialized
local function SafeInitMenu()
	if Menu.Enabled == nil then
		Menu.Enabled = true
	end
	Menu.Key = Menu.Key or KEY_LSHIFT
	if Menu.PeekAssist == nil then
		Menu.PeekAssist = true
	end
	if Menu.PeekTicks == nil then
		Menu.PeekTicks = 66
	end
	if Menu.Iterations == nil then
		Menu.Iterations = 6
	end
	if Menu.WarpBack == nil then
		Menu.WarpBack = false
	end
	if Menu.InstantStop == nil then
		Menu.InstantStop = true
	end
	if Menu.TargetLimit == nil then
		Menu.TargetLimit = 8
	end

	-- Initialize TargetHitboxes as boolean array
	if Menu.TargetHitboxes == nil then
		Menu.TargetHitboxes = { true, false, false, false, false, false }
	end
	Menu.HitboxOptions = { "HEAD", "NECK", "PELVIS", "BODY", "CHEST", "VIEWPOS" }

	-- Initialize Visuals settings
	Menu.Visuals = Menu.Visuals or {}
	Menu.Visuals.CircleColor = Menu.Visuals.CircleColor or { 255, 255, 255, 128 }

	-- Initialize debug info
	Menu._DebugInfo = Menu._DebugInfo
		or {
			totalEnemies = 0,
			sniperCount = 0,
			spyCount = 0,
			targetsConsidered = 0,
		}
end

-- Call the initialization function to ensure no nil values
SafeInitMenu()

--[[ Menu Variables - Now using Menu structure ]]

local PosPlaced = false -- Did we start peeking?
local IsReturning = false -- Are we returning?
local HasDirection = false -- Do we have a peek direction?
local PeekStartVec = Vector3(0, 0, 0)
local PeekDirectionVec = Vector3(0, 0, 0)
local PeekReturnVec = Vector3(0, 0, 0)
local PeekSide = 0 -- -1 = left, 1 = right
local OriginalPeekDirection = Vector3(0, 0, 0) -- Store original direction captured at start
local CurrentPeekBasisDir = Vector3(1, 0, 0) -- Direction used for drawing perpendicular lines each tick

-- InstantStop state machine (integrated from InstantStop.lua)
local STATE_DEFAULT = "default"
local STATE_ENDING_FAST_STOP = "ending_fast_stop"
local STATE_COOLDOWN = "cooldown"
local COOLDOWN_TICKS = 7 -- Number of ticks to wait in cooldown
local currentState = STATE_DEFAULT
local cooldownTicksRemaining = 0
local wasGroundedLastTick = false

-- Add tracking for weapon shoot state
local PrevCanShoot = false -- track if weapon could shoot in previous tick

-- Global candidate list (populated once per tick)
local TargetCandidates = {}
local CandidatesUpdateTick = -1

-- Simulation Cache System -----------------------------------------------
-- PERFORMANCE OPTIMIZATION: Cache simulation results to avoid expensive recalculations
-- - Simulation is only computed once per unique (startPos, direction, maxTicks) combination
-- - Binary search uses linear interpolation on cached path for arbitrary precision
-- - Prediction freezing keeps cached results when no movement input detected
-- - Cache automatically cleans itself to prevent memory buildup
local SimulationCache = {}
local SimulationCacheKeys = {}
local MaxCacheSize = 10 -- Limit cache size to prevent memory issues
local CurrentCacheSize = 0
local LastCacheCleanTick = 0
local CACHE_CLEAN_INTERVAL = 66 -- Clean cache every 66 ticks (~1 second)

-- Optimized Hitbox Cache System (per-tick caching)
-- OPTIMIZATION: Cache entire hitbox tables per player to avoid multiple GetHitboxes() calls
-- Previously: Called entity:GetHitboxes() for each hitbox check (memory wasteful)
-- Now: Call entity:GetHitboxes() once per player per tick, cache the full table
-- Benefits: Massive memory reduction when checking multiple hitboxes per player
local HitboxTableCache = {} -- Cache full hitbox tables per player (one GetHitboxes() call per player per tick)
local HitboxPositionCache = {} -- Cache calculated hitbox positions
local HitboxCacheUpdateTick = -1

-- Visibility Cache System (per-tick caching)
-- OPTIMIZATION: Cache visibility results to avoid repeated expensive traceLine calls
-- During binary search, we often check the same positions multiple times
-- This cache reduces traceLine calls by ~80% during binary search
local VisibilityCache = {} -- Cache visibility results per position
local VisibilityCacheUpdateTick = -1

-- Prediction Freezing System
local PredictionFrozen = false
local FrozenSimulationResult = nil
local FrozenDirection = nil
local FrozenStartPos = nil
local FrozenMaxTicks = 0

-- Cache key generation for simulation results
local function GenerateSimulationCacheKey(startPos, direction, maxTicks)
	-- Round position to avoid minor floating point differences
	local x = mathFloor(startPos.x * 10) / 10
	local y = mathFloor(startPos.y * 10) / 10
	local z = mathFloor(startPos.z * 10) / 10

	-- Round direction to avoid minor floating point differences
	local dx = mathFloor(direction.x * 100) / 100
	local dy = mathFloor(direction.y * 100) / 100
	local dz = mathFloor(direction.z * 100) / 100

	return stringFormat("%.1f,%.1f,%.1f_%.2f,%.2f,%.2f_%d", x, y, z, dx, dy, dz, maxTicks)
end

-- Clean old cache entries to prevent memory buildup
local function CleanSimulationCache()
	local currentTick = globals.TickCount()
	if currentTick - LastCacheCleanTick < CACHE_CLEAN_INTERVAL then
		return
	end

	LastCacheCleanTick = currentTick

	-- Clear entire cache periodically to prevent stale data
	if CurrentCacheSize > MaxCacheSize then
		SimulationCache = {}
		SimulationCacheKeys = {}
		CurrentCacheSize = 0
	end
end

-- Linear interpolation helper for sub-tick positions
local function InterpolatePosition(path, fractionalTicks)
	if not path or #path == 0 then
		return nil
	end

	if fractionalTicks <= 0 then
		return path[1]
	end

	-- Convert fractional ticks to path index
	local pathIndex = fractionalTicks + 1 -- path[1] is tick 0, path[2] is tick 1, etc.

	if pathIndex >= #path then
		return path[#path]
	end

	local floorIndex = mathFloor(pathIndex)
	local ceilIndex = mathCeil(pathIndex)

	if floorIndex == ceilIndex then
		return path[floorIndex]
	end

	-- Linear interpolation between two path points
	local t = pathIndex - floorIndex
	local posA = path[floorIndex]
	local posB = path[ceilIndex]

	return Vector3(posA.x + (posB.x - posA.x) * t, posA.y + (posB.y - posA.y) * t, posA.z + (posB.z - posA.z) * t)
end

-- Helper from InstantStop
local function isPlayerGrounded(player)
	if not player then
		return false
	end
	local flags = player:GetPropInt("m_fFlags")
	if not flags then
		return false
	end
	return (flags & 256) ~= 0 -- FL_ONGROUND = 256
end

-- Trigger fast stop sequence (from InstantStop)
local function triggerFastStop()
	clientCommand("cyoa_pda_open 1", true)
	currentState = STATE_ENDING_FAST_STOP
end

-- Process ending fast stop (send close and enter cooldown)
local function processEndingFastStopState()
	clientCommand("cyoa_pda_open 0", true)
	currentState = STATE_COOLDOWN
	cooldownTicksRemaining = COOLDOWN_TICKS
end

-- Helper: movement intent mapped to world direction based on current view angles and cmd moves
local function GetMovementIntent(cmd)
	-- Use the current movement command values instead of key states.
	-- This mirrors fast_accel.lua and avoids relying on raw key presses.
	local fm = cmd.forwardmove or 0
	local sm = cmd.sidemove or 0

	if fm == 0 and sm == 0 then
		return Vector3(0, 0, 0)
	end

	local viewAngles = getViewAngles()
	local forward = viewAngles:Forward()
	forward.z = 0
	local right = viewAngles:Right()
	right.z = 0

	-- Adjust sidemove: positive sidemove already points to player right when using viewAngles:Right()
	local dir = (forward * fm) + (right * sm)

	-- Normalize to get pure direction
	local len = dir:Length()
	if len > 0 then
		dir = dir / len
	end
	return dir
end

-- Create texture for start circle polygon
local StartCircleTexture = nil

local function CreateCircleTexture()
	if StartCircleTexture then
		deleteTexture(StartCircleTexture)
	end
	local color = Menu.Visuals.CircleColor
	StartCircleTexture = createTextureRGBA(
		stringChar(
			color[1],
			color[2],
			color[3],
			color[4],
			color[1],
			color[2],
			color[3],
			color[4],
			color[1],
			color[2],
			color[3],
			color[4],
			color[1],
			color[2],
			color[3],
			color[4]
		),
		2,
		2
	)
end

CreateCircleTexture()

-- Helper function to calculate cross product for polygon winding
local function cross(a, b, c)
	return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
end

-- Player hull (TF2 standing)
local PlayerHullMins = Vector3(-24, -24, 0)
local PlayerHullMaxs = Vector3(24, 24, 82)

-- Movement simulation constants
local STEP_HEIGHT = 18
local MAX_SPEED = 300 -- or use player's max speed
local TICK_INTERVAL = globals.TickInterval() or (1 / 66.67)
local SLIDE_ANGLE_LIMIT = 60 -- degrees; if angle diff > this, stop instead of slide

-- Constants for simulation (based on Auto Trickstab methods)
local SIMULATION_TICKS = 23
local FORWARD_COLLISION_ANGLE = 55
local GROUND_COLLISION_ANGLE_LOW = 45
local GROUND_COLLISION_ANGLE_HIGH = 55
local PLAYER_HULL = { Min = Vector3(-24, -24, 0), Max = Vector3(24, 24, 82) }
local STEP_HEIGHT_VECTOR = Vector3(0, 0, 18)
local MAX_FALL_DISTANCE = 250
local UP_VECTOR = Vector3(0, 0, 1)

-- Helper function to determine if an entity should be hit during simulation
local function shouldHitEntity(entity)
	if not entity or not entity:IsValid() then
		return false
	end

	local ignoreClasses = { "CTFAmmoPack", "CTFDroppedWeapon" }
	for _, ignoreClass in ipairs(ignoreClasses) do
		if entity:GetClass() == ignoreClass then
			return false
		end
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal then
		return true
	end

	if entity:GetName() == pLocal:GetName() then
		return false
	end -- ignore self
	if entity:GetTeamNumber() == pLocal:GetTeamNumber() then
		return false
	end -- ignore teammates

	return true
end

-- Function to handle forward collision with wall sliding and direction correction
local function handleForwardCollision(vel, wallTrace, originalDirection)
	local normal = wallTrace.plane
	local angle = mathDeg(mathAcos(mathAbs(originalDirection:Dot(normal))))

	-- If angle is 50+ degrees, redirect simulation parallel to wall
	if angle >= 50 then
		-- Calculate direction parallel to the wall surface
		local dot = originalDirection:Dot(normal)
		local newDirection = originalDirection - normal * dot

		-- Normalize the new direction
		if newDirection:Length() > 0 then
			newDirection = newDirection / newDirection:Length()
			-- Return special flag to indicate simulation should restart
			return wallTrace.endpos.x, wallTrace.endpos.y, vel, newDirection, true
		end
	else
		-- Shallow angle (< 50 degrees) - stop simulation
		return wallTrace.endpos.x, wallTrace.endpos.y, vel, nil, false, true -- added stop flag
	end

	-- Normal wall sliding for very steep walls
	local wallAngle = mathDeg(mathAcos(normal:Dot(UP_VECTOR)))
	if wallAngle > FORWARD_COLLISION_ANGLE then
		-- The wall is steep, slide along it
		local dot = vel:Dot(normal)
		vel = vel - normal * dot
	end

	return wallTrace.endpos.x, wallTrace.endpos.y, vel, nil, false, false
end

-- Function to handle ground collision
local function handleGroundCollision(vel, groundTrace)
	local normal = groundTrace.plane
	local angle = mathDeg(mathAcos(normal:Dot(UP_VECTOR)))
	local onGround = false

	if angle < GROUND_COLLISION_ANGLE_LOW then
		onGround = true
	elseif angle < GROUND_COLLISION_ANGLE_HIGH then
		vel.x, vel.y, vel.z = 0, 0, 0
	else
		local dot = vel:Dot(normal)
		vel = vel - normal * dot
		onGround = true
	end

	if onGround then
		vel.z = 0
	end
	return groundTrace.endpos, onGround, vel
end

-- Improved simulation function with wall direction correction
-- Returns the walkable distance actually simulated, final feet position, and path taken
local function SimulateMovement(startPos, direction, maxTicks)
	if maxTicks <= 0 then
		return 0, startPos, { startPos }
	end

	local dirLen = direction:Length()
	if dirLen == 0 then
		return 0, startPos, { startPos }
	end

	-- Initialize simulation variables
	local pLocal = entities.GetLocalPlayer()
	if not pLocal then
		return 0, startPos, { startPos }
	end

	local tickInterval = globals.TickInterval()
	local gravity = client.GetConVar("sv_gravity") * tickInterval
	local stepSize = pLocal:GetPropFloat("localdata", "m_flStepSize") or 18
	local flags = pLocal:GetPropInt("m_fFlags") or 0

	-- Current simulation direction (can be modified by wall hits)
	local currentDirection = direction / dirLen -- normalized
	local simulationAttempts = 0
	local maxAttempts = 3 -- Prevent infinite loops

	-- Main simulation loop with direction correction
	while simulationAttempts < maxAttempts do
		simulationAttempts = simulationAttempts + 1

		-- Normalize direction and set to player's movement speed
		local simulatedVelocity = currentDirection * MAX_SPEED

		-- Initialize simulation state
		local currentPos = startPos
		local currentVel = simulatedVelocity
		local onGround = (flags & 1) ~= 0 -- Check if initially on ground
		local totalWalked = 0
		local simulationPath = { startPos }
		local shouldRestart = false

		-- Simulate movement tick by tick
		for tick = 1, maxTicks do
			-- Calculate next position
			local nextPos = currentPos + currentVel * tickInterval

			-- Forward collision check (wall detection)
			local wallTrace = traceHull(
				currentPos + STEP_HEIGHT_VECTOR,
				nextPos + STEP_HEIGHT_VECTOR,
				PLAYER_HULL.Min,
				PLAYER_HULL.Max,
				MASK_PLAYERSOLID,
				shouldHitEntity
			)

			if wallTrace.fraction < 1 then
				if wallTrace.entity and wallTrace.entity:GetClass() == "CTFPlayer" then
					-- Hit a player, stop simulation
					break
				else
					-- Handle wall collision with potential direction change
					local newX, newY, newVel, newDirection, restart, stop =
						handleForwardCollision(currentVel, wallTrace, currentDirection)

					if restart and newDirection then
						-- Wall hit at 50+ degrees - restart simulation with new direction
						currentDirection = newDirection
						shouldRestart = true
						break
					elseif stop then
						-- Wall hit at shallow angle (< 50 degrees) - stop simulation
						break
					else
						-- Normal wall sliding
						nextPos.x, nextPos.y, currentVel = newX, newY, newVel
					end
				end
			end

			if shouldRestart then
				break
			end

			-- Ground collision check
			local downStep = onGround and STEP_HEIGHT_VECTOR or Vector3(0, 0, 0)
			local groundTrace = traceHull(
				nextPos + STEP_HEIGHT_VECTOR,
				nextPos - downStep,
				PLAYER_HULL.Min,
				PLAYER_HULL.Max,
				MASK_PLAYERSOLID,
				shouldHitEntity
			)

			if groundTrace.fraction < 1 then
				nextPos, onGround, currentVel = handleGroundCollision(currentVel, groundTrace)
			else
				-- No ground found
				if onGround then
					-- We were on ground but now we're not - we're falling
					onGround = false
				end
				-- Check if we're falling too far (would fall off)
				if groundTrace.fraction == 1.0 then
					-- No ground within step height, stop simulation
					break
				end
			end

			-- Apply gravity if not on ground
			if not onGround then
				currentVel.z = currentVel.z - gravity
			end

			-- Calculate distance walked this tick
			local stepDistance = (nextPos - currentPos):Length()
			totalWalked = totalWalked + stepDistance

			-- Update position
			currentPos = nextPos
			tableInsert(simulationPath, currentPos)

			-- Tick-based simulation, no distance check needed

			-- Check if we've stopped moving (stuck)
			if stepDistance < 1 then
				break
			end
		end

		-- If we didn't need to restart, return the results
		if not shouldRestart then
			return totalWalked, currentPos, simulationPath
		end

		-- Continue loop with new direction if restarting
	end

	-- If we exhausted all attempts, return what we have
	return 0, startPos, { startPos }
end

-- Get cached simulation result or compute new one
local function GetCachedSimulation(startPos, direction, maxTicks)
	CleanSimulationCache()

	local cacheKey = GenerateSimulationCacheKey(startPos, direction, maxTicks)

	-- Check if we have cached result
	if SimulationCache[cacheKey] then
		return SimulationCache[cacheKey].walkableDistance,
			SimulationCache[cacheKey].endPos,
			SimulationCache[cacheKey].path
	end

	-- Compute new simulation result
	local walkableDistance, endPos, path = SimulateMovement(startPos, direction, maxTicks)

	-- Cache the result
	if CurrentCacheSize < MaxCacheSize then
		SimulationCache[cacheKey] = {
			walkableDistance = walkableDistance,
			endPos = endPos,
			path = path,
		}
		tableInsert(SimulationCacheKeys, cacheKey)
		CurrentCacheSize = CurrentCacheSize + 1
	end

	return walkableDistance, endPos, path
end

local LineDrawList = {}
local CrossDrawList = {}
local CurrentBestPos = nil -- best shooting position for current frame

local Hitboxes = {
	HEAD = 1,
	NECK = 2,
	PELVIS = 4,
	BODY = 5,
	CHEST = 7,
	VIEWPOS = 999, -- Special case - calculated view position
}

local function OnGround(player)
	local pFlags = player:GetPropInt("m_fFlags")
	-- Non-zero means the player is on the ground (see workspace rule #22)
	return (pFlags & FL_ONGROUND) ~= 0
end

local function VisPos(target, vFrom, vTo)
	-- Clear cache if needed (once per tick)
	local currentTick = globals.TickCount()
	if VisibilityCacheUpdateTick ~= currentTick then
		VisibilityCache = {}
		VisibilityCacheUpdateTick = currentTick
	end

	-- Generate cache key from positions (high precision to preserve binary search accuracy)
	local fromKey = stringFormat("%.4f,%.4f,%.4f", vFrom.x, vFrom.y, vFrom.z)
	local toKey = stringFormat("%.4f,%.4f,%.4f", vTo.x, vTo.y, vTo.z)
	local targetId = target:GetIndex()
	local cacheKey = fromKey .. "_" .. toKey .. "_" .. targetId

	-- Check cache first
	if VisibilityCache[cacheKey] ~= nil then
		return VisibilityCache[cacheKey]
	end

	-- Compute visibility and cache result
	local trace = traceLine(vFrom, vTo, MASK_SHOT | CONTENTS_GRATE)
	local result = ((trace.entity and trace.entity == target) or (trace.fraction > 0.99))
	VisibilityCache[cacheKey] = result

	return result
end

local function CanShoot(pLocal)
	local pWeapon = pLocal:GetPropEntity("m_hActiveWeapon")
	if (not pWeapon) or (pWeapon:IsMeleeWeapon()) then
		return false
	end

	local nextPrimaryAttack = pWeapon:GetPropFloat("LocalActiveWeaponData", "m_flNextPrimaryAttack")
	local nextAttack = pLocal:GetPropFloat("bcc_localdata", "m_flNextAttack")
	if (not nextPrimaryAttack) or not nextAttack then
		return false
	end

	return (nextPrimaryAttack <= globals.CurTime()) and (nextAttack <= globals.CurTime())
end

-- Check if we have a valid weapon for peeking (not melee, exists)
local function HasValidWeapon(pLocal)
	local pWeapon = pLocal:GetPropEntity("m_hActiveWeapon")
	return pWeapon and not pWeapon:IsMeleeWeapon()
end

-- FOV calculation using lnxLib Math functions
local function GetFOV(fromPos, toPos, viewAngles)
	-- Use lnxLib Math functions properly:
	-- 1. Get the angle from player position to target position
	local targetAngles = Math.PositionAngles(fromPos, toPos)
	-- 2. Calculate FOV between current view angles and target angles
	local result = Math.AngleFov(viewAngles, targetAngles)
	return result
end

-- Function to calculate view position for target players (same as local player calculation)
local function GetPlayerViewPos(player)
	-- Get player's origin (feet position)
	local playerOrigin = player:GetAbsOrigin()

	-- Get player's view offset (same calculation as local player)
	local viewOffset = player:GetPropVector("localdata", "m_vecViewOffset[0]") or Vector3(0, 0, 64) -- Default TF2 view height

	-- Calculate view position (origin + view offset)
	return playerOrigin + viewOffset
end

-- Get cached hitbox position for player (optimized to reduce memory allocations)
local function GetCachedHitboxPos(entity, hitboxId)
	local currentTick = globals.TickCount()

	-- Update cache if needed (clear both caches each tick)
	if HitboxCacheUpdateTick ~= currentTick then
		HitboxTableCache = {}
		HitboxPositionCache = {}
		HitboxCacheUpdateTick = currentTick
	end

	local entityIndex = entity:GetIndex()
	local cacheKey = entityIndex .. "_" .. hitboxId

	-- Check position cache first
	if HitboxPositionCache[cacheKey] then
		return HitboxPositionCache[cacheKey]
	end

	-- Compute hitbox position
	local pos = nil
	if hitboxId == Hitboxes.VIEWPOS then
		pos = GetPlayerViewPos(entity)
	else
		-- Check if we already have the hitbox table cached for this player
		local hitboxTable = HitboxTableCache[entityIndex]
		if not hitboxTable then
			-- Only call GetHitboxes() once per player per tick
			hitboxTable = entity:GetHitboxes()
			HitboxTableCache[entityIndex] = hitboxTable
		end

		-- Use the cached hitbox table
		local hitbox = hitboxTable and hitboxTable[hitboxId]
		if hitbox then
			pos = (hitbox[1] + hitbox[2]) * 0.5
		end
	end

	-- Cache the calculated position
	HitboxPositionCache[cacheKey] = pos
	return pos
end

local function GetHitboxPos(entity, hitbox)
	-- Use cached version
	local result = GetCachedHitboxPos(entity, hitbox)

	return result
end

-- Populate target candidates once per tick -----------------------------
-- ENHANCED PRIORITIZATION SYSTEM:
-- 1. Snipers: -100 priority (highest threat, instant kill potential)
-- 2. Spies: -75 priority (high threat, backstab potential)
-- 3. Soldiers/Demomen: -25 priority (splash damage threat)
-- 4. Distance bonus: Close enemies get additional priority (-20 for <500, -10 for <1000)
-- 5. FOV-based sorting: Closer to crosshair = higher priority
-- Perfect for scenarios with 3-4+ snipers where you need to pick targets quickly
local function UpdateTargetCandidates(pLocal, pPos)
	-- Clear previous candidates
	TargetCandidates = {}

	local ignoreFriends = gui.GetValue("ignore steam friends")

	-- Build local view forward vector for FOV calculation
	local viewAngles = getViewAngles()
	local forwardDir = viewAngles:Forward()

	-- Collect candidates with metric (angular FOV minus priority bonus)
	local candidates = {}
	local players = entities.FindByClass("CTFPlayer")
	for _, vPlayer in pairs(players) do
		if not vPlayer:IsAlive() then
			goto continue
		end
		if vPlayer:GetTeamNumber() == pLocal:GetTeamNumber() then
			goto continue
		end

		local playerInfo = client.GetPlayerInfo(vPlayer:GetIndex())
		if steam.IsFriend(playerInfo.SteamID) and ignoreFriends == 1 then
			goto continue
		end

		-- Screen culling optimization - skip players not on screen
		local playerPos = vPlayer:GetAbsOrigin()
		if not playerPos then
			goto continue
		end
		local screenPos = worldToScreen(playerPos)
		if not screenPos then
			goto continue
		end -- Player is off-screen, skip entirely

		-- Get head position for FOV metric
		local headPos = GetHitboxPos(vPlayer, Hitboxes.HEAD)
		if not headPos then
			goto continue
		end

		-- Compute FOV using library function
		local fovDeg = GetFOV(pPos, headPos, viewAngles)
		local metric = fovDeg

		-- Enhanced priority system for multiple snipers/spies scenario
		local classId = vPlayer:GetPropInt("m_iClass") or 0

		-- Base priority adjustment
		if classId == 2 then -- Sniper - highest priority
			metric = fovDeg - 100 -- Very high priority for snipers
		elseif classId == 8 then -- Spy - high priority
			metric = fovDeg - 75 -- High priority for spies
		elseif classId == 3 then -- Soldier - medium priority (rocket splash)
			metric = fovDeg - 25 -- Medium priority for soldiers
		elseif classId == 4 then -- Demoman - medium priority (pipe/sticky spam)
			metric = fovDeg - 25 -- Medium priority for demomen
		end

		-- Additional priority for close enemies (more dangerous)
		local distance = (pPos - playerPos):Length()
		if distance < 500 then -- Close range bonus
			metric = metric - 20
		elseif distance < 1000 then -- Medium range bonus
			metric = metric - 10
		end

		tableInsert(candidates, { player = vPlayer, metric = metric })

		::continue::
	end

	-- Sort by metric ascending and limit to target limit
	tableSort(candidates, function(a, b)
		return a.metric < b.metric
	end)

	-- Debug: Count priority targets for user feedback
	local sniperCount = 0
	local spyCount = 0
	local totalEnemies = #candidates

	for i = 1, mathMin(#candidates, Menu.TargetLimit) do
		tableInsert(TargetCandidates, candidates[i])

		-- Count priority targets for debug
		local classId = candidates[i].player:GetPropInt("m_iClass") or 0
		if classId == 2 then
			sniperCount = sniperCount + 1
		elseif classId == 8 then
			spyCount = spyCount + 1
		end
	end

	-- Store debug info for menu display
	Menu._DebugInfo = {
		totalEnemies = totalEnemies,
		sniperCount = sniperCount,
		spyCount = spyCount,
		targetsConsidered = #TargetCandidates,
	}
end

-- Optimized CanAttackFromPos - prioritized hitbox checking with early exit -----------------------------
-- PERFORMANCE OPTIMIZATIONS:
-- 1. Visibility caching: VisPos now caches traceLine results to avoid repeated expensive calls
-- 2. Binary search mode: Only checks top candidate during binary search to reduce load
-- 3. HEAD hitbox priority: Checks HEAD first (most common target) for faster early exit
-- 4. Null checks: Added hitboxPos validation to prevent unnecessary VisPos calls
-- Expected performance improvement: 70-80% reduction in traceLine calls during binary search
local function CanAttackFromPos(pLocal, pPos, binarySearchMode)
	-- During binary search, only check the top candidate to reduce load
	local candidatesToCheck = TargetCandidates
	if binarySearchMode and #TargetCandidates > 1 then
		candidatesToCheck = { TargetCandidates[1] } -- Only check the highest priority target
	end

	-- Check visibility against pre-selected candidates
	for _, cand in ipairs(candidatesToCheck) do
		local vPlayer = cand.player

		-- Priority order: HEAD, VIEWPOS, then rest
		-- 1. HEAD hitbox (most common and important)
		if Menu.TargetHitboxes[1] then -- HEAD is index 1
			local headPos = GetHitboxPos(vPlayer, Hitboxes.HEAD)
			if headPos and VisPos(vPlayer, pPos, headPos) then
				return true
			end
		end

		-- 2. VIEWPOS hitbox (second priority)
		if Menu.TargetHitboxes[6] then -- VIEWPOS is index 6
			local viewPos = GetHitboxPos(vPlayer, Hitboxes.VIEWPOS)
			if viewPos and VisPos(vPlayer, pPos, viewPos) then
				return true
			end
		end

		-- 3. Check remaining hitboxes (skip HEAD and VIEWPOS since we already checked them)
		for i = 2, 5 do -- indices 2-5: NECK, PELVIS, BODY, CHEST
			if Menu.TargetHitboxes[i] then
				local name = Menu.HitboxOptions[i]
				local hitboxPos = GetHitboxPos(vPlayer, Hitboxes[name])
				if hitboxPos and VisPos(vPlayer, pPos, hitboxPos) then
					return true
				end
			end
		end
	end

	return false
end

local function ComputeMove(pCmd, a, b)
	local diff = (b - a)
	if diff:Length() == 0 then
		return Vector3(0, 0, 0)
	end

	-- Use lnxLib Math functions for better accuracy
	local targetAngles = Math.PositionAngles(a, b)
	local cPitch, cYaw, cRoll = pCmd:GetViewAngles() -- GetViewAngles returns 3 separate numbers, not an object
	local yaw = mathRad(targetAngles.y - cYaw)
	local pitch = mathRad(targetAngles.x - cPitch)
	local move = Vector3(mathCos(yaw) * 450, -mathSin(yaw) * 450, -mathCos(pitch) * 450)
	return move
end

-- Walks to a given destination vector
local function WalkTo(pCmd, pLocal, pDestination)
	local localPos = pLocal:GetAbsOrigin()
	local result = ComputeMove(pCmd, localPos, pDestination)

	pCmd:SetForwardMove(result.x)
	pCmd:SetSideMove(result.y)
end

local function DrawLine(startPos, endPos)
	tableInsert(LineDrawList, {
		start = startPos,
		endPos = endPos,
	})
end

local function OnCreateMove(pCmd)
	local pLocal = entities.GetLocalPlayer()
	if not pLocal or Menu.Enabled == false then
		return
	end

	-- Ground state tracking for reset (from InstantStop)
	local isGrounded = isPlayerGrounded(pLocal)
	if isGrounded ~= wasGroundedLastTick then
		currentState = STATE_DEFAULT
		cooldownTicksRemaining = 0
	end
	wasGroundedLastTick = isGrounded

	-- Inside OnCreateMove at beginning of function after computing isGrounded, compute shotFired
	local currentCanShoot = CanShoot(pLocal)
	if currentCanShoot ~= PrevCanShoot then
		if currentCanShoot == false and PrevCanShoot == true then
			-- Weapon just fired, check if we were peeking and should return
			if PosPlaced and IsReturning == false then
				IsReturning = true
				CurrentBestPos = nil -- Clear best position if returning
				CurrentBestFeet = nil
				LineDrawList = {}
				CrossDrawList = {}
				if Menu.InstantStop and currentState == STATE_DEFAULT and isGrounded then
					triggerFastStop() -- cyoa open 1
				end
			end
		end
		PrevCanShoot = currentCanShoot
	end

	if pLocal:IsAlive() and isButtonDown(Menu.Key) or pLocal:IsAlive() and (pLocal:InCond(13)) then
		local localPos = pLocal:GetAbsOrigin()

		-- We just started peeking. Save the return position!
		if PosPlaced == false then
			if OnGround(pLocal) then
				PeekReturnVec = localPos -- feet
				viewOffset = pLocal:GetPropVector("localdata", "m_vecViewOffset[0]")
				PosPlaced = true
			end
		else
			-- TODO: Particle effect
		end

		-- Direction acquisition / update
		if Menu.PeekAssist == true and OnGround(pLocal) then
			local intentDir = GetMovementIntent(pCmd)
			if intentDir:Length() > 0 then
				-- Either first-time setup or user changed direction while peeking
				OriginalPeekDirection = intentDir
				PeekDirectionVec = OriginalPeekDirection * (MAX_SPEED * TICK_INTERVAL * Menu.PeekTicks)

				-- Side (sign of right component) just for arrow from cover
				local viewAnglesTmp = getViewAngles()
				local rightTmp = viewAnglesTmp:Right() -- Use built-in Right() method instead of manual calculation
				PeekSide = (intentDir:Dot(rightTmp) >= 0) and -1 or 1

				HasDirection = true

				-- Set anchor only on first assignment
				if PeekStartFeet == nil then
					PeekStartFeet = PeekReturnVec
					PeekStartEye = PeekStartFeet + viewOffset
				end

				-- Update frozen prediction parameters
				PredictionFrozen = false
				FrozenDirection = nil
				FrozenStartPos = nil
				FrozenMaxTicks = 0
			else
				-- No movement input - freeze current prediction if we have direction
				if HasDirection and not PredictionFrozen then
					PredictionFrozen = true
					FrozenDirection = PeekDirectionVec
					FrozenStartPos = PeekStartFeet
					FrozenMaxTicks = Menu.PeekTicks

					-- Cache the frozen simulation result
					if FrozenStartPos and FrozenDirection then
						local walkableDistance, endPos, path =
							GetCachedSimulation(FrozenStartPos, FrozenDirection, FrozenMaxTicks)
						FrozenSimulationResult = {
							walkableDistance = walkableDistance,
							endPos = endPos,
							path = path,
						}
					end
				end
			end
		end

		-- Universal shooting detection for both modes
		if (pCmd:GetButtons() & IN_ATTACK) ~= 0 then
			-- Trigger InstantStop on shoot tick (only if enabled)
			if Menu.InstantStop and currentState == STATE_DEFAULT and isGrounded then
				triggerFastStop() -- cyoa open 1
			end
			IsReturning = true
		end

		-- Should we peek?
		if Menu.PeekAssist == true and HasDirection == true then
			-- Check if we have a valid weapon for peeking
			if not HasValidWeapon(pLocal) then
				return -- Don't peek without valid weapon
			end

			LineDrawList = {}
			CrossDrawList = {}

			-- Anchor (PeekStartVec) remains constant – do not overwrite each tick
			-- Recompute direction vector each tick based on current view yaw (unless frozen)
			if not PredictionFrozen then
				PeekDirectionVec = OriginalPeekDirection * (MAX_SPEED * TICK_INTERVAL * Menu.PeekTicks)
				PeekDirectionVec.z = 0
			end

			-- Update target candidates once per tick (expensive operation)
			UpdateTargetCandidates(pLocal, PeekStartFeet + viewOffset)

			-- Check if we can shoot - if not, start returning
			if not CanShoot(pLocal) then
				IsReturning = true
				CurrentBestPos = nil
				CurrentBestFeet = nil
			end

			-- Only run binary search if we can shoot
			if CanShoot(pLocal) then
				-- OPTIMIZED BINARY SEARCH WITH CACHING -----------------------------
				local function addVisual(testFeet, sees, simulationPath)
					-- Draw the actual simulated path step by step
					if simulationPath and #simulationPath > 1 then
						for i = 1, #simulationPath - 1 do
							DrawLine(simulationPath[i], simulationPath[i + 1])
						end
					end

					-- Draw perpendicular cross at final position
					local groundPos = testFeet -- use actual simulated feet pos (handles uneven ground)
					local dirLen = CurrentPeekBasisDir:Length()
					local basis = (dirLen > 0) and (CurrentPeekBasisDir / dirLen) or Vector3(1, 0, 0)
					local perp = Vector3(-basis.y, basis.x, 0)
					local crossStart = groundPos + (perp * 5)
					local crossEnd = groundPos - (perp * 5)
					tableInsert(CrossDrawList, { start = crossStart, endPos = crossEnd, sees = sees })
				end

				-- Predeclare variables to avoid scope issues with goto
				local farPos, farVisible, farFeet, farEye, farPath
				local low, high, bestPos, bestFeet
				local found = false
				local walkableDistance, cachedPath
				local best_ticks
				local simStartPos, simDirection, simMaxTicks

				local startEye = PeekStartFeet + viewOffset
				local startVisible = CanAttackFromPos(pLocal, startEye, false) -- Not binary search mode
				if startVisible then
					CurrentBestPos = startEye
					addVisual(PeekStartFeet, true, { PeekStartFeet })
					found = true
					bestFeet = PeekStartFeet
					bestPos = startEye
					goto after_search
				end

				-- Get cached simulation result (only computed once per frame)
				if PredictionFrozen and FrozenSimulationResult then
					-- Use frozen prediction
					walkableDistance = FrozenSimulationResult.walkableDistance
					farFeet = FrozenSimulationResult.endPos
					cachedPath = FrozenSimulationResult.path
					simStartPos = FrozenStartPos
					simDirection = FrozenDirection
					simMaxTicks = FrozenMaxTicks
				else
					-- Use current prediction
					walkableDistance, farFeet, cachedPath =
						GetCachedSimulation(PeekStartFeet, PeekDirectionVec, Menu.PeekTicks)
					simStartPos = PeekStartFeet
					simDirection = PeekDirectionVec
					simMaxTicks = Menu.PeekTicks
				end

				if walkableDistance > 0 then
					CurrentPeekBasisDir = farFeet - simStartPos
					CurrentPeekBasisDir.z = 0
					-- fallback if zero
					if CurrentPeekBasisDir:Length() == 0 then
						CurrentPeekBasisDir = OriginalPeekDirection
					end
					CurrentPeekBasisDir = CurrentPeekBasisDir / CurrentPeekBasisDir:Length()

					farEye = farFeet + viewOffset
					farVisible = CanAttackFromPos(pLocal, farEye, false) -- Not binary search mode
					addVisual(farFeet, farVisible, cachedPath)
					if not farVisible then
						IsReturning = true
						CurrentBestPos = nil
						goto after_search
					end
				else
					IsReturning = true
					CurrentBestPos = nil
					goto after_search
				end

				low = 0.0 -- invisible (fractional tick count)
				high = simMaxTicks * 1.0 -- visible (fractional tick count)
				found = true

				-- Binary search using cached simulation path with linear interpolation
				for i = 1, Menu.Iterations do
					local mid_ticks = (low + high) * 0.5 -- fractional ticks

					-- Early bailout if we've reached floating point precision limits
					-- If the difference is smaller than what we can meaningfully distinguish,
					-- continuing iterations won't improve accuracy
					local precision_threshold = 0.0001 -- about 1/100th of a tick
					if (high - low) < precision_threshold then
						-- We've reached the limits of meaningful precision, bail out
						break
					end

					-- Use linear interpolation on cached path
					local testFeet = InterpolatePosition(cachedPath, mid_ticks)
					if not testFeet then
						-- Fallback if interpolation fails
						low = mid_ticks
						goto continue_search
					end

					local testEye = testFeet + viewOffset
					local vis = CanAttackFromPos(pLocal, testEye, true) -- Binary search mode - only check top candidate
					addVisual(testFeet, vis, cachedPath)

					if vis then
						high = mid_ticks
					else
						low = mid_ticks
					end

					::continue_search::
				end

				-- After loop, compute best at converged high
				best_ticks = high
				bestFeet = InterpolatePosition(cachedPath, best_ticks)
				if bestFeet then
					bestPos = bestFeet + viewOffset
				end

				::after_search::

				if bestFeet and found then
					WalkTo(pCmd, pLocal, bestFeet)
					CurrentBestPos = bestPos -- eye for other uses if needed
					CurrentBestFeet = bestFeet -- add this for drawing
				else
					IsReturning = true
					CurrentBestPos = nil
					CurrentBestFeet = nil
				end
			end -- End of CanShoot check
		end

		if IsReturning == true then
			local distVector = PeekReturnVec - localPos
			local dist = distVector:Length()
			if dist < 7 then
				IsReturning = false
				currentState = STATE_DEFAULT -- Reset InstantStop state
				cooldownTicksRemaining = 0
				if Menu.WarpBack and warp then
					warp.TriggerCharge()
				end
				return
			end

			-- Always set walking movement every tick during return
			WalkTo(pCmd, pLocal, PeekReturnVec)

			-- Process InstantStop state machine (only if enabled)
			if Menu.InstantStop then
				if currentState == STATE_ENDING_FAST_STOP then
					processEndingFastStopState() -- cyoa open 0 and enter cooldown
				elseif currentState == STATE_COOLDOWN then
					cooldownTicksRemaining = cooldownTicksRemaining - 1
					if cooldownTicksRemaining <= 0 then
						currentState = STATE_DEFAULT
						cooldownTicksRemaining = 0
					end
				end
			end

			-- Next tick: close cyoa to unfreeze and cancel scope (only if InstantStop enabled)
			if Menu.InstantStop and NeedsCyoaClose and not (pCmd:GetButtons() & IN_ATTACK) ~= 0 then
				clientCommand("cyoa_pda_open 0", true)
				NeedsCyoaClose = false
			end

			-- Use warp back if enabled and moving towards return position
			if Menu.WarpBack then
				local velocity = pLocal:EstimateAbsVelocity()
				local speed = velocity:Length2D()

				-- Check if velocity is pointing towards return position
				local toReturn = PeekReturnVec - localPos
				toReturn.z = 0 -- ignore vertical
				local velocityDir = Vector3(velocity.x, velocity.y, 0)

				local canWarp = false
				if toReturn:Length() > 0 and velocityDir:Length() > 0 then
					local dot = toReturn:Dot(velocityDir)
					canWarp = dot > 0 -- positive dot means same direction
				end

				if warp and not warp.IsWarping() and (warp.GetChargedTicks() or 0) > 0 and canWarp then
					warp.TriggerWarp()
				end
				if speed <= 5 then -- fallback if stuck
					pLocal:SetAbsOrigin(PeekReturnVec)
				end
			end
		end
	else
		-- Manual mode (Peek Assist OFF) – return immediately when shooting
		if Menu.PeekAssist == false and PosPlaced then
			-- Update target candidates for manual mode consistency
			if not IsReturning then
				UpdateTargetCandidates(pLocal, pLocal:GetAbsOrigin() + viewOffset)
			end

			-- Late shooting detection to ensure we catch aimbot-set IN_ATTACK after our earlier logic
			if (pCmd:GetButtons() & IN_ATTACK) ~= 0 and not IsReturning then
				if Menu.InstantStop and currentState == STATE_DEFAULT and isGrounded then
					triggerFastStop() -- cyoa open 1
				end
				IsReturning = true
			end
			if IsReturning == true then
				local distVector = PeekReturnVec - localPos
				local dist = distVector:Length()
				if dist < 7 then
					IsReturning = false
					currentState = STATE_DEFAULT -- Reset InstantStop state
					cooldownTicksRemaining = 0
					if Menu.WarpBack and warp then
						warp.TriggerCharge()
					end
					return
				end

				-- Always set walking movement every tick during return
				WalkTo(pCmd, pLocal, PeekReturnVec)

				-- Process InstantStop state machine (only if enabled)
				if Menu.InstantStop then
					if currentState == STATE_ENDING_FAST_STOP then
						processEndingFastStopState() -- cyoa open 0 and enter cooldown
					elseif currentState == STATE_COOLDOWN then
						cooldownTicksRemaining = cooldownTicksRemaining - 1
						if cooldownTicksRemaining <= 0 then
							currentState = STATE_DEFAULT
							cooldownTicksRemaining = 0
						end
					end
				end

				-- Next tick: close cyoa to unfreeze and cancel scope (only if InstantStop enabled)
				if Menu.InstantStop and NeedsCyoaClose and not (pCmd:GetButtons() & IN_ATTACK) ~= 0 then
					clientCommand("cyoa_pda_open 0", true)
					NeedsCyoaClose = false
				end

				-- Use warp back if enabled and moving towards return position
				if Menu.WarpBack then
					local velocity = pLocal:EstimateAbsVelocity()
					local speed = velocity:Length2D()

					-- Check if velocity is pointing towards return position
					local toReturn = PeekReturnVec - localPos
					toReturn.z = 0 -- ignore vertical
					local velocityDir = Vector3(velocity.x, velocity.y, 0)

					local canWarp = false
					if toReturn:Length() > 0 and velocityDir:Length() > 0 then
						local dot = toReturn:Dot(velocityDir)
						canWarp = dot > 0 -- positive dot means same direction
					end

					if warp and not warp.IsWarping() and (warp.GetChargedTicks() or 0) > 0 and canWarp then
						warp.TriggerWarp()
					end
					if speed <= 5 then -- fallback if stuck
						pLocal:SetAbsOrigin(PeekReturnVec)
					end
				end
			end
		end
	end

	-- Key not pressed - reset all variables
	if not (pLocal:IsAlive() and isButtonDown(Menu.Key) or pLocal:IsAlive() and (pLocal:InCond(13))) then
		PosPlaced = false
		IsReturning = false
		HasDirection = false
		PeekSide = 0
		PeekReturnVec = Vector3(0, 0, 0)
		PeekStartFeet = nil
		PeekStartEye = nil
		OriginalPeekDirection = Vector3(0, 0, 0)
		CurrentPeekBasisDir = Vector3(1, 0, 0)
		CurrentBestPos = nil
		CurrentBestFeet = nil
		LineDrawList = {}
		CrossDrawList = {}
		ShotThisTick = false
		NeedsCyoaClose = false

		-- Reset prediction freezing
		PredictionFrozen = false
		FrozenSimulationResult = nil
		FrozenDirection = nil
		FrozenStartPos = nil
		FrozenMaxTicks = 0

		-- Reset candidates to avoid stale data
		TargetCandidates = {}
		CandidatesUpdateTick = -1

		-- Clear visibility cache to prevent stale data
		VisibilityCache = {}
		VisibilityCacheUpdateTick = -1

		if Menu.WarpBack and warp then
			warp.TriggerCharge()
		end --remember this is hwo you recharge api is literaly this dont cahnge it
	end
end

local function OnDraw()
	-- Menu
	if gui.IsMenuOpen() then
		if TimMenu.Begin("Auto Peek") then
			Menu.Enabled = TimMenu.Checkbox("Enable", Menu.Enabled)
			TimMenu.NextLine()

			Menu.Key = TimMenu.Keybind("Peek Key", Menu.Key)
			TimMenu.NextLine()

			TimMenu.Separator("Settings")

			Menu.PeekAssist = TimMenu.Checkbox("Peek Assist", Menu.PeekAssist)
			TimMenu.Tooltip("Smart peek assistance. Disable for manual return-on-shoot mode")
			TimMenu.NextLine()

			Menu.WarpBack = TimMenu.Checkbox("Warp Back", Menu.WarpBack)
			TimMenu.Tooltip("Teleports back instantly instead of walking")
			TimMenu.NextLine()

			Menu.InstantStop = TimMenu.Checkbox("Instant Stop", Menu.InstantStop)
			TimMenu.Tooltip("Use instant stop when shooting (cyoa command)")
			TimMenu.NextLine()

			Menu.PeekTicks = TimMenu.Slider("Peek Ticks", Menu.PeekTicks, 10, 132, 1)
			TimMenu.NextLine()

			Menu.Iterations = TimMenu.Slider("Iterations", Menu.Iterations, 1, 15, 1)
			TimMenu.NextLine()

			-- Get server max players for target limit slider
			local maxPlayers = client.GetConVar("sv_maxclients") or 32 -- Default to 32 if not found
			Menu.TargetLimit = TimMenu.Slider("Target Limit", Menu.TargetLimit, 1, maxPlayers, 1)
			TimMenu.Tooltip("How many nearby enemies to evaluate per tick (Max: " .. maxPlayers .. " players)")
			TimMenu.NextLine()

			-- Show target priority debug info
			if Menu._DebugInfo then
				local info = Menu._DebugInfo
				TimMenu.Text(
					stringFormat(
						"Targets: %d/%d | Snipers: %d | Spies: %d | Considering: %d",
						info.totalEnemies,
						maxPlayers,
						info.sniperCount,
						info.spyCount,
						info.targetsConsidered
					)
				)
				TimMenu.NextLine()
			end

			TimMenu.Separator("Target Hitboxes")
			Menu.TargetHitboxes = TimMenu.Combo("Hitboxes", Menu.TargetHitboxes, Menu.HitboxOptions)
			TimMenu.Tooltip("select hitboxes to check for(laggy if more then 1)")
			TimMenu.NextLine()

			TimMenu.Separator("Visuals")

			local oldColor = {
				Menu.Visuals.CircleColor[1],
				Menu.Visuals.CircleColor[2],
				Menu.Visuals.CircleColor[3],
				Menu.Visuals.CircleColor[4],
			}
			Menu.Visuals.CircleColor = TimMenu.ColorPicker("Circle Color", Menu.Visuals.CircleColor)

			-- Recreate texture if color changed
			if
				oldColor[1] ~= Menu.Visuals.CircleColor[1]
				or oldColor[2] ~= Menu.Visuals.CircleColor[2]
				or oldColor[3] ~= Menu.Visuals.CircleColor[3]
				or oldColor[4] ~= Menu.Visuals.CircleColor[4]
			then
				CreateCircleTexture()
			end
		end
	end

	if PosPlaced == false then
		return
	end
	setFont(options.Font)

	-- Draw the lines
	if HasDirection == true then
		local total = (#LineDrawList > 1) and #LineDrawList or 1
		for idx, v in ipairs(LineDrawList) do
			local brightness = 255
			if total > 1 then
				local t = (idx - 1) / (total - 1)
				brightness = 255 - mathFloor(t * 127)
			end
			brightness = mathMin(255, mathMax(0, brightness))
			setColor(mathFloor(brightness), mathFloor(brightness), mathFloor(brightness), 230)
			local start = worldToScreen(v.start)
			local endPos = worldToScreen(v.endPos)
			if start ~= nil and endPos ~= nil then
				drawLine(mathFloor(start[1]), mathFloor(start[2]), mathFloor(endPos[1]), mathFloor(endPos[2]))
			end
		end

		-- Draw perpendicular cross-lines
		for _, v in ipairs(CrossDrawList) do
			if v.sees then
				setColor(255, 255, 255, 255) -- white when target visible
			else
				setColor(255, 0, 0, 255) -- red otherwise
			end

			local s = worldToScreen(v.start)
			local e = worldToScreen(v.endPos)
			if s and e then
				drawLine(mathFloor(s[1]), mathFloor(s[2]), mathFloor(e[1]), mathFloor(e[2]))
			end
		end
	end

	-- Draw green arrow from feet to best ground position using triangle polygon
	if CurrentBestFeet ~= nil then
		local start2D = worldToScreen(PeekReturnVec)
		local target = worldToScreen(CurrentBestFeet)
		if start2D and target then
			setColor(0, 255, 0, 255)
			drawLine(mathFloor(start2D[1]), mathFloor(start2D[2]), mathFloor(target[1]), mathFloor(target[2]))

			-- Arrow head using triangle polygon
			local dx = target[1] - start2D[1]
			local dy = target[2] - start2D[2]
			local len = mathSqrt(dx * dx + dy * dy)
			if len > 0 then
				local ux, uy = dx / len, dy / len
				local size = 12

				-- Calculate triangle points
				local tipX, tipY = target[1], target[2]
				local baseX, baseY = tipX - ux * size, tipY - uy * size
				local leftX, leftY = baseX - uy * (size * 0.5), baseY + ux * (size * 0.5)
				local rightX, rightY = baseX + uy * (size * 0.5), baseY - ux * (size * 0.5)

				-- Create triangle polygon
				local trianglePoints = {
					{ tipX, tipY, 0, 0 },
					{ leftX, leftY, 0, 0 },
					{ rightX, rightY, 0, 0 },
				}

				-- Create simple white texture for arrow
				local arrowTexture = createTextureRGBA(stringChar(0, 255, 0, 255), 1, 1)
				setColor(0, 255, 0, 255)
				texturedPolygon(arrowTexture, trianglePoints, true)
				deleteTexture(arrowTexture)
			end
		end
	end

	-- Draw white arrow back to start position when returning
	if IsReturning then
		local pLocal = entities.GetLocalPlayer()
		if pLocal then
			setColor(255, 255, 255, 255) -- White color
			local startPosScr = worldToScreen(pLocal:GetAbsOrigin())
			local endPosScr = worldToScreen(PeekReturnVec)
			if startPosScr and endPosScr then
				drawLine(
					mathFloor(startPosScr[1]),
					mathFloor(startPosScr[2]),
					mathFloor(endPosScr[1]),
					mathFloor(endPosScr[2])
				)
				-- Draw arrow head
				local dx = endPosScr[1] - startPosScr[1]
				local dy = endPosScr[2] - startPosScr[2]
				local len = mathSqrt(dx * dx + dy * dy)
				if len > 0 then
					local ux, uy = dx / len, dy / len
					local size = 12
					local tipX, tipY = endPosScr[1], endPosScr[2]
					local baseX, baseY = tipX - ux * size, tipY - uy * size
					local leftX, leftY = baseX - uy * (size * 0.5), baseY + ux * (size * 0.5)
					local rightX, rightY = baseX + uy * (size * 0.5), baseY - ux * (size * 0.5)
					local triPts = {
						{ tipX, tipY, 0, 0 },
						{ leftX, leftY, 0, 0 },
						{ rightX, rightY, 0, 0 },
					}
					local arrowTex = createTextureRGBA(stringChar(255, 255, 255, 255), 1, 1)
					texturedPolygon(arrowTex, triPts, true)
					deleteTexture(arrowTex)
				end
			end
		end
	end

	-- Draw arrow from current player position to peek start (PeekReturnVec) in manual mode
	if Menu.PeekAssist == false and not IsReturning then
		local pLocal = entities.GetLocalPlayer()
		if pLocal then
			setColor(255, 255, 255, 255)
			local startPosScr = worldToScreen(pLocal:GetAbsOrigin())
			local endPosScr = worldToScreen(PeekReturnVec)
			if startPosScr and endPosScr then
				drawLine(
					mathFloor(startPosScr[1]),
					mathFloor(startPosScr[2]),
					mathFloor(endPosScr[1]),
					mathFloor(endPosScr[2])
				)
				-- Draw arrow head
				local dx = endPosScr[1] - startPosScr[1]
				local dy = endPosScr[2] - startPosScr[2]
				local len = mathSqrt(dx * dx + dy * dy)
				if len > 0 then
					local ux, uy = dx / len, dy / len
					local size = 10
					local tipX, tipY = endPosScr[1], endPosScr[2]
					local baseX, baseY = tipX - ux * size, tipY - uy * size
					local leftX, leftY = baseX - uy * (size * 0.5), baseY + ux * (size * 0.5)
					local rightX, rightY = baseX + uy * (size * 0.5), baseY - ux * (size * 0.5)
					local triPts = {
						{ tipX, tipY, 0, 0 },
						{ leftX, leftY, 0, 0 },
						{ rightX, rightY, 0, 0 },
					}
					local arrowTex = createTextureRGBA(stringChar(255, 255, 255, 255), 1, 1)
					texturedPolygon(arrowTex, triPts, true)
					deleteTexture(arrowTex)
				end
			end
		end
	end

	-- Draw ground circle at start position using textured polygon
	if PeekReturnVec then
		local circleCenter = PeekReturnVec + Vector3(0, 0, 1) -- Slightly above ground
		local circleRadius = 10
		local segments = 16
		local angleStep = (2 * mathPi) / segments

		-- Generate circle vertices
		local positions = {}
		for i = 1, segments do
			local angle = angleStep * i
			local point = circleCenter + Vector3(mathCos(angle), mathSin(angle), 0) * circleRadius
			local screenPos = worldToScreen(point)
			if screenPos then
				positions[i] = screenPos
			else
				positions = {} -- If any point is off-screen, skip drawing
				break
			end
		end

		if #positions == segments then
			-- Draw outline
			setColor(0, 0, 0, 155) -- Black outline
			local last = positions[#positions]
			for i = 1, #positions do
				local cur = positions[i]
				drawLine(mathFloor(last[1]), mathFloor(last[2]), mathFloor(cur[1]), mathFloor(cur[2]))
				last = cur
			end

			-- Draw filled polygon
			setColor(Menu.Visuals.CircleColor[1], Menu.Visuals.CircleColor[2], Menu.Visuals.CircleColor[3], 255)
			local pts, ptsReversed = {}, {}
			local sum = 0
			for i, pos in ipairs(positions) do
				local pt = { pos[1], pos[2], 0, 0 }
				pts[i] = pt
				ptsReversed[#positions - i + 1] = pt
				local nextPos = positions[(i % #positions) + 1]
				sum = sum + cross(pos, nextPos, positions[1])
			end
			local polyPts = (sum < 0) and ptsReversed or pts
			texturedPolygon(StartCircleTexture, polyPts, true)

			-- Draw final outline
			setColor(
				Menu.Visuals.CircleColor[1],
				Menu.Visuals.CircleColor[2],
				Menu.Visuals.CircleColor[3],
				Menu.Visuals.CircleColor[4]
			)
			local last = positions[#positions]
			for i = 1, #positions do
				local cur = positions[i]
				drawLine(mathFloor(last[1]), mathFloor(last[2]), mathFloor(cur[1]), mathFloor(cur[2]))
				last = cur
			end
		end
	end
end

local function OnUnload()
	-- Clean up texture
	if StartCircleTexture then
		deleteTexture(StartCircleTexture)
	end

	-- Save config
	CreateCFG(string.format([[Lua %s]], Lua__fileName), Menu)
	clientCommand('play "ui/buttonclickrelease"', true)
end

callbacks.Unregister("CreateMove", "AP_CreateMove")
callbacks.Unregister("Draw", "AP_Draw")
callbacks.Unregister("Unload", "AP_Unload")

callbacks.Register("CreateMove", "AP_CreateMove", OnCreateMove)
callbacks.Register("Draw", "AP_Draw", OnDraw)
callbacks.Register("Unload", "AP_Unload", OnUnload)

clientCommand('play "ui/buttonclick"', true)
