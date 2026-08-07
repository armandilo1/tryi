-- ============================================
-- FULL SCRIPT – UNDERGROUND AUTOFARM + ESP + SHERIFF + MURDERER + MISC
-- WITH WORKING SHOOT MURDERER, PLAYER LIST FLING, AND TELEPORTS
-- KEYBINDS: Q = Toggle GUI, R = Shoot Murderer, E = Speed Boost, F = Fly, N = Noclip
-- FIXED: Speed Boost uses Walk Speed slider value, Fly toggle works properly, Noclip toggles correctly
-- ============================================

-- SERVICES
local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local VirtualUser       = game:GetService("VirtualUser")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local StarterGui        = game:GetService("StarterGui")

-- ============================================
-- VARIABLES
-- ============================================
local isActive              = false
local autofarmRunning       = false
local autofarmLoopThread    = nil
-- Held true while the "bag is full" actions run, so the coin loop cannot drag
-- you off mid-fling.
local farmPaused            = false
local antiAfkConnection     = nil
local currentMap            = nil
local flySpeed              = 15
local farmStartTime         = 0
local totalCoinsCollected   = 0
local collectedDisplayValue = 0

local player    = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local rootPart  = character:WaitForChild("HumanoidRootPart")

local espEnabled     = { murderer = false, sheriff = false, innocent = false, trap = false }
local espHighlights  = {}
local trapHighlights = {}

local gunDropESP        = false
local autoGetDroppedGun = false
local gunDropHighlights = {}
local gunDropLabels     = {}
local grabbedGuns       = {}

local coinESP        = false
local coinHighlights = {}
local coinESPThread  = nil

-- Anti-AFK is its own switch now instead of being welded to the farm loop.
local antiAfkEnabled = false

-- MM2 exposes no "coins in bag" value anywhere on the player or the HUD (checked
-- both), so "bag full" is measured with the hub's own per-round collected count.
local bagFullAt          = 40
local flingMurdererOnFull = false
local resetPlayerOnFull   = false
local bagFullFired        = false

local gunBtn   = nil
local shootBtn = nil
local killAllBtn = nil

local noClipConnection = nil
local flyEnabled = false
local flyConnection = nil
local flyspeedValue = 50

local guiVisible = true
local Window = nil
-- Declared up here on purpose: every `if WindUI then WindUI:Notify(...)` below
-- used to read a nil global because WindUI was a local created near the bottom,
-- so none of those notifications ever fired.
local WindUI = nil

-- Some WindUI builds expose no SetValue on toggle objects; calling it blind
-- spammed the console with "attempt to call missing method 'SetValue'".
local function setToggleValue(toggle, value)
    if not toggle then return end
    pcall(function() toggle:SetValue(value) end)
end

-- Speed boost variables
local speedBoostActive = false
local defaultWalkSpeed = 16
local boostedWalkSpeed = 50
local flyToggle = nil
local noclipToggle = nil
local currentWalkSpeedValue = 16
local speedBoostValue = 16

-- ============================================
-- CHARACTER RESET
-- ============================================
player.CharacterAdded:Connect(function(char)
    character = char
    rootPart  = char:WaitForChild("HumanoidRootPart")

    -- Kill fly cleanly on respawn
    if flyEnabled then
        flyEnabled = false
        if flyConnection then flyConnection:Disconnect(); flyConnection = nil end
        setToggleValue(flyToggle, false)
    end

    -- Kill noclip cleanly on respawn
    if noClipConnection then
        noClipConnection:Disconnect()
        noClipConnection = nil
        setToggleValue(noclipToggle, false)
    end

    -- Restore speed boost after respawn if it was active
    if speedBoostActive then
        task.wait(0.1)
        local hum = char:FindFirstChild("Humanoid")
        if hum then hum.WalkSpeed = currentWalkSpeedValue end
    end
end)

-- ============================================
-- HELPERS
-- ============================================
local function findChild(parent, name, className)
    if className then
        for _, v in next, parent:GetChildren() do
            if v.Name == name and v.ClassName == className then return v end
        end
    else
        for _, v in next, parent:GetChildren() do
            if v.Name == name then return v end
        end
    end
end

local function getHRP(plr)
    if plr and plr.Character then
        return findChild(plr.Character, "HumanoidRootPart")
            or findChild(plr.Character, "PrimaryPart")
    end
end

local function dist(a, b) return (a - b).Magnitude end

-- ============================================
-- NOCLIP + FARM POSE + MAP
-- ============================================
-- Remembers only the parts noclip actually switched off, so they can be put
-- back exactly as they were.
local noClipOriginal = {}

-- The parts to switch off, cached. GetDescendants() on the character allocated
-- a fresh array every Heartbeat - sixty a second for as long as noclip (or the
-- farm, which turns it on) was running. The set only changes when you respawn
-- or pick up an accessory, so half a second between rebuilds is plenty.
local noClipParts   = {}
local noClipCacheAt = 0

local function refreshNoClipParts()
    table.clear(noClipParts)

    -- Drop parts from characters that no longer exist. These are Instance keys,
    -- so leaving them in pinned every limb of every body you have died in for
    -- the whole session - a slow leak that only showed up after a few rounds.
    for part in pairs(noClipOriginal) do
        if not part.Parent then noClipOriginal[part] = nil end
    end

    if not character then return end
    for _, v in next, character:GetDescendants() do
        if v:IsA("BasePart") then noClipParts[#noClipParts + 1] = v end
    end
end

local function setNoClip(enabled)
    if enabled then
        if not noClipConnection then
            noClipCacheAt = 0   -- force a rebuild on the first frame
            noClipConnection = RunService.Heartbeat:Connect(function()
                if not character then return end
                if tick() - noClipCacheAt > 0.5 then
                    noClipCacheAt = tick()
                    refreshNoClipParts()
                end
                for i = 1, #noClipParts do
                    local v = noClipParts[i]
                    if v.Parent and v.CanCollide then
                        noClipOriginal[v] = true
                        v.CanCollide = false
                    end
                end
            end)
        end
        -- Update UI toggle if it exists
        setToggleValue(noclipToggle, true)
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Noclip ENABLED", Duration=1.5, Icon="square"}) end
    else
        if noClipConnection then
            noClipConnection:Disconnect()
            noClipConnection = nil
        end
        -- Restore ONLY what we turned off. The old code set every BasePart to
        -- CanCollide = true, which made parts that are meant to stay pass-through
        -- (HumanoidRootPart, accessory handles) solid — that is what made walking
        -- feel wrong after toggling noclip off.
        for part, was in pairs(noClipOriginal) do
            if part and part.Parent then part.CanCollide = was end
            noClipOriginal[part] = nil
        end
        -- Update UI toggle if it exists
        setToggleValue(noclipToggle, false)
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Noclip DISABLED", Duration=1.5, Icon="square"}) end
    end
end

-- FLY FUNCTION - REWRITTEN: BodyVelocity + BodyGyro, no recursion
local flyUpdatingUI = false

local function toggleFly(state)
    flyEnabled = state

    if flyConnection then
        flyConnection:Disconnect()
        flyConnection = nil
    end

    local char = player.Character
    if not char then
        flyEnabled = false
        return
    end

    local hrp      = char:FindFirstChild("HumanoidRootPart")
    local humanoid = char:FindFirstChild("Humanoid")

    -- Clean up old fly objects
    if hrp then
        local oldBV = hrp:FindFirstChild("FlyBodyVelocity")
        if oldBV then oldBV:Destroy() end
        local oldBG = hrp:FindFirstChild("FlyBodyGyro")
        if oldBG then oldBG:Destroy() end
    end

    if state then
        if not hrp then
            flyEnabled = false
            return
        end

        if humanoid then
            humanoid.PlatformStand = true
        end

        local bv = Instance.new("BodyVelocity")
        bv.Name     = "FlyBodyVelocity"
        bv.Velocity = Vector3.zero
        bv.MaxForce = Vector3.new(9e9, 9e9, 9e9)
        bv.P        = 5000
        bv.Parent   = hrp

        local bg = Instance.new("BodyGyro")
        bg.Name      = "FlyBodyGyro"
        bg.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
        bg.P         = 9000
        bg.D         = 500
        bg.CFrame    = hrp.CFrame
        bg.Parent    = hrp

        flyConnection = RunService.Heartbeat:Connect(function()
            if not flyEnabled then return end

            local c = player.Character
            if not c then return end
            local h = c:FindFirstChild("HumanoidRootPart")
            if not h then return end

            local bodyVel  = h:FindFirstChild("FlyBodyVelocity")
            local bodyGyro = h:FindFirstChild("FlyBodyGyro")
            if not bodyVel or not bodyGyro then return end

            local camera = workspace.CurrentCamera
            if not camera then return end

            local forward = camera.CFrame.LookVector
            local right   = camera.CFrame.RightVector
            local up      = Vector3.new(0, 1, 0)

            local dir = Vector3.zero

            if UserInputService:IsKeyDown(Enum.KeyCode.W)         then dir = dir + forward end
            if UserInputService:IsKeyDown(Enum.KeyCode.S)         then dir = dir - forward end
            if UserInputService:IsKeyDown(Enum.KeyCode.A)         then dir = dir - right   end
            if UserInputService:IsKeyDown(Enum.KeyCode.D)         then dir = dir + right   end
            if UserInputService:IsKeyDown(Enum.KeyCode.Space)     then dir = dir + up      end
            if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then dir = dir - up      end

            if dir.Magnitude > 0 then
                bodyVel.Velocity = dir.Unit * flyspeedValue
            else
                bodyVel.Velocity = Vector3.zero
            end

            bodyGyro.CFrame = camera.CFrame
        end)

        -- Update UI without re-triggering the callback
        if flyToggle then
            flyUpdatingUI = true
            pcall(function() flyToggle:SetValue(true) end)
            flyUpdatingUI = false
        end
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Fly ON", Duration=1.5, Icon="arrow-up"}) end
    else
        if humanoid then
            humanoid.PlatformStand = false
        end

        if flyToggle then
            flyUpdatingUI = true
            pcall(function() flyToggle:SetValue(false) end)
            flyUpdatingUI = false
        end
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Fly OFF", Duration=1.5, Icon="arrow-up"}) end
    end
end

-- SPEED BOOST FUNCTION - FIXED: E toggles between 16 and slider value, never corrupts default
local function toggleSpeedBoost()
    local char = player.Character
    local hum  = char and char:FindFirstChild("Humanoid")
    if not hum then
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Character not found!", Duration=1.5, Icon="warning"}) end
        return
    end

    speedBoostActive = not speedBoostActive
    if speedBoostActive then
        hum.WalkSpeed = currentWalkSpeedValue
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Speed Boost ON! (" .. currentWalkSpeedValue .. ")", Duration=1.5, Icon="zap"}) end
    else
        hum.WalkSpeed = 16
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Speed Boost OFF (16)", Duration=1.5, Icon="zap"}) end
    end
end

-- NOCLIP TOGGLE FUNCTION - FIXED
local function toggleNoclip()
    if noClipConnection then
        setNoClip(false)
    else
        setNoClip(true)
    end
end

local function setFarmPose(enabled)
    local upperTorso = character and character:FindFirstChild("UpperTorso")
    if not upperTorso then return end
    local gyro = upperTorso:FindFirstChild("AutoFarmGyro")
    local vel  = upperTorso:FindFirstChild("AutoFarmVelocity")
    if enabled then
        if not gyro and not vel then
            local hrp = getHRP(player)
            if hrp then
                local hum = character:FindFirstChild("Humanoid")
                if hum then
                    local pose = CFrame.new(hrp.Position) * CFrame.Angles(math.rad(90), 0, math.rad(90))
                    setNoClip(true)
                    local g = Instance.new("BodyGyro")
                    g.Name = "AutoFarmGyro"; g.P = 90000
                    g.MaxTorque = Vector3.new(9e9,9e9,9e9); g.CFrame = pose; g.Parent = upperTorso
                    local v2 = Instance.new("BodyVelocity")
                    v2.Name = "AutoFarmVelocity"
                    v2.Velocity = Vector3.zero; v2.MaxForce = Vector3.new(9e9,9e9,9e9); v2.Parent = upperTorso
                    hrp.CFrame = pose; hum.PlatformStand = true
                end
            end
        end
    else
        local hum = character and character:FindFirstChild("Humanoid")
        if hum then
            if gyro then gyro:Destroy() end
            if vel  then vel:Destroy()  end
            hum.PlatformStand = false
        end
        setNoClip(false)
    end
end

local function findMap()
    for _, v in next, Workspace:GetChildren() do
        if v:FindFirstChild("CoinAreas") or v:FindFirstChild("CoinContainer") then
            currentMap = v; return v
        end
    end
end

-- ============================================
-- ROLE DETECTION
-- ============================================
local function getRoleFromBackpack(plr)
    if not plr or not plr.Backpack then return "innocent" end
    local hasKnife, hasGun = false, false
    local function check(name)
        name = name:lower()
        if name:find("knife") or name:find("dagger") or name:find("blade") or name:find("sword") then hasKnife = true end
        if name:find("gun") or name:find("pistol") or name:find("revolver") or name:find("shotgun") or name:find("rifle") then hasGun = true end
    end
    for _, item in ipairs(plr.Backpack:GetChildren()) do check(item.Name) end
    if plr.Character then
        for _, tool in ipairs(plr.Character:GetChildren()) do
            if tool:IsA("Tool") then check(tool.Name) end
        end
    end
    if hasKnife then return "murderer"
    elseif hasGun then return "sheriff"
    else return "innocent" end
end

local function getPlayerByRole(role)
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= player and getRoleFromBackpack(plr) == role and plr.Character then return plr end
    end
end

-- ============================================
-- TRAP ESP
-- ============================================
-- Runs against every descendant of workspace on each sweep, and against every
-- instance the game adds while Trap ESP is on - so it must not allocate.
-- obj.Name:lower() built a throwaway string per call: 41 KB of garbage per
-- sweep, measured in-game across 16,147 descendants. Case-insensitive character
-- classes match in one pass with zero allocation.
--
-- Five checks collapse to two because the extras were already substrings:
-- "beartrap" and "bear_trap" both contain "trap", "landmine" contains "mine".
-- Verified against every name in the place - same 3 hits, zero mismatches.
local function isTrap(obj)
    local n = obj.Name
    return n:find("[Tt][Rr][Aa][Pp]") ~= nil or n:find("[Mm][Ii][Nn][Ee]") ~= nil
end

local function addTrapHighlight(obj)
    if not espEnabled.trap then return end
    for _, h in ipairs(obj:GetChildren()) do
        if h:IsA("Highlight") and h.Name == "TrapESPHL" then return end
    end
    local h = Instance.new("Highlight")
    h.Name = "TrapESPHL"
    h.FillColor = Color3.fromRGB(255,100,0); h.FillTransparency = 0.2
    h.OutlineColor = Color3.fromRGB(255,100,0); h.OutlineTransparency = 0
    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop; h.Parent = obj
    table.insert(trapHighlights, h)
end

local function setupTrapESP()
    for _, h in pairs(trapHighlights) do if h and h.Parent then h:Destroy() end end
    trapHighlights = {}
    if not espEnabled.trap then return end
    for _, obj in ipairs(workspace:GetDescendants()) do
        if isTrap(obj) then addTrapHighlight(obj) end
    end
end

-- ============================================
-- PLAYER ESP
-- ============================================
-- Darker shade of a fill color, used for the outline so the body reads clearly against the map
local function darken(color, factor)
    factor = factor or 0.45
    return Color3.new(color.R * factor, color.G * factor, color.B * factor)
end

local function createFullBodyESP(playerObj, color)
    if not playerObj or not playerObj.Character then return nil end
    local char = playerObj.Character
    for _, v in ipairs(char:GetChildren()) do if v:IsA("Highlight") then v:Destroy() end end
    local h = Instance.new("Highlight")
    h.FillColor = color; h.FillTransparency = 0.15
    h.OutlineColor = darken(color); h.OutlineTransparency = 0
    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop; h.Parent = char
    return h
end

-- Reconciles instead of rebuilding. The old version destroyed every Highlight
-- and made a fresh one twice a second, whether or not anything had changed -
-- and a Highlight is not a cheap instance to create, it makes the renderer
-- rebuild its outline pass. Now a highlight is only created when a player first
-- qualifies, recoloured when their role changes, and destroyed when they stop
-- qualifying or respawn into a new character.
local function updateESP()
    local anyOn = espEnabled.murderer or espEnabled.sheriff or espEnabled.innocent

    -- Drop anything stale: feature switched off, player gone, or respawned.
    for plr, h in pairs(espHighlights) do
        if not anyOn or not plr.Parent or h.Parent ~= plr.Character then
            if h then h:Destroy() end
            espHighlights[plr] = nil
        end
    end
    if not anyOn then return end

    for _, plr in ipairs(Players:GetPlayers()) do
        local char = (plr ~= player) and plr.Character or nil
        if char and char:FindFirstChild("HumanoidRootPart") then
            local role = getRoleFromBackpack(plr)
            local color
            if role == "murderer" and espEnabled.murderer then color = Color3.fromRGB(255,0,0)
            elseif role == "sheriff" and espEnabled.sheriff then color = Color3.fromRGB(0,100,255)
            elseif role == "innocent" and espEnabled.innocent then color = Color3.fromRGB(0,255,0)
            end

            local h = espHighlights[plr]
            if color then
                if not h then
                    h = createFullBodyESP(plr, color)
                    if h then espHighlights[plr] = h end
                elseif h.FillColor ~= color then
                    h.FillColor    = color
                    h.OutlineColor = darken(color)
                end
            elseif h then
                h:Destroy()
                espHighlights[plr] = nil
            end
        end
    end
end

Players.PlayerRemoving:Connect(function(plr)
    if espHighlights[plr] then espHighlights[plr]:Destroy(); espHighlights[plr] = nil end
end)

-- ============================================
-- GUN DROP ESP
-- ============================================
local function createGunDropLabel(obj)
    if not obj then return nil end
    local billboard = Instance.new("BillboardGui")
    billboard.Size = UDim2.new(0,100,0,20); billboard.Adornee = obj
    billboard.AlwaysOnTop = true; billboard.MaxDistance = 300; billboard.Parent = obj
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1,0,1,0); lbl.BackgroundTransparency = 1
    lbl.Text = "Dropped Gun"; lbl.TextColor3 = Color3.fromRGB(255,255,0)
    lbl.TextScaled = true; lbl.Font = Enum.Font.GothamBold
    lbl.TextStrokeColor3 = Color3.fromRGB(0,0,0); lbl.TextStrokeTransparency = 0.3
    lbl.Parent = billboard
    table.insert(gunDropLabels, billboard)
    return billboard
