local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local RS               = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local Camera           = workspace.CurrentCamera
local localPlayer      = Players.LocalPlayer

if _G.AXIOM_CLEANUP then pcall(_G.AXIOM_CLEANUP) end

local oldGui = (game:GetService("CoreGui"):FindFirstChild("AxiomGUI"))
    or (localPlayer:FindFirstChild("PlayerGui") and localPlayer.PlayerGui:FindFirstChild("AxiomGUI"))
if oldGui then oldGui:Destroy() end

_G.AXIOM_ROLE_CACHE   = {}
_G.AXIOM_PLAYER_LINES = {}
_G.AXIOM_GUN_LINES    = {}

local STATE = {
    esp       = true,
    grab      = true,
    aimbot    = true,
    silentaim = false,
}

local connections  = {}
local renderConn   = nil
local grabConn     = nil
local IS_MOBILE    = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local aimbotActive = false

local Gameplay             = RS:FindFirstChild("Remotes") and RS.Remotes:FindFirstChild("Gameplay")
local GetCurrentPlayerData = Gameplay and Gameplay:FindFirstChild("GetCurrentPlayerData")

local ROLE_COLOR = {
    Murderer = Color3.fromRGB(255, 0,   50),
    Sheriff  = Color3.fromRGB(0,   170, 255),
    Hero     = Color3.fromRGB(255, 215, 0),
    Innocent = Color3.fromRGB(200, 200, 200),
    Dead     = Color3.fromRGB(80,  80,  80),
    Unknown  = Color3.fromRGB(150, 150, 150),
    GunDrop  = Color3.fromRGB(0,   255, 120),
}

local TRACER = {
    Murderer = { Thickness = 4.0, Transparency = 1.0 },
    Sheriff  = { Thickness = 3.5, Transparency = 1.0 },
    Hero     = { Thickness = 3.5, Transparency = 1.0 },
    GunDrop  = { Thickness = 4.0, Transparency = 1.0 },
    Default  = { Thickness = 1.2, Transparency = 0.4 },
}

local AIM = {
    AimBone           = "HumanoidRootPart",
    FOVRadius         = 300,
    MaxDistance       = 1200,
    WallCheck         = false,
    AimKey            = Enum.UserInputType.MouseButton2,
    FallbackToNearest = true,
}

local fovCircle     = Drawing.new("Circle")
fovCircle.Radius    = AIM.FOVRadius
fovCircle.Color     = Color3.fromRGB(255, 60, 60)
fovCircle.Thickness = 1.2
fovCircle.Filled    = false
fovCircle.Visible   = false

-- ─── role helpers ──────────────────────────────────────────────────────────────

local function resolveRole(name)
    local e = _G.AXIOM_ROLE_CACHE[name]
    if not e then return "Unknown" end
    if e.Dead or e.Killed then return "Dead" end
    return e.Role or "Unknown"
end

local function pollRoles()
    if not GetCurrentPlayerData then return end
    local ok, data = pcall(function() return GetCurrentPlayerData:InvokeServer() end)
    if ok and type(data) == "table" then _G.AXIOM_ROLE_CACHE = data end
end

local function cacheHasData()
    if not _G.AXIOM_ROLE_CACHE then return false end
    for _ in pairs(_G.AXIOM_ROLE_CACHE) do return true end
    return false
end

local function isMurderer(player)
    if not cacheHasData() then return false end
    local e = _G.AXIOM_ROLE_CACHE[player.Name]
    if not e or e.Dead or e.Killed then return false end
    return e.Role == "Murderer"
end

local function isAlive(player)
    local char = player.Character
    if not char then return false end
    local h = char:FindFirstChildOfClass("Humanoid")
    return h and h.Health > 0
end

-- ─── ESP ───────────────────────────────────────────────────────────────────────

local function buildHighlight(inst, color, name)
    local ex = inst:FindFirstChild(name)
    if ex then ex:Destroy() end
    local hl               = Instance.new("Highlight")
    hl.Name                = name
    hl.FillTransparency    = 0.4
    hl.OutlineTransparency = 0
    hl.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
    hl.FillColor           = color
    hl.OutlineColor        = Color3.new(1, 1, 1)
    hl.Parent              = inst
