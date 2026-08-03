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

local gunBtn   = nil
local shootBtn = nil
local killAllBtn = nil

local autoKillEnabled = false
local autoKillThread  = nil
local autoKillTouchThread = nil

local noClipConnection = nil
local flyEnabled = false
local flyConnection = nil
local flyspeedValue = 50

-- ============================================
-- CHARACTER RESET
-- ============================================
pcall(function()
    player.CharacterAdded:Connect(function(char)
        character = char
        rootPart  = char:WaitForChild("HumanoidRootPart")
    end)
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
local function setNoClip(enabled)
    if enabled then
        if not noClipConnection then
            noClipConnection = RunService.Heartbeat:Connect(function()
                if character then
                    for _, v in next, character:GetDescendants() do
                        if v:IsA("BasePart") then v.CanCollide = false end
                    end
                end
            end)
        end
    else
        if noClipConnection then noClipConnection:Disconnect(); noClipConnection = nil end
        if character then
            for _, v in next, character:GetDescendants() do
                if v:IsA("BasePart") then v.CanCollide = true end
            end
        end
    end
end

-- FLY FUNCTION
local function toggleFly(state)
    flyEnabled = state
    if flyConnection then
        flyConnection:Disconnect()
        flyConnection = nil
    end
    if state then
        local hrp = rootPart
        local humanoid = character:FindFirstChild("Humanoid")
        if humanoid then
            humanoid.PlatformStand = true
        end
        flyConnection = RunService.Heartbeat:Connect(function()
            if not hrp or not flyEnabled then return end
            local camera = workspace.CurrentCamera
            if not camera then return end
            local forward = camera.CFrame.LookVector * flyspeedValue
            local right = camera.CFrame.RightVector * flyspeedValue
            local up = Vector3.new(0, flyspeedValue, 0)
            
            local vel = Vector3.new(0, 0, 0)
            if UserInputService:IsKeyDown(Enum.KeyCode.W) then vel = vel + forward end
            if UserInputService:IsKeyDown(Enum.KeyCode.S) then vel = vel - forward end
            if UserInputService:IsKeyDown(Enum.KeyCode.A) then vel = vel - right end
            if UserInputService:IsKeyDown(Enum.KeyCode.D) then vel = vel + right end
            if UserInputService:IsKeyDown(Enum.KeyCode.Space) then vel = vel + up end
            if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then vel = vel - up end
            hrp.Velocity = vel
        end)
    else
        local humanoid = character:FindFirstChild("Humanoid")
        if humanoid then
            humanoid.PlatformStand = false
        end
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
local function isTrap(obj)
    local n = obj.Name:lower()
    return n:find("trap") or n:find("beartrap") or n:find("bear_trap") or n:find("mine") or n:find("landmine")
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
local function createFullBodyESP(playerObj, color)
    if not playerObj or not playerObj.Character then return nil end
    local char = playerObj.Character
    for _, v in ipairs(char:GetChildren()) do if v:IsA("Highlight") then v:Destroy() end end
    local h = Instance.new("Highlight")
    h.FillColor = color; h.FillTransparency = 0.15
    h.OutlineColor = color; h.OutlineTransparency = 0
    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop; h.Parent = char
    return h
end

local function updateESP()
    for _, h in pairs(espHighlights) do if h and h.Parent then h:Destroy() end end
    espHighlights = {}
    if not espEnabled.murderer and not espEnabled.sheriff and not espEnabled.innocent then return end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= player and plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") then
            local role = getRoleFromBackpack(plr)
            local color
            if role == "murderer" and espEnabled.murderer then color = Color3.fromRGB(255,0,0)
            elseif role == "sheriff" and espEnabled.sheriff then color = Color3.fromRGB(0,100,255)
            elseif role == "innocent" and espEnabled.innocent then color = Color3.fromRGB(0,255,0)
            end
            if color then
                local h = createFullBodyESP(plr, color)
                if h then espHighlights[plr] = h end
            end
        end
    end
end

pcall(function()
    Players.PlayerRemoving:Connect(function(plr)
        if espHighlights[plr] then espHighlights[plr]:Destroy(); espHighlights[plr] = nil end
    end)
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
-- CIRCLE BUTTON FACTORY
-- ============================================
local function makeCircleButton(guiName, labelText, defaultPos, onClick)
    local gui = Instance.new("ScreenGui")
    gui.Name = guiName; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.Parent = CoreGui

    local isMobile = UserInputService.TouchEnabled
    local size = isMobile and 70 or 55

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
    outline.Color = Color3.fromRGB(255,255,255); outline.Thickness = 3
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
            if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Gun grabbed!", Duration=2, Icon="check"}) end) end
        else
            gunBtn.flash("No\nGun", Color3.fromRGB(255,80,80))
            if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="No dropped gun found!", Duration=2, Icon="warning"}) end) end
        end
    end