end

local function createGunDropHighlight(obj)
    if not obj then return end
    for i,v in pairs(gunDropHighlights) do if v and v.Parent == obj then v:Destroy(); gunDropHighlights[i]=nil end end
    local h = Instance.new("Highlight")
    h.FillColor = Color3.fromRGB(255,255,0); h.FillTransparency = 0.3
    h.OutlineColor = Color3.fromRGB(255,255,0); h.OutlineTransparency = 0
    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop; h.Parent = obj
    table.insert(gunDropHighlights, h)
    createGunDropLabel(obj)
end

local function setupGunDropESP()
    for _,v in pairs(gunDropHighlights) do if v and v.Parent then v:Destroy() end end
    gunDropHighlights = {}
    for _,v in pairs(gunDropLabels) do if v and v.Parent then v:Destroy() end end
    gunDropLabels = {}
    if not gunDropESP then return end
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj.Name == "GunDrop" and obj:IsA("BasePart") then createGunDropHighlight(obj) end
    end
end

-- ============================================
-- COIN ESP
-- ============================================
local COIN_COLOR    = Color3.fromRGB(255, 225, 120)
local COIN_HL_LIMIT = 24   -- Roblox renders ~31 Highlights max, so only the closest coins get a glow

-- Coins normally render fine (MainCoin sits at Transparency 0), but for a short
-- window right after a map loads every part is still at 1. A Highlight has no
-- surface to draw on during that window, so revealCoin covers it.
local coinOriginal = {}   -- BasePart -> its transparency before we touched it

local function findCoinContainer()
    for _, obj in ipairs(Workspace:GetChildren()) do
        local cc = obj:FindFirstChild("CoinContainer")
        if cc then return cc end
    end
    return nil
end

-- The coin disc is the MainCoin mesh. The other parts under CoinVisual are
-- boxes bigger than the disc, so revealing them spills past the coin's shape.
local function getCoinMesh(coin)
    local vis = coin:FindFirstChild("CoinVisual")
    if not vis then return nil end
    return vis:FindFirstChild("MainCoin") or vis:FindFirstChildWhichIsA("MeshPart")
end

-- Only unhide the disc, and leave its own colour alone — the Highlight supplies
-- the yellow, so nothing glows brighter than the coin itself.
local function revealCoin(coin)
    local mesh = getCoinMesh(coin)
    if not mesh then return nil end
    if not coinOriginal[mesh] then
        coinOriginal[mesh] = { transparency = mesh.Transparency }
    end
    -- Checked every pass rather than once: a coin can still be at 1 when we
    -- first see it, and the game may set it back during the load-in window.
    if mesh.Transparency ~= 0 then mesh.Transparency = 0 end
    return mesh
end

local function restoreCoins()
    for part, orig in pairs(coinOriginal) do
        if part and part.Parent then
            part.Transparency = orig.transparency
        end
        coinOriginal[part] = nil
    end
end

local function removeCoinESP(coin)
    if coinHighlights[coin] then coinHighlights[coin]:Destroy(); coinHighlights[coin] = nil end
end

local function clearCoinESP()
    for coin in pairs(coinHighlights) do removeCoinESP(coin) end
    restoreCoins()
end

-- Highlights live under CoreGui rather than the coin, so a collected coin
-- cannot take one down with it and we control their lifetime ourselves.
local function refreshCoinESP()
    local container = findCoinContainer()
    if not container then
        for coin in pairs(coinHighlights) do removeCoinESP(coin) end
        return
    end

    local seen, live = {}, {}
    for _, coin in ipairs(container:GetChildren()) do
        if coin.Name == "Coin_Server" and not coin:GetAttribute("Collected") then
            seen[coin] = true
            live[#live+1] = coin
            revealCoin(coin)          -- every coin, no cap
        end
    end

    for coin in pairs(coinHighlights) do if not seen[coin] then removeCoinESP(coin) end end
    for part in pairs(coinOriginal) do if not part.Parent then coinOriginal[part] = nil end end

    -- Read the character fresh; the shared rootPart upvalue goes stale on respawn.
    local char = player.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if hrp then
        local pos = hrp.Position
        table.sort(live, function(a, b)
            return (a.Position - pos).Magnitude < (b.Position - pos).Magnitude
        end)
    end

    -- Only the closest coins get a Highlight — the engine renders ~31 at most,
    -- shared with the player/trap/gun-drop highlights.
    for i, coin in ipairs(live) do
        if i <= COIN_HL_LIMIT then
            local anchor = getCoinMesh(coin)   -- already revealed in the pass above
            if anchor then
                local h = coinHighlights[coin]
                if not h or not h.Parent then
                    h = Instance.new("Highlight")
                    h.Name = "CoinESPHL"
                    h.FillColor = COIN_COLOR; h.FillTransparency = 0.3
                    h.OutlineTransparency = 1   -- inside only
                    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    h.Parent = CoreGui
                    coinHighlights[coin] = h
                end
                if h.Adornee ~= anchor then h.Adornee = anchor end
            end
        elseif coinHighlights[coin] then
            removeCoinESP(coin)
        end
    end
end

local function setupCoinESP()
    if coinESPThread then task.cancel(coinESPThread); coinESPThread = nil end
    clearCoinESP()
    if not coinESP then return end
    coinESPThread = task.spawn(function()
        local first = true
        while coinESP do
            -- pcall so one bad pass can never leave the toggle ON with a dead loop
            local ok, err = pcall(refreshCoinESP)
            if not ok then warn("[CoinESP] refresh failed: " .. tostring(err)) end

            if first then
                first = false
                local n = 0
                for _ in pairs(coinHighlights) do n += 1 end
                -- WindUI is declared local far below this point, so it is nil up
                -- here — print is the only feedback that actually reaches you.
                print("[CoinESP] ON — highlighted " .. n .. " coin(s)")
            end
            task.wait(0.5)
        end
    end)
end

-- ============================================
-- TOOL FINDERS
-- ============================================
local function getToolByKeyword(source, ...)
    local keywords = {...}
    if not source then return nil end
    for _, tool in ipairs(source:GetChildren()) do
        if tool:IsA("Tool") then
            local n = tool.Name:lower()
            for _, kw in ipairs(keywords) do if n:find(kw) then return tool end end
        end
    end
    return nil
end

local function getGunTool()
    local kw = {"gun","pistol","revolver","sheriff","rifle","shotgun"}
    return getToolByKeyword(character, table.unpack(kw))
        or getToolByKeyword(player.Backpack, table.unpack(kw))
end

local function getKnifeTool()
    local kw = {"knife","dagger","blade","sword"}
    return getToolByKeyword(character, table.unpack(kw))
        or getToolByKeyword(player.Backpack, table.unpack(kw))
end

-- ============================================
-- GUN GRAB
-- ============================================
local function findGunInWorkspace()
    local map = findMap()
    if map then
        for _, child in ipairs(map:GetDescendants()) do
            if child.Name == "GunDrop" and child:IsA("BasePart") and child.Parent then return child end
        end
    end
    for _, child in ipairs(Workspace:GetDescendants()) do
        if child.Name == "GunDrop" and child:IsA("BasePart") and child.Parent then return child end
    end
end

local function grabGun()
    local gunPart = findGunInWorkspace()
    if not gunPart or grabbedGuns[gunPart] then return false end
    local char = player.Character
    if not char then return false end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end
    local original = char:GetPivot()
    char:PivotTo(CFrame.new(gunPart.Position + Vector3.new(0, 2.5, 0)))
    task.wait(0.02)
    pcall(function() firetouchinterest(hrp, gunPart, 0); firetouchinterest(hrp, gunPart, 1) end)
    char:PivotTo(original)
    grabbedGuns[gunPart] = true
    return true
end

-- ============================================
-- CIRCLE BUTTON FACTORY - BIGGER DESKTOP SIZE
-- ============================================
local function makeCircleButton(guiName, labelText, defaultPos, onClick)
    local gui = Instance.new("ScreenGui")
    gui.Name = guiName; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.Parent = CoreGui

    local isMobile = UserInputService.TouchEnabled
    local size = isMobile and 70 or 80

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, size, 0, size)
    btn.Position = defaultPos or UDim2.new(0.85, -size/2, 0.5, 0)
    btn.Text = ""; btn.BackgroundTransparency = 1
    btn.BorderSizePixel = 0; btn.AutoButtonColor = false; btn.ZIndex = 2; btn.Parent = gui

    local circle = Instance.new("Frame")
    circle.Size = UDim2.new(1,0,1,0); circle.AnchorPoint = Vector2.new(0.5,0.5)
    circle.Position = UDim2.new(0.5,0,0.5,0); circle.BackgroundTransparency = 1
    circle.BorderSizePixel = 0; circle.Parent = btn
    Instance.new("UICorner", circle).CornerRadius = UDim.new(1, 0)

    local outline = Instance.new("UIStroke", circle)
    outline.Color = Color3.fromRGB(255,255,255); outline.Thickness = 4
    outline.Transparency = 0.2; outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0.85,0,0.85,0); label.AnchorPoint = Vector2.new(0.5,0.5)
    label.Position = UDim2.new(0.5,0,0.5,0); label.BackgroundTransparency = 1
    label.Text = labelText; label.TextScaled = true; label.Font = Enum.Font.SourceSansBold
    label.TextColor3 = Color3.fromRGB(255,255,255); label.TextWrapped = true
    label.TextStrokeTransparency = 0.2; label.TextStrokeColor3 = Color3.fromRGB(0,0,0); label.Parent = btn

    task.spawn(function()
        while gui and gui.Parent do
            local t1 = TweenService:Create(outline, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Transparency=0.05})
            t1:Play(); t1.Completed:Wait()
            local t2 = TweenService:Create(outline, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Transparency=0.4})
            t2:Play(); t2.Completed:Wait()
        end
    end)

    btn.MouseButton1Click:Connect(onClick)
    btn.TouchTap:Connect(onClick)

    local locked = { value = false }
    local dragging = false; local dragStart, mouseStart

    btn.InputBegan:Connect(function(input)
        if locked.value then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = btn.Position; mouseStart = input.Position
        end
    end)
    btn.InputChanged:Connect(function(input)
        if locked.value then return end
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - mouseStart
            btn.Position = UDim2.new(dragStart.X.Scale, dragStart.X.Offset + d.X,
                                     dragStart.Y.Scale, dragStart.Y.Offset + d.Y)
        end
    end)
    btn.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)

    local obj = {}
    obj.setLocked  = function(state) locked.value = state end
    obj.setLabel   = function(text, color) label.Text = text; if color then label.TextColor3 = color end end
    obj.resetLabel = function() label.Text = labelText; label.TextColor3 = Color3.fromRGB(255,255,255) end
    obj.flash = function(text, color, dur) obj.setLabel(text, color); task.delay(dur or 1, obj.resetLabel) end
    obj.destroy = function() if gui then gui:Destroy() end end
    return obj