end

local function destroyESP()
    for _, p in ipairs(Players:GetPlayers()) do
        local c = p.Character
        if c then
            local h = c:FindFirstChild("AXIOM_ESP_HL")
            if h then h:Destroy() end
        end
    end
    for p, l in pairs(_G.AXIOM_PLAYER_LINES) do
        pcall(function() l:Remove() end)
        _G.AXIOM_PLAYER_LINES[p] = nil
    end
    for g, l in pairs(_G.AXIOM_GUN_LINES) do
        if g and g:FindFirstChild("AXIOM_GUN_HL") then g.AXIOM_GUN_HL:Destroy() end
        pcall(function() l:Remove() end)
        _G.AXIOM_GUN_LINES[g] = nil
    end
end

local function setupPlayerESP(player)
    if player == localPlayer then return end
    local char = player.Character
    if not char then return end
    buildHighlight(char, ROLE_COLOR[resolveRole(player.Name)] or ROLE_COLOR.Unknown, "AXIOM_ESP_HL")
end

local function setupGunESP(part)
    if not part or not part:IsA("BasePart") then return end
    buildHighlight(part, ROLE_COLOR.GunDrop, "AXIOM_GUN_HL")
    if not _G.AXIOM_GUN_LINES[part] then
        local l        = Drawing.new("Line")
        l.Thickness    = TRACER.GunDrop.Thickness
        l.Transparency = TRACER.GunDrop.Transparency
        l.Color        = ROLE_COLOR.GunDrop
        _G.AXIOM_GUN_LINES[part] = l
    end
end

local function scanGuns()
    for _, i in ipairs(workspace:GetDescendants()) do
        if i.Name == "GunDrop" then setupGunESP(i) end
    end
end

local function buildAllESP()
    for _, p in ipairs(Players:GetPlayers()) do setupPlayerESP(p) end
end

-- ─── aimbot target ─────────────────────────────────────────────────────────────

local function screenCenter()
    local v = Camera.ViewportSize
    return Vector2.new(v.X / 2, v.Y / 2)
end

local function toScreen(pos)
    local sp, on = Camera:WorldToViewportPoint(pos)
    return Vector2.new(sp.X, sp.Y), on, sp.Z
end

local function predictedPos(char)
    local bone = char:FindFirstChild(AIM.AimBone)
    if not bone then return nil end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local vel = hrp and hrp.AssemblyLinearVelocity or Vector3.zero
    return bone.Position + vel * 0.04
end

local function getBestTarget()
    local center = screenCenter()
    local lc     = localPlayer.Character
    local lhrp   = lc and lc:FindFirstChild("HumanoidRootPart")
    if not lhrp then return nil end

    local mTarget, mDist = nil, AIM.FOVRadius
    local fTarget, fDist = nil, AIM.FOVRadius

    for _, p in ipairs(Players:GetPlayers()) do
        if p == localPlayer or not isAlive(p) then continue end
        local char = p.Character
        if not char then continue end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp then continue end
        if (hrp.Position - lhrp.Position).Magnitude > AIM.MaxDistance then continue end
        local pred = predictedPos(char)
        if not pred then continue end
        local sp, on, depth = toScreen(pred)
        if not on or depth <= 0 then continue end
        local fd = (sp - center).Magnitude
        if isMurderer(p) and fd < mDist then mDist = fd; mTarget = p end
        if AIM.FallbackToNearest and fd < fDist then fDist = fd; fTarget = p end
    end

    if mTarget then return mTarget end
    if AIM.FallbackToNearest and not cacheHasData() then return fTarget end
    return nil
end

local function fireAimbot()
    if not STATE.aimbot then return end
    local t = getBestTarget()
    if not t then return end
    local char = t.Character
    if not char then return end
    local pred = predictedPos(char)
    if pred then Camera.CFrame = CFrame.new(Camera.CFrame.Position, pred) end
