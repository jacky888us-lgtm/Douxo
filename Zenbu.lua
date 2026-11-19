--[[
	FruitFinder.lua -- Blox Fruits fruit finder (Luau, executor script)

	Features: fruit-only ESP (name, distance, first-seen time), live list menu,
	fly-to-fruit (manual per fruit, nearest, or auto), full cleanup on re-run/close.

	Everything build-dependent lives in Config below. Items marked ASSUMPTION or
	UNKNOWN were NOT verified on a real build -- use the Probe button to check them.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local CoreGui = game:GetService("CoreGui")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
	task.wait()
	LocalPlayer = Players.LocalPlayer
end

----------------------------------------------------------------------
-- Config (single place for every game-dependent value)
----------------------------------------------------------------------
local Config = {
	Fruit = {
		-- ASSUMPTION (unverified): a spawned fruit is a Tool that is a direct child
		-- of a SearchRoot, has a BasePart child "Handle", and its name contains "Fruit".
		-- Verify with the Probe button; change these four values if the Probe disagrees.
		ClassName = "Tool",
		RequiredChild = "Handle",
		NamePatterns = { "Fruit" }, -- plain-text, case-sensitive; set to nil to accept any Tool
		SearchRoots = { Workspace },

		-- DERIVED from your screenshots: map geometry is named "Meshes/bloxfruits_...",
		-- which is what polluted the old ESP. Rejected by name as a second safety net.
		RejectPrefixes = { "Meshes/" },

		HandleWaitSeconds = 5,
	},

	DespawnSeconds = nil, -- UNKNOWN: fruit lifetime on this build. nil = no countdown shown.
	StudToMeter = 0.28, -- Roblox convention (1 stud = 0.28 m)
	MaxCoord = 1e6, -- plausibility bound for any world position
	UpdateInterval = 0.2,

	Fly = {
		Speed = 150, -- UNCALIBRATED studs/s, tune in-game
		SpeedMin = 25,
		SpeedMax = 500,
		SpeedStep = 25,
		ArriveOffset = Vector3.new(0, 0, 0),
		HoldSeconds = 1.5, -- stay on the fruit this long after arrival
		RetryAfter = 30, -- auto-fly skips a fruit this long if it is still there after hold
		TimeoutPadding = 8,
		MaxDt = 0.1,
	},

	Colors = {
		Panel = Color3.fromRGB(24, 24, 32),
		Row = Color3.fromRGB(38, 38, 50),
		Button = Color3.fromRGB(52, 52, 70),
		Accent = Color3.fromRGB(190, 90, 220),
		Text = Color3.fromRGB(240, 240, 245),
		FruitName = Color3.fromRGB(255, 220, 90),
		FruitFill = Color3.fromRGB(255, 200, 60),
	},
}

----------------------------------------------------------------------
-- Pure helpers (no game access, checkable offline)
----------------------------------------------------------------------
local Util = {}

function Util.isFinite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

function Util.isPlausiblePosition(p, maxCoord)
	return Util.isFinite(p.X) and Util.isFinite(p.Y) and Util.isFinite(p.Z)
		and math.abs(p.X) <= maxCoord and math.abs(p.Y) <= maxCoord and math.abs(p.Z) <= maxCoord
end

function Util.trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Util.nameMatches(name, patterns, rejectPrefixes)
	if rejectPrefixes then
		for _, prefix in ipairs(rejectPrefixes) do
			if name:sub(1, #prefix) == prefix then
				return false
			end
		end
	end
	if patterns == nil then
		return true
	end
	for _, pattern in ipairs(patterns) do
		if string.find(name, pattern, 1, true) then
			return true
		end
	end
	return false
end

function Util.formatDistance(studs, unit, studToMeter)
	if unit == "m" then
		return string.format("%d m", math.floor(studs * studToMeter + 0.5))
	end
	return string.format("%d studs", math.floor(studs + 0.5))
end

function Util.formatAge(seconds)
	seconds = math.max(0, math.floor(seconds))
	if seconds < 60 then
		return string.format("%ds", seconds)
	elseif seconds < 3600 then
		return string.format("%dm %02ds", seconds // 60, seconds % 60)
	end
	return string.format("%dh %02dm", seconds // 3600, (seconds % 3600) // 60)
end

function Util.stepToward(current, target, speed, dt)
	local delta = target - current
	local dist = delta.Magnitude
	local step = speed * dt
	if dist <= step then
		return target, true
	end
	return current + delta.Unit * step, false
end

----------------------------------------------------------------------
-- Single instance guard + environment
----------------------------------------------------------------------
local env = (getgenv and getgenv()) or _G
if env.__FruitFinder and type(env.__FruitFinder.Cleanup) == "function" then
	pcall(env.__FruitFinder.Cleanup)
end

local function guiContainer()
	local ok, hidden = pcall(function()
		return gethui and gethui()
	end)
	if ok and typeof(hidden) == "Instance" then
		return hidden
	end
	local okCore = pcall(function()
		return CoreGui.Name
	end)
	if okCore then
		return CoreGui
	end
	return LocalPlayer:WaitForChild("PlayerGui")
end

local alive = true
local connections = {}
local function connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

local State = {
	espEnabled = true,
	autoFly = false,
	notify = true,
	unit = "studs",
	speed = Config.Fly.Speed,
	statusMsg = "siap",
}

local Tracked = {} -- [Instance] = record
local Blacklist = {} -- [Instance] = expiry (os.clock)
local Seen = setmetatable({}, { __mode = "k" }) -- notification dedupe
local RootSet = {}
local rows = {} -- [record] = { frame, label, conn }

local container = guiContainer()
local espFolder = Instance.new("Folder")
espFolder.Name = "FF_ESP"
espFolder.Parent = container

local menuGui = Instance.new("ScreenGui")
menuGui.Name = "FF_Menu"
menuGui.ResetOnSpawn = false
menuGui.DisplayOrder = 100
menuGui.Parent = container

local statusLabel, listFrame, emptyLabel
local setStatus, refreshControls, startFlight, stopFlight, trackFruit, untrack, removeRow

----------------------------------------------------------------------
-- Character / world helpers
----------------------------------------------------------------------
local function getHumanoid()
	local char = LocalPlayer.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function getRoot()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function originPosition()
	local root = getRoot()
	if root then
		return root.Position
	end
	local cam = Workspace.CurrentCamera
	return cam and cam.CFrame.Position or nil
end

local function isFruit(inst)
	if not inst:IsA(Config.Fruit.ClassName) then
		return false
	end
	return Util.nameMatches(inst.Name, Config.Fruit.NamePatterns, Config.Fruit.RejectPrefixes)
end

setStatus = function(msg)
	if msg then
		State.statusMsg = msg
	end
	if statusLabel and statusLabel.Parent then
		local count = 0
		for _ in pairs(Tracked) do
			count += 1
		end
		statusLabel.Text = string.format("%s | buah: %d | speed %d", State.statusMsg, count, State.speed)
	end
end

local function describe(rec)
	local age = os.clock() - rec.firstSeenClock
	local timeTxt
	if rec.preexisting then
		timeTxt = "sudah ada >= " .. Util.formatAge(age) .. " (spawn asli tak diketahui)"
	else
		timeTxt = "muncul " .. Util.formatAge(age) .. " lalu (" .. os.date("%H:%M:%S", rec.firstSeenWall) .. ")"
		if Config.DespawnSeconds then
			timeTxt = timeTxt .. " | sisa ~" .. Util.formatAge(math.max(0, Config.DespawnSeconds - age))
		end
	end
	return Util.formatDistance(rec.dist or 0, State.unit, Config.StudToMeter), timeTxt
end

----------------------------------------------------------------------
-- ESP
----------------------------------------------------------------------
local function buildEsp(rec)
	local bb = Instance.new("BillboardGui")
	bb.Name = "FF_Label"
	bb.Adornee = rec.handle
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = math.huge
	bb.Size = UDim2.fromOffset(270, 40)
	bb.StudsOffset = Vector3.new(0, 3, 0)
	bb.Enabled = State.espEnabled

	local nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.new(1, 0, 0.55, 0)
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 15
	nameLabel.TextColor3 = Config.Colors.FruitName
	nameLabel.TextStrokeTransparency = 0.3
	nameLabel.Text = rec.name
	nameLabel.Parent = bb

	local infoLabel = Instance.new("TextLabel")
	infoLabel.BackgroundTransparency = 1
	infoLabel.Position = UDim2.fromScale(0, 0.55)
	infoLabel.Size = UDim2.new(1, 0, 0.45, 0)
	infoLabel.Font = Enum.Font.Gotham
	infoLabel.TextSize = 11
	infoLabel.TextColor3 = Config.Colors.Text
	infoLabel.TextStrokeTransparency = 0.4
	infoLabel.Text = ""
	infoLabel.Parent = bb
	bb.Parent = espFolder

	local hl = Instance.new("Highlight")
	hl.Adornee = rec.handle
	hl.FillColor = Config.Colors.FruitFill
	hl.OutlineColor = Color3.new(1, 1, 1)
	hl.FillTransparency = 0.55
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Enabled = State.espEnabled
	hl.Parent = espFolder

	rec.esp = { bb = bb, nameLabel = nameLabel, infoLabel = infoLabel, hl = hl }
end

----------------------------------------------------------------------
-- Tracking
----------------------------------------------------------------------
local function notifyFound(rec)
	if not State.notify or Seen[rec.inst] then
		return
	end
	Seen[rec.inst] = true
	local origin = originPosition()
	local distTxt = ""
	if origin then
		distTxt = " (" .. Util.formatDistance((rec.handle.Position - origin).Magnitude, State.unit, Config.StudToMeter) .. ")"
	end
	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = "Fruit Finder",
			Text = rec.name .. distTxt,
			Duration = 5,
		})
	end)
end

trackFruit = function(inst, preexisting)
	if not alive or Tracked[inst] or not isFruit(inst) then
		return
	end
	task.spawn(function()
		local handle = inst:FindFirstChild(Config.Fruit.RequiredChild)
			or inst:WaitForChild(Config.Fruit.RequiredChild, Config.Fruit.HandleWaitSeconds)
		if not alive or Tracked[inst] or not handle or not handle:IsA("BasePart") then
			return
		end
		if not RootSet[inst.Parent] then
			return
		end
		local rec = {
			inst = inst,
			handle = handle,
			name = Util.trim(inst.Name),
			firstSeenClock = os.clock(),
			firstSeenWall = os.time(),
			preexisting = preexisting,
		}
		Tracked[inst] = rec
		buildEsp(rec)
		rec.conn = inst.AncestryChanged:Connect(function()
			if not RootSet[inst.Parent] then
				untrack(inst)
			end
		end)
		notifyFound(rec)
		setStatus()
	end)
end

untrack = function(inst)
	local rec = Tracked[inst]
	if not rec then
		return
	end
	Tracked[inst] = nil
	if rec.conn then
		rec.conn:Disconnect()
	end
	if rec.esp then
		rec.esp.bb:Destroy()
		rec.esp.hl:Destroy()
	end
	removeRow(rec)
	Blacklist[inst] = nil
	setStatus()
end

----------------------------------------------------------------------
-- Flight
----------------------------------------------------------------------
local Flight = { active = false }
local savedCollide = {}

local function setNoclip(char)
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") then
			if savedCollide[part] == nil then
				savedCollide[part] = part.CanCollide
			end
			part.CanCollide = false
		end
	end
end

local function restoreCollide()
	for part, was in pairs(savedCollide) do
		if part.Parent then
			part.CanCollide = was
		end
		savedCollide[part] = nil
	end
end

stopFlight = function(reason)
	if not Flight.active then
		return
	end
	Flight.active = false
	if Flight.conn then
		Flight.conn:Disconnect()
		Flight.conn = nil
	end
	if Flight.stepConn then
		Flight.stepConn:Disconnect()
		Flight.stepConn = nil
	end
	restoreCollide()
	local root = getRoot()
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	Flight.target = nil
	setStatus(reason or "berhenti")
end

local function noclipStep()
	local char = LocalPlayer.Character
	if char then
		setNoclip(char)
	end
end

local function flightStep(dt)
	local rec = Flight.target
	local root = getRoot()
	local hum = getHumanoid()
	if not root or not hum or hum.Health <= 0 then
		return stopFlight("karakter tidak tersedia")
	end
	if not rec or Tracked[rec.inst] ~= rec then
		if Flight.arrivedAt then
			return stopFlight("tiba, buah sudah hilang dari dunia (kemungkinan terambil)")
		end
		return stopFlight("buah hilang sebelum tiba")
	end
	local goal = rec.handle.Position + Config.Fly.ArriveOffset
	if not Util.isPlausiblePosition(goal, Config.MaxCoord) then
		return stopFlight("posisi target tidak valid")
	end
	if os.clock() > Flight.deadline then
		return stopFlight("timeout")
	end

	dt = math.min(dt, Config.Fly.MaxDt)
	local nextPos, arrived = Util.stepToward(root.Position, goal, State.speed, dt)
	root.CFrame = CFrame.new(nextPos) * root.CFrame.Rotation
	root.AssemblyLinearVelocity = Vector3.zero

	if arrived then
		Flight.arrivedAt = Flight.arrivedAt or os.clock()
		if os.clock() - Flight.arrivedAt >= Config.Fly.HoldSeconds then
			Blacklist[rec.inst] = os.clock() + Config.Fly.RetryAfter
			stopFlight("tiba, buah masih ada; auto-fly lewati " .. Config.Fly.RetryAfter .. "s")
		end
	end
end

startFlight = function(rec)
	if not alive then
		return
	end
	local root, hum = getRoot(), getHumanoid()
	if not root or not hum or hum.Health <= 0 then
		setStatus("karakter belum siap")
		return
	end
	if Tracked[rec.inst] ~= rec then
		setStatus("buah sudah tidak ada")
		return
	end
	if Flight.active then
		stopFlight("ganti target")
	end
	local dist = (rec.handle.Position - root.Position).Magnitude
	Flight.active = true
	Flight.target = rec
	Flight.arrivedAt = nil
	Flight.deadline = os.clock() + (dist / State.speed) * 2 + Config.Fly.TimeoutPadding
	Flight.stepConn = RunService.Stepped:Connect(noclipStep)
	Flight.conn = RunService.Heartbeat:Connect(flightStep)
	setStatus("terbang ke " .. rec.name)
end

local function nearestFruit(respectBlacklist)
	local origin = originPosition()
	if not origin then
		return nil
	end
	local now = os.clock()
	local best, bestDist
	for inst, rec in pairs(Tracked) do
		local pos = rec.handle.Position
		local blocked = respectBlacklist and Blacklist[inst] and Blacklist[inst] > now
		if not blocked and Util.isPlausiblePosition(pos, Config.MaxCoord) then
			local d = (pos - origin).Magnitude
			if not bestDist or d < bestDist then
				best, bestDist = rec, d
			end
		end
	end
	return best
end

----------------------------------------------------------------------
-- Menu
----------------------------------------------------------------------
local function make(class, props, parent)
	local obj = Instance.new(class)
	for k, v in pairs(props) do
		obj[k] = v
	end
	obj.Parent = parent
	return obj
end

local frame = make("Frame", {
	Name = "Panel",
	BackgroundColor3 = Config.Colors.Panel,
	BorderSizePixel = 0,
	Position = UDim2.fromOffset(10, 60),
	Size = UDim2.fromOffset(320, 320),
	ClipsDescendants = true,
}, menuGui)
make("UICorner", { CornerRadius = UDim.new(0, 10) }, frame)

local titleBar = make("Frame", {
	BackgroundColor3 = Config.Colors.Accent,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 28),
}, frame)
make("TextLabel", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(8, 0),
	Size = UDim2.new(1, -70, 1, 0),
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextColor3 = Config.Colors.Text,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "Fruit Finder",
}, titleBar)