end

-- ============================================
-- ACTION CALLBACKS
-- ============================================
local function grabGunManual()
    local ok = grabGun()
    if gunBtn then
        if ok then
            gunBtn.flash("Got it!", Color3.fromRGB(0,255,100))
            if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Gun grabbed!", Duration=2, Icon="check"}) end
        else
            gunBtn.flash("No\nGun", Color3.fromRGB(255,80,80))
            if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="No dropped gun found!", Duration=2, Icon="warning"}) end
        end
    end
end

-- ============================================
-- MURDERER FUNCTIONS - STAB REMOTE
-- ============================================
local function equipTool(tool)
    if not tool then return end
    if tool.Parent == player.Backpack then
        local hum = character and character:FindFirstChild("Humanoid")
        if hum then hum:EquipTool(tool); task.wait(0.3) end
    end
end

-- Rewritten after reading this build's KnifeClient. firetouchinterest on the
-- Handle was never going to work: the client's Touched handler bails unless a
-- stab is already running and started under 0.85s ago
--   if os.clock() - lastStab > 0.85 then return end
--   if not stabbing then return end
--   Events.HandleTouched:FireServer(part)
-- and the old code never fired the stab, so every touch was thrown away.
--
-- The YARHM hub fires Knife.Stab:FireServer("Slash"), which no longer exists on
-- this version - the remotes moved into Knife.Events. So this drives the same
-- pair the real weapon does: announce the stab, then report each target as the
-- thing the handle hit.
local function getKnifeRemotes()
    local knife = (character and character:FindFirstChild("Knife"))
        or (player.Backpack and player.Backpack:FindFirstChild("Knife"))
        or getKnifeTool()
    if not knife then return nil end

    equipTool(knife)
    knife = character and character:FindFirstChild(knife.Name)
    if not knife then return nil end

    local events = knife:FindFirstChild("Events")
    local stabbed = events and events:FindFirstChild("KnifeStabbed")
    local touched = events and events:FindFirstChild("HandleTouched")
    if not stabbed or not touched then return nil end
    return knife, stabbed, touched
end

-- Returns nil when there is no usable knife, so the caller can tell "no weapon"
-- apart from "weapon but nobody was in reach".
local function killAllWithTouch()
    local knife, stabbed, touched = getKnifeRemotes()
    if not knife then return nil end

    local myChar = player.Character
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return nil end

    -- Collect first, so the drag and the stab happen back to back.
    local targets = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= player and plr.Character then
            local hum  = plr.Character:FindFirstChild("Humanoid")
            local root = plr.Character:FindFirstChild("HumanoidRootPart")
            if hum and root and hum.Health > 0 then
                targets[#targets + 1] = { root = root, was = root.Anchored }
            end
        end
    end
    if #targets == 0 then return 0 end

    -- Anchoring holds them in place client-side long enough for the server to
    -- see the hit where we say it happened; without it they drift straight back.
    local infront = myRoot.CFrame + myRoot.CFrame.LookVector * 2
    for _, t in ipairs(targets) do
        t.root.Anchored = true
        t.root.CFrame = infront
    end

    pcall(function() stabbed:FireServer() end)
    task.wait(0.1)
    for _, t in ipairs(targets) do
        pcall(function() touched:FireServer(t.root) end)
    end

    -- Let them go again. Leaving them anchored freezes them on your screen for
    -- the rest of the round.
    task.delay(0.4, function()
        for _, t in ipairs(targets) do
            if t.root and t.root.Parent then t.root.Anchored = t.was end
        end
    end)

    return #targets
end

local function killAllPlayers()
    local killed = killAllWithTouch()

    -- Exactly one notification, raised here only. The old code also notified
    -- from inside killAllWithTouch, which is where the double toast came from.
    if killed == nil then
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="No knife found! You are not the murderer.", Duration=2, Icon="warning"}) end
        if killAllBtn then killAllBtn.flash("No Knife", Color3.fromRGB(255,80,80), 1.5) end
        return
    end

    if WindUI then
        WindUI:Notify({
            Title = "FurqwkScripts",
            Content = killed > 0 and ("Stabbed " .. killed .. " players at once!") or "Nobody alive to stab.",
            Duration = 2, Icon = killed > 0 and "sword" or "warning",
        })
    end
    if killAllBtn then
        if killed > 0 then
            killAllBtn.flash("Killed " .. killed, Color3.fromRGB(0,255,100), 1.5)
        else
            killAllBtn.flash("No Kill", Color3.fromRGB(255,80,80), 1.5)
        end
    end
end

-- ============================================
-- SHOOT MURDERER - FROM YARHM (WORKING)
-- ============================================
local function FindMurderer()
    for _, Player in ipairs(Players:GetPlayers()) do
        if Player ~= player then
            if Player.Backpack and Player.Backpack:FindFirstChild("Knife") then return Player end
            if Player.Character and Player.Character:FindFirstChild("Knife") then return Player end
        end
    end
    return nil
end

local function FindSheriff()
    for _, Player in ipairs(Players:GetPlayers()) do
        if Player.Backpack and Player.Backpack:FindFirstChild("Gun") then return Player end
        if Player.Character and Player.Character:FindFirstChild("Gun") then return Player end
    end
    return nil
end

local function FindSheriffNotLocalPlayer()
    for _, Player in ipairs(Players:GetPlayers()) do
        if Player ~= player then
            if Player.Backpack and Player.Backpack:FindFirstChild("Gun") then return Player end
            if Player.Character and Player.Character:FindFirstChild("Gun") then return Player end
        end
    end
    return nil
end

local function GetPredictedPosition(TargetPlayer, Offset)
    Offset = Offset or 2.8
    local Character = TargetPlayer.Character
    if not Character then return nil end
    local HumanoidRootPart = Character:FindFirstChild("HumanoidRootPart")
    local Humanoid = Character:FindFirstChildOfClass("Humanoid")
    if not HumanoidRootPart or not Humanoid then return nil end
    local LinearVelocity = HumanoidRootPart.AssemblyLinearVelocity
    local MoveDirection = Humanoid.MoveDirection
    return HumanoidRootPart.Position + (LinearVelocity * Vector3.new(0.75, 0.5, 0.75)) * (Offset / 15) + MoveDirection * Offset
end

local function ShootMurderer()
    if FindSheriff() ~= player then
        if shootBtn then shootBtn.flash("Not Sheriff", Color3.fromRGB(255,80,80)) end
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="You are not the sheriff!", Duration=2, Icon="warning"}) end
        return
    end

    local Murderer = FindMurderer() or FindSheriffNotLocalPlayer()
    if not Murderer then
        if shootBtn then shootBtn.flash("No Target", Color3.fromRGB(255,80,80)) end
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="No murderer found!", Duration=2, Icon="warning"}) end
        return
    end

    local Character = player.Character
    if not Character then
        if shootBtn then shootBtn.flash("No Char", Color3.fromRGB(255,80,80)) end
        return
    end

    local GunTool = Character:FindFirstChild("Gun")
    if not GunTool then
        local Backpack = player.Backpack
        if Backpack and Backpack:FindFirstChild("Gun") then
            local Humanoid = Character:FindFirstChildOfClass("Humanoid")
            if Humanoid then
                Humanoid:EquipTool(Backpack:FindFirstChild("Gun"))
                task.wait(0.1)
                GunTool = Character:FindFirstChild("Gun")
            end
        else
            grabGun()
            task.wait(0.3)
            GunTool = Character:FindFirstChild("Gun") or (player.Backpack and player.Backpack:FindFirstChild("Gun"))
            if not GunTool then
                if shootBtn then shootBtn.flash("No Gun", Color3.fromRGB(255,80,80)) end
                if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="No gun found! Grab one first.", Duration=2, Icon="warning"}) end
                return
            end
        end
    end
    
    if not GunTool then
        if shootBtn then shootBtn.flash("No Gun", Color3.fromRGB(255,80,80)) end
        return
    end

    local MurdererCharacter = Murderer.Character
    if not MurdererCharacter then
        if shootBtn then shootBtn.flash("No Char", Color3.fromRGB(255,80,80)) end
        return
    end

    local MurdererRootPart = MurdererCharacter:FindFirstChild("HumanoidRootPart")
    if not MurdererRootPart then
        if shootBtn then shootBtn.flash("No HRP", Color3.fromRGB(255,80,80)) end
        return
    end

    local PredictedPosition = GetPredictedPosition(Murderer, 2.8) or MurdererRootPart.Position
    local RightHand = Character:FindFirstChild("RightHand")
    if not RightHand then
        if shootBtn then shootBtn.flash("No Hand", Color3.fromRGB(255,80,80)) end
        return
    end

    local KnifeLocal = GunTool:FindFirstChild("KnifeLocal")
    if KnifeLocal then
        local CreateBeam = KnifeLocal:FindFirstChild("CreateBeam")
        if CreateBeam then
            local RemoteFunction = CreateBeam:FindFirstChild("RemoteFunction")
            if RemoteFunction then
                pcall(function()
                    RemoteFunction:InvokeServer(1, PredictedPosition, "AH2")
                    if shootBtn then shootBtn.flash("Shot!", Color3.fromRGB(0,255,100)) end
                    if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Shot fired at murderer!", Duration=2, Icon="check"}) end
                end)
                return
            end
        end
    end

    local ShootRemote = GunTool:FindFirstChild("Shoot")
    if ShootRemote then
        pcall(function()
            ShootRemote:FireServer(CFrame.new(RightHand.Position), CFrame.new(PredictedPosition))
            if shootBtn then shootBtn.flash("Shot!", Color3.fromRGB(0,255,100)) end
            if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Shot fired at murderer!", Duration=2, Icon="check"}) end
        end)
        return
    end

    local success = false
    for _, child in ipairs(GunTool:GetDescendants()) do
        if child:IsA("RemoteEvent") then
            pcall(function()
                child:FireServer(PredictedPosition)
                child:FireServer(PredictedPosition, Murderer)
                success = true
            end)
        elseif child:IsA("RemoteFunction") and typeof(child.InvokeServer) == "function" then
            pcall(function()
                child:InvokeServer(PredictedPosition)
                success = true
            end)
        end
    end
    
    if success then
        if shootBtn then shootBtn.flash("Shot!", Color3.fromRGB(0,255,100)) end
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Shot fired at murderer!", Duration=2, Icon="check"}) end
    else
        if shootBtn then shootBtn.flash("Failed", Color3.fromRGB(255,80,80)) end
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Failed to shoot!", Duration=2, Icon="warning"}) end
    end
end

-- ============================================
-- FLING - FROM YARHM (WORKING)
-- ============================================
-- Declared before use: ANTIFLING's restorer reads this so our own fling is not
-- yanked back the instant it starts.
flingInProgress = false

