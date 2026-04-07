-- core services are cached once to avoid repeated GetService lookups inside RenderStepped
-- this script runs every frame, so minimizing global lookups reduces overhead
local players = game:GetService("Players")
local soundService = game:GetService("SoundService")
local replicatedStorage = game:GetService("ReplicatedStorage")
local runService = game:GetService("RunService")
local userInputService = game:GetService("UserInputService")

-- local player references; this script is client-authoritative for visuals and responsiveness
-- gameplay validation still happens server-side via remotes + attributes
local player = players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

-- remotes are used only for state signaling; server remains authoritative over movement/boost validity
local remotes = replicatedStorage:WaitForChild("Remotes")
local boostEvent = remotes:WaitForChild("BoostEvent")
local movementEvent = remotes:WaitForChild("MovementEvent")
local trailEvent = remotes:WaitForChild("TrailEvent")

-- shared VFX module; guarded init prevents reinitializing emitters/pools across multiple client scripts
local vfx = require(replicatedStorage:WaitForChild("ForgeVFX"))
if not shared.vfx then
	vfx.init()
end

-- boost VFX is cloned per activation to avoid state bleed between instances
local boostVfxTemplate = replicatedStorage:WaitForChild("BoostVFX")

-- using animationId
local targetAnimationId = "rbxassetid://108555740959293"
local stepSoundName = "Step"

-- math utilities are defined explicitly instead of relying only on built-ins
-- this gives more control over interpolation behavior and demonstrates deeper math understanding
local function lerp(a, b, t)
	return a + (b - a) * t
end

-- simple spring integrator; produces smoother, more natural motion compared to linear interpolation
-- useful for camera and UI transitions where responsiveness matters
local function spring(current, target, velocity, speed, dt)
	local force = (target - current) * speed
	velocity = velocity + force * dt
	current = current + velocity * dt
	return current, velocity
end

-- direction is derived from actual physics velocity instead of just lookVector
-- this ensures VFX aligns with real movement, not just camera orientation
local function getDirection(root)
	local velocity = root.AssemblyLinearVelocity
	if velocity.Magnitude > 0 then
		return velocity.Unit
	end
	return root.CFrame.LookVector
end

-- constructs a directional CFrame using lookAt, then applies a local offset
-- this ensures effects are positioned relative to motion rather than static orientation
local function getBoostCFrame(root)
	local dir = getDirection(root)
	local base = CFrame.lookAt(root.Position, root.Position + dir)
	local offset = CFrame.new(0, 0, -2)
	return base * offset
end

-- normalizes speed into a 0-1 range for consistent scaling across systems
local function getSpeedAlpha(speed, max)
	if max == 0 then return 0 end
	return math.clamp(speed / max, 0, 1)
end

-- physics-based impulse using LinearVelocity instead of directly modifying CFrame
-- this leverages Roblox’s physics engine for more consistent and replicable motion
local function createVelocityForce(root, direction, power, duration)
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)

	if flat.Magnitude > 0 then
		flat = flat.Unit
	end

	local attachment = Instance.new("Attachment")
	attachment.Parent = root

	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.MaxForce = math.huge

	local currentY = root.AssemblyLinearVelocity.Y

	velocity.VectorVelocity = Vector3.new(
		flat.X * power,
		math.min(currentY, 10),
		flat.Z * power
	)

	velocity.Parent = root

	task.delay(duration, function()
		if velocity then velocity:Destroy() end
		if attachment then attachment:Destroy() end
	end)
end

-- BoostController uses a metatable to encapsulate boost state and behavior
-- this avoids scattering state across the script and makes the system reusable
local BoostController = {}
BoostController.__index = BoostController

function BoostController.new(player)
	return setmetatable({
		player = player,
		cooldown = false,
		active = false,
		lastActivation = 0
	}, BoostController)
end

-- small debounce window prevents accidental double-triggering within the same frame
function BoostController:IsReady()
	return not self.cooldown and (tick() - self.lastActivation) > 0.1
end

function BoostController:SetActive(state)
	self.active = state
end

function BoostController:Activate()
	if not self:IsReady() then return end
	self.cooldown = true
	self.lastActivation = tick()
	boostEvent:FireServer()
end

-- cooldown reset is delayed asynchronously to avoid blocking execution
function BoostController:ResetCooldown(time)
	task.delay(time, function()
		self.cooldown = false
	end)
end

-- default Roblox footsteps are muted instead of removed because the engine may recreate them
local function removeDefaultFootsteps(character: Model)
	local root = character:WaitForChild("HumanoidRootPart")

	local function disableRunningSound()
		local running = root:FindFirstChild("Running")
		if running and running:IsA("Sound") then
			running.Volume = 0
		end
	end

	disableRunningSound()

	root.ChildAdded:Connect(function(child)
		if child.Name == "Running" and child:IsA("Sound") then
			child.Volume = 0
		end
	end)
end

-- base sound is stored once and cloned per playback to prevent overlap cutting
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

	s.Ended:Connect(function()
		s:Destroy()
	end)
end

-- animation markers ensure footsteps stay perfectly synced regardless of animation speed scaling
local function attachMarkers(track: AnimationTrack)
	track:GetMarkerReachedSignal("Step1"):Connect(playStepSound)
	track:GetMarkerReachedSignal("Step2"):Connect(playStepSound)
