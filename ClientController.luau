--[[
	CLIENT MOVEMENT & VISUAL SYSTEM

	This script is responsible for:
	1. Detecting player movement and syncing it to the server
	2. Dynamically adjusting camera FOV based on speed
	3. Selecting and applying speed-based trails
	4. Handling rebirth visual effects (VFX)
	5. Managing smooth transitions for speed-based visuals

	Design goals:
	- Avoid redundant server calls (state caching)
	- Keep visuals smooth (interpolation)
	- Fully client-driven visuals, server-informed state
]]

--===== Services & Core References =====--
local player = game.Players.LocalPlayer
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local camera = workspace.CurrentCamera

-- RemoteEvents used to communicate movement and visual state to the server
local movementEvent = RS:WaitForChild("Remotes"):WaitForChild("MovementEvent")
local trailEvent = RS:WaitForChild("Remotes"):WaitForChild("TrailEvent")

-- Shared storage containing trail assets (not directly used here but part of system structure)
local trailsFolder = RS:WaitForChild("Trails")


--===== Runtime State =====--

-- Stores last applied trail to prevent unnecessary server updates
local lastTrail: string? = nil

-- Smoothed speed value used for visuals (instead of raw speed, experimental still in testing)
local displaySpeed = 0

-- Cached morph state affecting trail selection logic
local isAgnesMorph = player:GetAttribute("AgnesMorph") or false

-- Controls how quickly displaySpeed interpolates toward real speed
local speedSmooth = 8


--===== Trail Selection =====--

--[[
	Determines which trail should be used based on:
	- Player's max speed
	- Whether the player is in Agnes morph state

	This function does NOT apply anything.
	It only maps speed › trail name.
]]
local function getTrailByMaxSpeed(maxSpeed: number): string?
	if isAgnesMorph then
		if maxSpeed >= 10000 then
			return "AgnesMorph3"
		elseif maxSpeed >= 5000 then
			return "AgnesTrail"
		elseif maxSpeed >= 1000 then
			return "AgnesMorph2"
		elseif maxSpeed >= 100 then
			return "AgnesMorph1"
		end
	else
		if maxSpeed >= 100000 then
			return "AgnesTrail"
		elseif maxSpeed >= 50000 then
			return "FifthTrail"
		elseif maxSpeed >= 10000 then
			return "FourthTrail"
		elseif maxSpeed >= 5000 then
			return "ThirdTrail"
		elseif maxSpeed >= 200 then
			return "SecondTrail"
		elseif maxSpeed >= 30 then
			return "StarterTrail"
		end
	end

	return nil
end


--===== Utility: Instance Scanners =====--

-- Extracts all attachments from a hierarchy (used for VFX/trail setups)
local function getAttachments(root: Instance)
	local list = {}
	for _, v in ipairs(root:GetDescendants()) do
		if v:IsA("Attachment") then
			table.insert(list, v)
		end
	end
	return list
end

-- Extracts all trail-like objects (Trail/Beam) from a hierarchy
local function getTrails(root: Instance)
	local list = {}
	for _, v in ipairs(root:GetDescendants()) do
		if v:IsA("Trail") or v:IsA("Beam") then
			table.insert(list, v)
		end
	end
	return list
end


--===== Utility: Physics Binding =====--