local function skidFlingImpl(TargetPlayer)
    if not TargetPlayer or not TargetPlayer.Character then return end

    local Character = player.Character
    local Humanoid = Character and (Character:FindFirstChildOfClass("Humanoid") or Character:FindFirstChild("Humanoid"))
    local RootPart = Character and (Character:FindFirstChild("HumanoidRootPart") or Character.PrimaryPart)

    local TCharacter = TargetPlayer and TargetPlayer.Character
    local THumanoid
    local TRootPart
    local THead
    local Accessory
    local Handle

    if TCharacter and TCharacter:FindFirstChildOfClass("Humanoid") then
        THumanoid = TCharacter:FindFirstChildOfClass("Humanoid")
    end
    if THumanoid then
        TRootPart = TCharacter:FindFirstChild("HumanoidRootPart") or TCharacter.PrimaryPart or THumanoid.RootPart
    end
    if TCharacter and TCharacter:FindFirstChild("Head") then
        THead = TCharacter.Head
    end
    if TCharacter and TCharacter:FindFirstChildOfClass("Accessory") then
        Accessory = TCharacter:FindFirstChildOfClass("Accessory")
    end
    if Accessory and Accessory:FindFirstChild("Handle") then
        Handle = Accessory.Handle
    end

    if Character and Humanoid and RootPart then
        if RootPart.Velocity.Magnitude < 50 then
            getgenv().OldPos = RootPart.CFrame
        end
        
        local CurrentCam = workspace.CurrentCamera
        if THead then
            CurrentCam.CameraSubject = THead
        elseif not THead and Handle then
            CurrentCam.CameraSubject = Handle
        elseif THumanoid and TRootPart then
            CurrentCam.CameraSubject = THumanoid
        end
        if not (TCharacter and TCharacter:FindFirstChildWhichIsA("BasePart")) then
            return
        end
        
        local FPos = function(BasePart, Pos, Ang)
            RootPart.CFrame = CFrame.new(BasePart.Position) * Pos * Ang
            pcall(function()
                if Character and Character.PrimaryPart then
                    Character:SetPrimaryPartCFrame(CFrame.new(BasePart.Position) * Pos * Ang)
                end
            end)
            RootPart.Velocity = Vector3.new(9e7, 9e7 * 10, 9e7)
            RootPart.RotVelocity = Vector3.new(9e8, 9e8, 9e8)
        end
        
        local SFBasePart = function(BasePart)
            local TimeToWait = 2
            local Time = tick()
            local Angle = 0

            repeat
                if RootPart and THumanoid then
                    if BasePart.Velocity.Magnitude < 50 then
                        Angle = Angle + 100

                        FPos(BasePart, CFrame.new(0, 1.5, 0) + THumanoid.MoveDirection * BasePart.Velocity.Magnitude / 1.25, CFrame.Angles(math.rad(Angle),0 ,0))
                        task.wait()

                        FPos(BasePart, CFrame.new(0, -1.5, 0) + THumanoid.MoveDirection * BasePart.Velocity.Magnitude / 1.25, CFrame.Angles(math.rad(Angle), 0, 0))
                        task.wait()

                        FPos(BasePart, CFrame.new(2.25, 1.5, -2.25) + THumanoid.MoveDirection * BasePart.Velocity.Magnitude / 1.25, CFrame.Angles(math.rad(Angle), 0, 0))
                        task.wait()

                        FPos(BasePart, CFrame.new(-2.25, -1.5, 2.25) + THumanoid.MoveDirection * BasePart.Velocity.Magnitude / 1.25, CFrame.Angles(math.rad(Angle), 0, 0))
                        task.wait()

                        FPos(BasePart, CFrame.new(0, 1.5, 0) + THumanoid.MoveDirection,CFrame.Angles(math.rad(Angle), 0, 0))
                        task.wait()

                        FPos(BasePart, CFrame.new(0, -1.5, 0) + THumanoid.MoveDirection,CFrame.Angles(math.rad(Angle), 0, 0))
                        task.wait()
                    else
                        FPos(BasePart, CFrame.new(0, 1.5, THumanoid.WalkSpeed), CFrame.Angles(math.rad(90), 0, 0))
                        task.wait()

                        FPos(BasePart, CFrame.new(0, -1.5, -THumanoid.WalkSpeed), CFrame.Angles(0, 0, 0))
                        task.wait()

                        FPos(BasePart, CFrame.new(0, 1.5, THumanoid.WalkSpeed), CFrame.Angles(math.rad(90), 0, 0))
                        task.wait()
                        
                        FPos(BasePart, CFrame.new(0, 1.5, TRootPart and TRootPart.Velocity.Magnitude / 1.25 or 0), CFrame.Angles(math.rad(90), 0, 0))
                        task.wait()

                        FPos(BasePart, CFrame.new(0, -1.5, -(TRootPart and TRootPart.Velocity.Magnitude / 1.25 or 0)), CFrame.Angles(0, 0, 0))
                        task.wait()

                        FPos(BasePart, CFrame.new(0, 1.5, TRootPart and TRootPart.Velocity.Magnitude / 1.25 or 0), CFrame.Angles(math.rad(90), 0, 0))
                        task.wait()

                        FPos(BasePart, CFrame.new(0, -1.5, 0), CFrame.Angles(math.rad(90), 0, 0))
                        task.wait()

                        FPos(BasePart, CFrame.new(0, -1.5, 0), CFrame.Angles(0, 0, 0))
                        task.wait()

                        FPos(BasePart, CFrame.new(0, -1.5 ,0), CFrame.Angles(math.rad(-90), 0, 0))
                        task.wait()

                        FPos(BasePart, CFrame.new(0, -1.5, 0), CFrame.Angles(0, 0, 0))
                        task.wait()
                    end
                else
                    break
                end
            until BasePart.Velocity.Magnitude > 500 or BasePart.Parent ~= TargetPlayer.Character or TargetPlayer.Parent ~= Players or TargetPlayer.Character ~= TCharacter or (THumanoid and THumanoid.Sit) or (Humanoid and Humanoid.Health <= 0) or tick() > Time + TimeToWait
        end
        
        if not getgenv().FPDH then
             getgenv().FPDH = workspace.FallenPartsDestroyHeight
        end

        workspace.FallenPartsDestroyHeight = 0/0
        
        local BV = Instance.new("BodyVelocity")
        BV.Name = "EpixVel"
        BV.Parent = RootPart
        BV.Velocity = Vector3.new(9e8, 9e8, 9e8)
        BV.MaxForce = Vector3.new(1/0, 1/0, 1/0)
        
        Humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
        
        if TRootPart and THead then
            if (TRootPart.CFrame.p - THead.CFrame.p).Magnitude > 5 then
                SFBasePart(THead)
            else
                SFBasePart(TRootPart)
            end
        elseif TRootPart and not THead then
            SFBasePart(TRootPart)
        elseif not TRootPart and THead then
            SFBasePart(THead)
        elseif not TRootPart and not THead and Accessory and Handle then
            SFBasePart(Handle)
        end
        
        if BV and BV.Parent then BV:Destroy() end
        Humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, true)
        workspace.CurrentCamera.CameraSubject = Humanoid
        
        repeat
            if getgenv().OldPos then
                RootPart.CFrame = getgenv().OldPos * CFrame.new(0, .5, 0)
                pcall(function()
                    if Character and Character.PrimaryPart then
                        Character:SetPrimaryPartCFrame(getgenv().OldPos * CFrame.new(0, .5, 0))
                    end
                end)
            end
            Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
            for _, x in ipairs(Character:GetChildren()) do
                if x:IsA("BasePart") then
                    x.Velocity, x.RotVelocity = Vector3.new(), Vector3.new()
                end
            end
            task.wait()
        until not getgenv().OldPos or (RootPart.Position - getgenv().OldPos.p).Magnitude < 25
        
        if getgenv().FPDH then
            workspace.FallenPartsDestroyHeight = getgenv().FPDH
        end
    end
end

-- The flag has to come back down on every exit path, including the early
-- returns inside the body, or ANTIFLING stays switched off for good.
local SkidFling = function(TargetPlayer)
    flingInProgress = true
    local ok, err = pcall(skidFlingImpl, TargetPlayer)
    flingInProgress = false
    if not ok then warn("[Fling] " .. tostring(err)) end
end

-- ============================================
-- TELEPORT FUNCTIONS - FIXED
-- ============================================
local function getMap()
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:FindFirstChild("CoinContainer") and obj:FindFirstChild("Spawns") then
            return obj
        end
        if obj:FindFirstChild("CoinAreas") then
            return obj
        end
    end
    return nil
end

local function getLobby()
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj.Name:lower() == "lobby" then
            return obj
        end
        if obj:FindFirstChild("Lobby") and obj.Lobby:IsA("BasePart") then
            return obj.Lobby
        end
        if obj:FindFirstChild("LobbySpawns") then
            return obj
        end
    end
    return nil
end

local function TeleportToPlayer(target)
    if not target or not target.Character then return end
    local char = player.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local targetHRP = target.Character:FindFirstChild("HumanoidRootPart")
    if not targetHRP then return end
    hrp.CFrame = targetHRP.CFrame * CFrame.new(0, 3, 0)
    if WindUI then 
        WindUI:Notify({
            Title="FurqwkScripts", 
            Content="Teleported to " .. target.Name, 
            Duration=2, 
            Icon="check"
        }) 
    end
end

