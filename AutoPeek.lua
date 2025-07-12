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

local options = {
	Font = draw.CreateFont("Roboto", 20, 400),
}

-- Menu structure
local Menu = {
	-- Main settings
	Enabled = true,
	Key = KEY_LSHIFT, -- Hold this key to start peeking
	PeekAssist = true, -- Enables peek assist (smart mode). Disable for manual return
	PeekTicks = 33, -- Max peek ticks (10-132)
	Iterations = 7, -- Binary-search refinement passes
	WarpBack = false, -- Warp back instantly instead of walking

	TargetLimit = 3, -- Max players considered per tick

	-- Target hitboxes
	TargetHitboxes = { true, false, false, false, false, false }, -- Defaults: HEAD on, others off
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
		local keyRepr = (type(k) == "string") and string.format("[\"%s\"]", k) or string.format("[%s]", k)
		out = out .. indent .. "    " .. keyRepr .. " = "
		if type(v) == "table" then
			out = out .. serializeTable(v, level + 1) .. ",\n"
		elseif type(v) == "string" then
			out = out .. string.format("\"%s\",\n", v)
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
		if lv == nil then return false end
		if type(v) ~= type(lv) then return false end
		if type(v) == "table" then
			if not keysMatch(v, lv) then return false end
		end
	end
	-- Second, loaded must NOT contain extra keys absent in template
	for k, _ in pairs(loaded) do
		if template[k] == nil then return false end
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
	if Menu.Enabled == nil then Menu.Enabled = true end
	Menu.Key = Menu.Key or KEY_LSHIFT
	if Menu.PeekAssist == nil then Menu.PeekAssist = true end
	if Menu.PeekTicks == nil then Menu.PeekTicks = 66 end
	if Menu.Iterations == nil then Menu.Iterations = 6 end
	if Menu.WarpBack == nil then Menu.WarpBack = false end
	if Menu.TargetLimit == nil then Menu.TargetLimit = 5 end

	-- Initialize TargetHitboxes as boolean array
	if Menu.TargetHitboxes == nil then
		Menu.TargetHitboxes = { true, false, false, false, false, false }
	end
	Menu.HitboxOptions = { "HEAD", "NECK", "PELVIS", "BODY", "CHEST", "VIEWPOS" }

	-- Initialize Visuals settings
	Menu.Visuals = Menu.Visuals or {}
	Menu.Visuals.CircleColor = Menu.Visuals.CircleColor or { 255, 255, 255, 128 }
end

-- Call the initialization function to ensure no nil values
SafeInitMenu()

--[[ Menu Variables - Now using Menu structure ]]

local PosPlaced = false    -- Did we start peeking?
local IsReturning = false  -- Are we returning?
local HasDirection = false -- Do we have a peek direction?
local PeekStartVec = Vector3(0, 0, 0)
local PeekDirectionVec = Vector3(0, 0, 0)
local PeekReturnVec = Vector3(0, 0, 0)
local PeekSide = 0                             -- -1 = left, 1 = right
local OriginalPeekDirection = Vector3(0, 0, 0) -- Store original direction captured at start
local CurrentPeekBasisDir = Vector3(1, 0, 0)   -- Direction used for drawing perpendicular lines each tick

-- InstantStop state machine (integrated from InstantStop.lua)
local STATE_DEFAULT = "default"
local STATE_ENDING_FAST_STOP = "ending_fast_stop"
local STATE_COOLDOWN = "cooldown"
local COOLDOWN_TICKS = 7 -- Number of ticks to wait in cooldown
local currentState = STATE_DEFAULT
local cooldownTicksRemaining = 0
local wasGroundedLastTick = false

-- Helper from InstantStop
local function isPlayerGrounded(player)
	if not player then return false end
	local flags = player:GetPropInt("m_fFlags")
	if not flags then return false end
	return (flags & 256) ~= 0 -- FL_ONGROUND = 256
end

-- Trigger fast stop sequence (from InstantStop)
local function triggerFastStop()
	client.Command("cyoa_pda_open 1", true)
	currentState = STATE_ENDING_FAST_STOP
end

-- Process ending fast stop (send close and enter cooldown)
local function processEndingFastStopState()
	client.Command("cyoa_pda_open 0", true)
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

	local viewAngles = engine.GetViewAngles()
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
		draw.DeleteTexture(StartCircleTexture)
	end
	local color = Menu.Visuals.CircleColor
	StartCircleTexture = draw.CreateTextureRGBA(string.char(
		color[1], color[2], color[3], color[4],
		color[1], color[2], color[3], color[4],
		color[1], color[2], color[3], color[4],
		color[1], color[2], color[3], color[4]
	), 2, 2)
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
local MAX_SPEED = 300        -- or use player's max speed
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
	if not entity or not entity:IsValid() then return false end

	local ignoreClasses = { "CTFAmmoPack", "CTFDroppedWeapon" }
	for _, ignoreClass in ipairs(ignoreClasses) do
		if entity:GetClass() == ignoreClass then return false end
	end

	local pLocal = entities.GetLocalPlayer()
	if not pLocal then return true end

	if entity:GetName() == pLocal:GetName() then return false end             -- ignore self
	if entity:GetTeamNumber() == pLocal:GetTeamNumber() then return false end -- ignore teammates

	return true
end

-- Function to handle forward collision with wall sliding and direction correction
local function handleForwardCollision(vel, wallTrace, originalDirection)
	local normal = wallTrace.plane
	local angle = math.deg(math.acos(math.abs(originalDirection:Dot(normal))))

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
	local wallAngle = math.deg(math.acos(normal:Dot(UP_VECTOR)))
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
	local angle = math.deg(math.acos(normal:Dot(UP_VECTOR)))
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

	if onGround then vel.z = 0 end
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
	if not pLocal then return 0, startPos, { startPos } end

	local tickInterval = globals.TickInterval()
	local gravity = client.GetConVar("sv_gravity") * tickInterval
	local stepSize = pLocal:GetPropFloat("localdata", "m_flStepSize") or 18
	local flags = pLocal:GetPropInt("m_fFlags") or 0

	-- Current simulation direction (can be modified by wall hits)
	local currentDirection = direction / dirLen -- normalized
	local simulationAttempts = 0
	local maxAttempts = 3                       -- Prevent infinite loops

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
			local wallTrace = engine.TraceHull(
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
					local newX, newY, newVel, newDirection, restart, stop = handleForwardCollision(currentVel, wallTrace,
						currentDirection)

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
			local groundTrace = engine.TraceHull(
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
			table.insert(simulationPath, currentPos)

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
	local trace = engine.TraceLine(vFrom, vTo, MASK_SHOT | CONTENTS_GRATE)
	return ((trace.entity and trace.entity == target) or (trace.fraction > 0.99))
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

-- Function to calculate view position for target players (same as local player calculation)
local function GetPlayerViewPos(player)
	if not player or not player:IsValid() then
		return nil
	end

	-- Get player's origin (feet position)
	local playerOrigin = player:GetAbsOrigin()
	if not playerOrigin then
		return nil
	end

	-- Get player's view offset (same calculation as local player)
	local viewOffset = player:GetPropVector("localdata", "m_vecViewOffset[0]")
	if not viewOffset then
		-- Fallback to default view offset if property not available
		viewOffset = Vector3(0, 0, 64) -- Default TF2 view height
	end

	-- Calculate view position (origin + view offset)
	return playerOrigin + viewOffset
end

local function GetHitboxPos(entity, hitbox)
	-- Special case for VIEWPOS - calculate view position instead of using hitbox
	if hitbox == Hitboxes.VIEWPOS then
		return GetPlayerViewPos(entity)
	end

	-- Normal hitbox handling
	local hitbox = entity:GetHitboxes()[hitbox]
	if not hitbox then
		return
	end

	return (hitbox[1] + hitbox[2]) * 0.5
end

-- Modified CanAttackFromPos with target limit and priority -----------------------------
local function CanAttackFromPos(pLocal, pPos)
	if CanShoot(pLocal) == false then
		return false
	end
	local ignoreFriends = gui.GetValue("ignore steam friends")

	-- Build local view forward vector for FOV calculation
	local viewAngles = engine.GetViewAngles()
	local forwardDir = viewAngles:Forward()

	-- Collect candidates with metric (angular FOV minus priority bonus)
	local candidates = {}
	local players = entities.FindByClass("CTFPlayer")
	for _, vPlayer in pairs(players) do
		if not vPlayer:IsValid() or not vPlayer:IsAlive() then goto continue end
		if vPlayer:GetTeamNumber() == pLocal:GetTeamNumber() then goto continue end

		local playerInfo = client.GetPlayerInfo(vPlayer:GetIndex())
		if steam.IsFriend(playerInfo.SteamID) and ignoreFriends == 1 then goto continue end

		-- Get head position for FOV metric
		local headPos = GetHitboxPos(vPlayer, Hitboxes.HEAD)
		if not headPos then goto continue end

		-- Compute FOV using lnxLib if available
		local fovDeg
		if Math then
			local targetAngles = Math.PositionAngles(pPos, headPos)
			fovDeg = Math.AngleFov(viewAngles, targetAngles)
		else
			-- Fallback manual dot computation
			local toTarget = headPos - pPos
			local dist = toTarget:Length()
			if dist == 0 then goto continue end
			local dir = toTarget / dist
			local dot = math.max(-1, math.min(1, forwardDir:Dot(dir)))
			fovDeg = math.deg(math.acos(dot))
		end

		-- Priority bonus
		local classId = vPlayer:GetPropInt("m_iClass") or 0
		local bonus = 0
		if classId == 2 then -- Sniper
			bonus = 100
		elseif classId == 8 then -- Spy
			bonus = 50
		end
		local metric = fovDeg - bonus
		table.insert(candidates, { player = vPlayer, metric = metric })

		::continue::
	end

	-- Sort by metric ascending
	table.sort(candidates, function(a, b) return a.metric < b.metric end)

	local checked = 0
	for _, cand in ipairs(candidates) do
		if checked >= Menu.TargetLimit then break end
		checked = checked + 1

		local vPlayer = cand.player
		-- Check selected hitboxes from array
		for i, enabled in ipairs(Menu.TargetHitboxes) do
			if enabled then
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

	local x = diff.x
	local y = diff.y
	local vSilent = Vector3(x, y, 0)

	local ang = vSilent:Angles()
	local cPitch, cYaw, cRoll = pCmd:GetViewAngles()
	local yaw = math.rad(ang.y - cYaw)
	local pitch = math.rad(ang.x - cPitch)
	local move = Vector3(math.cos(yaw) * 450, -math.sin(yaw) * 450, -math.cos(pitch) * 450)

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
	table.insert(LineDrawList, {
		start = startPos,
		endPos = endPos,
	})
end

--[[
local function OnPlayerHurt(ev)
	if ev:GetName() ~= "player_hurt" then return end
	if not PosPlaced then return end     -- Only trigger if we're actively peeking
	if not Menu.WarpBack then return end -- Only if warp is enabled

	local localPlayer = entities.GetLocalPlayer()
	if not localPlayer then return end

	-- Check if WE are the attacker
	local attacker = entities.GetByUserID(ev:GetInt("attacker"))
	if not attacker or localPlayer:GetIndex() ~= attacker:GetIndex() then return end

	-- Check if victim is an enemy
	local victimEnt = entities.GetByUserID(ev:GetInt("userid"))
	if not victimEnt then return end

	-- Ignore team damage
	if victimEnt:GetTeamNumber() == localPlayer:GetTeamNumber() then return end

	-- We successfully damaged an enemy - warp immediately
	if warp and not warp.IsWarping() and (warp.GetChargedTicks() or 0) > 0 then
		warp.TriggerWarp()
	end
end
--]]

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

	if pLocal:IsAlive() and input.IsButtonDown(Menu.Key) or pLocal:IsAlive() and (pLocal:InCond(13)) then
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
				local viewAnglesTmp = engine.GetViewAngles()
				local yawTmp = math.rad(viewAnglesTmp.y)
				local rightTmp = Vector3(-math.sin(yawTmp), math.cos(yawTmp), 0)
				PeekSide = (intentDir:Dot(rightTmp) >= 0) and -1 or 1

				HasDirection = true

				-- Set anchor only on first assignment
				if PeekStartFeet == nil then
					PeekStartFeet = PeekReturnVec
					PeekStartEye = PeekStartFeet + viewOffset
				end
			end
		end

		-- Should we peek?
		if Menu.PeekAssist == true and HasDirection == true then
			LineDrawList = {}
			CrossDrawList = {}

			-- Anchor (PeekStartVec) remains constant – do not overwrite each tick
			-- Recompute direction vector each tick based on current view yaw
			PeekDirectionVec = OriginalPeekDirection * (MAX_SPEED * TICK_INTERVAL * Menu.PeekTicks)
			PeekDirectionVec.z = 0

			-- SMART BINARY SEARCH -----------------------------
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
				table.insert(CrossDrawList, { start = crossStart, endPos = crossEnd, sees = sees })
			end

			-- Predeclare variables to avoid scope issues with goto
			-- NOTE: ALL variables used after any 'goto after_search' MUST be predeclared here
			-- to prevent "jumps into scope of local" errors
			local farPos, farVisible, farFeet, farEye, farPath
			local hullTrace, maxRatio, effectiveDir
			local currentPos, remainingDir, totalDistance, maxDistance
			local low, high, bestPos, bestFeet
			local found = false
			local requestedDistance, walkableDistance, simEndPos, startPath
			local best_dist
			local ignored_dist

			local startEye = PeekStartFeet + viewOffset
			local startVisible = CanAttackFromPos(pLocal, startEye)
			if startVisible then
				CurrentBestPos = startEye
				addVisual(PeekStartFeet, true, { PeekStartFeet })
				found = true
				bestFeet = PeekStartFeet
				bestPos = startEye
				goto after_search
			end

			walkableDistance, farFeet, farPath = SimulateMovement(PeekStartFeet, PeekDirectionVec, Menu.PeekTicks)

			if walkableDistance > 0 then
				CurrentPeekBasisDir = farFeet - PeekStartFeet
				CurrentPeekBasisDir.z = 0
				-- fallback if zero
				if CurrentPeekBasisDir:Length() == 0 then
					CurrentPeekBasisDir = OriginalPeekDirection
				end
				CurrentPeekBasisDir = CurrentPeekBasisDir / CurrentPeekBasisDir:Length()

				farEye = farFeet + viewOffset
				farVisible = CanAttackFromPos(pLocal, farEye)
				addVisual(farFeet, farVisible, farPath)
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

			low = 0.0      -- invisible
			high = walkableDistance -- visible
			found = true

			for i = 1, Menu.Iterations do
				local mid_dist = (low + high) * 0.5
				local test_dist, testFeet, testPath = SimulateMovement(PeekStartFeet, PeekDirectionVec,
					math.floor(mid_dist / (MAX_SPEED * TICK_INTERVAL)))
				local testEye = testFeet + viewOffset
				local vis = CanAttackFromPos(pLocal, testEye)
				addVisual(testFeet, vis, testPath)

				if vis then
					high = mid_dist
				else
					low = mid_dist
				end
			end

			-- After loop, compute best at converged high
			best_dist = high
			ignored_dist, bestFeet = SimulateMovement(PeekStartFeet, PeekDirectionVec,
				math.floor(best_dist / (MAX_SPEED * TICK_INTERVAL)))
			bestPos = bestFeet + viewOffset

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
		end

		-- We've just attacked. Let's return!
		if (pCmd:GetButtons() & IN_ATTACK) ~= 0 then
			-- Trigger InstantStop on shoot tick
			if currentState == STATE_DEFAULT and isGrounded then
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
				if Menu.WarpBack and warp then warp.TriggerCharge() end
				return
			end

			-- Always set walking movement every tick during return
			WalkTo(pCmd, pLocal, PeekReturnVec)

			-- Process InstantStop state machine
			if currentState == STATE_ENDING_FAST_STOP then
				processEndingFastStopState() -- cyoa open 0 and enter cooldown
			elseif currentState == STATE_COOLDOWN then
				cooldownTicksRemaining = cooldownTicksRemaining - 1
				if cooldownTicksRemaining <= 0 then
					currentState = STATE_DEFAULT
					cooldownTicksRemaining = 0
				end
			end

			-- Next tick: close cyoa to unfreeze and cancel scope
			if NeedsCyoaClose and not (pCmd:GetButtons() & IN_ATTACK) ~= 0 then
				client.Command("cyoa_pda_open 0", true)
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
			if (pCmd:GetButtons() & IN_ATTACK) ~= 0 then
				-- First tick: open cyoa and start returning
				if not ShotThisTick then
					client.Command("cyoa_pda_open 1", true)
					ShotThisTick = true
					NeedsCyoaClose = true
				end
				IsReturning = true
			end

			-- Next tick: close cyoa to unfreeze and cancel scope
			if NeedsCyoaClose and not (pCmd:GetButtons() & IN_ATTACK) ~= 0 then
				client.Command("cyoa_pda_open 0", true)
				NeedsCyoaClose = false
			end

			if IsReturning == true then
				local distVector = PeekReturnVec - localPos
				local dist = distVector:Length()
				if dist < 12 then
					IsReturning = false
					if Menu.WarpBack and warp then warp.TriggerCharge() end
					return
				end

				-- First set walking movement, then warp
				WalkTo(pCmd, pLocal, PeekReturnVec)

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
					if speed <= 5 then
						pLocal:SetAbsOrigin(PeekReturnVec)
					end
				end
			end
		end
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
		if Menu.WarpBack and warp then warp.TriggerCharge() end --remember this is hwo you recharge api is literaly this dont cahnge it
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

			Menu.PeekTicks = TimMenu.Slider("Peek Ticks", Menu.PeekTicks, 10, 132, 1)
			TimMenu.NextLine()

			Menu.Iterations = TimMenu.Slider("Iterations", Menu.Iterations, 1, 15, 1)
			TimMenu.NextLine()

			Menu.TargetLimit = TimMenu.Slider("Target Limit", Menu.TargetLimit, 1, 20, 1)
			TimMenu.Tooltip("How many nearby enemies to evaluate per tick")
			TimMenu.NextLine()

			TimMenu.Separator("Target Hitboxes")
			Menu.TargetHitboxes = TimMenu.Combo("Hitboxes", Menu.TargetHitboxes, Menu.HitboxOptions)
			TimMenu.Tooltip("select hitboxes to check for(laggy if more then 1)")
			TimMenu.NextLine()

			TimMenu.Separator("Visuals")

			local oldColor = { Menu.Visuals.CircleColor[1], Menu.Visuals.CircleColor[2], Menu.Visuals.CircleColor[3],
				Menu.Visuals.CircleColor[4] }
			Menu.Visuals.CircleColor = TimMenu.ColorPicker("Circle Color", Menu.Visuals.CircleColor)

			-- Recreate texture if color changed
			if oldColor[1] ~= Menu.Visuals.CircleColor[1] or oldColor[2] ~= Menu.Visuals.CircleColor[2] or
				oldColor[3] ~= Menu.Visuals.CircleColor[3] or oldColor[4] ~= Menu.Visuals.CircleColor[4] then
				CreateCircleTexture()
			end
		end
	end

	if PosPlaced == false then
		return
	end

	draw.SetFont(options.Font)

	-- Draw the lines
	if HasDirection == true then
		local total = (#LineDrawList > 1) and #LineDrawList or 1
		for idx, v in ipairs(LineDrawList) do
			local brightness = 255
			if total > 1 then
				local t = (idx - 1) / (total - 1)
				brightness = 255 - math.floor(t * 127)
			end
			brightness = math.min(255, math.max(0, brightness))
			draw.Color(math.floor(brightness), math.floor(brightness), math.floor(brightness), 230)
			local start = client.WorldToScreen(v.start)
			local endPos = client.WorldToScreen(v.endPos)
			if start ~= nil and endPos ~= nil then
				draw.Line(math.floor(start[1]), math.floor(start[2]), math.floor(endPos[1]), math.floor(endPos[2]))
			end
		end

		-- Draw perpendicular cross-lines
		for _, v in ipairs(CrossDrawList) do
			if v.sees then
				draw.Color(255, 255, 255, 255) -- white when target visible
			else
				draw.Color(255, 0, 0, 255) -- red otherwise
			end

			local s = client.WorldToScreen(v.start)
			local e = client.WorldToScreen(v.endPos)
			if s and e then
				draw.Line(math.floor(s[1]), math.floor(s[2]), math.floor(e[1]), math.floor(e[2]))
			end
		end
	end

	-- Draw green arrow from feet to best ground position using triangle polygon
	if CurrentBestFeet ~= nil then
		local start2D = client.WorldToScreen(PeekReturnVec)
		local target = client.WorldToScreen(CurrentBestFeet)
		if start2D and target then
			draw.Color(0, 255, 0, 255)
			draw.Line(math.floor(start2D[1]), math.floor(start2D[2]), math.floor(target[1]), math.floor(target[2]))

			-- Arrow head using triangle polygon
			local dx = target[1] - start2D[1]
			local dy = target[2] - start2D[2]
			local len = math.sqrt(dx * dx + dy * dy)
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
					{ tipX,   tipY,   0, 0 },
					{ leftX,  leftY,  0, 0 },
					{ rightX, rightY, 0, 0 }
				}

				-- Create simple white texture for arrow
				local arrowTexture = draw.CreateTextureRGBA(string.char(0, 255, 0, 255), 1, 1)
				draw.Color(0, 255, 0, 255)
				draw.TexturedPolygon(arrowTexture, trianglePoints, true)
				draw.DeleteTexture(arrowTexture)
			end
		end
	end

	-- Draw arrow from current player position to peek start (PeekReturnVec)
	if Menu.PeekAssist == false then
		local pLocal = entities.GetLocalPlayer()
		if pLocal then
			draw.Color(255, 255, 255, 255)
			local startPosScr = client.WorldToScreen(pLocal:GetAbsOrigin())
			local endPosScr = client.WorldToScreen(PeekReturnVec)
			if startPosScr and endPosScr then
				draw.Line(
					math.floor(startPosScr[1]),
					math.floor(startPosScr[2]),
					math.floor(endPosScr[1]),
					math.floor(endPosScr[2])
				)
				-- Draw arrow head
				local dx = endPosScr[1] - startPosScr[1]
				local dy = endPosScr[2] - startPosScr[2]
				local len = math.sqrt(dx * dx + dy * dy)
				if len > 0 then
					local ux, uy = dx / len, dy / len
					local size = 10
					local tipX, tipY = endPosScr[1], endPosScr[2]
					local baseX, baseY = tipX - ux * size, tipY - uy * size
					local leftX, leftY = baseX - uy * (size * 0.5), baseY + ux * (size * 0.5)
					local rightX, rightY = baseX + uy * (size * 0.5), baseY - ux * (size * 0.5)
					local triPts = {
						{ tipX,   tipY,   0, 0 },
						{ leftX,  leftY,  0, 0 },
						{ rightX, rightY, 0, 0 },
					}
					local arrowTex = draw.CreateTextureRGBA(string.char(255, 255, 255, 255), 1, 1)
					draw.TexturedPolygon(arrowTex, triPts, true)
					draw.DeleteTexture(arrowTex)
				end
			end
		end
	end

	-- Draw ground circle at start position using textured polygon
	if PeekReturnVec then
		local circleCenter = PeekReturnVec + Vector3(0, 0, 1) -- Slightly above ground
		local circleRadius = 10
		local segments = 16
		local angleStep = (2 * math.pi) / segments

		-- Generate circle vertices
		local positions = {}
		for i = 1, segments do
			local angle = angleStep * i
			local point = circleCenter + Vector3(math.cos(angle), math.sin(angle), 0) * circleRadius
			local screenPos = client.WorldToScreen(point)
			if screenPos then
				positions[i] = screenPos
			else
				positions = {} -- If any point is off-screen, skip drawing
				break
			end
		end

		if #positions == segments then
			-- Draw outline
			draw.Color(0, 0, 0, 155) -- Black outline
			local last = positions[#positions]
			for i = 1, #positions do
				local cur = positions[i]
				draw.Line(math.floor(last[1]), math.floor(last[2]), math.floor(cur[1]), math.floor(cur[2]))
				last = cur
			end

			-- Draw filled polygon
			draw.Color(Menu.Visuals.CircleColor[1], Menu.Visuals.CircleColor[2], Menu.Visuals.CircleColor[3], 255)
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
			draw.TexturedPolygon(StartCircleTexture, polyPts, true)

			-- Draw final outline
			draw.Color(Menu.Visuals.CircleColor[1], Menu.Visuals.CircleColor[2], Menu.Visuals.CircleColor[3],
				Menu.Visuals.CircleColor[4])
			local last = positions[#positions]
			for i = 1, #positions do
				local cur = positions[i]
				draw.Line(math.floor(last[1]), math.floor(last[2]), math.floor(cur[1]), math.floor(cur[2]))
				last = cur
			end
		end
	end
end

local function OnUnload()
	-- Clean up texture
	if StartCircleTexture then
		draw.DeleteTexture(StartCircleTexture)
	end

	-- Save config
	CreateCFG(string.format([[Lua %s]], Lua__fileName), Menu)
	client.Command('play "ui/buttonclickrelease"', true)
end

callbacks.Unregister("CreateMove", "AP_CreateMove")
callbacks.Unregister("Draw", "AP_Draw")
callbacks.Unregister("Unload", "AP_Unload")
-- callbacks.Unregister("FireGameEvent", "AP_PlayerHurt")

callbacks.Register("CreateMove", "AP_CreateMove", OnCreateMove)
callbacks.Register("Draw", "AP_Draw", OnDraw)
callbacks.Register("Unload", "AP_Unload", OnUnload)
-- callbacks.Register("FireGameEvent", "AP_PlayerHurt", OnPlayerHurt)

client.Command('play "ui/buttonclick"', true)
