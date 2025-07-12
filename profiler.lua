--[[
    Performance Profiler Module for Lmaobox
    Author: titaniummachine1
    
    Usage:
    local Profiler = require("profiler")
    
    -- In your functions:
    Profiler.Start(functionId)
    -- ... your code ...
    Profiler.End(functionId)
    
    -- In OnDraw:
    Profiler.Draw()
    
    -- In menu:
    Profiler.DrawMenu()
]]

local Profiler = {}

-- Configuration
local PROFILER_ENABLED = true -- Set to false to disable profiler entirely
local PROFILER_MAX_TIME = 0.01 -- Dynamic scale based on frame budget
local PROFILER_WINDOW_SIZE = 66 -- ~1 second at 66fps

-- Profiler State
local ProfilerActive = false
local ProfilerFrameStartTimes = {} -- Track start times for current frame
local ProfilerFrameAccumulator = {} -- Accumulate times for current frame
local ProfilerDisplayData = {} -- Data to display (rolling average)

-- Memory tracking system
local ProfilerMemoryStart = 0 -- Memory at start of frame
local ProfilerMemoryEnd = 0 -- Memory at end of frame
local ProfilerMemoryDelta = 0 -- Memory change per frame
local ProfilerMemoryAccumulator = 0 -- Accumulate memory changes
local ProfilerMemoryDisplayData = 0 -- Rolling average memory usage

-- Per-function memory tracking
local ProfilerFunctionMemoryStart = {} -- Memory at start of each function
local ProfilerFunctionMemoryAccumulator = {} -- Accumulate memory changes per function
local ProfilerFunctionMemoryDisplayData = {} -- Rolling average memory usage per function

-- Rolling window system for stable profiling over time
local ProfilerHistory = {} -- Circular buffer of recent frame data
local ProfilerMemoryHistory = {} -- Circular buffer of memory data
local ProfilerFunctionMemoryHistory = {} -- Circular buffer of per-function memory data
local ProfilerHistoryIndex = 1 -- Current position in circular buffer
local ProfilerHistoryCount = 0 -- How many frames we've accumulated

-- Frame timing expectations
local EXPECTED_FRAME_TIME = 1.0 / 66.67 -- Expected frame time at 66fps (~0.015 seconds)
local EXPECTED_TICK_TIME = globals.TickInterval() or EXPECTED_FRAME_TIME

-- Total program execution tracking
local TotalProgramTime = 0

-- Helper function to validate numeric values and prevent NaN
local function ValidateNumber(value, fallback)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback or 0
	end
	return value
end

-- Function definitions with colors and IDs - organized by category
local ProfilerFunctions = {
	-- Core Logic Functions
	{ id = 1, name = "UpdateTargetCandidates", color = { 255, 100, 100 } },
	{ id = 2, name = "SimulateMovement", color = { 100, 255, 100 } },
	{ id = 3, name = "CanAttackFromPos", color = { 100, 100, 255 } },
	{ id = 4, name = "GetFOV", color = { 255, 255, 100 } },
	{ id = 5, name = "VisPos", color = { 255, 100, 255 } },
	{ id = 6, name = "GetHitboxPos", color = { 100, 255, 255 } },
	{ id = 7, name = "BinarySearch", color = { 255, 150, 50 } },
	{ id = 8, name = "WalkTo", color = { 150, 255, 50 } },

	-- OnCreateMove Logic Functions
	{ id = 9, name = "OnCreateMove_Segment", color = { 50, 255, 150 } },
	{ id = 10, name = "PeekLogic", color = { 255, 200, 50 } },
	{ id = 11, name = "ReturnLogic", color = { 200, 255, 50 } },
	{ id = 12, name = "DirectionUpdate", color = { 50, 200, 255 } },

	-- Visual Functions
	{ id = 13, name = "OnDraw_Total", color = { 150, 50, 255 } },
	{ id = 14, name = "VisualDrawing", color = { 255, 50, 200 } },
	{ id = 15, name = "MenuDrawing", color = { 200, 50, 255 } },
}