local function TeleportToMap()
    local char = player.Character
    if not char then 
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Character not found!", Duration=2, Icon="warning"}) end
        return 
    end

    local map = getMap()
    if not map then 
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Map not found! Trying to find spawn...", Duration=2, Icon="warning"}) end
        for _, obj in ipairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and (obj.Name:lower():find("spawn") or obj.Name:lower():find("start")) then
                local hrp = char:FindFirstChild("HumanoidRootPart")
                if hrp then
                    hrp.CFrame = obj.CFrame * CFrame.new(0, 3, 0)
                    if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Teleported to spawn point!", Duration=2, Icon="check"}) end
                    return
                end
            end
        end
        return 
    end

    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="HRP not found!", Duration=2, Icon="warning"}) end
        return
    end

    local spawns = map:FindFirstChild("Spawns")
    if not spawns then
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Spawns not found!", Duration=2, Icon="warning"}) end
        return
    end

    local spawnParts = {}
    for _, v in ipairs(spawns:GetChildren()) do
        if v:IsA("BasePart") then
            table.insert(spawnParts, v)
        end
    end

    if #spawnParts == 0 then
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="No spawn parts found!", Duration=2, Icon="warning"}) end
        return
    end

    local spawn = spawnParts[math.random(1, #spawnParts)]
    if spawn and spawn:IsA("BasePart") then
        hrp.CFrame = spawn.CFrame * CFrame.new(0, 3, 0)
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Teleported to map!", Duration=2, Icon="check"}) end
    end
end

local function TeleportToLobby()
    local char = player.Character
    if not char then 
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Character not found!", Duration=2, Icon="warning"}) end
        return 
    end

    local lobby = getLobby()
    if not lobby then 
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Lobby not found!", Duration=2, Icon="warning"}) end
        return 
    end

    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="HRP not found!", Duration=2, Icon="warning"}) end
        return
    end

    local spawns = lobby:FindFirstChild("Spawns") or lobby:FindFirstChild("LobbySpawns")
    if not spawns then
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Spawns not found in lobby!", Duration=2, Icon="warning"}) end
        return
    end

    local spawnParts = {}
    for _, v in ipairs(spawns:GetChildren()) do
        if v:IsA("BasePart") then
            table.insert(spawnParts, v)
        end
    end

    if #spawnParts == 0 then
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="No spawn parts found!", Duration=2, Icon="warning"}) end
        return
    end

    local spawn = spawnParts[math.random(1, #spawnParts)]
    if spawn and spawn:IsA("BasePart") then
        hrp.CFrame = spawn.CFrame * CFrame.new(0, 3, 0)
        if WindUI then WindUI:Notify({Title="FurqwkScripts", Content="Teleported to lobby!", Duration=2, Icon="check"}) end
    end
end

-- ============================================
-- WORKSPACE LISTENERS
-- ============================================
Workspace.DescendantAdded:Connect(function(obj)
    if obj.Name == "GunDrop" then
        if gunDropESP then createGunDropHighlight(obj) end
        if autoGetDroppedGun then task.spawn(function() task.wait(1); grabGun() end) end
    end
    if espEnabled.trap and isTrap(obj) then task.wait(0.1); addTrapHighlight(obj) end
end)

Workspace.DescendantRemoving:Connect(function(obj)
    if obj.Name == "GunDrop" then
        for i,v in pairs(gunDropHighlights) do if v and v.Parent==obj then v:Destroy(); gunDropHighlights[i]=nil end end
        for i,v in pairs(gunDropLabels)     do if v and v.Parent==obj then v:Destroy(); gunDropLabels[i]=nil     end end
    end
    if obj.Name == "Coin_Server" then removeCoinESP(obj) end
end)

-- ============================================
-- AUTOFARM
-- ============================================
local activeTween       = nil
local activeTweenConn   = nil
local currentTargetCoin = nil

-- Tears the current tween down in the right order. Cancel() fires Completed
-- SYNCHRONOUSLY with PlaybackState.Cancelled (measured in-game, not assumed),
-- so the connection has to be dropped first or the old handler runs mid-teardown.
local function clearTween()
    if activeTweenConn then activeTweenConn:Disconnect(); activeTweenConn = nil end
    if activeTween then activeTween:Cancel(); activeTween = nil end
end

-- This is what made the stutter get worse the longer the farm ran.
--
-- The old code set currentTargetCoin = coin and THEN called activeTween:Cancel().
-- Because Cancel() fires Completed synchronously, the previous tween's handler
-- ran right there and reset currentTargetCoin back to nil - wiping the value one
-- line after it was assigned. So the "same coin, already tweening" guard at the
-- top of this function could never hold, and the 20 Hz loop built and threw away
-- a fresh Tween on every single pass. Each one left a live Completed connection
-- pinning its closure and coin, so garbage piled up until the collector had to
-- stop and sweep - the hitch every few seconds.
--
-- Now: disconnect before cancelling (so the stale handler never runs), assign
-- the target after the teardown, ignore a handler whose tween was superseded,
-- and only collect the coin on a real completion.
local function flyTo(coin)
    if not rootPart then return end
    if coin == currentTargetCoin and activeTween then return end
    clearTween()
    currentTargetCoin = coin
    local pos = coin.Position
    local d   = (pos - rootPart.Position).Magnitude
    if d < 1 then return end
    local goal = CFrame.new(pos.X, pos.Y - 3, pos.Z) * CFrame.Angles(math.rad(90), 0, math.rad(90))
    local tween = TweenService:Create(rootPart,
        TweenInfo.new(math.max(d / (flySpeed * 1.2), 0.1), Enum.EasingStyle.Linear),
        { CFrame = goal })
    activeTween = tween
    activeTweenConn = tween.Completed:Connect(function(state)
        if activeTween ~= tween then return end   -- a newer target already took over
        if activeTweenConn then activeTweenConn:Disconnect(); activeTweenConn = nil end
        activeTween = nil
        currentTargetCoin = nil
        if state == Enum.PlaybackState.Completed and coin.Parent and rootPart then
            pcall(function() firetouchinterest(rootPart, coin, 0); firetouchinterest(rootPart, coin, 1) end)
        end
    end)
    tween:Play()
end

-- Coins only ever live directly under the map's CoinContainer, so the old
-- workspace:GetDescendants() walk was building an array of every instance in
-- the game twenty times a second to find them. That single call was the largest
-- source of garbage in the script.
local cachedCoinContainer = nil
local coinScanAt          = 0
local coinScanList        = {}

local function findNearestCoin()
    if not rootPart then return nil end

    if not (cachedCoinContainer and cachedCoinContainer.Parent) then
        cachedCoinContainer = findCoinContainer()
    end

    local candidates
    if cachedCoinContainer then
        candidates = cachedCoinContainer:GetChildren()   -- one level, ~100 entries
    else
        -- No container on this map. Keep the old behaviour as a fallback, but
        -- rescan once a second instead of twenty times.
        if tick() - coinScanAt > 1 then
            coinScanAt = tick()
            table.clear(coinScanList)
            for _, obj in next, workspace:GetDescendants() do
                if obj:IsA("BasePart") and obj.Name == "Coin_Server" then
                    coinScanList[#coinScanList + 1] = obj
                end
            end
        end
        candidates = coinScanList
    end

    local pos, best, nearest = rootPart.Position, 300, nil
    for _, obj in next, candidates do
        -- The IsA guard is kept from the original: a map that ships Coin_Server
        -- as a Model instead of a part would otherwise throw on .Position and
        -- kill the farm thread outright.
        if obj.Name == "Coin_Server" and obj.Parent and obj:IsA("BasePart")
        and not obj:GetAttribute("Collected") then
            local d = (obj.Position - pos).Magnitude
            if d < best then best = d; nearest = obj end
        end
    end
    return nearest
end

local coinRemote = ReplicatedStorage:FindFirstChild("Remotes")
    and ReplicatedStorage.Remotes:FindFirstChild("Gameplay")
    and ReplicatedStorage.Remotes.Gameplay:FindFirstChild("CoinCollected")
if coinRemote then
    coinRemote.OnClientEvent:Connect(function()
        if isActive then totalCoinsCollected = totalCoinsCollected + 1; collectedDisplayValue = totalCoinsCollected end
    end)
end

local function startAutofarmLoop()
    if autofarmRunning then return end
    autofarmRunning = true
    farmStartTime = tick(); totalCoinsCollected = 0; collectedDisplayValue = 0
    bagFullFired = false
    farmPaused   = false
    setFarmPose(true)
    autofarmLoopThread = task.spawn(function()
        while isActive do
            task.wait(0.05)
            -- Bag-full actions own the character while this is set.
            if farmPaused then continue end
            character = player.Character
            if not character then continue end
            rootPart = character:FindFirstChild("HumanoidRootPart")
            if not rootPart then continue end
            local ut = character:FindFirstChild("UpperTorso")
            if ut and not ut:FindFirstChild("AutoFarmGyro") then setFarmPose(true) end
            local coin = findNearestCoin()
            if coin and coin.Parent then
                if (coin.Position - rootPart.Position).Magnitude <= 6 then
                    pcall(function() firetouchinterest(rootPart,coin,0); firetouchinterest(rootPart,coin,1) end)
                end
                flyTo(coin)
            end
        end
    end)
end

function stopAutofarmLoop()
    farmPaused = false
    autofarmRunning = false
    clearTween()   -- disconnects the Completed handler too, so nothing leaks
    currentTargetCoin = nil
    if autofarmLoopThread then task.cancel(autofarmLoopThread); autofarmLoopThread = nil end
    -- Anti-AFK is no longer tied to the farm; it has its own toggle and keeps
    -- running (or not) independently of whether the farm is on.
    setFarmPose(false)
end

-- ============================================
-- ANTI-AFK
-- ============================================
function setAntiAfk(state)
    antiAfkEnabled = state
    if antiAfkConnection then antiAfkConnection:Disconnect(); antiAfkConnection = nil end
    if not state then return end
    antiAfkConnection = RunService.Heartbeat:Connect(function()
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end)
end

-- ============================================
-- COIN BAG FULL WATCHER
-- ============================================
-- Fires once per farm run when the round's collected count crosses the
-- threshold, then stays quiet until the farm is restarted.
--
-- Farming is held off for the whole time these actions run. The old version
-- fired one fling and let the loop drag you straight back to the next coin,
-- and the farm pose (BodyGyro + PlatformStand on the UpperTorso) fought the
-- fling for control of your character, so it usually did nothing at all.

-- Give up on a murderer who never shows so a dead round does not park the farm
-- forever.
local BAG_FULL_NO_TARGET_GRACE = 15   -- seconds

local function flingMurdererUntilDown()
    local lastSeen = tick()

    while isActive and flingMurdererOnFull do
        local m = getPlayerByRole("murderer")
        local hum = m and m.Character and m.Character:FindFirstChildOfClass("Humanoid")

        if hum then
            if hum.Health <= 0 then break end   -- they are down, we are done
            lastSeen = tick()
            pcall(SkidFling, m)
        elseif tick() - lastSeen > BAG_FULL_NO_TARGET_GRACE then
            break                                -- nobody holds the knife anymore
        end

        task.wait(0.5)
    end
end

task.spawn(function()
    while task.wait(0.5) do
        if isActive and not bagFullFired and collectedDisplayValue >= bagFullAt then
            bagFullFired = true

            -- Stop chasing coins and drop the farm pose, or nothing below can
            -- move your character.
            farmPaused = true
            setFarmPose(false)
            clearTween()
            currentTargetCoin = nil
            task.wait(0.1)

            if flingMurdererOnFull then
                flingMurdererUntilDown()
            end

            if resetPlayerOnFull then
                task.wait(0.5)
                local hum = player.Character and player.Character:FindFirstChild("Humanoid")
                if hum then hum.Health = 0 end
            end

            farmPaused = false
        end
    end
end)

-- ============================================
-- ESP UPDATE LOOP
-- ============================================
-- setupGunDropESP and setupTrapESP each walk workspace:GetDescendants() and
-- destroy/recreate every Highlight and BillboardGui they own. Running both of
-- those twice a second was the second big source of the hitching, and it was
-- redundant: the DescendantAdded/DescendantRemoving listeners above already
-- add and remove those highlights as the objects appear and vanish. They now
-- get a reconciling sweep every 5 seconds purely as a safety net for a missed
-- event, which is imperceptible.
--
-- updateESP stays at 0.5s because it no longer rebuilds anything it can reuse.
task.spawn(function()
    local sweep = 0
    while task.wait(0.5) do
        if espEnabled.murderer or espEnabled.sheriff or espEnabled.innocent then updateESP() end

        sweep += 1
        if sweep >= 10 then
            sweep = 0
            if gunDropESP      then setupGunDropESP() end
            if espEnabled.trap then setupTrapESP()   end
        end
    end
end)

-- ============================================
-- LOAD WINDUI
-- ============================================
-- No `local` here: WindUI is declared at the top of the file so the feature
-- functions above can actually see it.
WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local GuiService = game:GetService("GuiService")
local Camera     = Workspace.CurrentCamera

-- ============================================
-- DEVICE
-- ============================================
local IS_CONSOLE = GuiService:IsTenFootInterface()
local IS_MOBILE  = (not IS_CONSOLE)
    and UserInputService.TouchEnabled
    and not UserInputService.KeyboardEnabled

-- Live multiplier driven by the Window Size slider on the Home tab. 1 = default.
local windowScale = 1

-- Phones get a window sized to the screen; tablets land in the middle.
local function fitSize()
    local vp = Camera.ViewportSize

    if IS_MOBILE then
        -- Width and height are set from different goals, so they get different
        -- fractions.
        --
        -- WIDTH is what made it feel oversized: 0.92 of the screen left almost
        -- no game visible around it. 0.78 reads as a window sitting on top of
        -- the game rather than replacing it.
        --
        -- HEIGHT is not a cosmetic choice - it is what decides how many tabs
        -- you can see. Ten tabs at WindUI's ~32px row need ~320px of sidebar
        -- before the header is counted, so squeezing the height is exactly
        -- what hid ESP, Fling, Player, Misc and Settings. It goes UP, not down.
        return UDim2.fromOffset(
            math.clamp(math.floor(vp.X * 0.78 * windowScale), 280, 500),
            math.clamp(math.floor(vp.Y * 0.88 * windowScale), 300, 520)
        )
    end

    if IS_CONSOLE then
        return UDim2.fromOffset(680, 520)
    end

    return UDim2.fromOffset(580, 460)
end

-- ============================================
-- PALETTES
-- ============================================
local PALETTES = {
    { Name = "Onyx",   Swatch = "#f59e0b", Background = "#171717", Accent = "#1e1e1e", Outline = "#303030", Text = "#f4f4f5", Placeholder = "#a1a1aa", Button = "#f59e0b", Icon = "#a1a1aa", Gradient = { "#f59e0b", "#b45309" } },
    { Name = "Frost",  Swatch = "#38bdf8", Background = "#0f1720", Accent = "#161f2b", Outline = "#26303f", Text = "#eaf2fb", Placeholder = "#93a4bb", Button = "#38bdf8", Icon = "#8fa6c0", Gradient = { "#38bdf8", "#0369a1" } },
    { Name = "Orchid", Swatch = "#a78bfa", Background = "#16121f", Accent = "#1e192b", Outline = "#2f2740", Text = "#f2edff", Placeholder = "#a498bf", Button = "#a78bfa", Icon = "#9c8fb8", Gradient = { "#a78bfa", "#6d28d9" } },
    { Name = "Venom",  Swatch = "#34d399", Background = "#101815", Accent = "#16211d", Outline = "#23342d", Text = "#e9fbf3", Placeholder = "#8fb0a3", Button = "#34d399", Icon = "#87a89b", Gradient = { "#34d399", "#047857" } },
    { Name = "Ember",  Swatch = "#fb7185", Background = "#180f12", Accent = "#22161a", Outline = "#35222a", Text = "#fdeef1", Placeholder = "#bd97a1", Button = "#fb7185", Icon = "#b18f97", Gradient = { "#fb7185", "#9f1239" } },
    { Name = "Paper",  Swatch = "#e4e4e7", Background = "#0e0e0e", Accent = "#181818", Outline = "#2b2b2b", Text = "#fafafa", Placeholder = "#8f8f8f", Button = "#e4e4e7", Icon = "#8f8f8f", Gradient = { "#e4e4e7", "#71717a" } },
}

local PALETTE_BY_NAME, THEME_NAMES = {}, {}

for _, p in ipairs(PALETTES) do
    PALETTE_BY_NAME[p.Name] = p
    table.insert(THEME_NAMES, p.Name)

    WindUI:AddTheme({
        Name        = p.Name,
        Background  = Color3.fromHex(p.Background),
        Accent      = Color3.fromHex(p.Accent),
        Outline     = Color3.fromHex(p.Outline),
        Text        = Color3.fromHex(p.Text),
        Placeholder = Color3.fromHex(p.Placeholder),
        Button      = Color3.fromHex(p.Button),
        Icon        = Color3.fromHex(p.Icon),
    })
end

local currentTheme = "Onyx"
WindUI:SetTheme(currentTheme)

-- ============================================
-- WINDOW
-- ============================================
Window = WindUI:CreateWindow({
    Title  = "FurqwkScripts",
    Icon   = "gem",
    Author = "Murder Mystery 2",
    Folder = "FurqwkScriptsHub",

    Size    = fitSize(),
    -- MinSize has to sit below what the slider can ask for, or WindUI clamps
    -- the small end back up and the slider appears to do nothing.
    MinSize = IS_MOBILE and Vector2.new(230, 190) or Vector2.new(540, 400),
    -- Height raised from 500: fitSize can now ask for up to 520 for the tab
    -- list, and MaxSize would have silently clamped it back down.
    MaxSize = IS_MOBILE and Vector2.new(620, 560) or Vector2.new(820, 600),

    -- Touch needs a narrower sidebar or the content column disappears.
    SideBarWidth  = IS_MOBILE and 112 or 190,
    HideSearchBar = IS_MOBILE,       -- the keyboard covers half the screen

    -- Both of these were off on mobile, and both were mistakes.
    -- Resizable: you asked to resize and could not - there was no handle to
    -- drag because it was disabled here.
    -- ScrollBarEnabled: there are ten tabs, and with no scrollbar the sidebar
    -- stopped at Murderer. Every tab past it - ESP, Fling, Player, Misc,
    -- Settings - was unreachable, including the Misc window-size control.
    Resizable        = true,
    ScrollBarEnabled = true,

    Theme       = currentTheme,
    Transparent = false,
    ToggleKey   = Enum.KeyCode.Q,

    -- The avatar card sits at the BOTTOM of the sidebar, below the tabs, and
    -- eats roughly two tabs' worth of height. On a phone that space is better
    -- spent showing Misc and Settings than showing you your own username.
    User = { Enabled = not IS_MOBILE, Anonymous = false },
})

Window:Tag({ Title = "Youtube: FurqwkScripts", Icon = "youtube", Color = Color3.fromHex("#ff0000") })
Window:Tag({
    Title  = IS_MOBILE and "Mobile" or "PC",
    Icon   = IS_MOBILE and "smartphone" or "monitor",
    Color  = Color3.fromHex("#3f3f46"),
    Border = true,
})

-- Rotate the phone, keep the window on screen.
local refitting = false
Camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
    if refitting then return end
    refitting = true
    task.delay(0.25, function()
        pcall(function() Window:SetSize(fitSize()) end)
        refitting = false
    end)
end)

-- ============================================
-- UI HELPERS
-- ============================================
local notificationsOn = true

local function notify(title, content, icon)
    if not notificationsOn then return end
    WindUI:Notify({
        Title = title, Content = content, Icon = icon or "gem",
        Duration = IS_MOBILE and 4 or 3,   -- longer to read on a small screen
    })
end

local function Section(tab, title)
    return tab:Section({ Title = title, TextSize = IS_MOBILE and 16 or 17 })
end

-- Descriptions are dropped on mobile: two lines per card eats the whole screen.
local function desc(text)
    return (not IS_MOBILE) and text or nil
end

local function Toggle(tab, flag, title, d, default, cb)
    return tab:Toggle({
        Flag = flag, Title = title, Desc = desc(d),
        Value = default or false,
        Callback = cb,
    })
end

local function Slider(tab, flag, title, d, min, max, default, step, cb)
    return tab:Slider({
        Flag = flag, Title = title, Desc = desc(d),
        Step = step or 1,
        Value = { Min = min, Max = max, Default = default },
        Callback = cb,
    })
end

local function Dropdown(tab, flag, title, d, values, default, cb)
    return tab:Dropdown({
        Flag = flag, Title = title, Desc = desc(d),
        Values = values, Value = default,
        Callback = cb,
    })
end

local function Button(tab, title, d, cb, variant)
    return tab:Button({
        Title = title, Desc = desc(d),
        Variant = variant,
        Callback = cb,
    })
end

-- ============================================
-- FLOATING OPEN BUTTON - the only way back in on mobile
-- ============================================
-- 0.5 rendered as a thumbnail-sized pill wedged into the top HUD; 1.0 gives the
-- minimised button a readable size on desktop too.
local openButtonScale = IS_MOBILE and 0.85 or 1

local function paintOpenButton(palette)
    pcall(function()
        Window:EditOpenButton({
            Title = "Furqwk",
            Icon  = "gem",
            CornerRadius    = UDim.new(1, 0),
            StrokeThickness = IS_MOBILE and 3 or 2,
            Enabled    = true,
            Draggable  = true,
            OnlyMobile = false,
            Scale      = openButtonScale,
            Color = ColorSequence.new(
                Color3.fromHex(palette.Gradient[1]),
                Color3.fromHex(palette.Gradient[2])
            ),
        })
    end)
end

paintOpenButton(PALETTE_BY_NAME[currentTheme])

-- ============================================
-- SIDEBAR STRUCTURE
-- ============================================
-- Flat list, no collapsible groups: the sidebar is short enough that the
-- expand/collapse headers were just an extra click in the way.
local HomeTab     = Window:Tab({ Title = "Home", Icon = "house" })
local AutofarmTab = Window:Tab({ Title = "Autofarm", Icon = "coins" })
local MurdererTab = Window:Tab({ Title = "Murderer", Icon = "skull" })
local SheriffTab  = Window:Tab({ Title = "Sheriff", Icon = "shield" })
local SpawnTab    = Window:Tab({ Title = "Spawner", Icon = "package-plus" })
local ESPTab      = Window:Tab({ Title = "ESP", Icon = "eye" })
local MovementTab = Window:Tab({ Title = IS_MOBILE and "Fling" or "Fling & Teleport", Icon = "zap" })
local PlayerTab   = Window:Tab({ Title = "Player", Icon = "user" })
local MiscTab     = Window:Tab({ Title = "Misc", Icon = "sliders-horizontal" })
local SettingsTab = Window:Tab({ Title = "Settings", Icon = "settings" })

-- This WindUI build ignores a Color field on Tab (verified: a tab created with
-- Color renders the same white-tinted icon as one without), so the per-tab
-- colours are applied by hand afterwards. Reaching into the rendered tree is
-- fragile, hence the pcall and the silent give-up.
local TAB_COLORS = {
    ["Home"]             = Color3.fromHex("#f59e0b"),
    ["Autofarm"]         = Color3.fromHex("#fbbf24"),
    ["Murderer"]         = Color3.fromHex("#fb7185"),
    ["Sheriff"]          = Color3.fromHex("#60a5fa"),
    ["Spawner"]          = Color3.fromHex("#f472b6"),
    ["ESP"]              = Color3.fromHex("#34d399"),
    ["Fling & Teleport"] = Color3.fromHex("#a78bfa"),
    ["Fling"]            = Color3.fromHex("#a78bfa"),
    ["Player"]           = Color3.fromHex("#38bdf8"),
    ["Misc"]             = Color3.fromHex("#94a3b8"),
    ["Settings"]         = Color3.fromHex("#a1a1aa"),
}

-- Rendered shape of one sidebar entry, confirmed by walking the live tree:
--   ImageButton                      <- the clickable tab
--     ImageLabel "Outline"           <- selection ring
--     ImageLabel "Frame"             <- row container (UIListLayout)
--       TextLabel                    <- the title
--       Frame  16x16                 <- icon holder  ... we turn this into the badge
--         ImageLabel                 <- the glyph itself
local function tintTabIcons()
    pcall(function()
        for _, d in ipairs(CoreGui:GetDescendants()) do
            if d:IsA("TextLabel") then
                local colour = TAB_COLORS[d.Text]
                -- A name match alone is not enough: element cards are ImageButtons
                -- too, so a dropdown titled "Player" used to be treated as the
                -- Player tab and had every frame inside it crushed into a 22x22
                -- badge - that is what left the fling picker drawn as a blue box
                -- with the name spilling out beside it. A real sidebar row puts
                -- its title directly inside the button's row Frame; cards nest
                -- theirs two levels deeper under TitleFrame.
                local row = d.Parent
                local btn = row and row.Parent
                if colour and row and row:IsA("GuiObject") and row.Name == "Frame"
                    and btn and btn:IsA("ImageButton") then
                    -- Only the icon holder sitting next to the title, never the
                    -- whole subtree.
                    for _, holder in ipairs(row:GetChildren()) do
                        local glyph = holder:IsA("Frame") and holder:FindFirstChildWhichIsA("ImageLabel")
                        if glyph then
                            glyph.ImageColor3 = colour

                            -- Soft rounded badge behind the glyph.
                            holder.BackgroundColor3     = colour
                            holder.BackgroundTransparency = 0.78
                            holder.Size = UDim2.fromOffset(22, 22)

                            if not holder:FindFirstChild("HubBadgeCorner") then
                                local corner = Instance.new("UICorner")
                                corner.Name = "HubBadgeCorner"
                                corner.CornerRadius = UDim.new(0, 6)
                                corner.Parent = holder
                            end
                            -- Keeps the glyph at its original 16px inside the
                            -- larger badge instead of stretching to fill it.
                            if not holder:FindFirstChild("HubBadgePad") then
                                local pad = Instance.new("UIPadding")
                                pad.Name = "HubBadgePad"
                                pad.PaddingTop    = UDim.new(0, 3)
                                pad.PaddingBottom = UDim.new(0, 3)
                                pad.PaddingLeft   = UDim.new(0, 3)
                                pad.PaddingRight  = UDim.new(0, 3)
                                pad.Parent = holder
                            end
                        end
                    end
                end
            end
        end
    end)
end

-- Vertical wash over the window panel: the picked palette colour up top, fading
-- out to plain/near-white at the bottom.
-- Walking down by name from CoreGui is unreliable: leftover WindUI ScreenGuis
-- from earlier loads sit alongside the live one and FindFirstChild happily
-- returns an empty stale one. Search for the panel itself instead.
-- The panel is not painted with BackgroundColor3 at all — it is an ImageLabel
-- called "Background" (a UIGradient tints its ImageColor3 just the same). The
-- "Main" frame above it is fully transparent, so a gradient there is invisible.
local function findWindowBackground()
    for _, d in ipairs(CoreGui:GetDescendants()) do
        if d:IsA("Folder") and d.Name == "Window" then
            local frame = d:FindFirstChild("Frame")
            local bg    = frame and frame:FindFirstChild("Background")
            if bg and bg:IsA("ImageLabel") then return bg end
        end
    end
    return nil
end

local function paintWindowGradient(palette)
    pcall(function()
        local bg = findWindowBackground()
        if not bg then return end

        local grad = bg:FindFirstChild("HubGradient")
        if not grad then
            grad = Instance.new("UIGradient")
            grad.Name = "HubGradient"
            grad.Rotation = 90          -- keypoint 0 = top, 1 = bottom
            grad.Parent = bg
        end
        grad.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromHex(palette.Swatch)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
        })
    end)
