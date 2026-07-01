local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local Workspace = game:GetService("Workspace")

local plr = Players.LocalPlayer
local char, hum, hrp, HRPA
local paused, db = false, false
local cpCounter = 0
local pauseKey, createKey, deleteKey, teleportKey, menuKey = "E","F","V","R","M"
local pausedData = {CFrame=nil,Camera=nil,Velocity=nil,RotVelocity=nil,State=nil}

local FPS, StateConnection = nil, nil
local FrameTimes = {}
local Clock = RS:IsRunning() and time or os.clock
local StartTime = Clock()

local HumanoidStateTypes = {
    Enum.HumanoidStateType.Jumping, Enum.HumanoidStateType.Climbing,
    Enum.HumanoidStateType.Freefall, Enum.HumanoidStateType.Running,
    Enum.HumanoidStateType.Landed, Enum.HumanoidStateType.Seated,
    Enum.HumanoidStateType.Swimming, Enum.HumanoidStateType.GettingUp,
    Enum.HumanoidStateType.FallingDown,
}

-- Utility: batch-set properties on an instance
local function set(inst, props)
    for k,v in pairs(props) do inst[k] = v end
    return inst
end

local truss = set(Instance.new("TrussPart"), {
    Name="Truss", Parent=nil, CastShadow=false, CanCollide=false,
    Color=Color3.fromRGB(163,162,165), Material=Enum.Material.Plastic,
    Size=Vector3.new(2,2,2), Anchored=true, Massless=true, Transparency=1
})
set(Instance.new("Animation"), {AnimationId="http://www.roblox.com/asset/?id=180436334", Parent=truss})

local function CalculateFPS()
    local cur = Clock()
    for i = #FrameTimes, 1, -1 do
        if FrameTimes[i] < cur - 1 then table.remove(FrameTimes, i) end
    end
    table.insert(FrameTimes, 1, cur)
    local elapsed = cur - StartTime
    return elapsed >= 1 and #FrameTimes or math.floor(#FrameTimes / elapsed)
end

local function OnStateChanged(Old, New)
    if New == Old or not hum then return end
    for _, s in pairs(HumanoidStateTypes) do if s ~= New then hum:SetStateEnabled(s, false) end end
    task.wait((1/60) - (1/(FPS or 60)))
    if not hum then return end
    for _, s in pairs(HumanoidStateTypes) do if s ~= New then hum:SetStateEnabled(s, true) end end
end

local function setupCharacter(character)
    char = character
    hum = char:WaitForChild("Humanoid", 10)
    hrp = char:WaitForChild("HumanoidRootPart", 10)
    if not hrp or not hum then return end
    HRPA = hrp:FindFirstChild("HumanoidRootPartAnchor")
    if not HRPA then
        HRPA = set(Instance.new("Part"), {
            Name="HumanoidRootPartAnchor", Anchored=false, CanCollide=false,
            Transparency=1, Size=Vector3.new(2,2,1), Massless=true,
            CFrame=hrp.CFrame, Parent=hrp
        })
        set(Instance.new("WeldConstraint"), {Part0=HRPA, Part1=hrp, Parent=HRPA})
    end
    if StateConnection then StateConnection:Disconnect(); StateConnection = nil end
    paused = false
end

setupCharacter(plr.Character or plr.CharacterAdded:Wait())
plr.CharacterAdded:Connect(setupCharacter)

local CPFolder = Workspace:FindFirstChild("AdvancedCPWS")
    or set(Instance.new("Folder"), {Name="AdvancedCPWS", Parent=Workspace})

pcall(function() CoreGui.AdvancedCPGUI:Destroy() end)
pcall(function() CoreGui.MenuGUI:Destroy() end)

local AdvancedCPGUI = set(Instance.new("ScreenGui"), {
    Name="AdvancedCPGUI", ResetOnSpawn=false,
    ZIndexBehavior=Enum.ZIndexBehavior.Sibling, Parent=CoreGui
})