local body = make("Frame", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(0, 28),
	Size = UDim2.new(1, 0, 1, -28),
}, frame)

local function titleButton(text, xOffset, onClick)
	local b = make("TextButton", {
		Text = text,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = Config.Colors.Text,
		BackgroundTransparency = 1,
		Position = UDim2.new(1, xOffset, 0, 0),
		Size = UDim2.fromOffset(32, 28),
	}, titleBar)
	connect(b.Activated, onClick)
	return b
end

local minimized = false
titleButton("-", -64, function()
	minimized = not minimized
	body.Visible = not minimized
	frame.Size = minimized and UDim2.fromOffset(320, 28) or UDim2.fromOffset(320, 320)
end)

local Cleanup -- forward
titleButton("X", -32, function()
	Cleanup()
end)

-- dragging (mouse and touch)
local dragging, dragStart, startPos = false, nil, nil
connect(titleBar.InputBegan, function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = frame.Position
		local c
		c = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
				c:Disconnect()
			end
		end)
	end
end)
connect(UserInputService.InputChanged, function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local d = input.Position - dragStart
		frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end)

-- controls grid
local controls = make("Frame", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(6, 4),
	Size = UDim2.new(1, -12, 0, 98),
}, body)
make("UIGridLayout", {
	CellSize = UDim2.new(1 / 3, -4, 0, 30),
	CellPadding = UDim2.fromOffset(4, 4),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, controls)

local function makeButton(text, order, onClick)
	local b = make("TextButton", {
		Text = text,
		LayoutOrder = order,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = Config.Colors.Text,
		BackgroundColor3 = Config.Colors.Button,
		BorderSizePixel = 0,
	}, controls)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
	connect(b.Activated, onClick)
	return b
end

local btnEsp = makeButton("", 1, function()
	State.espEnabled = not State.espEnabled
	refreshControls()
end)
local btnAuto = makeButton("", 2, function()
	State.autoFly = not State.autoFly
	refreshControls()
end)
local btnNotify = makeButton("", 3, function()
	State.notify = not State.notify
	refreshControls()
end)
local btnUnit = makeButton("", 4, function()
	State.unit = (State.unit == "studs") and "m" or "studs"
	refreshControls()
end)
makeButton("Speed -", 5, function()
	State.speed = math.max(Config.Fly.SpeedMin, State.speed - Config.Fly.SpeedStep)
	setStatus()
end)
makeButton("Speed +", 6, function()
	State.speed = math.min(Config.Fly.SpeedMax, State.speed + Config.Fly.SpeedStep)
	setStatus()
end)
makeButton("Stop", 7, function()
	stopFlight("dihentikan manual")
	State.autoFly = false
	refreshControls()
end)
makeButton("Terdekat", 8, function()
	local rec = nearestFruit(false)
	if rec then
		startFlight(rec)
	else
		setStatus("belum ada buah terdeteksi")
	end
end)

local function probe()
	print("[FruitFinder] StreamingEnabled =", Workspace.StreamingEnabled)
	local total, matched = 0, 0
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Tool") then
			local parent = inst.Parent
			if not (parent and parent:FindFirstChildOfClass("Humanoid")) then
				total += 1
				local ok = isFruit(inst)
				if ok then
					matched += 1
				end
				if total <= 100 then
					print(string.format("[FruitFinder] Tool %s | class=%s | matched=%s", inst:GetFullName(), inst.ClassName, tostring(ok)))
				end
			end
		end
	end
	setStatus(string.format("probe: %d Tool dunia, %d cocok (lihat console)", total, matched))
end
makeButton("Probe", 9, probe)

refreshControls = function()
	btnEsp.Text = "ESP: " .. (State.espEnabled and "ON" or "OFF")
	btnAuto.Text = "Auto-fly: " .. (State.autoFly and "ON" or "OFF")
	btnNotify.Text = "Notif: " .. (State.notify and "ON" or "OFF")
	btnUnit.Text = "Unit: " .. State.unit
end
refreshControls()

statusLabel = make("TextLabel", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(6, 106),
	Size = UDim2.new(1, -12, 0, 32),
	Font = Enum.Font.Gotham,
	TextSize = 11,
	TextColor3 = Config.Colors.Text,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	Text = "",
}, body)