-- Initialize accumulator and display data
for i = 1, #ProfilerFunctions do
	ProfilerFrameAccumulator[i] = 0
	ProfilerDisplayData[i] = 0
	ProfilerFunctionMemoryAccumulator[i] = 0
	ProfilerFunctionMemoryDisplayData[i] = 0
end

-- Initialize rolling history buffer
for frameIndex = 1, PROFILER_WINDOW_SIZE do
	ProfilerHistory[frameIndex] = {}
	ProfilerFunctionMemoryHistory[frameIndex] = {}
	for funcIndex = 1, #ProfilerFunctions do
		ProfilerHistory[frameIndex][funcIndex] = 0
		ProfilerFunctionMemoryHistory[frameIndex][funcIndex] = 0
	end
	ProfilerMemoryHistory[frameIndex] = 0
end

-- Public API Functions
function Profiler.Start(functionId)
	if not PROFILER_ENABLED then
		return
	end
	ProfilerFrameStartTimes[functionId] = globals.RealTime()
	if ProfilerActive then
		ProfilerFunctionMemoryStart[functionId] = ValidateNumber(collectgarbage("count"), 0)
	end
end

function Profiler.End(functionId)
	if not PROFILER_ENABLED then
		return
	end
	local startTime = ProfilerFrameStartTimes[functionId]
	if startTime then
		local duration = globals.RealTime() - startTime
		ProfilerFrameAccumulator[functionId] = ProfilerFrameAccumulator[functionId] + duration
		ProfilerFrameStartTimes[functionId] = nil

		-- Track memory usage per function
		if ProfilerActive then
			local memoryStart = ProfilerFunctionMemoryStart[functionId]
			if memoryStart then
				local memoryEnd = ValidateNumber(collectgarbage("count"), 0)
				local memoryDelta = ValidateNumber(memoryEnd - memoryStart, 0)
				ProfilerFunctionMemoryAccumulator[functionId] =
					ValidateNumber(ProfilerFunctionMemoryAccumulator[functionId] + math.abs(memoryDelta), 0)
				ProfilerFunctionMemoryStart[functionId] = nil
			end
		end
	end
end

function Profiler.StartFrame()
	if not PROFILER_ENABLED then
		return
	end
	if ProfilerActive then
		ProfilerMemoryStart = ValidateNumber(collectgarbage("count"), 0)
	end
end