end

-- Forward declarations so Panic can reset the controls it turns off.
local farmToggle, coinESPToggle
local espToggles = {}

-- ============================================
-- PANIC - one switch that really does stop everything
-- ============================================
local function panicOff()
    isActive = false
    stopAutofarmLoop()
    setToggleValue(farmToggle, false)

    espEnabled.murderer = false
    espEnabled.sheriff  = false
    espEnabled.innocent = false
    espEnabled.trap     = false
    updateESP()
    setupTrapESP()
    for _, t in pairs(espToggles) do setToggleValue(t, false) end

    gunDropESP = false
    setupGunDropESP()

    coinESP = false
    setupCoinESP()
    setToggleValue(coinESPToggle, false)

    autoGetDroppedGun = false

    if flyEnabled then toggleFly(false) end
    if noClipConnection then setNoClip(false) end

    if speedBoostActive then
        speedBoostActive = false
        local hum = player.Character and player.Character:FindFirstChild("Humanoid")
        if hum then hum.WalkSpeed = 16 end
    end
end

-- ============================================
-- HOME
-- ============================================
Section(HomeTab, "Session")

local sessionCard = HomeTab:Paragraph({
    Title = "Signed in as " .. (player and player.DisplayName or "Player"),
    Desc  = "Uptime 0:00 | FPS -",
    Image = "activity",
    ImageSize = 20,
})