end

-- ============================================
-- MURDERER FUNCTIONS - USING TOUCH INTEREST
-- ============================================
local function equipTool(tool)
    if not tool then return end
    if tool.Parent == player.Backpack then
        local hum = character and character:FindFirstChild("Humanoid")
        if hum then hum:EquipTool(tool); task.wait(0.3) end
    end
end

local function killWithKnifeTouch(targetPlayer)
    if not targetPlayer or not targetPlayer.Character then return false end
    local knife = getKnifeTool()
    if not knife then return false end
    
    equipTool(knife)
    
    local handle = knife:FindFirstChild("Handle") or knife:FindFirstChild("Blade") or knife:FindFirstChildWhichIsA("BasePart")
    if not handle then return false end
    
    local targetHRP = targetPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not targetHRP then return false end
    
    pcall(function() 
        firetouchinterest(handle, targetHRP, 0)
        task.wait(0.05)
        firetouchinterest(handle, targetHRP, 1)
    end)
    
    return true
end

local function killAllWithTouch()
    local knife = getKnifeTool()
    if not knife then
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="No knife found! You are not murderer!", Duration=2, Icon="warning"}) end) end
        return 0
    end
    
    local killed = 0
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= player and plr.Character then
            local hum = plr.Character:FindFirstChild("Humanoid")
            if hum and hum.Health > 0 then
                local success = killWithKnifeTouch(plr)
                if success then killed = killed + 1 end
                task.wait(0.05)
            end
        end
    end
    return killed
end

local function killAllPlayers()
    local killed = killAllWithTouch()
    if WindUI then 
        if killed > 0 then
            pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Killed " .. killed .. " players with touch!", Duration=2, Icon="sword"}) end)
        else
            pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="No players killed! Make sure you have a knife.", Duration=2, Icon="warning"}) end)
        end
    end
    if killAllBtn then 
        if killed > 0 then
            killAllBtn.flash("Killed "..killed, Color3.fromRGB(0,255,100), 1.5)
        else
            killAllBtn.flash("No Kill", Color3.fromRGB(255,80,80), 1.5)
        end
    end
end

local function startAutoKillTouch()
    if autoKillThread then task.cancel(autoKillThread); autoKillThread = nil end
    if autoKillTouchThread then task.cancel(autoKillTouchThread); autoKillTouchThread = nil end
    
    autoKillTouchThread = task.spawn(function()
        while autoKillEnabled do
            local knife = getKnifeTool()
            if knife then
                for _, plr in ipairs(Players:GetPlayers()) do
                    if not autoKillEnabled then break end
                    if plr ~= player and plr.Character then
                        local hum = plr.Character:FindFirstChild("Humanoid")
                        if hum and hum.Health > 0 then
                            killWithKnifeTouch(plr)
                            task.wait(0.05)
                        end
                    end
                end
            end
            task.wait(0.1)
        end
    end)
end

local function stopAutoKill()
    autoKillEnabled = false
    if autoKillThread then task.cancel(autoKillThread); autoKillThread = nil end
    if autoKillTouchThread then task.cancel(autoKillTouchThread); autoKillTouchThread = nil end
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
        return
    end

    local Murderer = FindMurderer() or FindSheriffNotLocalPlayer()
    if not Murderer then
        if shootBtn then shootBtn.flash("No Target", Color3.fromRGB(255,80,80)) end
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
                    if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Shot fired at murderer!", Duration=2, Icon="check"}) end) end
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
            if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Shot fired at murderer!", Duration=2, Icon="check"}) end) end
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
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Shot fired at murderer!", Duration=2, Icon="check"}) end) end
    else
        if shootBtn then shootBtn.flash("Failed", Color3.fromRGB(255,80,80)) end
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Failed to shoot!", Duration=2, Icon="warning"}) end) end
    end