local holder = set(Instance.new("Frame"), {
    Name="InstructionHolderPC", Parent=AdvancedCPGUI,
    AnchorPoint=Vector2.new(0,1), BackgroundTransparency=1,
    Position=UDim2.new(0,0,1,0), Size=UDim2.new(0.1,0,0.2,0)
})

local function makeLabel(name, pos, text)
    return set(Instance.new("TextLabel"), {
        Name=name, Parent=holder, AnchorPoint=Vector2.new(0,1),
        BackgroundTransparency=1, Position=pos, Size=UDim2.new(1,0,0.25,0),
        Font=Enum.Font.SourceSansBold, Text=text,
        TextColor3=Color3.fromRGB(64,64,64), TextScaled=true,
        TextStrokeColor3=Color3.new(1,1,1), TextStrokeTransparency=0.9,
        TextTransparency=0.3, TextWrapped=true
    })
end

local pauseLabel   = makeLabel("Pause",    UDim2.new(0,0,0,0),    "Press E to pause/unpause.")
local createLabel  = makeLabel("Create",   UDim2.new(0,0,0.25,0), "Press F to create a checkpoint.")
local deleteLabel  = makeLabel("Delete",   UDim2.new(0,0,0.5,0),  "Press V to delete your last checkpoint.")
local tpLabel      = makeLabel("Teleport", UDim2.new(0,0,0.75,0), "Press R to go to your latest checkpoint.")
local menuLabel    = makeLabel("Menu",     UDim2.new(0,0,1,0),    "Press M to open settings.")

local MenuGUI = set(Instance.new("ScreenGui"), {Name="MenuGUI", ResetOnSpawn=false, Parent=CoreGui})
local Menu = set(Instance.new("ScrollingFrame"), {
    Name="Menu", Parent=MenuGUI, Active=true, AnchorPoint=Vector2.new(0.5,0.5),
    BackgroundColor3=Color3.fromRGB(64,64,64), BackgroundTransparency=0.5,
    Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(0,200,0,200),
    Visible=false, ScrollBarThickness=6, CanvasSize=UDim2.new(0,0,0,360)
})
set(Instance.new("UIListLayout"), {Parent=Menu, SortOrder=Enum.SortOrder.LayoutOrder})

local function makeTextTop(id, text)
    local Row = set(Instance.new("Frame"), {Name=tostring(id), Parent=Menu, BackgroundTransparency=1, Size=UDim2.new(1,-12,0,40)})
    set(Instance.new("TextLabel"), {
        Parent=Row, BackgroundTransparency=1, Position=UDim2.new(1,0,0,0),
        Size=UDim2.new(1,0,1,0), Font=Enum.Font.SourceSans,
        AnchorPoint=Vector2.new(1,0), Text=text,
        TextColor3=Color3.fromRGB(255,255,255), TextScaled=true,
        TextTransparency=0.3, TextStrokeTransparency=0.9
    })
end

