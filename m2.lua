-- ============================================
-- CIRCLE BUTTON FACTORY - BIGGER DESKTOP SIZE
-- ============================================
local function makeCircleButton(guiName, labelText, defaultPos, onClick)
    local gui = Instance.new("ScreenGui")
    gui.Name = guiName; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.Parent = CoreGui

    local isMobile = UserInputService.TouchEnabled
    local size = isMobile and 70 or 80  -- Desktop: 80, Mobile: 70

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