listFrame = make("ScrollingFrame", {
	BackgroundColor3 = Config.Colors.Row,
	BackgroundTransparency = 0.5,
	BorderSizePixel = 0,
	Position = UDim2.fromOffset(6, 142),
	Size = UDim2.new(1, -12, 1, -148),
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 4,
}, body)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, listFrame)
make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, listFrame)

emptyLabel = make("TextLabel", {
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 30),
	Font = Enum.Font.Gotham,
	TextSize = 11,
	TextColor3 = Config.Colors.Text,
	Text = "Belum ada buah terdeteksi",
}, listFrame)

local function createRow(rec)
	local row = make("Frame", {
		BackgroundColor3 = Config.Colors.Row,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -4, 0, 36),
	}, listFrame)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
	local label = make("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 0),
		Size = UDim2.new(1, -66, 1, 0),
		Font = Enum.Font.Gotham,
		TextSize = 10,
		TextColor3 = Config.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Text = "",
	}, row)
	local flyBtn = make("TextButton", {
		Text = "Fly",
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = Config.Colors.Text,
		BackgroundColor3 = Config.Colors.Accent,
		BorderSizePixel = 0,
		Position = UDim2.new(1, -58, 0.5, -14),
		Size = UDim2.fromOffset(52, 28),
	}, row)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, flyBtn)
	local conn = flyBtn.Activated:Connect(function()
		if Tracked[rec.inst] == rec then
			startFlight(rec)
		end
	end)
	rows[rec] = { frame = row, label = label, conn = conn }