function Profiler.EndFrame()
	if not PROFILER_ENABLED then
		return
	end
	-- End frame memory tracking
	if ProfilerActive then
		ProfilerMemoryEnd = ValidateNumber(collectgarbage("count"), 0)
		ProfilerMemoryDelta = ValidateNumber(ProfilerMemoryEnd - ProfilerMemoryStart, 0)
		ProfilerMemoryAccumulator = ValidateNumber(ProfilerMemoryAccumulator + math.abs(ProfilerMemoryDelta), 0)
	end

	-- Store current frame data in circular buffer
	for i = 1, #ProfilerFunctions do
		ProfilerHistory[ProfilerHistoryIndex][i] = ProfilerFrameAccumulator[i]
		ProfilerFrameAccumulator[i] = 0

		ProfilerFunctionMemoryHistory[ProfilerHistoryIndex][i] = ProfilerFunctionMemoryAccumulator[i]
		ProfilerFunctionMemoryAccumulator[i] = 0
	end

	ProfilerMemoryHistory[ProfilerHistoryIndex] = ProfilerMemoryAccumulator
	ProfilerMemoryAccumulator = 0

	ProfilerHistoryIndex = ProfilerHistoryIndex + 1
	if ProfilerHistoryIndex > PROFILER_WINDOW_SIZE then
		ProfilerHistoryIndex = 1
	end
	if ProfilerHistoryCount < PROFILER_WINDOW_SIZE then
		ProfilerHistoryCount = ProfilerHistoryCount + 1
	end

	-- Calculate rolling average from history buffer
	for funcIndex = 1, #ProfilerFunctions do
		local totalTime = 0
		local totalMemory = 0

		for frameIndex = 1, ProfilerHistoryCount do
			totalTime = totalTime + ValidateNumber(ProfilerHistory[frameIndex][funcIndex], 0)
			totalMemory = totalMemory + ValidateNumber(ProfilerFunctionMemoryHistory[frameIndex][funcIndex], 0)
		end

		ProfilerDisplayData[funcIndex] =
			ValidateNumber(ProfilerHistoryCount > 0 and totalTime / ProfilerHistoryCount or 0, 0)
		ProfilerFunctionMemoryDisplayData[funcIndex] =
			ValidateNumber(ProfilerHistoryCount > 0 and totalMemory / ProfilerHistoryCount or 0, 0)
	end

	-- Calculate rolling average total memory usage
	local totalMemory = 0
	for frameIndex = 1, ProfilerHistoryCount do
		totalMemory = totalMemory + ValidateNumber(ProfilerMemoryHistory[frameIndex], 0)
	end
	ProfilerMemoryDisplayData = ValidateNumber(ProfilerHistoryCount > 0 and totalMemory / ProfilerHistoryCount or 0, 0)

	-- Calculate total program time
	TotalProgramTime = 0
	for i = 1, #ProfilerFunctions do
		TotalProgramTime = TotalProgramTime + ProfilerDisplayData[i]
	end
	PROFILER_MAX_TIME = EXPECTED_FRAME_TIME

	ProfilerFrameStartTimes = {}
end

-- Profiler font (create once on load, set every frame to avoid memory overflow)
local ProfilerFont = draw.CreateFont("Arial", 12, 400)