local function makeRow(id, text, key)
    local Row = set(Instance.new("Frame"), {Name=tostring(id), Parent=Menu, BackgroundTransparency=1, Size=UDim2.new(1,-12,0,40)})
    local Toggle = set(Instance.new("TextButton"), {
        Parent=Row, AnchorPoint=Vector2.new(0.5,0.5),
        Position=UDim2.new(0,14,0.5,0), Size=UDim2.new(0,14,0,14),
        BackgroundColor3=Color3.new(1,1,1), Text=""
    })
    local Key = set(Instance.new("TextButton"), {
        Parent=Row, AnchorPoint=Vector2.new(0.5,0.5),
        Position=UDim2.new(0,62,0.5,0), Size=UDim2.new(0,36,0,36),
        BackgroundColor3=Color3.new(0,0,0), BackgroundTransparency=0.5,
        Font=Enum.Font.SourceSansBold, Text=key,
        TextColor3=Color3.fromRGB(220,220,220), TextScaled=true, TextStrokeTransparency=0.9
    })
    set(Instance.new("TextLabel"), {
        Parent=Row, BackgroundTransparency=1,
        Position=UDim2.new(0,92,0,0), Size=UDim2.new(1,-92,1,0),
        Font=Enum.Font.SourceSansBold, Text=text,
        TextColor3=Color3.fromRGB(220,220,220), TextScaled=true,
        TextTransparency=0.3, TextStrokeTransparency=0.9
    })
    local val = set(Instance.new("StringValue"), {Name="ConfigVal", Value=key, Parent=Key})
    local editing = false
    Toggle.MouseButton1Click:Connect(function()
        editing = not editing
        if editing then
            Toggle.BackgroundColor3 = Color3.new(0,0,0)
            Key.BackgroundColor3 = Color3.new(0.5,0.5,0.5)
            Key.Text = "_"
            local c; c = UIS.InputBegan:Connect(function(i, gp)
                if gp or i.KeyCode == Enum.KeyCode.Unknown then return end
                local k = i.KeyCode.Name
                val.Value, Key.Text, editing = k, k, false
                Toggle.BackgroundColor3 = Color3.new(1,1,1)
                Key.BackgroundColor3 = Color3.new(0,0,0)
                c:Disconnect()
            end)
        end
    end)
    return Key
end

local KeybindsText = makeTextTop(1, "Keybinds")
local keyPause    = makeRow(2, "Pause",    "E")
local keyCreate   = makeRow(3, "Create",   "F")
local keyDelete   = makeRow(4, "Delete",   "V")
local keyTeleport = makeRow(5, "Teleport", "R")
local keyMenu     = makeRow(6, "Menu",     "M")

local function makeTextRow(id, labelText, placeholder)
    local Row = set(Instance.new("Frame"), {Name=tostring(id), Parent=Menu, BackgroundTransparency=1, Size=UDim2.new(1,-12,0,40)})
    local Toggle = set(Instance.new("TextButton"), {
        Parent=Row, AnchorPoint=Vector2.new(0.5,0.5),
        Position=UDim2.new(0,14,0.5,0), Size=UDim2.new(0,14,0,14),
        BackgroundColor3=Color3.new(1,1,1), Text=""
    })
    local Box = set(Instance.new("TextBox"), {
        Parent=Row, AnchorPoint=Vector2.new(0.5,0.5),
        Position=UDim2.new(0,62,0.5,0), Size=UDim2.new(0,36,0,36),
        BackgroundColor3=Color3.new(0,0,0), BackgroundTransparency=0.5,
        Font=Enum.Font.SourceSansBold, PlaceholderText=placeholder,
        PlaceholderColor3=Color3.fromRGB(178,178,178), Text="",
        TextColor3=Color3.new(1,1,1), TextScaled=true, TextEditable=false
    })
    set(Instance.new("TextLabel"), {
        Parent=Row, BackgroundTransparency=1,
        Position=UDim2.new(0,92,0,0), Size=UDim2.new(1,-92,1,0),
        Font=Enum.Font.SourceSansBold, Text=labelText,
        TextColor3=Color3.fromRGB(220,220,220), TextScaled=true,
        TextWrapped=true, TextTransparency=0.3, TextStrokeTransparency=0.9
    })
    local enabled = false
    Toggle.MouseButton1Click:Connect(function()
        enabled = not enabled
        Toggle.BackgroundColor3 = enabled and Color3.new(0,0,0) or Color3.new(1,1,1)
        Box.TextEditable = enabled
        Box.BackgroundColor3 = enabled and Color3.new(0.5,0.5,0.5) or Color3.new(0,0,0)
    end)
    return Box
end

local CheckpointText = makeTextTop(7, "Checkpoints")
local targetBox      = makeTextRow(8, "Checkpoint\nto teleport to", "1")
local transparencyBox = makeTextRow(9, "Checkpoint\ntransparency", "0.5")