--[[
	Welds a visual part to the HumanoidRootPart.

	Purpose:
	- Ensures VFX parts follow the player
	- Removes physics influence (massless, no collision)
]]
local function weldToRoot(part: BasePart, root: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true

	part.CFrame = root.CFrame

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = part
	weld.Part1 = root
	weld.Parent = part
end


--===== Utility: Effect Control =====--

-- Disables all active particle and trail emitters inside a character
local function disableEffects(char: Model)
	for _, v in ipairs(char:GetDescendants()) do
		if v:IsA("ParticleEmitter") then
			v.Enabled = false
			v.Rate = 0
		elseif v:IsA("Trail") or v:IsA("Beam") then
			v.Enabled = false
		end
	end
end

--[[
	Fully removes all temporary visual objects from the character.

	Used for:
	- Resetting VFX state
	- Preventing leftover visual artifacts
]]
local function disableAndCleanup(char: Model)
	disableEffects(char)

	task.wait(0.2)

	for _, v in ipairs(char:GetDescendants()) do
		if v:IsA("Attachment") or v:IsA("Trail") or v:IsA("Beam") or v:IsA("ParticleEmitter") then
			v:Destroy()
		end

		if v:IsA("BasePart") and v.Name == "TrailPart" then
			v:Destroy()
		end
	end
end


--===== Trail Application =====--

--[[
	Applies trail based on current smoothed speed.

	Key responsibilities:
	- Prevents unnecessary server calls using lastTrail cache
	- Removes trail when speed is too low
	- Delegates trail creation to server via RemoteEvent
]]
local function applyTrail()
	local maxSpeed = player:GetAttribute("MaxSpeed") or 0
	local speed = displaySpeed

	if speed < 5 then
		if lastTrail ~= nil then
			lastTrail = nil
			trailEvent:FireServer(nil)
		end
		return
	end

	local trailName = getTrailByMaxSpeed(maxSpeed)

	if lastTrail == trailName then return end
	lastTrail = trailName

	trailEvent:FireServer(trailName)
end


--===== Attribute Reactivity =====--

-- Reacts to morph changes and forces trail recalculation
player:GetAttributeChangedSignal("AgnesMorph"):Connect(function()
	isAgnesMorph = player:GetAttribute("AgnesMorph") or false
	lastTrail = nil
	applyTrail()
end)


--===== Frame Update Loop =====--

--[[
	Runs every frame to handle:
	- Movement detection
	- Speed smoothing (interpolation)
	- Camera FOV scaling
	- Trail updates

	This is the core runtime loop of the system.
]]
RunService.RenderStepped:Connect(function(dt)
	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	-- Detect movement state and inform server
	local isRunning = humanoid.MoveDirection.Magnitude > 0
	movementEvent:FireServer(isRunning)

	-- Smooth speed transition to avoid jittery visuals
	local realSpeed = player:GetAttribute("CurrentSpeed") or 0
	local max = player:GetAttribute("MaxSpeed") or 10

	displaySpeed += (realSpeed - displaySpeed) * math.clamp(speedSmooth * dt, 0, 1)

	-- Dynamically scale camera FOV based on speed
	local targetFov = 70 + (displaySpeed ^ 0.9) * 0.06
	local maxFov = 70 + (max ^ 0.9) * 0.06

	camera.FieldOfView = math.clamp(targetFov, 70, maxFov)

	-- Update trail after speed changes
	applyTrail()
end)


--===== Character Initialization =====--

--[[
	Runs whenever the character spawns.

	Handles:
	- Rebirth VFX spawning and cleanup
	- Resetting runtime state
	- Reinitializing trail logic
]]
player.CharacterAdded:Connect(function()
	task.wait(0.3)

	local char = player.Character or player.CharacterAdded:Wait()
	local root = char:WaitForChild("HumanoidRootPart")

	task.spawn(function()
		if player:GetAttribute("JustRebirthed") == true then

			local vfxSource = RS:FindFirstChild("RebirthVFX")
			if not vfxSource then
				return
			end

			local clone = vfxSource:Clone()
			clone.Parent = char

			if clone:IsA("BasePart") then
				weldToRoot(clone, root)
			end

			for _, obj in ipairs(clone:GetDescendants()) do
				if obj:IsA("BasePart") then
					weldToRoot(obj, root)
				end
			end

			for _, obj in ipairs(clone:GetDescendants()) do
				if obj:IsA("ParticleEmitter") then
					obj.Enabled = true

					local emitCount = obj:GetAttribute("EmitCount")
					if emitCount and emitCount > 0 then
						obj:Emit(emitCount)
					end
				end
			end

			task.delay(3, function()
				if clone then
					clone:Destroy()
				end
			end)

			task.wait(0.5)
			player:SetAttribute("JustRebirthed", false)
		end
	end)

	displaySpeed = 0
	lastTrail = nil
	isAgnesMorph = player:GetAttribute("AgnesMorph") or false

	applyTrail()
end)