end

-- ─── silent aim — intercept-first, identify-on-fire ───────────────────────────

local hookInstalled = false

local function hookSilentAim()
    if hookInstalled then return end
    hookInstalled = true

    local mt = getrawmetatable(game)
    setreadonly(mt, false)

    local originalNamecall = mt.__namecall
    mt.__namecall = newcclosure(function(self, ...)
        if getnamecallmethod() == "FireServer"
            and self.Name == "Shoot"
            and STATE.silentaim
        then
            local args   = { ... }
            local target = getBestTarget()
            if target then
                local char = target.Character
                local hrp  = char and char:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local vel       = hrp.AssemblyLinearVelocity
                    local predicted = hrp.Position + vel * 0.04
                    args[2]         = CFrame.new(predicted)
                end
            end
            return originalNamecall(self, table.unpack(args))
        end
        return originalNamecall(self, ...)
    end)

    setreadonly(mt, true)
end

hookSilentAim()

-- ─── render ────────────────────────────────────────────────────────────────────

local function startRender()
    if renderConn then renderConn:Disconnect() end
    local pollTimer = 0

    renderConn = RunService.RenderStepped:Connect(function(dt)
        local vp     = Camera.ViewportSize
        local cx, cy = vp.X / 2, vp.Y

        if STATE.esp then
            pollTimer = pollTimer + dt
            if pollTimer >= 2 then pollTimer = 0; task.spawn(pollRoles) end

            for _, p in ipairs(Players:GetPlayers()) do
                if p == localPlayer then continue end
                local char = p.Character
                if not char then
                    local l = _G.AXIOM_PLAYER_LINES[p]
                    if l then l.Visible = false end
                    continue
                end
                local hrp = char:FindFirstChild("HumanoidRootPart")
                if not hrp then continue end

                local role  = resolveRole(p.Name)
                local color = ROLE_COLOR[role] or ROLE_COLOR.Unknown
                local ts    = TRACER[role] or TRACER.Default

                local hl = char:FindFirstChild("AXIOM_ESP_HL")
                if hl then hl.FillColor = color else buildHighlight(char, color, "AXIOM_ESP_HL") end

                if not _G.AXIOM_PLAYER_LINES[p] then _G.AXIOM_PLAYER_LINES[p] = Drawing.new("Line") end
                local l = _G.AXIOM_PLAYER_LINES[p]
                local sp, on = Camera:WorldToViewportPoint(hrp.Position)
                if on then
                    l.From = Vector2.new(cx, cy); l.To = Vector2.new(sp.X, sp.Y)
                    l.Color = color; l.Thickness = ts.Thickness; l.Transparency = ts.Transparency
                    l.Visible = true
                else
                    l.Visible = false
                end
            end

            for g, l in pairs(_G.AXIOM_GUN_LINES) do
                if not g or not g.Parent then
                    pcall(function() l:Remove() end); _G.AXIOM_GUN_LINES[g] = nil; continue
                end
                local sp, on = Camera:WorldToViewportPoint(g.Position)
                if on then
                    l.From = Vector2.new(cx, cy); l.To = Vector2.new(sp.X, sp.Y)
                    l.Thickness = TRACER.GunDrop.Thickness; l.Transparency = TRACER.GunDrop.Transparency
                    l.Visible = true
                else
                    l.Visible = false
                end
            end

            for p, l in pairs(_G.AXIOM_PLAYER_LINES) do
                if not p.Parent then pcall(function() l:Remove() end); _G.AXIOM_PLAYER_LINES[p] = nil end
            end
        end

        fovCircle.Position = screenCenter()
        fovCircle.Visible  = STATE.aimbot

        if not IS_MOBILE and STATE.aimbot and UserInputService:IsMouseButtonPressed(AIM.AimKey) then
            fireAimbot()
        end
        if IS_MOBILE and STATE.aimbot and aimbotActive then
            fireAimbot()
        end
    end)
end