-- Profiler visualization
function Profiler.Draw()
	if not PROFILER_ENABLED or not ProfilerActive then
		return
	end

	-- Get screen dimensions
	local screenW, screenH = draw.GetScreenSize()
	local timeBarHeight = 40
	local coreLogicBarHeight = 25
	local onCreateMoveBarHeight = 25
	local visualBarHeight = 25
	local totalBarHeight = timeBarHeight + coreLogicBarHeight + onCreateMoveBarHeight + visualBarHeight + 30
	local barY = screenH - totalBarHeight - 10

	-- Draw background
	draw.Color(0, 0, 0, 180)
	draw.FilledRect(0, barY - 80, screenW, barY + totalBarHeight)

	-- Expected frame time reference line and info
	draw.Color(255, 255, 255, 255)
	draw.SetFont(ProfilerFont)
	local expectedFrameMs = ValidateNumber(EXPECTED_FRAME_TIME * 1000, 15)
	local actualFrameMs = ValidateNumber(TotalProgramTime * 1000, 0)
	local frameUsagePercent =
		ValidateNumber(TotalProgramTime > 0 and (TotalProgramTime / EXPECTED_FRAME_TIME) * 100 or 0, 0)
	local tickTime = ValidateNumber(ProfilerDisplayData[9] or 0, 0)
	local frameTime = ValidateNumber(ProfilerDisplayData[13] or 0, 0)

	-- Draw timing info above bars
	draw.Color(255, 255, 255, 255)
	draw.Text(
		5,
		barY - 78,
		string.format(
			"Frame Budget: %.3fms (%.0ffps) | Actual: %.3fms (%.1f%%) | OnCreateMove: %.3fms | Draw: %.3fms",
			expectedFrameMs,
			1.0 / EXPECTED_FRAME_TIME,
			actualFrameMs,
			frameUsagePercent,
			tickTime * 1000,
			frameTime * 1000
		)
	)

	-- Calculate total function memory for display
	local totalFunctionMemoryDisplay = 0
	for i = 1, #ProfilerFunctions do
		totalFunctionMemoryDisplay = totalFunctionMemoryDisplay
			+ ValidateNumber(ProfilerFunctionMemoryDisplayData[i], 0)
	end

	draw.Text(
		5,
		barY - 62,
		string.format(
			"Total Memory: %.1fKB/frame | Window: %d frames | Scale: Time=%.3fms",
			totalFunctionMemoryDisplay,
			ProfilerHistoryCount,
			ValidateNumber(PROFILER_MAX_TIME * 1000, 15)
		)
	)

	-- Draw TIME BAR (upper) - scaled to frame budget
	local timeBarY = barY
	local currentX = 0

	for i = 1, #ProfilerFunctions do
		local func = ProfilerFunctions[i]
		local functionTime = ValidateNumber(ProfilerDisplayData[i], 0)

		-- Calculate bar width based on frame budget
		local barWidth = 0
		if EXPECTED_FRAME_TIME > 0 and functionTime > 0 then
			-- Scale bars to percentage of frame budget
			local frameBudgetPercent = ValidateNumber(functionTime / EXPECTED_FRAME_TIME, 0)
			barWidth = ValidateNumber(math.floor(screenW * frameBudgetPercent), 0)

			-- Ensure even tiny percentages get at least 1 pixel if they have any time
			if barWidth == 0 and functionTime > 0 then
				barWidth = 1
			end
		end

		-- Validate bar width and position
		barWidth = math.max(0, math.min(barWidth, screenW - currentX))

		-- Only draw bar if it has actual time (width > 0)
		if barWidth > 0 then
			-- Draw colored time bar
			draw.Color(func.color[1], func.color[2], func.color[3], 200)
			draw.FilledRect(
				math.floor(currentX),
				math.floor(timeBarY),
				math.floor(currentX + barWidth),
				math.floor(timeBarY + timeBarHeight)
			)

			-- Draw function info if bar is wide enough
			if barWidth > 25 then -- Show text if bar is wide enough
				draw.Color(255, 255, 255, 255)
				draw.Text(math.floor(currentX + 2), math.floor(timeBarY + 2), string.format("%d", func.id))
				draw.Text(
					math.floor(currentX + 2),
					math.floor(timeBarY + 16),
					string.format("%.2fms", functionTime * 1000)
				)
			end

			currentX = currentX + barWidth
		end
	end
end

-- Profiler Menu Section
function Profiler.DrawMenu()
	if not PROFILER_ENABLED then
		return
	end

	local TimMenu = require("TimMenu")

	TimMenu.Separator("Profiler")
	ProfilerActive = TimMenu.Checkbox("Enable Profiler", ProfilerActive)
	TimMenu.Tooltip("Shows performance profiling at bottom of screen")

	if ProfilerActive and TimMenu.Button("Reset Profiler") then
		-- Clear all profiler data
		for i = 1, #ProfilerFunctions do
			ProfilerDisplayData[i] = 0
			ProfilerFrameAccumulator[i] = 0
			ProfilerFunctionMemoryDisplayData[i] = 0
			ProfilerFunctionMemoryAccumulator[i] = 0
		end
		ProfilerFrameStartTimes = {}
		ProfilerFunctionMemoryStart = {}

		-- Clear rolling history buffer
		for frameIndex = 1, PROFILER_WINDOW_SIZE do
			for funcIndex = 1, #ProfilerFunctions do
				ProfilerHistory[frameIndex][funcIndex] = 0
				ProfilerFunctionMemoryHistory[frameIndex][funcIndex] = 0
			end
		end
		ProfilerHistoryIndex = 1
		ProfilerHistoryCount = 0
	end
end

-- Enable/Disable profiler
function Profiler.SetEnabled(enabled)
	PROFILER_ENABLED = enabled
end

function Profiler.IsEnabled()
	return PROFILER_ENABLED
end

return Profiler