end

removeRow = function(rec)
	local row = rows[rec]
	if not row then
		return
	end
	rows[rec] = nil
	row.conn:Disconnect()
	row.frame:Destroy()
end

----------------------------------------------------------------------
-- Update loop
----------------------------------------------------------------------
local function sweep()
	for inst, rec in pairs(Tracked) do
		if not RootSet[inst.Parent] or rec.handle.Parent ~= inst then
			untrack(inst)
		end
	end
end

local function updateAll()
	local origin = originPosition()
	local count = 0
	for _, rec in pairs(Tracked) do
		local pos = rec.handle.Position
		local valid = origin ~= nil and Util.isPlausiblePosition(pos, Config.MaxCoord)
		rec.valid = valid
		rec.esp.bb.Enabled = State.espEnabled and valid
		rec.esp.hl.Enabled = State.espEnabled and valid
		if valid then
			count += 1
			rec.dist = (pos - origin).Magnitude
			local distTxt, timeTxt = describe(rec)
			rec.esp.nameLabel.Text = rec.name .. " | " .. distTxt
			rec.esp.infoLabel.Text = timeTxt
			if not rows[rec] then
				createRow(rec)
			end
			local row = rows[rec]
			row.frame.LayoutOrder = math.floor(rec.dist)
			row.label.Text = rec.name .. " | " .. distTxt .. "\n" .. timeTxt
		else
			removeRow(rec)
		end
	end
	emptyLabel.Visible = (count == 0)
