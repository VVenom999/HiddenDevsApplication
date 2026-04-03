-- grabbing core services once so we’re not repeatedly calling GetService every frame
-- this script runs on RenderStepped so avoiding redundant lookups matters
local players = game:GetService("Players")
local soundService = game:GetService("SoundService")
local replicatedStorage = game:GetService("ReplicatedStorage")
local runService = game:GetService("RunService")
local userInputService = game:GetService("UserInputService")

-- local player references; this entire script is client-authoritative for visuals only
-- gameplay state still comes from server via attributes / remotes
local player = players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

-- remotes are only used to notify the server about state changes,
-- server remains authoritative (movement state, boost validation, trails)
local remotes = replicatedStorage:WaitForChild("Remotes")
local boostEvent = remotes:WaitForChild("BoostEvent")
local movementEvent = remotes:WaitForChild("MovementEvent")
local trailEvent = remotes:WaitForChild("TrailEvent")

-- VFX module is shared, so I guard init to avoid reinitializing emitters/pools multiple times
-- shared.vfx acts as a global flag across client scripts
local vfx = require(replicatedStorage:WaitForChild("ForgeVFX"))
if not shared.vfx then
	vfx.init()
end

-- prebuilt model that gets welded to the player during boost
-- cloning per boost avoids state bleed between uses
local boostVfxTemplate = replicatedStorage:WaitForChild("BoostVFX")

-- animation id is used instead of name because Roblox can reuse animation instances
-- ids are stable and avoid false positives
local targetAnimationId = "rbxassetid://108555740959293"
local stepSoundName = "Step"

-- roblox injects a default "Running" sound into HumanoidRootPart
-- instead of deleting it (which can cause it to reappear), I just mute it permanently
local function removeDefaultFootsteps(character: Model)
	local root = character:WaitForChild("HumanoidRootPart")

	local function disableRunningSound()
		local running = root:FindFirstChild("Running")
		if running and running:IsA("Sound") then
			running.Volume = 0
		end
	end

	disableRunningSound()

	-- engine can re-add this sound on state changes, so I hook ChildAdded as a safeguard
	root.ChildAdded:Connect(function(child)
		if child.Name == "Running" and child:IsA("Sound") then
			child.Volume = 0
		end
	end)
end

-- I keep the base step sound in SoundService as a template
-- cloning ensures overlapping steps don’t cut each other off mid-play
local function getStepSound(): Sound?
	local sound = soundService:FindFirstChild(stepSoundName)
	if sound and sound:IsA("Sound") then
		return sound
	end
	return nil
end

local function playStepSound()
	local baseSound = getStepSound()
	if not baseSound then return end

	local s = baseSound:Clone()
	s.Parent = soundService
	s:Play()

	-- explicit cleanup so we don’t accumulate finished sound instances over time
	s.Ended:Connect(function()
		s:Destroy()
	end)
end

-- animation markers are much more reliable than timing based on speed
-- this keeps footsteps synced even if animation speed changes
local function attachMarkers(track: AnimationTrack)
	track:GetMarkerReachedSignal("Step1"):Connect(playStepSound)
	track:GetMarkerReachedSignal("Step2"):Connect(playStepSound)
end

-- filtering is necessary because AnimationPlayed fires for everything (idle, jump, etc.)
local function isTargetAnimation(track: AnimationTrack): boolean
	local anim = track.Animation
	if not anim then return false end
	return anim.AnimationId == targetAnimationId
end

-- this replaces the entire default footstep system with animation-driven audio
local function setupFootsteps(character: Model)
	removeDefaultFootsteps(character)

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	humanoid.AnimationPlayed:Connect(function(track: AnimationTrack)
		if isTargetAnimation(track) then
			attachMarkers(track)
		end
	end)
end

-- UI sounds are centralized so every button feels consistent
local hoverSound = soundService:WaitForChild("Hover")
local clickSound = soundService:WaitForChild("Click")

-- without this table, reconnecting signals on re-scan would stack listeners
-- leading to duplicated sounds per interaction
local processed = {}

local function playSound(sound)
	if sound then sound:Play() end
end

local function setupButton(button)
	if processed[button] then return end
	processed[button] = true

	button.MouseEnter:Connect(function()
		playSound(hoverSound)
	end)

	button.MouseButton1Click:Connect(function()
		playSound(clickSound)
	end)
end

-- GUI is dynamic (menus open/close), so I scan existing + future descendants
-- avoids needing manual hookup per UI
local function scanGui(gui)
	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("TextButton") or d:IsA("ImageButton") then
			setupButton(d)
		end
	end

	gui.DescendantAdded:Connect(function(d)
		if d:IsA("TextButton") or d:IsA("ImageButton") then
			setupButton(d)
		end
	end)
end

local function initGuiSounds()
	for _, gui in ipairs(playerGui:GetChildren()) do
		if gui:IsA("ScreenGui") then
			scanGui(gui)
		end
	end

	playerGui.ChildAdded:Connect(function(child)
		if child:IsA("ScreenGui") then
			scanGui(child)
		end
	end)
end

-- these values are tuned for feel, not realism
-- cooldown prevents spam, timeout prevents client hanging if server rejects
local boostCooldown = 2
local boostDuration = 3
local boostTimeout = 0.5

-- local cache so we don’t spam remotes every frame
-- also used for change detection
local lastTrail: string? = nil
local lastRunningState = nil
local displaySpeed = 0