local CpCustom = tonumber(targetBox.PlaceholderText)
if targetBox.Text ~= nil and targetBox.Text ~= "" then
    CpCustom = tonumber(targetBox.Text)
end

if transparencyBox then
    transparencyBox.FocusLost:Connect(function()
        local v = tonumber(transparencyBox.Text)
        if v then
            v = math.clamp(v, 0, 1)
            for _, child in ipairs(CPFolder:GetChildren()) do
                if child:IsA("BasePart") or child:IsA("Decal") then child.Transparency = v end
            end
            transparencyBox.Text = tostring(v)
        else
            transparencyBox.Text = ""
        end
    end)
end

local function createCheckpointPart()
    local tv = tonumber(transparencyBox.Text ~= "" and transparencyBox.Text or transparencyBox.PlaceholderText) or 0.5
    local p = set(Instance.new("Part"), {
        Name="CP", CastShadow=false, Color=Color3.fromRGB(163,162,165),
        Material=Enum.Material.Neon, Transparency=math.clamp(tv,0,1),
        Size=Vector3.new(2,2,1), Anchored=true, CanCollide=false, Massless=true
    })
    for name, cls in pairs({
        CameraCFrame="CFrameValue", CharacterAssemblyAngularVelocity="Vector3Value",
        CharacterAssemblyLinearVelocity="Vector3Value", CharacterCFrame="CFrameValue",
        HumanoidStateType="StringValue", SteppedCFrame="CFrameValue"
    }) do
        set(Instance.new(cls), {Name=name, Parent=p})
    end
    return p
end

-- Shared helper: apply saved pause state to hrp/hum
local function applyPausedState(cf, steppedCf, linVel, angVel, stateStr)
    local function changeState()
        if stateStr == "Jumping" or stateStr == "Seated" then
            hum:ChangeState("Freefall")
        else
            hum:ChangeState(stateStr)
        end
    end
    HRPA.CFrame = cf
    hrp.AssemblyLinearVelocity = linVel
    hrp.AssemblyAngularVelocity = angVel
    changeState()
    truss.CanCollide = false
    truss.Parent = nil
    HRPA.CFrame = steppedCf
    hrp.AssemblyLinearVelocity = linVel
    hrp.AssemblyAngularVelocity = angVel
    changeState()
    truss.CanCollide = false
    truss.Parent = nil
end

local PausedSteppedCFrame, PausedCameraCFrame, PausedCharacterCFrame
local PausedCharacterAssemblyLinearVelocity, PausedCharacterAssemblyAngularVelocity
local PausedHumanoidStateType

local function pauseFunc()
    if not hum or hum.Health <= 0 or not hrp or not HRPA then return end
    db = true
    RS.Heartbeat:Wait(); RS.RenderStepped:Wait()
    if HRPA.Anchored then
        HRPA.Anchored = false
        RS.Stepped:Wait()
        applyPausedState(PausedCharacterCFrame, PausedSteppedCFrame,
            PausedCharacterAssemblyLinearVelocity, PausedCharacterAssemblyAngularVelocity,
            PausedHumanoidStateType)
        paused = false
    else
        RS.Stepped:Wait()
        PausedSteppedCFrame = hrp.CFrame
        RS.Heartbeat:Wait()
        PausedCameraCFrame = Workspace.CurrentCamera.CFrame
        PausedCharacterCFrame = hrp.CFrame
        PausedCharacterAssemblyLinearVelocity = hrp.AssemblyLinearVelocity
        PausedCharacterAssemblyAngularVelocity = hrp.AssemblyAngularVelocity
        PausedHumanoidStateType = string.sub(tostring(hum:GetState()), 24)
        HRPA.Anchored = true
        HRPA.CFrame = PausedSteppedCFrame
        paused = true
    end
    db = false
end