end

-- ============================================
-- FLING - FROM YARHM (WORKING)
-- ============================================
local SkidFling = function(TargetPlayer)
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
        pcall(function()
            WindUI:Notify({
                Title="FurqwkScripts", 
                Content="Teleported to " .. target.Name, 
                Duration=2, 
                Icon="check"
            })
        end)
    end
end

local function TeleportToMap()
    local char = player.Character
    if not char then 
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Character not found!", Duration=2, Icon="warning"}) end) end
        return 
    end

    local map = getMap()
    if not map then 
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Map not found! Trying to find spawn...", Duration=2, Icon="warning"}) end) end
        for _, obj in ipairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and (obj.Name:lower():find("spawn") or obj.Name:lower():find("start")) then
                local hrp = char:FindFirstChild("HumanoidRootPart")
                if hrp then
                    hrp.CFrame = obj.CFrame * CFrame.new(0, 3, 0)
                    if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Teleported to spawn point!", Duration=2, Icon="check"}) end) end
                    return
                end
            end
        end
        return 
    end

    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="HRP not found!", Duration=2, Icon="warning"}) end) end
        return
    end

    local spawns = map:FindFirstChild("Spawns")
    if not spawns then
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Spawns not found!", Duration=2, Icon="warning"}) end) end
        return
    end

    local spawnParts = {}
    for _, v in ipairs(spawns:GetChildren()) do
        if v:IsA("BasePart") then
            table.insert(spawnParts, v)
        end
    end

    if #spawnParts == 0 then
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="No spawn parts found!", Duration=2, Icon="warning"}) end) end
        return
    end

    local spawn = spawnParts[math.random(1, #spawnParts)]
    if spawn and spawn:IsA("BasePart") then
        hrp.CFrame = spawn.CFrame * CFrame.new(0, 3, 0)
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Teleported to map!", Duration=2, Icon="check"}) end) end
    end
end

local function TeleportToLobby()
    local char = player.Character
    if not char then 
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Character not found!", Duration=2, Icon="warning"}) end) end
        return 
    end

    local lobby = getLobby()
    if not lobby then 
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Lobby not found!", Duration=2, Icon="warning"}) end) end
        return 
    end

    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="HRP not found!", Duration=2, Icon="warning"}) end) end
        return
    end

    local spawns = lobby:FindFirstChild("Spawns") or lobby:FindFirstChild("LobbySpawns")
    if not spawns then
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Spawns not found in lobby!", Duration=2, Icon="warning"}) end) end
        return
    end

    local spawnParts = {}
    for _, v in ipairs(spawns:GetChildren()) do
        if v:IsA("BasePart") then
            table.insert(spawnParts, v)
        end
    end

    if #spawnParts == 0 then
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="No spawn parts found!", Duration=2, Icon="warning"}) end) end
        return
    end

    local spawn = spawnParts[math.random(1, #spawnParts)]
    if spawn and spawn:IsA("BasePart") then
        hrp.CFrame = spawn.CFrame * CFrame.new(0, 3, 0)
        if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Teleported to lobby!", Duration=2, Icon="check"}) end) end
    end
end

-- ============================================
-- WORKSPACE LISTENERS
-- ============================================
pcall(function()
    Workspace.DescendantAdded:Connect(function(obj)
        if obj.Name == "GunDrop" then
            if gunDropESP then createGunDropHighlight(obj) end
            if autoGetDroppedGun then task.spawn(function() task.wait(1); grabGun() end) end
        end
        if espEnabled.trap and isTrap(obj) then task.wait(0.1); addTrapHighlight(obj) end
    end)
end)

pcall(function()
    Workspace.DescendantRemoving:Connect(function(obj)
        if obj.Name == "GunDrop" then
            for i,v in pairs(gunDropHighlights) do if v and v.Parent==obj then v:Destroy(); gunDropHighlights[i]=nil end end
            for i,v in pairs(gunDropLabels)     do if v and v.Parent==obj then v:Destroy(); gunDropLabels[i]=nil     end end
        end
    end)
end)

-- ============================================
-- AUTOFARM
-- ============================================
local activeTween       = nil
local currentTargetCoin = nil

local function flyTo(coin)
    if not rootPart then return end
    if coin == currentTargetCoin and activeTween then return end
    currentTargetCoin = coin
    if activeTween then activeTween:Cancel(); activeTween = nil end
    local pos = coin.Position
    local d   = (pos - rootPart.Position).Magnitude
    if d < 1 then return end
    local goal = CFrame.new(pos.X, pos.Y - 3, pos.Z) * CFrame.Angles(math.rad(90), 0, math.rad(90))
    activeTween = TweenService:Create(rootPart,
        TweenInfo.new(math.max(d / (flySpeed * 1.2), 0.1), Enum.EasingStyle.Linear),
        { CFrame = goal })
    activeTween:Play()
    activeTween.Completed:Connect(function()
        if coin and coin.Parent and rootPart then
            pcall(function() firetouchinterest(rootPart, coin, 0); firetouchinterest(rootPart, coin, 1) end)
        end
        currentTargetCoin = nil; activeTween = nil
    end)
end

local function findNearestCoin()
    if not rootPart then return nil end
    local pos, best, nearest = rootPart.Position, 300, nil
    for _, obj in next, workspace:GetDescendants() do
        if obj:IsA("BasePart") and obj.Name == "Coin_Server"
        and not obj:GetAttribute("Collected") and obj.Parent then
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
    antiAfkConnection = RunService.Heartbeat:Connect(function()
        pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end)
    end)
    setFarmPose(true)
    autofarmLoopThread = task.spawn(function()
        while isActive do
            task.wait(0.05)
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
    autofarmRunning = false
    if activeTween then activeTween:Cancel(); activeTween = nil end
    currentTargetCoin = nil
    if autofarmLoopThread then task.cancel(autofarmLoopThread); autofarmLoopThread = nil end
    if antiAfkConnection then antiAfkConnection:Disconnect(); antiAfkConnection = nil end
    setFarmPose(false)
end

-- ============================================
-- ESP UPDATE LOOP
-- ============================================
task.spawn(function()
    while task.wait(0.5) do
        if espEnabled.murderer or espEnabled.sheriff or espEnabled.innocent then updateESP() end
        if gunDropESP then setupGunDropESP() end
        if espEnabled.trap then setupTrapESP() end
    end
end)

-- ============================================
-- LOAD WINDUI - WITH ERROR HANDLING
-- ============================================
local WindUI = nil
local success, err = pcall(function()
    WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
end)

if not success or not WindUI then
    warn("Failed to load WindUI: " .. tostring(err))
    return
end

-- Define themes safely
local function safeAddTheme()
    pcall(function()
        WindUI:AddTheme({
            Name="Black Theme", 
            Accent=Color3.fromRGB(0, 255, 0), 
            Background=Color3.fromHex("#000000"),
            Outline=Color3.fromHex("#1a1a1a"), 
            Text=Color3.fromHex("#ffffff"),
            Placeholder=Color3.fromHex("#4d4d4d"), 
            Button=Color3.fromHex("#0a0a0a"), 
            Icon=Color3.fromHex("#808080"),
        })
    end)
end

safeAddTheme()

-- Safe popup
pcall(function()
    WindUI:Popup({
        Title="FurqwkScripts", Icon="info", Content="Script By Furqwk Scripts",
        Buttons={
            {Title="Cancel", Callback=function() end, Variant="Tertiary"},
            {Title="Continue", Icon="arrow-right", Callback=function() end, Variant="Primary"}
        }
    })
end)

pcall(function()
    WindUI:Notify({Title="FurqwkScripts", Content="Have Fun!", Duration=3, Icon="bird"})
end)

local Window = nil
pcall(function()
    Window = WindUI:CreateWindow({
        Title="FurqwkScripts Hub", Icon="door-open", Author="by FurqwkScripts",
        Folder="FurqwkScriptsHub", Size=UDim2.fromOffset(580,460),
        MinSize=Vector2.new(560,350), MaxSize=Vector2.new(850,560),
        ToggleKey=Enum.KeyCode.LeftShift, Transparent=true, Theme="Black Theme",
        Resizable=true, SideBarWidth=200, BackgroundImageTransparency=0.42,
        HideSearchBar=true, ScrollBarEnabled=false,
    })
end)

if not Window then
    warn("Failed to create Window")
    return
end

pcall(function()
    Window:Tag({
        Title = "YouTube: FurqwkScripts",
        Icon = "youtube",
        Color = Color3.fromRGB(255, 0, 0),
        Radius = 0,
    })
end)

-- ============================================
-- TAB: AUTOFARM
-- ============================================
local AutofarmTab = nil
pcall(function()
    AutofarmTab = Window:Tab({Title="Autofarm", Icon="tractor"})
end)

if not AutofarmTab then return end

local farmToggle = AutofarmTab:Toggle({
    Title="Auto Farm (Underground)", Desc="Toggle autofarm ON/OFF",
    Icon="tractor", Type="Checkbox", Value=false,
    Callback=function(state) isActive=state; if isActive then findMap(); startAutofarmLoop() else stopAutofarmLoop() end end
})

AutofarmTab:Input({
    Title="Fly Speed (1-25)", Desc="Adjust movement speed", Placeholder="15", Default="15",
    Callback=function(value) local n=tonumber(value); if n then flySpeed=math.clamp(n,1,25) end end
})

local CollectedDisplay = AutofarmTab:Button({Title="💰 Collected: 0", Desc="Total coins collected", Callback=function() end})
local TimerDisplay     = AutofarmTab:Button({Title="⏱ Time: 0s",     Desc="Elapsed time",         Callback=function() end})
local RateDisplay      = AutofarmTab:Button({Title="📊 Rate/h: 0",   Desc="Collection rate/hour", Callback=function() end})

task.spawn(function()
    while task.wait(0.05) do
        if isActive then
            local elapsed = tick() - farmStartTime
            local rate = elapsed > 0 and math.floor((collectedDisplayValue/elapsed)*3600) or 0
            pcall(function()
                CollectedDisplay:SetTitle("💰 Collected: "..collectedDisplayValue)
                TimerDisplay:SetTitle("⏱ Time: "..math.floor(elapsed).."s")
                RateDisplay:SetTitle("📊 Rate/h: "..rate)
            end)
        end
    end
end)

AutofarmTab:Button({
    Title="🔄 Reset Counter", Desc="Reset collected count and timer",
    Callback=function()
        totalCoinsCollected=0; collectedDisplayValue=0; farmStartTime=tick()
        pcall(function()
            CollectedDisplay:SetTitle("💰 Collected: 0")
            TimerDisplay:SetTitle("⏱ Time: 0s")
            RateDisplay:SetTitle("📊 Rate/h: 0")
        end)
    end
})

AutofarmTab:Keybind({Title="⌨ Keybind", Desc="Toggle autofarm", Value="G",
    Callback=function() farmToggle:SetValue(not isActive) end})

-- ============================================
-- TAB: PLAYER
-- ============================================
local PlayerTab = nil
pcall(function()
    PlayerTab = Window:Tab({Title="Player", Icon="user"})
end)

if PlayerTab then
    local noclipToggle = PlayerTab:Toggle({
        Title="No Clip",
        Desc="Toggle no clip through walls",
        Icon="square",
        Type="Checkbox",
        Value=false,
        Callback=function(state) setNoClip(state) end
    })

    local flyToggle = PlayerTab:Toggle({
        Title="Fly",
        Desc="Toggle flying mode (WASD + Space/Shift)",
        Icon="arrow-up",
        Type="Checkbox",
        Value=false,
        Callback=function(state) toggleFly(state) end
    })

    PlayerTab:Slider({
        Title = "Fly Speed",
        Desc = "Adjust fly speed (1-200)",
        Step = 1,
        Value = { Min = 1, Max = 200, Default = 50 },
        Callback = function(value) flyspeedValue = value end
    })

    PlayerTab:Toggle({
        Title="Anti Fling",
        Desc="Prevents other players from flinging you",
        Icon="shield",
        Type="Checkbox",
        Value=false,
        Callback=function(state)
            local conn = nil
            if state then
                conn = RunService.Heartbeat:Connect(function()
                    if character and rootPart then
                        if rootPart.Velocity.Magnitude > 100 then
                            rootPart.Velocity = rootPart.Velocity * 0.9
                            if rootPart.Velocity.Magnitude > 500 then
                                rootPart.Velocity = Vector3.new(0, 0, 0)
                                local hum = character:FindFirstChild("Humanoid")
                                if hum then hum.PlatformStand = false end
                            end
                        end
                    end
                end)
            else
                if conn then conn:Disconnect() end
            end
        end
    })

    PlayerTab:Slider({
        Title = "Walk Speed",
        Desc = "Adjust walk speed (1-100)",
        Step = 1,
        Value = { Min = 1, Max = 100, Default = 16 },
        Callback = function(value)
            local hum = character and character:FindFirstChild("Humanoid")
            if hum then hum.WalkSpeed = value end
        end
    })

    PlayerTab:Button({
        Title="🔄 Reset Walkspeed",
        Desc="Reset walkspeed to 16",
        Callback=function()
            local hum = character and character:FindFirstChild("Humanoid")
            if hum then hum.WalkSpeed = 16 end
            if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts", Content="Walk speed reset to 16!", Duration=2, Icon="refresh"}) end) end
        end
    })

    PlayerTab:Button({
        Title="💀 Kill Character",
        Desc="Kill your character (respawns)",
        Callback=function()
            local hum = character and character:FindFirstChild("Humanoid")
            if hum then hum.Health = 0 end
        end
    })
end

-- ============================================
-- TAB: ESP
-- ============================================
local ESPTab = nil
pcall(function()
    ESPTab = Window:Tab({Title="ESP", Icon="eye"})
end)

if ESPTab then
    ESPTab:Toggle({Title="Murderer ESP", Desc="Show players with KNIFE in RED",
        Icon="skull", Type="Checkbox", Value=false,
        Callback=function(state) espEnabled.murderer=state; updateESP() end})
    ESPTab:Toggle({Title="Sheriff ESP", Desc="Show players with GUN in BLUE",
        Icon="shield", Type="Checkbox", Value=false,
        Callback=function(state) espEnabled.sheriff=state; updateESP() end})
    ESPTab:Toggle({Title="Innocent ESP", Desc="Show players with NO WEAPON in GREEN",
        Icon="users", Type="Checkbox", Value=false,
        Callback=function(state) espEnabled.innocent=state; updateESP() end})
    ESPTab:Toggle({Title="Gun Drop ESP", Desc="Show dropped guns in YELLOW with label",
        Icon="gun", Type="Checkbox", Value=false,
        Callback=function(state) gunDropESP=state; setupGunDropESP() end})
    ESPTab:Toggle({Title="Trap ESP", Desc="Show murderer traps in ORANGE — bear traps, mines, floor traps",
        Icon="alert-triangle", Type="Checkbox", Value=false,
        Callback=function(state) espEnabled.trap=state; setupTrapESP() end})
    ESPTab:Button({Title="🔄 Refresh ESP", Desc="Manually refresh all highlights",
        Callback=function() updateESP(); setupGunDropESP(); setupTrapESP() end})
end

-- ============================================
-- TAB: SHERIFF
-- ============================================
local SheriffTab = nil
pcall(function()
    SheriffTab = Window:Tab({Title="Sheriff", Icon="shield"})
end)

if SheriffTab then
    SheriffTab:Toggle({Title="Show Gun Button", Desc="Floating grab gun button on screen",
        Icon="circle", Type="Checkbox", Value=false,
        Callback=function(state)
            if state then
                if gunBtn then gunBtn.destroy() end
                gunBtn = makeCircleButton("GrabGunButton","Grab\nGun",UDim2.new(0.85,-27,0.40,0),grabGunManual)
            else
                if gunBtn then gunBtn.destroy(); gunBtn=nil end
            end
        end})
    SheriffTab:Toggle({Title="Lock Gun Button", Desc="Lock gun button — cannot be dragged while locked",
        Icon="lock", Type="Checkbox", Value=false,
        Callback=function(state) if gunBtn then gunBtn.setLocked(state) end end})
    SheriffTab:Toggle({Title="Auto Get Dropped Gun", Desc="Auto-grab dropped guns when they appear",
        Icon="rocket", Type="Checkbox", Value=false,
        Callback=function(state) autoGetDroppedGun=state; if state then task.spawn(function() grabGun() end) end end})
    SheriffTab:Button({Title="🔫 Grab Gun", Desc="Grab dropped gun and return to position",
        Callback=function() grabGunManual() end})
    SheriffTab:Toggle({Title="Show Shoot Button", Desc="Floating shoot murderer button on screen",
        Icon="crosshair", Type="Checkbox", Value=false,
        Callback=function(state)
            if state then
                if shootBtn then shootBtn.destroy() end
                shootBtn = makeCircleButton("ShootMurdButton","Shoot\nMurd",UDim2.new(0.85,-27,0.55,0),ShootMurderer)
            else
                if shootBtn then shootBtn.destroy(); shootBtn=nil end
            end
        end})
    SheriffTab:Toggle({Title="Lock Shoot Button", Desc="Lock shoot button position",
        Icon="lock", Type="Checkbox", Value=false,
        Callback=function(state) if shootBtn then shootBtn.setLocked(state) end end})
    SheriffTab:Button({Title="🎯 Shoot Murderer",
        Desc="Shoots the murderer with prediction",
        Callback=function() ShootMurderer() end})
    SheriffTab:Keybind({Title="Sheriff Keybind", Value="J", 
        Callback=function() ShootMurderer() end})
end

-- ============================================
-- TAB: TELEPORTS
-- ============================================
local TeleportsTab = nil
pcall(function()
    TeleportsTab = Window:Tab({Title="Teleports", Icon="map-pin"})
end)

if TeleportsTab then
    local RoleTeleportSection = TeleportsTab:Section({
        Title = "Teleport to Role",
        Box = false,
        TextXAlignment = "Left",
        Opened = true,
    })

    RoleTeleportSection:Button({
        Title = "🗡️ Teleport to Murderer",
        Desc = "Teleports you directly to the murderer",
        Icon = "skull",
        Callback = function()
            local m = getPlayerByRole("murderer")
            if m then
                TeleportToPlayer(m)
            else
                if WindUI then 
                    pcall(function()
                        WindUI:Notify({
                            Title="FurqwkScripts", 
                            Content="No murderer found!", 
                            Duration=2, 
                            Icon="warning"
                        })
                    end)
                end
            end
        end
    })

    RoleTeleportSection:Button({
        Title = "🔫 Teleport to Sheriff",
        Desc = "Teleports you directly to the sheriff",
        Icon = "shield",
        Callback = function()
            local s = getPlayerByRole("sheriff")
            if s then
                TeleportToPlayer(s)
            else
                if WindUI then 
                    pcall(function()
                        WindUI:Notify({
                            Title="FurqwkScripts", 
                            Content="No sheriff found!", 
                            Duration=2, 
                            Icon="warning"
                        })
                    end)
                end
            end
        end
    })

    local MapTeleportSection = TeleportsTab:Section({
        Title = "Map Teleports",
        Box = false,
        TextXAlignment = "Left",
        Opened = true,
    })

    MapTeleportSection:Button({
        Title = "🗺️ Teleport to Map",
        Desc = "Teleports you to the active map",
        Icon = "map",
        Callback = function() TeleportToMap() end
    })

    MapTeleportSection:Button({
        Title = "🏠 Teleport to Lobby",
        Desc = "Teleports you back to the lobby",
        Icon = "home",
        Callback = function() TeleportToLobby() end
    })
end

-- ============================================
-- TAB: MURDERER
-- ============================================
local MurdererTab = nil
pcall(function()
    MurdererTab = Window:Tab({Title="Murderer", Icon="skull"})
end)

if MurdererTab then
    local autoKillToggle = MurdererTab:Toggle({
        Title="Auto Kill All (Touch)", 
        Desc="Kill all players with knife using touch interest (no clicking)",
        Icon="zap", 
        Type="Checkbox", 
        Value=false,
        Callback=function(state) 
            autoKillEnabled = state
            if state then 
                startAutoKillTouch() 
            else 
                stopAutoKill() 
            end
        end
    })

    MurdererTab:Toggle({
        Title="Show Kill All Button",
        Desc="Show floating kill all button on screen",
        Icon="sword",
        Type="Checkbox",
        Value=false,
        Callback=function(state)
            if state then
                if killAllBtn then killAllBtn.destroy() end
                killAllBtn = makeCircleButton("KillAllButton","Kill\nAll",UDim2.new(0.85,-27,0.70,0),killAllPlayers)
            else
                if killAllBtn then killAllBtn.destroy(); killAllBtn = nil end
            end
        end
    })

    MurdererTab:Toggle({
        Title="Lock Kill All Button",
        Desc="Lock kill all button position",
        Icon="lock",
        Type="Checkbox",
        Value=false,
        Callback=function(state) if killAllBtn then killAllBtn.setLocked(state) end end
    })

    MurdererTab:Button({
        Title="⚔️ Kill All Now (Touch)", 
        Desc="Instantly kills all players with knife using touch interest", 
        Icon="sword",
        Callback=function() killAllPlayers() end
    })

    MurdererTab:Keybind({Title="Murderer Keybind", Value="K", 
        Callback=function()
            autoKillToggle:SetValue(not autoKillEnabled)
        end
    })
end

-- ============================================
-- TAB: MISC
-- ============================================
local MiscTab = nil
pcall(function()
    MiscTab = Window:Tab({Title="Misc", Icon="more-horizontal"})
end)

if MiscTab then
    -- THEME DROPDOWN - WITH SAFE HANDLING
    pcall(function()
        local themeNames = WindUI:GetThemes()
        if themeNames and #themeNames > 0 then
            local ThemeDropdown = MiscTab:Dropdown({
                Title = "Theme",
                Values = themeNames,
                Value = themeNames[1] or "Black Theme",
                Callback = function(theme)
                    pcall(function()
                        WindUI:SetTheme(theme)
                    end)
                end,
            })
        end
    end)

    -- FLING SECTION
    local FlingSection = MiscTab:Section({ 
        Title = "Player Fling",
        Box = false,
        TextXAlignment = "Left",
        Opened = true,
    })

    FlingSection:Button({Title="💨 Fling Murderer", Desc="Fling murderer out of map — you TP back after",
        Callback=function()
            local m = getPlayerByRole("murderer")
            if m then 
                SkidFling(m)
                if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts",Content="Murderer flung!",Duration=2,Icon="zap"}) end) end
            else
                if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts",Content="No murderer found!",Duration=2,Icon="warning"}) end) end
            end
        end})

    FlingSection:Button({Title="💨 Fling Sheriff", Desc="Fling sheriff out of map — you TP back after",
        Callback=function()
            local s = getPlayerByRole("sheriff")
            if s then 
                SkidFling(s)
                if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts",Content="Sheriff flung!",Duration=2,Icon="zap"}) end) end
            else
                if WindUI then pcall(function() WindUI:Notify({Title="FurqwkScripts",Content="No sheriff found!",Duration=2,Icon="warning"}) end) end
            end
        end})

    FlingSection:Button({Title="💨 Fling All", Desc="Fling all players in the server",
        Callback=function()
            local count = 0
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= player and p.Character then
                    SkidFling(p)
                    count = count + 1
                    task.wait(0.1)
                end
            end
            if WindUI then 
                pcall(function()
                    WindUI:Notify({
                        Title="FurqwkScripts",
                        Content="Flinged " .. count .. " players!",
                        Duration=2,
                        Icon="zap"
                    })
                end)
            end
        end})
end

-- ============================================
-- SELECT FIRST TAB
-- ============================================
task.wait(0.5)
pcall(function() 
    if Window and AutofarmTab then
        Window:SelectTab(AutofarmTab) 
    end
end)