end

local function autoFlyTick()
	if not State.autoFly or Flight.active then
		return
	end
	local rec = nearestFruit(true)
	if rec then
		startFlight(rec)
	end
end

local acc = 0
connect(RunService.Heartbeat, function(dt)
	acc += dt
	if acc < Config.UpdateInterval then
		return
	end
	acc = 0
	local ok, err = pcall(function()
		sweep()
		updateAll()
		autoFlyTick()
	end)
	if not ok then
		warn("[FruitFinder] update error:", err)
	end
end)

----------------------------------------------------------------------
-- Cleanup + init
----------------------------------------------------------------------
local api = {}

Cleanup = function()
	if not alive then
		return
	end
	alive = false
	stopFlight("cleanup")
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	for inst in pairs(Tracked) do
		untrack(inst)
	end
	for rec in pairs(rows) do
		removeRow(rec)
	end
	espFolder:Destroy()
	menuGui:Destroy()
	if env.__FruitFinder == api then
		env.__FruitFinder = nil
	end
end

api.Cleanup = Cleanup
env.__FruitFinder = api

for _, root in ipairs(Config.Fruit.SearchRoots) do
	RootSet[root] = true
	connect(root.ChildAdded, function(child)
		trackFruit(child, false)
	end)
	for _, child in ipairs(root:GetChildren()) do
		trackFruit(child, true)
	end
end

setStatus("siap")
print("[FruitFinder] loaded; StreamingEnabled =", Workspace.StreamingEnabled)