local function startGrab()
    if grabConn then grabConn:Disconnect() end
    local elapsed = 0
    grabConn = RunService.Heartbeat:Connect(function(dt)
        if not STATE.grab then return end
        elapsed = elapsed + dt
        if elapsed < 0.1 then return end
        elapsed = 0
        task.spawn(function()
            local char = localPlayer.Character
            if not char then return end
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if not hrp then return end
            for _, o in ipairs(workspace:GetDescendants()) do
                if o:IsA("TouchTransmitter") and o.Parent and o.Parent.Name == "GunDrop" then
                    firetouchinterest(hrp, o.Parent, 0)
                    task.wait(0.05)
                    firetouchinterest(hrp, o.Parent, 1)
                    return
                end
            end
        end)
    end)
end

local function hookPlayer(p)
    local c = p.CharacterAdded:Connect(function()
        if not STATE.esp then return end
        task.wait(0.15); setupPlayerESP(p)
    end)
    table.insert(connections, c)
end

for _, p in ipairs(Players:GetPlayers()) do hookPlayer(p) end
table.insert(connections, Players.PlayerAdded:Connect(function(p) hookPlayer(p) end))
table.insert(connections, workspace.DescendantAdded:Connect(function(i)
    if i.Name == "GunDrop" then task.wait(0.1); setupGunESP(i) end
end))

_G.AXIOM_CLEANUP = function()
    if renderConn then renderConn:Disconnect() end
    if grabConn   then grabConn:Disconnect()   end
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    table.clear(connections)
    destroyESP()
    fovCircle.Visible = false
    pcall(function() fovCircle:Remove() end)
end

startRender()
startGrab()
task.spawn(function() pollRoles(); buildAllESP(); scanGuns() end)

-- ─── GUI ───────────────────────────────────────────────────────────────────────

local gui = Instance.new("ScreenGui")
gui.Name            = "AxiomGUI"
gui.ResetOnSpawn    = false
gui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
gui.Parent = (RunService:IsStudio() and localPlayer:WaitForChild("PlayerGui")) or game:GetService("CoreGui")

local ACCENT   = Color3.fromRGB(255, 30,  60)
local BG_DARK  = Color3.fromRGB(10,  10,  14)
local BG_PANEL = Color3.fromRGB(22,  22,  30)
local BORDER   = Color3.fromRGB(40,  40,  55)
local TEXT_HI  = Color3.fromRGB(240, 240, 245)
local TEXT_LO  = Color3.fromRGB(110, 110, 130)
local GREEN    = Color3.fromRGB(0,   210, 100)

local function corner(r, p) local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); c.Parent = p end
local function stroke(t, c, p) local s = Instance.new("UIStroke"); s.Thickness = t; s.Color = c; s.Parent = p end

local main = Instance.new("Frame")
main.Size             = UDim2.new(0, 240, 0, 450)
main.Position         = UDim2.new(0, 40, 0, 40)
main.BackgroundColor3 = BG_DARK
main.BorderSizePixel  = 0
main.Active           = true
main.Parent           = gui
corner(10, main)
stroke(1, BORDER, main)

local accent_bar = Instance.new("Frame")
accent_bar.Size             = UDim2.new(1, 0, 0, 3)
accent_bar.BackgroundColor3 = ACCENT
accent_bar.BorderSizePixel  = 0
accent_bar.Parent           = main
corner(2, accent_bar)

local topbar = Instance.new("Frame")
topbar.Size                   = UDim2.new(1, 0, 0, 40)
topbar.Position               = UDim2.new(0, 0, 0, 3)
topbar.BackgroundTransparency = 1
topbar.Parent                 = main

local title_lbl = Instance.new("TextLabel")
title_lbl.Text                   = "AXIOM"
title_lbl.TextSize               = 15
title_lbl.Font                   = Enum.Font.GothamBold
title_lbl.TextColor3             = TEXT_HI
title_lbl.TextXAlignment         = Enum.TextXAlignment.Left
title_lbl.BackgroundTransparency = 1
title_lbl.Size                   = UDim2.new(1, -60, 1, 0)
title_lbl.Position               = UDim2.new(0, 16, 0, 0)
title_lbl.Parent                 = topbar