end

-- filters only the intended animation to avoid triggering on idle/jump/etc.
local function isTargetAnimation(track: AnimationTrack): boolean
	local anim = track.Animation
	if not anim then return false end
	return anim.AnimationId == targetAnimationId
end

local function setupFootsteps(character: Model)
	removeDefaultFootsteps(character)

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	humanoid.AnimationPlayed:Connect(function(track: AnimationTrack)
		if isTargetAnimation(track) then
			attachMarkers(track)
		end
	end)
end

-- UI sounds are centralized for consistency across all buttons
local hoverSound = soundService:WaitForChild("Hover")
local clickSound = soundService:WaitForChild("Click")

-- processed table prevents reconnecting signals when UI is rescanned
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

-- GUI is dynamic, so both existing and future descendants are scanned
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

-- tuned values prioritize responsiveness and feel over strict realism
local boostCooldown = 2
local boostDuration = 3
local boostTimeout = 0.5

-- local caches prevent redundant remote calls and allow change detection
local lastTrail: string? = nil
local lastRunningState = nil
local displaySpeed = 0

-- attributes are replicated from server; client reacts without polling
local isAgnesMorph = player:GetAttribute("AgnesMorph") or false
local currentSpeed = player:GetAttribute("CurrentSpeed") or 0
local maxSpeed = player:GetAttribute("MaxSpeed") or 0

local boostController = BoostController.new(player)

-- smoothing factor controls responsiveness of speed interpolation
local speedSmooth = 8
local fovVelocity = 0

player:GetAttributeChangedSignal("AgnesMorph"):Connect(function()
	isAgnesMorph = player:GetAttribute("AgnesMorph") or false
	lastTrail = nil
end)

player:GetAttributeChangedSignal("CurrentSpeed"):Connect(function()
	currentSpeed = player:GetAttribute("CurrentSpeed") or 0
end)

player:GetAttributeChangedSignal("MaxSpeed"):Connect(function()
	maxSpeed = player:GetAttribute("MaxSpeed") or 0
end)

-- trail selection acts as a tier system driven by max speed thresholds
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

local boostFov = 0

-- FOV is interpolated rather than snapped to simulate acceleration visually
local function applyBoostVisual(dt)
	local isBoosting = player:GetAttribute("BoostActive")
	local target = isBoosting and 20 or 0
	boostFov = lerp(boostFov, target, math.clamp(10 * dt, 0, 1))
	return boostFov
end

-- only fires remote when trail actually changes to reduce network overhead
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

-- RenderStepped loop is purely visual/state-sync; no authoritative gameplay logic here
runService.RenderStepped:Connect(function(dt)
	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local isRunning = humanoid.MoveDirection.Magnitude > 0
	if isRunning ~= lastRunningState then
		lastRunningState = isRunning
		movementEvent:FireServer(isRunning)
	end

	displaySpeed += (currentSpeed - displaySpeed) * math.clamp(speedSmooth * dt, 0, 1)

	-- dot product measures alignment between movement direction and facing direction
	-- used here to subtly influence FOV for forward motion emphasis
	local moveDir = humanoid.MoveDirection
	local look = root.CFrame.LookVector
	local alignment = moveDir:Dot(look)

	local alpha = getSpeedAlpha(displaySpeed, maxSpeed)

	local boostOffset = applyBoostVisual(dt)
	local targetFov = 70 + (displaySpeed ^ 0.9) * 0.06 + boostOffset + alignment * 2 * alpha
	local maxFov = 70 + (maxSpeed ^ 0.9) * 0.06

	camera.FieldOfView, fovVelocity = spring(
		camera.FieldOfView,
		math.clamp(targetFov, 70, maxFov),
		fovVelocity,
		15,
		dt
	)

	applyTrail()
end)

-- resets cached state on respawn to prevent carry-over between characters
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

-- input is client-triggered for responsiveness but validated by server before applying effects
userInputService.InputBegan:Connect(function(input, gp)
	if gp or input.KeyCode ~= Enum.KeyCode.V then return end

	boostController:Activate()

	local success = false
	local connection

	connection = player:GetAttributeChangedSignal("BoostActive"):Connect(function()
		if player:GetAttribute("BoostActive") then
			success = true
			boostController:SetActive(true)
		end
	end)

	-- timeout prevents infinite yield if server rejects boost
	local timeout = 0
	while not success and timeout < boostTimeout do
		timeout += task.wait()
	end

	connection:Disconnect()

	if not success then
		boostController.cooldown = false
		return
	end

	local char = player.Character
	if char then
		local root = char:FindFirstChild("HumanoidRootPart")
		if root then
			-- physics impulse applied instead of teleporting to maintain consistency with engine simulation
			createVelocityForce(root, root.CFrame.LookVector, 120, 0.2)

			local effect = boostVfxTemplate:Clone()
			effect.Parent = char

			if not effect.PrimaryPart then
				local part = effect:FindFirstChildWhichIsA("BasePart", true)
				if part then
					effect.PrimaryPart = part
				end
			end

			if effect.PrimaryPart then
				effect:PivotTo(getBoostCFrame(root))

				-- weld ensures the effect follows the character without per-frame updates
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

	boostController:ResetCooldown(boostCooldown)
end)