local function createFunc()
    if not hrp or not hum or hum.Health <= 0 then return end
    cpCounter += 1
    local cp = createCheckpointPart()
    cp.Name = "CP_" .. cpCounter
    local cf, cam, vel, rot, state
    if paused then
        cf    = pausedData.CFrame      or hrp.CFrame
        cam   = pausedData.Camera      or Workspace.CurrentCamera.CFrame
        vel   = pausedData.Velocity    or Vector3.zero
        rot   = pausedData.RotVelocity or Vector3.zero
        state = tostring(pausedData.State or hum:GetState())
    else
        cf, cam = hrp.CFrame, Workspace.CurrentCamera.CFrame
        vel, rot = hrp.AssemblyLinearVelocity, hrp.AssemblyAngularVelocity
        state = tostring(hum:GetState())
    end
    cp.CFrame = cf
    cp.SteppedCFrame.Value, cp.CameraCFrame.Value = cf, cam
    cp.CharacterCFrame.Value = cf
    cp.CharacterAssemblyLinearVelocity.Value = vel
    cp.CharacterAssemblyAngularVelocity.Value = rot
    cp.HumanoidStateType.Value = state
    cp.Parent = CPFolder
end

local function deleteFunc()
    if cpCounter <= 0 then return end
    local cp = CPFolder:FindFirstChild("CP_" .. cpCounter)
    if cp then cp:Destroy() end
    cpCounter -= 1
end

local function teleportFunc()
    if not hum or hum.Health <= 0 or not hrp or not HRPA then return end
    db = true
    RS.Heartbeat:Wait(); RS.RenderStepped:Wait()
    if cpCounter >= 1 then
        local wasAnchored = HRPA.Anchored
        HRPA.Anchored = true
        local priority = cpCounter
        if targetBox.TextEditable then
            local custom = tonumber(targetBox.Text)
            if custom and CPFolder:FindFirstChild("CP_" .. custom) then priority = custom end
        end
        RS.Stepped:Wait()
        local cpTarget = CPFolder:FindFirstChild("CP_" .. priority)
        if cpTarget then
            PausedSteppedCFrame  = cpTarget.SteppedCFrame.Value
            PausedCameraCFrame   = cpTarget.CameraCFrame.Value
            PausedCharacterCFrame = cpTarget.CharacterCFrame.Value
            PausedCharacterAssemblyLinearVelocity  = cpTarget.CharacterAssemblyLinearVelocity.Value
            PausedCharacterAssemblyAngularVelocity = cpTarget.CharacterAssemblyAngularVelocity.Value
            PausedHumanoidStateType = cpTarget.HumanoidStateType.Value
            RS.Heartbeat:Wait(); RS.RenderStepped:Wait(); RS.Stepped:Wait()
            HRPA.CFrame = PausedSteppedCFrame
            Workspace.CurrentCamera.CFrame = PausedCameraCFrame
            hrp.AssemblyLinearVelocity  = PausedCharacterAssemblyLinearVelocity
            hrp.AssemblyAngularVelocity = PausedCharacterAssemblyAngularVelocity
            local function changeState()
                if PausedHumanoidStateType == "Jumping" or PausedHumanoidStateType == "Seated" then
                    hum:ChangeState("Freefall")
                else
                    hum:ChangeState(PausedHumanoidStateType)
                end
            end
            changeState()
            RS.Heartbeat:Wait(); RS.Stepped:Wait()
            if not wasAnchored then
                HRPA.CFrame = PausedCharacterCFrame
                Workspace.CurrentCamera.CFrame = PausedCameraCFrame
                hrp.AssemblyLinearVelocity  = PausedCharacterAssemblyLinearVelocity
                hrp.AssemblyAngularVelocity = PausedCharacterAssemblyAngularVelocity
                changeState()
                HRPA.Anchored = false
                HRPA.CFrame = PausedSteppedCFrame
                Workspace.CurrentCamera.CFrame = PausedCameraCFrame
                hrp.AssemblyLinearVelocity  = PausedCharacterAssemblyLinearVelocity
                hrp.AssemblyAngularVelocity = PausedCharacterAssemblyAngularVelocity
                changeState()
            end
            truss.CanCollide = false
            truss.Parent = nil
        end
    end
    db = false