local sub_lbl = Instance.new("TextLabel")
sub_lbl.Text                   = "MM2"
sub_lbl.TextSize               = 11
sub_lbl.Font                   = Enum.Font.Gotham
sub_lbl.TextColor3             = ACCENT
sub_lbl.TextXAlignment         = Enum.TextXAlignment.Left
sub_lbl.BackgroundTransparency = 1
sub_lbl.Size                   = UDim2.new(1, 0, 0, 12)
sub_lbl.Position               = UDim2.new(0, 16, 0, 24)
sub_lbl.Parent                 = main

local minimize_btn = Instance.new("TextButton")
minimize_btn.Size              = UDim2.new(0, 28, 0, 20)
minimize_btn.Position          = UDim2.new(1, -44, 0, 10)
minimize_btn.BackgroundColor3  = BG_PANEL
minimize_btn.Text              = "—"
minimize_btn.TextColor3        = TEXT_LO
minimize_btn.TextSize          = 12
minimize_btn.Font              = Enum.Font.GothamBold
minimize_btn.BorderSizePixel   = 0
minimize_btn.Parent            = topbar
corner(4, minimize_btn)

local divider = Instance.new("Frame")
divider.Size             = UDim2.new(1, -32, 0, 1)
divider.Position         = UDim2.new(0, 16, 0, 50)
divider.BackgroundColor3 = BORDER
divider.BorderSizePixel  = 0
divider.Parent           = main

local content = Instance.new("Frame")
content.Size                   = UDim2.new(1, 0, 1, -60)
content.Position               = UDim2.new(0, 0, 0, 58)
content.BackgroundTransparency = 1
content.Parent                 = main

local list = Instance.new("UIListLayout")
list.Padding = UDim.new(0, 6)
list.Parent  = content

local pad = Instance.new("UIPadding")
pad.PaddingLeft  = UDim.new(0, 14)
pad.PaddingRight = UDim.new(0, 14)
pad.Parent       = content

local function makeToggle(labelTxt, descTxt, key, onToggle)
    local row = Instance.new("Frame")
    row.Size             = UDim2.new(1, 0, 0, 54)
    row.BackgroundColor3 = BG_PANEL
    row.BorderSizePixel  = 0
    row.Parent           = content
    corner(8, row)
    stroke(1, BORDER, row)

    local lbl = Instance.new("TextLabel")
    lbl.Text                   = labelTxt
    lbl.TextSize               = 13
    lbl.Font                   = Enum.Font.GothamBold
    lbl.TextColor3             = TEXT_HI
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.BackgroundTransparency = 1
    lbl.Size                   = UDim2.new(1, -64, 0, 18)
    lbl.Position               = UDim2.new(0, 12, 0, 8)
    lbl.Parent                 = row

    local desc = Instance.new("TextLabel")
    desc.Text                   = descTxt
    desc.TextSize               = 10
    desc.Font                   = Enum.Font.Gotham
    desc.TextColor3             = TEXT_LO
    desc.TextXAlignment         = Enum.TextXAlignment.Left
    desc.BackgroundTransparency = 1
    desc.Size                   = UDim2.new(1, -64, 0, 14)
    desc.Position               = UDim2.new(0, 12, 0, 28)
    desc.Parent                 = row

    local pill = Instance.new("Frame")
    pill.Size            = UDim2.new(0, 42, 0, 22)
    pill.Position        = UDim2.new(1, -54, 0.5, -11)
    pill.BorderSizePixel = 0
    pill.Parent          = row
    corner(11, pill)

    local knob = Instance.new("Frame")
    knob.Size             = UDim2.new(0, 16, 0, 16)
    knob.Position         = UDim2.new(0, 3, 0.5, -8)
    knob.BorderSizePixel  = 0
    knob.BackgroundColor3 = Color3.new(1, 1, 1)
    knob.Parent           = pill
    corner(8, knob)

    local function refresh(anim)
        local on          = STATE[key]
        local targetColor = on and GREEN or Color3.fromRGB(50, 50, 65)
        local targetPos   = on and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
        if anim then
            TweenService:Create(pill, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {BackgroundColor3 = targetColor}):Play()
            TweenService:Create(knob, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {Position = targetPos}):Play()
        else
            pill.BackgroundColor3 = targetColor
            knob.Position         = targetPos
        end
    end

    refresh(false)

    local btn = Instance.new("TextButton")
    btn.Size                   = UDim2.new(1, 0, 1, 0)
    btn.BackgroundTransparency = 1
    btn.Text                   = ""
    btn.Parent                 = row

    btn.MouseButton1Click:Connect(function()
        STATE[key] = not STATE[key]
        refresh(true)
        if onToggle then onToggle(STATE[key]) end
    end)

    return row