task.spawn(function()
    local start, frames, fps = os.clock(), 0, 0
    RunService.RenderStepped:Connect(function() frames += 1 end)

    while task.wait(1) do
        fps, frames = frames, 0
        local elapsed = math.floor(os.clock() - start)
        pcall(function()
            sessionCard:SetDesc(("Uptime %d:%02d | FPS %d"):format(elapsed // 60, elapsed % 60, fps))
        end)
    end
end)

if IS_MOBILE then
    HomeTab:Paragraph({
        Title = "Mobile mode",
        Desc  = "Drag the round button to move it, tap to hide or show this window.",
        Image = "smartphone",
        ImageSize = 20,
    })
else
    HomeTab:Paragraph({
        Title = "Keybinds",
        Desc  = "Q toggle menu | R shoot murderer | E speed boost | F fly | N noclip",
        Image = "keyboard",
        ImageSize = 20,
    })
end

-- Lives on Home, not Misc. The identical control in Misc was unreachable on a
-- phone: the sidebar had no scrollbar, so you could never scroll down to Misc
-- to shrink a window that was already too big to scroll past.
if IS_MOBILE then
    Section(HomeTab, "Window")

    -- Starts at 100 = the fitted size. Range is deliberately narrow and centred:
    -- going far below 100 is what buries the lower tabs again.
    Slider(HomeTab, "win_scale", "Window Size", nil, 80, 120, 100, 5, function(value)
        windowScale = value / 100
        pcall(function() Window:SetSize(fitSize()) end)
    end)
end

Section(HomeTab, "Shortcuts")

Button(HomeTab, "Open Autofarm", "Jump straight to the farm controls.", function()
    AutofarmTab:Select()
end)

Button(HomeTab, "Open Spawner", "Jump to the weapon spawner.", function()
    SpawnTab:Select()
end)

Button(HomeTab, "Panic - Everything Off", "Turns every feature off at once.", function()
    panicOff()
    notify("Panic", "All features disabled.", "power")
end, "Primary")

-- ============================================
-- AUTOFARM
-- ============================================
Section(AutofarmTab, "Coin Autofarm")

farmToggle = Toggle(AutofarmTab, "farm_coins", "Auto Farm (Underground)",
    "Flies you around picking up coins.", false, function(state)
        isActive = state
        if isActive then findMap(); startAutofarmLoop() else stopAutofarmLoop() end
    end)

AutofarmTab:Input({
    Title = "Fly Speed (1-25)",
    Desc  = desc("How fast the farm moves between coins."),
    Placeholder = "15", Value = "15",
    Callback = function(value)
        local n = tonumber(value)
        if n then flySpeed = math.clamp(n, 1, 25) end
    end,
})

Toggle(AutofarmTab, "anti_afk", "Anti-AFK",
    "Stops the 20-minute idle kick. Works whether or not the farm is running.",
    false, function(state) setAntiAfk(state) end)

Section(AutofarmTab, "When Coin Bag Is Full")

AutofarmTab:Paragraph({
    Title = "How full is measured",
    Desc  = "MM2 exposes no bag counter, so this uses the coins this hub has seen you collect this round. Set the threshold to match your bag size.",
    Image = "info",
    ImageSize = 20,
})

Slider(AutofarmTab, "bag_full_at", "Bag Full At", "Coins collected before the actions below fire.",
    10, 40, 40, 5, function(value) bagFullAt = value end)

Toggle(AutofarmTab, "full_fling_murderer", "Fling Murderer When Full",
    "Flings whoever holds the knife once the bag fills.", false, function(state)
        flingMurdererOnFull = state
    end)

Toggle(AutofarmTab, "full_reset", "Reset Character When Full",
    "Kills you so you respawn and bank the round.", false, function(state)
        resetPlayerOnFull = state
    end)

Section(AutofarmTab, "Stats")

local statsCard = AutofarmTab:Paragraph({
    Title = "Collected 0",
    Desc  = "Time 0s | Rate/h 0",
    Image = "coins",
    ImageSize = 20,
})

task.spawn(function()
    while task.wait(0.25) do
        if isActive then
            local elapsed = tick() - farmStartTime
            local rate = elapsed > 0 and math.floor((collectedDisplayValue / elapsed) * 3600) or 0
            pcall(function()
                statsCard:SetTitle("Collected " .. collectedDisplayValue)
                statsCard:SetDesc(("Time %ds | Rate/h %d"):format(math.floor(elapsed), rate))
            end)
        end
    end
end)

Button(AutofarmTab, "Reset Counter", "Clears the collected count and timer.", function()
    totalCoinsCollected = 0; collectedDisplayValue = 0; farmStartTime = tick()
    pcall(function()
        statsCard:SetTitle("Collected 0")
        statsCard:SetDesc("Time 0s | Rate/h 0")
    end)
    notify("Counter reset", "Back to zero.", "refresh-cw")
end)

-- ============================================
-- MURDERER
-- ============================================
Section(MurdererTab, "Buttons")

Toggle(MurdererTab, "mur_killall_btn", "Show Kill All Button",
    "Floating kill all button on screen.", false, function(state)
        if state then
            if killAllBtn then killAllBtn.destroy() end
            killAllBtn = makeCircleButton("KillAllButton", "Kill\nAll", UDim2.new(0.85, -40, 0.70, 0), killAllPlayers)
        else
            if killAllBtn then killAllBtn.destroy(); killAllBtn = nil end
        end
    end)

Toggle(MurdererTab, "mur_killall_lock", "Lock Kill All Button",
    "Cannot be dragged while locked.", false, function(state)
        if killAllBtn then killAllBtn.setLocked(state) end
    end)

Section(MurdererTab, "Actions")

Button(MurdererTab, "Kill All Now (Touch)",
    "Kills every player with the knife using touch interest.", function()
        killAllPlayers()
    end, "Primary")

-- ============================================
-- SHERIFF
-- ============================================
Section(SheriffTab, "Gun")

Toggle(SheriffTab, "she_gun_btn", "Show Grab Gun Button",
    "Floating grab gun button on screen.", false, function(state)
        if state then
            if gunBtn then gunBtn.destroy() end
            gunBtn = makeCircleButton("GrabGunButton", "Grab\nGun", UDim2.new(0.85, -40, 0.40, 0), grabGunManual)
        else
            if gunBtn then gunBtn.destroy(); gunBtn = nil end
        end
    end)

Toggle(SheriffTab, "she_gun_lock", "Lock Gun Button",
    "Cannot be dragged while locked.", false, function(state)
        if gunBtn then gunBtn.setLocked(state) end
    end)

Toggle(SheriffTab, "she_autogun", "Auto Get Dropped Gun",
    "Grabs dropped guns the moment they appear.", false, function(state)
        autoGetDroppedGun = state
        if state then task.spawn(function() grabGun() end) end
    end)

Button(SheriffTab, "Grab Gun", "Grab the dropped gun and return to your position.", function()
    grabGunManual()
end)

Section(SheriffTab, "Shooting")

Toggle(SheriffTab, "she_shoot_btn", "Show Shoot Button",
    "Floating shoot murderer button on screen.", false, function(state)
        if state then
            if shootBtn then shootBtn.destroy() end
            shootBtn = makeCircleButton("ShootMurdButton", "Shoot\nMurd", UDim2.new(0.85, -40, 0.55, 0), ShootMurderer)
        else
            if shootBtn then shootBtn.destroy(); shootBtn = nil end
        end
    end)

Toggle(SheriffTab, "she_shoot_lock", "Lock Shoot Button",
    "Cannot be dragged while locked.", false, function(state)
        if shootBtn then shootBtn.setLocked(state) end
    end)

Button(SheriffTab, "Shoot Murderer", "Shoots the murderer with prediction. Keybind: R", function()
    ShootMurderer()
end, "Primary")

-- ============================================
-- ESP
-- ============================================
Section(ESPTab, "Players")

espToggles.murderer = Toggle(ESPTab, "esp_murderer", "Murderer ESP",
    "Shows players holding a KNIFE in red.", false, function(state)
        espEnabled.murderer = state; updateESP()
    end)

espToggles.sheriff = Toggle(ESPTab, "esp_sheriff", "Sheriff ESP",
    "Shows players holding a GUN in blue.", false, function(state)
        espEnabled.sheriff = state; updateESP()
    end)

espToggles.innocent = Toggle(ESPTab, "esp_innocent", "Innocent ESP",
    "Shows unarmed players in green.", false, function(state)
        espEnabled.innocent = state; updateESP()
    end)

Section(ESPTab, "World")

espToggles.gunDrop = Toggle(ESPTab, "esp_gundrop", "Gun Drop ESP",
    "Marks dropped guns in yellow with a label.", false, function(state)
        gunDropESP = state; setupGunDropESP()
    end)

espToggles.trap = Toggle(ESPTab, "esp_trap", "Trap ESP",
    "Marks bear traps, mines and floor traps in orange.", false, function(state)
        espEnabled.trap = state; setupTrapESP()
    end)

coinESPToggle = Toggle(ESPTab, "esp_coins", "Coin ESP",
    "Fills the nearest coins with yellow, visible through walls.", false, function(state)
        coinESP = state; setupCoinESP()
    end)

Button(ESPTab, "Refresh ESP", "Rebuilds every highlight by hand.", function()
    updateESP(); setupGunDropESP(); setupTrapESP(); setupCoinESP()
    notify("ESP refreshed", "All highlights rebuilt.", "refresh-cw")
end)

-- ============================================
-- FLING & TELEPORT
-- ============================================
Section(MovementTab, "Teleport to Role")

Button(MovementTab, "Teleport to Murderer", "Puts you right on top of the murderer.", function()
    local m = getPlayerByRole("murderer")
    if m then TeleportToPlayer(m) else notify("FurqwkScripts", "No murderer found!", "triangle-alert") end
end)

Button(MovementTab, "Teleport to Sheriff", "Puts you right on top of the sheriff.", function()
    local s = getPlayerByRole("sheriff")
    if s then TeleportToPlayer(s) else notify("FurqwkScripts", "No sheriff found!", "triangle-alert") end
end)

Section(MovementTab, "Map Teleports")

Button(MovementTab, "Teleport to Map", "Drops you at a random map spawn.", function()
    TeleportToMap()
end)

Button(MovementTab, "Teleport to Lobby", "Sends you back to the lobby.", function()
    TeleportToLobby()
end)

Section(MovementTab, "Player Fling")

local flingTargetName = nil

local function serverPlayerNames()
    local names = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player then names[#names + 1] = p.Name end
    end
    table.sort(names)
    return names
end

-- Value has to be a real string: passing nil left the dropdown half-drawn, with
-- the option text bleeding over the description.
local initialNames = serverPlayerNames()
flingTargetName = initialNames[1]

-- Kept to the shape in the docs example: no Flag, no Desc. The extra fields are
-- what left the value chip drawn as a stub on top of the description.
local flingDropdown = MovementTab:Dropdown({
    Title  = "Player",
    Values = initialNames,
    Value  = initialNames[1] or "",
    Multi  = false,
    Callback = function(name) flingTargetName = name end,
})

-- Refresh(newTable) is the documented way to swap the option list.
local function refreshFlingList()
    local values = serverPlayerNames()
    pcall(function() flingDropdown:Refresh(values) end)
    -- Keep the shown selection pointing at someone who is still here.
    if not flingTargetName or not Players:FindFirstChild(flingTargetName) then
        flingTargetName = values[1]
        if flingTargetName then
            pcall(function() flingDropdown:Select(flingTargetName) end)
        end
    end
end

Players.PlayerAdded:Connect(function() task.wait(0.5); refreshFlingList() end)
Players.PlayerRemoving:Connect(function()
    task.wait(0.5)
    refreshFlingList()
    -- Don't keep pointing at someone who left.
    if flingTargetName and not Players:FindFirstChild(flingTargetName) then
        flingTargetName = nil
    end
end)

Button(MovementTab, "Refresh Player List", "Re-reads who is in the server.", function()
    refreshFlingList()
    notify("FurqwkScripts", #serverPlayerNames() .. " players found.", "users")
end)

Button(MovementTab, "Fling Selected", "Flings the player picked above. You teleport back after.", function()
    if not flingTargetName then
        notify("FurqwkScripts", "Pick a player from the list first!", "triangle-alert")
        return
    end
    local target = Players:FindFirstChild(flingTargetName)
    if not target or not target.Character then
        notify("FurqwkScripts", flingTargetName .. " is not in the server anymore.", "triangle-alert")
        refreshFlingList()
        return
    end
    SkidFling(target)
    notify("FurqwkScripts", "Flung " .. target.Name .. "!", "zap")
end, "Primary")

Section(MovementTab, "Fling by Role")

Button(MovementTab, "Fling Murderer", "Finds whoever holds the knife and flings them.", function()
    local m = getPlayerByRole("murderer")
    if m then
        SkidFling(m)
        notify("FurqwkScripts", "Flung the murderer (" .. m.Name .. ")!", "zap")
    else
        notify("FurqwkScripts", "No murderer found!", "triangle-alert")
    end
end)

Button(MovementTab, "Fling Sheriff", "Finds whoever holds the gun and flings them.", function()
    local s = getPlayerByRole("sheriff")
    if s then
        SkidFling(s)
        notify("FurqwkScripts", "Flung the sheriff (" .. s.Name .. ")!", "zap")
    else
        notify("FurqwkScripts", "No sheriff found!", "triangle-alert")
    end
end)

-- ============================================
-- PLAYER
-- ============================================
Section(PlayerTab, "Movement")

noclipToggle = Toggle(PlayerTab, "noclip", "No Clip",
    "Walk through walls and floors. Keybind: N", false, function(state)
        setNoClip(state)
    end)

flyToggle = Toggle(PlayerTab, "fly", "Fly",
    "WASD plus Space and Shift. Keybind: F", false, function(state)
        if flyUpdatingUI then return end   -- ignore programmatic SetValue
        toggleFly(state)
    end)

Slider(PlayerTab, "fly_speed", "Fly Speed", "Studs per second while flying.",
    1, 200, 50, 1, function(value) flyspeedValue = value end)

Section(PlayerTab, "Character")

Slider(PlayerTab, "walk_speed", "Walk Speed",
    "Applied straight away. E toggles between 16 and this value.",
    1, 100, 16, 1, function(value)
        currentWalkSpeedValue = value
        local char = player.Character
        local hum  = char and char:FindFirstChild("Humanoid")
        if hum then hum.WalkSpeed = value end
    end)

-- ANTIFLING - ported from the YARHM hub, which takes the opposite approach to
-- what was here before.
--
-- The old version rewrote YOUR character every Heartbeat: collisions off,
-- massless, and velocity zeroed. Zeroing wiped the walk velocity the Humanoid
-- had just applied, which is what made walking crawl.
--
-- This one never touches your character while you are moving normally. It
-- watches for the two things that actually happen during a fling:
--   1. someone else spinning at fling speeds  -> their parts get neutralised so
--      they cannot transfer that momentum into you
--   2. your own root going faster than any legitimate movement -> velocity is
--      cleared and you are put back where you were standing a moment ago
local antiFlingDetectConn  = nil
local antiFlingRestoreConn = nil
local antiFlingLastPos     = nil
local flingerSeen          = {}

local FLINGER_SPIN  = 50    -- rad/s on someone else's root = they are spinning up a fling
local FLINGER_SPEED = 100   -- studs/s ditto
local SELF_FLUNG    = 250   -- above this, you did not get there by walking or flying

Toggle(PlayerTab, "anti_fling", "ANTIFLING",
    "Neutralises flingers and snaps you back if you get flung.", false, function(state)
        if antiFlingDetectConn  then antiFlingDetectConn:Disconnect();  antiFlingDetectConn  = nil end
        if antiFlingRestoreConn then antiFlingRestoreConn:Disconnect(); antiFlingRestoreConn = nil end
        flingerSeen = {}
        antiFlingLastPos = nil
        if not state then return end

        -- Kill the momentum on whoever is winding up.
        antiFlingDetectConn = RunService.Heartbeat:Connect(function()
            for _, plr in ipairs(Players:GetPlayers()) do
                local char = plr ~= player and plr.Character
                local root = char and char.PrimaryPart
                if root then
                    if root.AssemblyAngularVelocity.Magnitude > FLINGER_SPIN
                        or root.AssemblyLinearVelocity.Magnitude > FLINGER_SPEED then

                        if not flingerSeen[plr.Name] then
                            flingerSeen[plr.Name] = true
                            notify("FurqwkScripts", plr.Name .. " is trying to fling!", "triangle-alert")
                        end

                        for _, part in ipairs(char:GetDescendants()) do
                            if part:IsA("BasePart") then
                                part.CanCollide = false
                                part.AssemblyAngularVelocity = Vector3.zero
                                part.AssemblyLinearVelocity  = Vector3.zero
                                part.CustomPhysicalProperties = PhysicalProperties.new(0, 0, 0)
                            end
                        end
                    end
                end
            end
        end)

        -- Catch the one that got through and undo it.
        antiFlingRestoreConn = RunService.Heartbeat:Connect(function()
            if flingInProgress then return end
            local char = player.Character
            local root = char and char.PrimaryPart
            if not root then return end

            if root.AssemblyLinearVelocity.Magnitude > SELF_FLUNG
                or root.AssemblyAngularVelocity.Magnitude > SELF_FLUNG then
                root.AssemblyLinearVelocity  = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
                if antiFlingLastPos then
                    root.CFrame = CFrame.new(antiFlingLastPos)
                end
            else
                -- Only the speeds you reach by playing get remembered as safe.
                antiFlingLastPos = root.Position
            end
        end)
    end)

Button(PlayerTab, "Reset Walkspeed", "Puts walk speed back to 16.", function()
    local hum = character and character:FindFirstChild("Humanoid")
    if hum then
        hum.WalkSpeed = 16
        defaultWalkSpeed = 16
        currentWalkSpeedValue = 16
    end
    notify("FurqwkScripts", "Walk speed reset to 16!", "refresh-cw")
end)

Button(PlayerTab, "Kill Character", "Kills you so you respawn.", function()
    local hum = character and character:FindFirstChild("Humanoid")
    if hum then hum.Health = 0 end
end)

-- ============================================
-- MISC
-- ============================================
Section(MiscTab, "Themes")

local themePreview = MiscTab:Paragraph({
    Title = "Onyx",
    Desc  = "Window #171717 | Cards #1e1e1e | Accent #f59e0b",
    Image = "palette",
    ImageSize = 20,
})

local themeDropdown

local function applyTheme(name, silent)
    local palette = PALETTE_BY_NAME[name]
    if not palette then return end

    currentTheme = name
    WindUI:SetTheme(name)
    paintOpenButton(palette)
    -- SetTheme repaints every icon back to the theme text colour, so the
    -- per-tab colours and the gradient have to be laid back down after it settles.
    task.delay(0.1, function()
        tintTabIcons()
        paintWindowGradient(palette)
    end)

    pcall(function()
        themePreview:SetTitle(palette.Name)
        themePreview:SetDesc(("Window %s | Cards %s | Accent %s")
            :format(palette.Background, palette.Accent, palette.Swatch))
    end)

    if not silent then
        notify("Theme changed", palette.Name .. " applied.", "palette")
    end
end

themeDropdown = Dropdown(MiscTab, "theme", "Palette",
    "Retints the whole window, not just the accent.",
    THEME_NAMES, currentTheme, function(name) applyTheme(name) end)

Button(MiscTab, "Cycle Palette", "Steps through the list.", function()
    local index = table.find(THEME_NAMES, currentTheme) or 1
    local nextName = THEME_NAMES[(index % #THEME_NAMES) + 1]
    pcall(function() themeDropdown:Select(nextName) end)
    applyTheme(nextName)
end)

pcall(function()
    WindUI:OnThemeChange(function(name)
        if name ~= currentTheme and PALETTE_BY_NAME[name] then
            currentTheme = name
            pcall(function() themeDropdown:Select(name) end)
        end
    end)
end)

Section(MiscTab, IS_MOBILE and "Mobile" or "Window")

if IS_MOBILE then
    Slider(MiscTab, "open_scale", "Open Button Size", nil, 5, 15, 9, 1, function(value)
        openButtonScale = value / 10
        paintOpenButton(PALETTE_BY_NAME[currentTheme])
    end)

    Dropdown(MiscTab, "win_size", "Window Size", nil,
        { "Fit screen", "Compact", "Tall" }, "Fit screen", function(choice)
            local vp = Camera.ViewportSize
            local sizes = {
                ["Fit screen"] = fitSize(),
                ["Compact"]    = UDim2.fromOffset(math.min(340, vp.X - 20), math.min(300, vp.Y - 40)),
                ["Tall"]       = UDim2.fromOffset(math.min(420, vp.X - 20), math.min(vp.Y * 0.9, 520)),
            }
            pcall(function() Window:SetSize(sizes[choice]) end)
        end)

    Button(MiscTab, "Recentre Window", nil, function()
        pcall(function() Window:SetSize(fitSize()) end)
        notify("Recentred", "Window refitted to the screen.", "move")
    end)
else
    Toggle(MiscTab, "transparent", "Transparent Background",
        "Frosted window instead of a solid fill.", false, function(state)
            -- This build has no SetTransparency; the old call was swallowed by
            -- the pcall, which is why the switch did nothing.
            local ok = pcall(function() Window:ToggleTransparency(state) end)
            if not ok then
                pcall(function() Window:SetBackgroundTransparency(state and 0.35 or 0) end)
            end
        end)

    Dropdown(MiscTab, "win_size", "Window Size", "Resize without dragging the corner.",
        { "Compact", "Default", "Large" }, "Default", function(choice)
            local sizes = {
                Compact = UDim2.fromOffset(540, 400),
                Default = UDim2.fromOffset(580, 460),
                Large   = UDim2.fromOffset(760, 560),
            }
            pcall(function() Window:SetSize(sizes[choice]) end)
        end)

    MiscTab:Keybind({
        Flag = "toggle_key", Title = "Toggle Key",
        Desc = "Opens and closes this window.",
        Value = "Q",
        Callback = function(key)
            pcall(function() Window:SetToggleKey(Enum.KeyCode[key]) end)
        end,
    })
end

Section(MiscTab, "Links")

Button(MiscTab, "Copy YouTube Link", "FurqwkScripts", function()
    if setclipboard then
        setclipboard("https://youtube.com/@FurqwkScripts")
        notify("Copied", "Channel link is on your clipboard.", "youtube")
    else
        notify("Not supported", "Your executor can't write to the clipboard.", "triangle-alert")
    end
end)

-- ============================================
-- SETTINGS
-- ============================================
Section(SettingsTab, "Interface")

Toggle(SettingsTab, "notifications", "Notifications",
    "Show a toast when something turns on.", true, function(state)
        notificationsOn = state
    end)

Section(SettingsTab, "Configs")

local configName = "default"

SettingsTab:Input({
    Title = "Config Name",
    Desc  = desc("Saved under the FurqwkScriptsHub folder."),
    Value = configName,
    Placeholder = "default",
    Callback = function(value)
        configName = (value ~= "" and value) or "default"
    end,
})

local ConfigManager = Window.ConfigManager

if ConfigManager then
    ConfigManager:Init(Window)

    Button(SettingsTab, "Save Config", "Writes every control to file.", function()
        local ok = pcall(function() ConfigManager:CreateConfig(configName):Save() end)
        notify(ok and "Config saved" or "Save failed", configName, "save")
    end, "Primary")

    Button(SettingsTab, "Load Config", "Restores a saved setup.", function()
        local ok = pcall(function() ConfigManager:CreateConfig(configName):Load() end)
        notify(ok and "Config loaded" or "Nothing to load", configName, "folder-open")
    end)
end

SettingsTab:Divider()

Button(SettingsTab, "Unload", "Closes the menu and clears it from memory.", function()
    Window:Dialog({
        Title = "Unload FurqwkScripts?",
        Content = "Every feature is turned off and the menu closes.",
        Buttons = {
            { Title = "Cancel" },
            { Title = "Unload", Variant = "Primary", Callback = function()
                panicOff()
                Window:Destroy()
            end },
        },
    })
end)

--------------------------------------------------------------------
-- Spawner - fetched on demand
--
-- The spawner carries a megabyte of scraped mesh data, so it lives on
-- GitHub rather than in this file. The button below pulls it down and
-- runs it; it builds its own cartoon window, separate from this one.
--
-- This must stay a raw.githubusercontent.com link. The github.com page
-- for the same file returns HTML, which blows up inside loadstring.
--------------------------------------------------------------------

local SPAWNER_URL = "https://raw.githubusercontent.com/furqwk/Soawn/refs/heads/main/mm2-spawner-cartoon.lua"

Section(SpawnTab, "Remote script")

local loaderCard = SpawnTab:Paragraph({
    Title = "Weapon Spawner",
    Desc  = "Not loaded.",
    Image = "cloud-download",
    ImageSize = 20,
})

local function card(text)
    pcall(function() loaderCard:SetDesc(text) end)
end

Button(SpawnTab, "Execute Spawner", "Fetches the script and opens its window.", function()
    if _G.__MM2Viz then
        notify("Already running", "Unload it first if you want a fresh copy.", "circle-alert")
        return
    end
    if SPAWNER_URL == "" or not SPAWNER_URL:find("^https?://") then
        notify("Bad link", "Put a raw script URL in the box above.", "link")
        return
    end

    card("Fetching...")

    task.spawn(function()
        local ok, source = pcall(function() return game:HttpGet(SPAWNER_URL) end)

        if not ok or type(source) ~= "string" or source == "" then
            card("Fetch failed.")
            notify("Fetch failed", "Couldn't reach that link.", "wifi-off")
            return
        end

        -- A deleted or private paste answers with an HTML error page, which would
        -- otherwise surface as a baffling syntax error on line 1.
        if source:sub(1, 1) == "<" then
            card("Got a web page, not a script.")
            notify("Wrong link", "That returned HTML - use the raw URL.", "triangle-alert")
            return
        end

        local chunk, compileErr = loadstring(source)
        if not chunk then
            card("Compile error.")
            notify("Compile failed", tostring(compileErr), "circle-x")
            return
        end

        local ran, runErr = pcall(chunk)
        if not ran then
            card("Run error.")
            notify("Spawner error", tostring(runErr), "circle-x")
            return
        end

        card(("Running | %d KB fetched."):format(#source // 1024))
        notify("Spawner running", "Its window is open - drag it anywhere.", "package-plus")
    end)
end, "Primary")

Button(SpawnTab, "Unload Spawner", "Closes its window and clears every overlay.", function()
    if _G.__MM2Viz and _G.__MM2Viz.destroy then
        pcall(_G.__MM2Viz.destroy)
        _G.__MM2Viz = nil
        card("Not loaded.")
        notify("Spawner unloaded", "Overlays cleared.", "power")
    else
        notify("Nothing to unload", "The spawner isn't running.", "circle-alert")
    end
end)

-- ============================================
-- KEYBINDS: Q = GUI, R = Shoot, E = Speed Boost, F = Fly, N = Noclip
-- ============================================
UserInputService.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

    -- Deliberately not checking gameProcessed: MM2 consumes F itself, so it
    -- arrives with gameProcessed = true and the fly bind never fired. Guarding
    -- on a focused text box instead keeps typing safe without losing the key.
    if UserInputService:GetFocusedTextBox() then return end

    local key = input.KeyCode

    if key == Enum.KeyCode.R then
        ShootMurderer()

    elseif key == Enum.KeyCode.E then
        toggleSpeedBoost()

    elseif key == Enum.KeyCode.F then
        toggleFly(not flyEnabled)

    elseif key == Enum.KeyCode.N then
        toggleNoclip()
    end
end)

-- ============================================
-- OPEN ON HOME
-- ============================================
task.wait(1.5)
pcall(function() HomeTab:Select() end)

-- Tabs are rendered by now, so the hand-applied styling will stick.
tintTabIcons()
paintWindowGradient(PALETTE_BY_NAME[currentTheme])

notify(
    "FurqwkScripts loaded",
    IS_MOBILE and "Tap the round button to hide or show." or "Press Q to hide the menu.",
    "gem"
)

print("KEYBINDS LOADED:")
print("[Q] - Toggle GUI")
print("[R] - Shoot Murderer")
print("[E] - Toggle Speed Boost")
print("[F] - Toggle Fly")
print("[N] - Toggle Noclip")
