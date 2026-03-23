local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")
local SoundService = game:GetService("SoundService")

local DataService = require(script.Parent.DataService)

local movementEvent = ReplicatedStorage.Remotes.MovementEvent
local rebirthEvent = ReplicatedStorage.Remotes.RebirthEvent

local PLAYTIME_GAIN = 0.3
local GAMEPASS_ID = 1760669530
local RebirthSound = SoundService:WaitForChild("RebirthSuccess")

local SPECIAL_PLAYERS = {
	VVenom999 = true,
	Ki5ugon = true,
	Mo3el = true,
	Gontoni = true,
	Zlomiczi = true,
}

-- momentum
local velocities: {[Player]: Vector3} = {}
local movingStates: {[Player]: boolean} = {}
local agnesStates: {[Player]: boolean} = {}

local ACCELERATION = 140
local FRICTION = 2.5
local VELOCITY_SMOOTH = 0.15

-- growth
local REBIRTH_MULTI = 1

-- =========================
-- GAMEPASS SYSTEM (FIXED)
-- =========================

local MAX_RETRIES = 3
local RETRY_DELAY = 1

local function ownsGamepass(player: Player): boolean
	for attempt = 1, MAX_RETRIES do
		local success, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, GAMEPASS_ID)
		end)

		if success then
			return result
		end

		task.wait(RETRY_DELAY)
	end

	return false
end

local function applyGamepass(player: Player)
	task.spawn(function()
		local owns = ownsGamepass(player)
		if player and player.Parent then
			player:SetAttribute("Has2xGamepass", owns)
		end
	end)
end

-- =========================
-- SETUP PLAYER
-- =========================

local function setupPlayer(player: Player)
	-- Agnes
	agnesStates[player] = player:GetAttribute("AgnesMorph") or false
	player:GetAttributeChangedSignal("AgnesMorph"):Connect(function()
		agnesStates[player] = player:GetAttribute("AgnesMorph") or false
	end)

	-- Gain config
	local baseGain = 1

	if SPECIAL_PLAYERS[player.Name] then
		baseGain = 100
	end

	player:SetAttribute("BaseGain", baseGain)
	player:SetAttribute("SpeedScale", 0)

	-- NEW GAMEPASS APPLY
	applyGamepass(player)
end

Players.PlayerAdded:Connect(setupPlayer)

-- Handle already in-game players (important)
for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end

-- Purchase detection (CRITICAL)
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
	if gamePassId == GAMEPASS_ID and wasPurchased then
		player:SetAttribute("Has2xGamepass", true)
	end
end)

-- passive gain
RunService.Heartbeat:Connect(function(dt)
	for _, player in pairs(Players:GetPlayers()) do
		local data = DataService:Get(player)
		if not data then continue end

		local isAgnes = agnesStates[player]
		local multiplier = if isAgnes then 2 else 1

		local rebirthMulti = (1 + data.Rebirth * REBIRTH_MULTI)
		local gamepassMulti = if player:GetAttribute("Has2xGamepass") then 2 else 1

		data.Playtime += dt
		data.MaxSpeed += PLAYTIME_GAIN * multiplier * rebirthMulti * gamepassMulti * dt

		player:SetAttribute("MaxSpeed", data.MaxSpeed)
		player.leaderstats.MaxSpeed.Value = math.floor(data.MaxSpeed)
	end
end)

-- movement state
movementEvent.OnServerEvent:Connect(function(player, isRunning)
	movingStates[player] = isRunning
end)

-- unified system
RunService.Heartbeat:Connect(function(dt)
	for _, player in pairs(Players:GetPlayers()) do
		local char = player.Character
		if not char then continue end

		local root = char:FindFirstChild("HumanoidRootPart")
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then continue end

		local data = DataService:Get(player)
		if not data then continue end

		local velocity = velocities[player] or Vector3.zero
		local moveDir = humanoid.MoveDirection
		local maxSpeed = player:GetAttribute("MaxSpeed") or 10
		local isRunning = movingStates[player]

		local isAgnes = agnesStates[player]
		local multiplier = if isAgnes then 2 else 1

		local BASE_GAIN = player:GetAttribute("BaseGain") or 1
		local SPEED_SCALE = player:GetAttribute("SpeedScale") or 0
		local gamepassMulti = if player:GetAttribute("Has2xGamepass") then 2 else 1

		if isRunning and moveDir.Magnitude > 0 then
			local target = moveDir * maxSpeed
			velocity = velocity:Lerp(target, ACCELERATION * dt / maxSpeed)
		else
			velocity *= math.exp(-FRICTION * dt)
		end

		if velocity.Magnitude > maxSpeed then
			velocity = velocity.Unit * maxSpeed
		end

		local currentVel = root.AssemblyLinearVelocity
		local newVel = Vector3.new(velocity.X, currentVel.Y, velocity.Z)
		root.AssemblyLinearVelocity = currentVel:Lerp(newVel, VELOCITY_SMOOTH)

		velocities[player] = velocity

		local realSpeed = Vector3.new(newVel.X, 0, newVel.Z).Magnitude
		player:SetAttribute("CurrentSpeed", realSpeed)

		if isRunning then
			local gain = BASE_GAIN + (realSpeed * SPEED_SCALE)
			gain *= (1 + data.Rebirth * REBIRTH_MULTI)
			gain *= multiplier
			gain *= gamepassMulti

			data.MaxSpeed += gain * dt
		end

		player:SetAttribute("MaxSpeed", data.MaxSpeed)
		player.leaderstats.MaxSpeed.Value = math.floor(data.MaxSpeed)

		humanoid.WalkSpeed = math.max(realSpeed, 0)

		if realSpeed > 1 then
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		else
			humanoid:ChangeState(Enum.HumanoidStateType.RunningNoPhysics)
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	velocities[player] = nil
	movingStates[player] = nil
	agnesStates[player] = nil
end)

-- rebirth unchanged
rebirthEvent.OnServerEvent:Connect(function(player)
	local data = DataService:Get(player)
	if not data then return end

	local requirement = 100 * (2 ^ data.Rebirth)

	if data.MaxSpeed >= requirement then
		RebirthSound:Play()
		data.Rebirth += 1
		data.MaxSpeed = 10

		player:SetAttribute("JustRebirthed", true)

		player:SetAttribute("Rebirth", data.Rebirth)
		player:SetAttribute("MaxSpeed", data.MaxSpeed)

		player.leaderstats.Rebirth.Value = data.Rebirth
		player.leaderstats.MaxSpeed.Value = data.MaxSpeed

		local character = player.Character
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.Health = 0
			end
		end
	end
end)