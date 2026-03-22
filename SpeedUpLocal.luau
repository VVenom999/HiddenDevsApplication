--[[
	Some additional notes from me
	- the leaderstats playtime is in minutes
	- the maxspeed stat is bound to gui 
	- the maxspeed is increasing rapidly to let yall test the actual game and the reset data button is for the same purpose
	- Animation was made by my friend Kisugon
	- Please dont mind the UI i am not a UI designer :(
	
	- Have a great day :)
	-- VVenom
	]]

--[[ Services ]]
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[[ Player References ]]
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")

--[[ GUI References ]]
local playerGui = player:WaitForChild("PlayerGui")
local gui = playerGui:WaitForChild("SpeedGUI")

local currentSpeedLabel = gui:WaitForChild("CurrentSpeedLabel")
local maxSpeedLabel = gui:WaitForChild("MaxSpeedLabel")

--[[ Speed Settings ]]
local baseSpeed = 16
local momentumStart = 32

local acceleration = 0.5
local deceleration = 0.2

--[[ Camera Settings ]]
local baseFov = 70
local fovPerSpeed = 0.1

--[[ Speed State ]]
local maxSpeed = baseSpeed
local currentSpeed = baseSpeed
local wasMoving = false

humanoid.WalkSpeed = baseSpeed

--[[ Trail System ]]
local activeTrail = nil
local trailFolder = ReplicatedStorage:FindFirstChild("Trails")
local trailsEnabled = trailFolder ~= nil

--[[ Trail Tiers ]]
local trailTiers = {
	{min = 1, max = 100, name = "LightningBlue"},
	{min = 100, max = 200, name = "LightningYellow"},
	{min = 300, max = 400, name = "LightningOrange"},
	{min = 500, max = math.huge, name = "LightningPurple"}
}

--[[ Momentum System ]]
local function applyMomentum()

	local moving = humanoid.MoveDirection.Magnitude > 0

	-- reset speed when starting to move
	if moving and not wasMoving then
		currentSpeed = baseSpeed
	end

	-- determine momentum strength based on current speed
	local momentumFactor = math.clamp((currentSpeed - momentumStart) / (maxSpeed - momentumStart), 0, 1)

	local dynamicAcceleration = acceleration * (1 + momentumFactor)
	local dynamicDeceleration = deceleration * (1 + momentumFactor)

	if moving then
		if currentSpeed < maxSpeed then
			currentSpeed += dynamicAcceleration
		end
	else
		if currentSpeed > baseSpeed then
			currentSpeed -= dynamicDeceleration
		end
	end

	-- clamp speed
	if currentSpeed > maxSpeed then
		currentSpeed = maxSpeed
	end

	if currentSpeed < baseSpeed then
		currentSpeed = baseSpeed
	end

	humanoid.WalkSpeed = currentSpeed
	wasMoving = moving

end

--[[ GUI Update ]]
local function updateGUI()

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local velocity = root.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X,0,velocity.Z).Magnitude

	currentSpeedLabel.Text = "Speed: "..math.floor(speed)
	maxSpeedLabel.Text = "Max Speed: "..math.floor(maxSpeed)

end

--[[ Camera Speed Effect ]]
local function updateCamera()

	local targetFov = baseFov + (currentSpeed * fovPerSpeed)

	camera.FieldOfView += (targetFov - camera.FieldOfView) * 0.1

end

--[[ Trail Tier Detection ]]
local function getTrailTier()

	for _,tier in pairs(trailTiers) do
		if currentSpeed >= tier.min and currentSpeed < tier.max then
			return tier.name
		end
	end

end

--[[ Remove Active Trail ]]
local function removeCurrentTrail()

	if activeTrail then
		activeTrail:Destroy()
		activeTrail = nil
	end

end

--[[ Apply Trail ]]
local function applyTrail()

	if not trailsEnabled then return end

	local tierName = getTrailTier()
	if not tierName then return end

	if activeTrail and activeTrail.Name == tierName then
		return
	end

	removeCurrentTrail()

	local template = trailFolder:FindFirstChild(tierName)
	if not template then return end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local newTrail = template:Clone()

	local attachment0 = Instance.new("Attachment")
	local attachment1 = Instance.new("Attachment")

	attachment0.Position = Vector3.new(0,0.5,0)
	attachment1.Position = Vector3.new(0,-0.5,0)

	attachment0.Parent = root
	attachment1.Parent = root

	newTrail.Attachment0 = attachment0
	newTrail.Attachment1 = attachment1
	newTrail.Parent = root

	activeTrail = newTrail

end

--[[ Main Speed System ]]
local function updateSpeedSystem()

	maxSpeed = player:GetAttribute("MaxSpeed") or baseSpeed

	applyMomentum()
	updateCamera()
	updateGUI()
	applyTrail()

end

--[[ Frame Update ]]
RunService.RenderStepped:Connect(function()

	updateSpeedSystem()

end)

--[[ Character Respawn ]]
player.CharacterAdded:Connect(function(newChar)

	character = newChar
	humanoid = character:WaitForChild("Humanoid")

	currentSpeed = baseSpeed
	humanoid.WalkSpeed = baseSpeed

end)