end

makeToggle("Role ESP",    "Highlights + tracers by role",           "esp", function(on)
    if not on then destroyESP() else task.spawn(function() pollRoles(); buildAllESP(); scanGuns() end) end
end)
makeToggle("Auto Grab",   "Instant gun pickup on spawn",            "grab", function() end)
makeToggle("Aimbot",      "Murderer-lock · hold AIM to snap",       "aimbot", function(on)
    fovCircle.Visible = on
    if not on then aimbotActive = false end
end)
makeToggle("Silent Aim",  "Redirects shot to murderer server-side", "silentaim", function() end)

-- ─── mobile aim button ─────────────────────────────────────────────────────────

local aimHoldBtn = Instance.new("TextButton")
aimHoldBtn.Size              = UDim2.new(1, -28, 0, 52)
aimHoldBtn.BackgroundColor3  = Color3.fromRGB(200, 20, 50)
aimHoldBtn.TextColor3        = Color3.new(1, 1, 1)
aimHoldBtn.Text              = "🎯  HOLD TO AIM"
aimHoldBtn.TextSize          = 14
aimHoldBtn.Font              = Enum.Font.GothamBold
aimHoldBtn.BorderSizePixel   = 0
aimHoldBtn.AutoButtonColor   = false
aimHoldBtn.Visible           = IS_MOBILE
aimHoldBtn.Parent            = content
corner(10, aimHoldBtn)
stroke(1, Color3.fromRGB(255, 60, 80), aimHoldBtn)

aimHoldBtn.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch then
        if not STATE.aimbot then return end
        aimbotActive = true
        TweenService:Create(aimHoldBtn, TweenInfo.new(0.1), {BackgroundColor3 = Color3.fromRGB(255, 50, 80)}):Play()
    end
end)

aimHoldBtn.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch then
        aimbotActive = false
        TweenService:Create(aimHoldBtn, TweenInfo.new(0.1), {BackgroundColor3 = Color3.fromRGB(200, 20, 50)}):Play()
    end
end)

-- ─── drag ──────────────────────────────────────────────────────────────────────

local drag      = false
local dragStart, startPos

topbar.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1
    or i.UserInputType == Enum.UserInputType.Touch then
        drag = true; dragStart = i.Position; startPos = main.Position
    end
end)

UserInputService.InputChanged:Connect(function(i)
    if drag and (i.UserInputType == Enum.UserInputType.MouseMovement
              or i.UserInputType == Enum.UserInputType.Touch) then
        local delta = i.Position - dragStart
        main.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end
end)

UserInputService.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1
    or i.UserInputType == Enum.UserInputType.Touch then
        drag = false
    end
end)

-- ─── minimize ──────────────────────────────────────────────────────────────────

local minimized  = false
local fullHeight = IS_MOBILE and 450 or 380

minimize_btn.MouseButton1Click:Connect(function()
    minimized = not minimized
    TweenService:Create(main, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
        Size = minimized and UDim2.new(0, 240, 0, 46) or UDim2.new(0, 240, 0, fullHeight)
    }):Play()
    content.Visible   = not minimized
    divider.Visible   = not minimized
    sub_lbl.Visible   = not minimized
    minimize_btn.Text = minimized and "+" or "—"
end)