end

local keyActions = {
    [pauseKey]    = pauseFunc,
    [createKey]   = createFunc,
    [deleteKey]   = deleteFunc,
    [teleportKey] = teleportFunc,
    [menuKey]     = function() Menu.Visible = not Menu.Visible end,
}

-- Camera tilt: rotate up/down 15 degrees around the camera's local X axis
local CAM_TILT_STEP = math.rad(15)
local CAM_TILT_MIN  = math.rad(-80)
local CAM_TILT_MAX  = math.rad(80)
local camTilt = 0  -- current accumulated tilt in radians

local function rotateCameraVertical(dir)
    local cam = Workspace.CurrentCamera
    camTilt = math.clamp(camTilt + dir * CAM_TILT_STEP, CAM_TILT_MIN, CAM_TILT_MAX)
    -- Decompose current CFrame: keep position & yaw, apply new pitch
    local cf = cam.CFrame
    local _, yaw, _ = cf:ToEulerAnglesYXZ()
    local pos = cf.Position
    cam.CFrame = CFrame.new(pos)
        * CFrame.Angles(0, yaw, 0)
        * CFrame.Angles(camTilt, 0, 0)
end

UIS.InputBegan:Connect(function(input, gameProcessed)
    if db or UIS:GetFocusedTextBox() then return end
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    local key = input.KeyCode
    if key == Enum.KeyCode.PageUp   then rotateCameraVertical(-1); return end
    if key == Enum.KeyCode.PageDown then rotateCameraVertical( 1); return end
    local fn = keyActions[key.Name]
    if fn then fn() end
end)

local function bindRemap(btn, labelObject, defaultTextPrefix, callback)
    if not btn then return end
    btn.MouseButton1Click:Connect(function()
        btn.Text = "_"
        local con; con = UIS.InputBegan:Connect(function(input)
            if input.KeyCode ~= Enum.KeyCode.Unknown then
                local key = input.KeyCode.Name
                btn.Text = key
                labelObject.Text = defaultTextPrefix .. key .. " " .. (string.match(defaultTextPrefix, "to%s+(.*)%.?$") or "")
                callback(key)
                con:Disconnect()
            end
        end)
    end)
end

bindRemap(keyPause,    pauseLabel,  "Press ", function(v) pauseKey    = v; keyActions[v] = pauseFunc    end)
bindRemap(keyCreate,   createLabel, "Press ", function(v) createKey   = v; keyActions[v] = createFunc   end)
bindRemap(keyDelete,   deleteLabel, "Press ", function(v) deleteKey   = v; keyActions[v] = deleteFunc   end)
bindRemap(keyTeleport, tpLabel,     "Press ", function(v) teleportKey = v; keyActions[v] = teleportFunc end)
bindRemap(keyMenu,     menuLabel,   "Press ", function(v) menuKey     = v; keyActions[v] = function() Menu.Visible = not Menu.Visible end end)

RS.Heartbeat:Connect(function()
    FPS = CalculateFPS()
    if hum and hum.Health > 0 and FPS > 61 and not StateConnection then
        StateConnection = hum.StateChanged:Connect(OnStateChanged)
    elseif StateConnection and (FPS <= 61 or not hum or hum.Health <= 0) then
        StateConnection:Disconnect(); StateConnection = nil
    end
    if paused and HRPA and HRPA.Parent and hrp and hum and hum.Health > 0 then
        HRPA.Anchored = true
        HRPA.CFrame = PausedCharacterCFrame or HRPA.CFrame
        hrp.AssemblyLinearVelocity  = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    elseif paused and (not hum or hum.Health <= 0) then
        paused = false
    end
end)