-- attributes come from server, client just reacts to them
-- caching avoids repeated GetAttribute calls in RenderStepped
local isAgnesMorph = player:GetAttribute("AgnesMorph") or false
local currentSpeed = player:GetAttribute("CurrentSpeed") or 0
local maxSpeed = player:GetAttribute("MaxSpeed") or 0

local boostOnCooldown = false
local speedSmooth = 8 -- higher = snappier, lower = smoother lag behind

-- attribute listeners keep everything reactive instead of polling
player:GetAttributeChangedSignal("AgnesMorph"):Connect(function()
	isAgnesMorph = player:GetAttribute("AgnesMorph") or false
	lastTrail = nil -- force re-evaluation since trail set changes
end)

player:GetAttributeChangedSignal("CurrentSpeed"):Connect(function()
	currentSpeed = player:GetAttribute("CurrentSpeed") or 0
end)

player:GetAttributeChangedSignal("MaxSpeed"):Connect(function()
	maxSpeed = player:GetAttribute("MaxSpeed") or 0
end)

-- this is basically a tier system driven by max speed
-- separating AgnesMorph lets me override progression without branching elsewhere
local function getTrailByMaxSpeed(maxSpeed: number): string?
	if isAgnesMorph then
		if maxSpeed >= 10000 then return "AgnesMorph3"
		elseif maxSpeed >= 5000 then return "AgnesTrail"
		elseif maxSpeed >= 1000 then return "AgnesMorph2"
		elseif maxSpeed >= 100 then return "AgnesMorph1" end
	else
		if maxSpeed >= 100000 then return "AgnesTrail"
		elseif maxSpeed >= 50000 then return "FifthTrail"
		elseif maxSpeed >= 10000 then return "FourthTrail"
		elseif maxSpeed >= 5000 then return "ThirdTrail"
		elseif maxSpeed >= 200 then return "SecondTrail"
		elseif maxSpeed >= 30 then return "StarterTrail" end
	end
	return nil
end

-- instead of snapping FOV, I ease it so boost feels like acceleration, not a toggle
local boostFov = 0

local function applyBoostVisual(dt)
	local isBoosting = player:GetAttribute("BoostActive")
	local target = isBoosting and 20 or 0

	-- exponential smoothing
	boostFov += (target - boostFov) * math.clamp(10 * dt, 0, 1)
	return boostFov
end

-- only sends to server when the trail actually changes
-- avoids unnecessary network traffic every frame
local function applyTrail()
	if displaySpeed < 5 then
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

-- this loop is purely visual + state syncing
-- no gameplay logic here, just reacting to replicated values
runService.RenderStepped:Connect(function(dt)
	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	-- I only send movement changes when state flips, not continuously
	local isRunning = humanoid.MoveDirection.Magnitude > 0
	if isRunning ~= lastRunningState then
		lastRunningState = isRunning
		movementEvent:FireServer(isRunning)
	end

	-- smoothing prevents jitter if server updates speed unevenly
	displaySpeed += (currentSpeed - displaySpeed) * math.clamp(speedSmooth * dt, 0, 1)

	-- FOV scaling is nonlinear (power 0.9) to reduce extreme stretching at high speeds
	local boostOffset = applyBoostVisual(dt)
	local targetFov = 70 + (displaySpeed ^ 0.9) * 0.06 + boostOffset
	local maxFov = 70 + (maxSpeed ^ 0.9) * 0.06

	camera.FieldOfView = math.clamp(targetFov, 70, maxFov)

	applyTrail()
end)

-- reset state on respawn so old data doesn’t carry over
local function setupCharacter(char)
	displaySpeed = 0
	lastTrail = nil
	isAgnesMorph = player:GetAttribute("AgnesMorph") or false

	setupFootsteps(char)
	applyTrail()
end

if player.Character then
	setupCharacter(player.Character)
end

player.CharacterAdded:Connect(setupCharacter)

initGuiSounds()

-- boost input is client-triggered but server-validated
-- client waits briefly for confirmation before committing visuals
userInputService.InputBegan:Connect(function(input, gp)
	if gp or input.KeyCode ~= Enum.KeyCode.V or boostOnCooldown then return end

	boostOnCooldown = true
	boostEvent:FireServer()

	local success = false
	local connection

	connection = player:GetAttributeChangedSignal("BoostActive"):Connect(function()
		if player:GetAttribute("BoostActive") then
			success = true
		end
	end)

	-- prevents infinite yield if server denies boost
	local timeout = 0
	while not success and timeout < boostTimeout do
		timeout += task.wait()
	end

	connection:Disconnect()

	if not success then
		boostOnCooldown = false
		return
	end

	-- attach VFX to root so it follows character cleanly
	local char = player.Character
	if char then
		local root = char:FindFirstChild("HumanoidRootPart")
		if root then
			local effect = boostVfxTemplate:Clone()
			effect.Parent = char

			-- fallback in case PrimaryPart isn’t set in the model
			if not effect.PrimaryPart then
				local part = effect:FindFirstChildWhichIsA("BasePart", true)
				if part then
					effect.PrimaryPart = part
				end
			end

			if effect.PrimaryPart then
				effect:PivotTo(root.CFrame)

				-- weld instead of constantly updating CFrame every frame
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = effect.PrimaryPart
				weld.Part1 = root
				weld.Parent = effect.PrimaryPart
			end

			vfx.emit(effect)

			task.delay(boostDuration, function()
				if effect then effect:Destroy() end
			end)
		end
	end

	task.delay(boostCooldown, function()
		boostOnCooldown = false
	end)
end)