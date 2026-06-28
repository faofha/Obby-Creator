local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("RunService")
local TS = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")
local Workspace = game:GetService("Workspace")

local TOGGLE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local function tweenToggle(frame, color)
    TS:Create(frame, TOGGLE_TWEEN, {BackgroundColor3 = color}):Play()
end

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

-- ── Executor file I/O ────────────────────────────────────────────────────────
-- Synapse X/Z, KRNL, and Fluxus all expose writefile/readfile/isfile globally.
-- Folder support (isfolder/makefolder) exists on Synapse & KRNL; we pcall it.
local SAVE_DIR  = "AdvancedCP"
local SAVE_FILE = SAVE_DIR .. "/checkpoints.json"

local function ensureDir()
    pcall(function()
        if isfolder and not isfolder(SAVE_DIR) then makefolder(SAVE_DIR) end
    end)
end

local function fileWrite(path, data)
    if writefile then pcall(writefile, path, data) end
end

local function fileRead(path)
    if readfile and isfile and isfile(path) then
        local ok, data = pcall(readfile, path)
        return ok and data or nil
    end
    return nil
end

-- ── Serialization helpers ────────────────────────────────────────────────────
local function cf2t(cf) return {cf:GetComponents()} end
local function t2cf(t)  return CFrame.new(table.unpack(t)) end
local function v3t(v)   return {v.X, v.Y, v.Z} end
local function tv3(t)   return Vector3.new(t[1], t[2], t[3]) end

local function serializeCP(cp)
    return {
        name      = cp.Name,
        cframe    = cf2t(cp.CharacterCFrame.Value),
        steppedCF = cf2t(cp.SteppedCFrame.Value),
        cameraCF  = cf2t(cp.CameraCFrame.Value),
        linVel    = v3t(cp.CharacterAssemblyLinearVelocity.Value),
        angVel    = v3t(cp.CharacterAssemblyAngularVelocity.Value),
        state     = cp.HumanoidStateType.Value,
    }
end

-- Minimal JSON encoder
local function encodeVal(v)
    local t = type(v)
    if t == "nil"     then return "null"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number"  then return tostring(v)
    elseif t == "string"  then return '"'..v:gsub('\\','\\\\'):gsub('"','\\"')..'"'
    elseif t == "table" then
        if #v > 0 then
            local p = {}
            for _,item in ipairs(v) do p[#p+1] = encodeVal(item) end
            return "["..table.concat(p,",").."]"
        else
            local p = {}
            for k,val in pairs(v) do p[#p+1] = '"'..tostring(k)..'":' .. encodeVal(val) end
            return "{"..table.concat(p,",").."}"
        end
    end
    return "null"
end

-- Lightweight recursive descent JSON decoder
local function decodeVal(s, i)
    i = i or 1
    while s:sub(i,i):match("%s") do i=i+1 end
    local c = s:sub(i,i)
    if c == '"' then
        local j, out = i+1, {}
        while j <= #s do
            local ch = s:sub(j,j)
            if ch == '\\' then local nx=s:sub(j+1,j+1); out[#out+1]=nx=='n'and'\n'or nx=='t'and'\t'or nx; j=j+2
            elseif ch == '"' then break
            else out[#out+1]=ch; j=j+1 end
        end
        return table.concat(out), j+1
    elseif c == '{' then
        local obj, j = {}, i+1
        while true do
            while s:sub(j,j):match("%s") do j=j+1 end
            if s:sub(j,j)=='}' then return obj, j+1 end
            local key; key,j = decodeVal(s,j)
            while s:sub(j,j):match("[%s:]") do j=j+1 end
            local val; val,j = decodeVal(s,j)
            obj[key]=val
            while s:sub(j,j):match("[%s,]") do j=j+1 end
        end
    elseif c == '[' then
        local arr, j = {}, i+1
        while true do
            while s:sub(j,j):match("%s") do j=j+1 end
            if s:sub(j,j)==']' then return arr, j+1 end
            local val; val,j = decodeVal(s,j)
            arr[#arr+1]=val
            while s:sub(j,j):match("[%s,]") do j=j+1 end
        end
    elseif s:sub(i,i+3)=="null"  then return nil,  i+4
    elseif s:sub(i,i+3)=="true"  then return true, i+4
    elseif s:sub(i,i+4)=="false" then return false,i+5
    else local num=s:match("^-?%d+%.?%d*[eE]?[+-]?%d*",i); return tonumber(num),i+#num end
end
local jsonDecode = function(s) local ok,v=pcall(decodeVal,s,1); return ok and v or nil end


pcall(function() CoreGui.AdvancedCPGUI:Destroy() end)
pcall(function() CoreGui.MenuGUI:Destroy() end)

-- ── Unified Settings + Slot Saves window (matches G2L layout exactly) ────────
local MenuGUI   = set(Instance.new("ScreenGui"), {Name="MenuGUI", ResetOnSpawn=false, Parent=CoreGui})

-- Outer SettingsFrame: white card, centred, aspect-locked (1.5)
local MenuFrame = set(Instance.new("Frame"), {
    Name="SettingsFrame", Parent=MenuGUI,
    AnchorPoint=Vector2.new(0.5,0.5),
    BackgroundColor3=Color3.fromRGB(255,255,255),
    BorderColor3=Color3.fromRGB(27,42,53),
    Position=UDim2.new(0.5,0,0.5,0),
    Size=UDim2.new(0.5,0,0.5,0),
    Visible=false,
})
set(Instance.new("UIAspectRatioConstraint"), {Parent=MenuFrame, AspectRatio=1.5})
set(Instance.new("UICorner"),               {Parent=MenuFrame})
set(Instance.new("UISizeConstraint"),       {Parent=MenuFrame, MinSize=Vector2.new(250,250)})

-- Title: "Settings" in Cartoon font
set(Instance.new("TextLabel"), {
    Parent=MenuFrame, AnchorPoint=Vector2.new(0.5,0),
    BackgroundTransparency=1, BorderColor3=Color3.fromRGB(27,42,53),
    Position=UDim2.new(0.5,0,0.025,0), Size=UDim2.new(0.7,0,0.1,0), ZIndex=3,
    Font=Enum.Font.Cartoon, Text="Settings",
    TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextWrapped=true,
})

-- Close button: red rotated "+"
local MenuClose = set(Instance.new("TextButton"), {
    Name="Close", Parent=MenuFrame,
    AnchorPoint=Vector2.new(1,0), BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(1,-5,0,5), Size=UDim2.new(0.1,0,0.1,0), ZIndex=5,
    Font=Enum.Font.SourceSans, Text="",
})
set(Instance.new("UIAspectRatioConstraint"), {Parent=MenuClose, DominantAxis=Enum.DominantAxis.Height})
set(Instance.new("TextLabel"), {
    Parent=MenuClose, AnchorPoint=Vector2.new(0.5,0.5),
    BackgroundTransparency=1, BorderColor3=Color3.fromRGB(27,42,53),
    Position=UDim2.new(0.5,0,0.5,0), Rotation=-45,
    Size=UDim2.new(2,0,2,0), ZIndex=5,
    Font=Enum.Font.GothamBold, Text="+",
    TextColor3=Color3.fromRGB(255,0,0), TextScaled=true, TextWrapped=true,
})
MenuClose.MouseButton1Click:Connect(function() MenuFrame.Visible = false end)

-- ThisFrame: full-size transparent container
local ThisFrame = set(Instance.new("Frame"), {
    Name="ThisFrame", Parent=MenuFrame,
    BackgroundTransparency=1, BorderColor3=Color3.fromRGB(27,42,53),
    Size=UDim2.new(1,0,1,0),
})

-- ── Left panel: SettingsFrame_2 (settings scroll, 45% wide) ─────────────────
local Menu = set(Instance.new("ScrollingFrame"), {
    Name="SettingsFrame", Parent=ThisFrame,
    Active=true,
    BackgroundColor3=Color3.fromRGB(240,240,240),
    BorderColor3=Color3.fromRGB(0,0,0), BorderSizePixel=0,
    Position=UDim2.new(0.05,0,0.15,0),
    Size=UDim2.new(0.45,0,0.8,0),
    CanvasSize=UDim2.new(0,0,0.65,0),
    ScrollBarThickness=8,
})
set(Instance.new("UICorner"),    {Parent=Menu})
set(Instance.new("UIListLayout"),{Parent=Menu, Padding=UDim.new(0,1), SortOrder=Enum.SortOrder.LayoutOrder})

-- ── Row builders (same as before, parent=Menu) ───────────────────────────────
local function makeTextTop(id, text)
    local Row = set(Instance.new("Frame"), {
        Name=tostring(id), Parent=Menu, BackgroundTransparency=1, BorderSizePixel=0,
        Size=UDim2.new(1,-10,0.065,-1), LayoutOrder=id,
    })
    set(Instance.new("TextLabel"), {
        Parent=Row, AnchorPoint=Vector2.new(0,0.5),
        BackgroundTransparency=1, BorderSizePixel=0,
        Position=UDim2.new(0,2,0.5,0), Size=UDim2.new(0.5,0,1,0),
        Font=Enum.Font.GothamBold, Text=text,
        TextColor3=Color3.fromRGB(50,50,50), TextScaled=true, TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,
    })
end

local function makeRow(id, text, key, labelObj, actionFn)
    local Row = set(Instance.new("Frame"), {
        Name=tostring(id), Parent=Menu,
        BackgroundTransparency=1, BorderColor3=Color3.fromRGB(120,120,120),
        Size=UDim2.new(1,-10,0.11,-1), LayoutOrder=id, ZIndex=3,
    })
    set(Instance.new("TextLabel"), {
        Name="TitleLabel", Parent=Row,
        AnchorPoint=Vector2.new(0,0.5), BackgroundTransparency=1,
        BorderColor3=Color3.fromRGB(27,42,53),
        Position=UDim2.new(0,5,0.5,0), Size=UDim2.new(0.6,-5,0.7,0), ZIndex=3,
        Font=Enum.Font.Unknown, Text=text,
        TextColor3=Color3.fromRGB(50,50,50), TextScaled=true, TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,
    })
    local KeyBtn = set(Instance.new("TextButton"), {
        Parent=Row, BackgroundTransparency=1, BorderSizePixel=0,
        Position=UDim2.new(0.6,0,0,0), Size=UDim2.new(0.4,0,1,0), ZIndex=3,
        Font=Enum.Font.Ubuntu, Text="",
    })
    local KeyBox = set(Instance.new("TextBox"), {
        Name="KeyBox", Parent=KeyBtn,
        AnchorPoint=Vector2.new(0.5,0.5),
        BackgroundColor3=Color3.fromRGB(200,200,200), BorderSizePixel=0,
        Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(0.8,0,0.8,0), ZIndex=4,
        Font=Enum.Font.Ubuntu, Text=key,
        TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextEditable=false,
    })
    set(Instance.new("UICorner"), {Parent=KeyBox, CornerRadius=UDim.new(0,4)})
    local val = set(Instance.new("StringValue"), {Name="ConfigVal", Value=key, Parent=KeyBtn})
    local editing = false
    local _labelObj2, _actionFn2, _setKeyVar2 = nil, nil, nil
    local function wire(lObj, aFn, sKV) _labelObj2=lObj; _actionFn2=aFn; _setKeyVar2=sKV end
    KeyBtn.MouseButton1Click:Connect(function()
        if not _actionFn2 then return end
        editing = not editing
        if editing then
            KeyBox.BackgroundColor3 = Color3.fromRGB(170,0,0)
            KeyBox.Text = "_"
            local c; c = UIS.InputBegan:Connect(function(i, gp)
                if gp or i.KeyCode == Enum.KeyCode.Unknown then return end
                local k = i.KeyCode.Name
                keyActions[val.Value] = nil
                keyActions[k] = _actionFn2
                if _setKeyVar2 then _setKeyVar2(k) end
                if _labelObj2 then
                    local suffix = _labelObj2.Text:match("Press %S+ (.+)") or ""
                    _labelObj2.Text = "Press " .. k .. (suffix ~= "" and " " .. suffix or "")
                end
                val.Value, KeyBox.Text, editing = k, k, false
                KeyBox.BackgroundColor3 = Color3.fromRGB(200,200,200)
                c:Disconnect()
            end)
        else
            KeyBox.BackgroundColor3 = Color3.fromRGB(200,200,200)
        end
    end)
    return KeyBtn, wire
end

local function makeTextRow(id, labelText, placeholder)
    local Row = set(Instance.new("Frame"), {
        Name=tostring(id), Parent=Menu,
        BackgroundTransparency=1, BorderColor3=Color3.fromRGB(120,120,120),
        Size=UDim2.new(1,-10,0.11,-1), LayoutOrder=id, ZIndex=3,
    })
    set(Instance.new("TextLabel"), {
        Name="TitleLabel", Parent=Row,
        AnchorPoint=Vector2.new(0,0.5), BackgroundTransparency=1,
        BorderColor3=Color3.fromRGB(27,42,53),
        Position=UDim2.new(0,5,0.5,0), Size=UDim2.new(0.6,-5,0.7,0), ZIndex=3,
        Font=Enum.Font.Unknown, Text=labelText,
        TextColor3=Color3.fromRGB(50,50,50), TextScaled=true, TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,
    })
    local Box = set(Instance.new("TextBox"), {
        Parent=Row, AnchorPoint=Vector2.new(0.5,0.5),
        BackgroundColor3=Color3.fromRGB(200,200,200), BorderSizePixel=0,
        Position=UDim2.new(0.8,0,0.5,0), Size=UDim2.new(0.275,0,0.8,0), ZIndex=3,
        Font=Enum.Font.Ubuntu, PlaceholderText=placeholder,
        PlaceholderColor3=Color3.fromRGB(178,178,178), Text="",
        TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextEditable=false,
    })
    set(Instance.new("UICorner"), {Parent=Box, CornerRadius=UDim.new(0,4)})
    local Toggle = set(Instance.new("TextButton"), {
        Parent=Row, AnchorPoint=Vector2.new(0.5,0.5),
        BackgroundColor3=Color3.new(1,1,1), BorderColor3=Color3.fromRGB(27,42,53),
        Position=UDim2.new(0.62,0,0.5,0), Size=UDim2.new(0,14,0,14), ZIndex=3,
        Font=Enum.Font.SourceSans, Text="",
    })
    local enabled = false
    Toggle.MouseButton1Click:Connect(function()
        enabled = not enabled
        Toggle.BackgroundColor3 = enabled and Color3.new(0,0,0) or Color3.new(1,1,1)
        Box.TextEditable = enabled
        Box.BackgroundColor3 = enabled and Color3.fromRGB(220,220,220) or Color3.fromRGB(200,200,200)
    end)
    return Box
end

-- ── Settings rows ─────────────────────────────────────────────────────────────
-- Keybinds section
makeTextTop(-1, "Keybinds")
local keyPause,    wirePause    = makeRow(1,  "Pause:",    "E", nil, nil)
local keyCreate,   wireCreate   = makeRow(2,  "Create:",   "F", nil, nil)
local keyDelete,   wireDelete   = makeRow(3,  "Delete:",   "V", nil, nil)
local keyTeleport, wireTeleport = makeRow(4,  "Teleport:", "R", nil, nil)
local keyMenu,     wireMenu     = makeRow(5,  "Menu:",     "M", nil, nil)
-- Checkpoints section
makeTextTop(6, "Checkpoints")
local targetBox      = makeTextRow(7, "Checkpoint to teleport to:", "1")
local transparencyBox = makeTextRow(8, "Checkpoint transparency:",  "0.5")

-- Teleport Enabled toggle (matches _212CheckpointTP in G2L)
local tpEnabledRow = set(Instance.new("Frame"), {
    Name="9", Parent=Menu, BackgroundTransparency=1,
    BorderColor3=Color3.fromRGB(120,120,120),
    Size=UDim2.new(1,-10,0.11,-1), LayoutOrder=9, ZIndex=3,
})
set(Instance.new("TextLabel"), {
    Name="TitleLabel", Parent=tpEnabledRow,
    AnchorPoint=Vector2.new(0,0.5), BackgroundTransparency=1,
    Position=UDim2.new(0,5,0.5,0), Size=UDim2.new(0.6,-5,0.7,0), ZIndex=3,
    Font=Enum.Font.Unknown, Text="Teleport Enabled:",
    TextColor3=Color3.fromRGB(50,50,50), TextScaled=true, TextWrapped=true,
    TextXAlignment=Enum.TextXAlignment.Left,
})
local tpToggleBtn = set(Instance.new("TextButton"), {
    Parent=tpEnabledRow, BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0.6,0,0,0), Size=UDim2.new(0.4,0,1,0), ZIndex=3, Text="",
})
local tpMiddle = set(Instance.new("Frame"), {
    Name="MiddleFrame", Parent=tpToggleBtn,
    AnchorPoint=Vector2.new(0.5,0.5),
    BackgroundColor3=Color3.fromRGB(0,170,0), BorderSizePixel=0,
    Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(0.6,0,0.65,0), ZIndex=4,
})
set(Instance.new("UICorner"), {Parent=tpMiddle, CornerRadius=UDim.new(1,0)})
local tpEnabled = true
tpToggleBtn.MouseButton1Click:Connect(function()
    tpEnabled = not tpEnabled
    tweenToggle(tpMiddle, tpEnabled
        and Color3.fromRGB(0,170,0) or Color3.fromRGB(170,0,0))
end)

-- Transparency Enabled toggle (matches _2CPTransparency in G2L)
local cpTransRow = set(Instance.new("Frame"), {
    Name="10", Parent=Menu, BackgroundTransparency=1,
    BorderColor3=Color3.fromRGB(120,120,120),
    Size=UDim2.new(1,-10,0.11,-1), LayoutOrder=10, ZIndex=3,
})
set(Instance.new("TextLabel"), {
    Name="TitleLabel", Parent=cpTransRow,
    AnchorPoint=Vector2.new(0,0.5), BackgroundTransparency=1,
    Position=UDim2.new(0,5,0.5,0), Size=UDim2.new(0.6,-5,0.7,0), ZIndex=3,
    Font=Enum.Font.Unknown, Text="Transparency Enabled:",
    TextColor3=Color3.fromRGB(50,50,50), TextScaled=true, TextWrapped=true,
    TextXAlignment=Enum.TextXAlignment.Left,
})
local cpTransBtn = set(Instance.new("TextButton"), {
    Parent=cpTransRow, BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0.6,0,0,0), Size=UDim2.new(0.4,0,1,0), ZIndex=3, Text="",
})
local cpTransMiddle = set(Instance.new("Frame"), {
    Name="MiddleFrame", Parent=cpTransBtn,
    AnchorPoint=Vector2.new(0.5,0.5),
    BackgroundColor3=Color3.fromRGB(0,170,0), BorderSizePixel=0,
    Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(0.6,0,0.65,0), ZIndex=4,
})
set(Instance.new("UICorner"), {Parent=cpTransMiddle, CornerRadius=UDim.new(1,0)})
local cpTransEnabled = true
cpTransBtn.MouseButton1Click:Connect(function()
    cpTransEnabled = not cpTransEnabled
    tweenToggle(cpTransMiddle, cpTransEnabled
        and Color3.fromRGB(0,170,0) or Color3.fromRGB(170,0,0))
end)

-- Line divider + Persistence rows
set(Instance.new("Frame"), {
    Name="11", Parent=Menu, BackgroundColor3=Color3.fromRGB(255,255,255),
    BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1), LayoutOrder=11,
})
makeTextTop(12, "Persistence")

local function makeActionButton(id, label, fn)
    local Row = set(Instance.new("Frame"), {
        Name=tostring(id), Parent=Menu, BackgroundTransparency=1,
        BorderColor3=Color3.fromRGB(120,120,120),
        Size=UDim2.new(1,-10,0.11,-1), LayoutOrder=id, ZIndex=3,
    })
    set(Instance.new("TextLabel"), {
        Name="TitleLabel", Parent=Row,
        AnchorPoint=Vector2.new(0,0.5), BackgroundTransparency=1,
        Position=UDim2.new(0,5,0.5,0), Size=UDim2.new(0.6,-5,0.7,0), ZIndex=3,
        Font=Enum.Font.Unknown, Text=label,
        TextColor3=Color3.fromRGB(50,50,50), TextScaled=true, TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,
    })
    local Btn = set(Instance.new("TextButton"), {
        Parent=Row, BackgroundTransparency=1, BorderSizePixel=0,
        Position=UDim2.new(0.6,0,0,0), Size=UDim2.new(0.4,0,1,0), ZIndex=3, Text="",
    })
    local Pill = set(Instance.new("Frame"), {
        Name="MiddleFrame", Parent=Btn,
        AnchorPoint=Vector2.new(0.5,0.5),
        BackgroundColor3=Color3.fromRGB(0,170,0), BorderSizePixel=0,
        Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(0.6,0,0.65,0), ZIndex=4,
    })
    set(Instance.new("UICorner"), {Parent=Pill, CornerRadius=UDim.new(1,0)})
    set(Instance.new("TextLabel"), {
        Parent=Pill, AnchorPoint=Vector2.new(0.5,0.5), BackgroundTransparency=1,
        Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(0.9,0,0.8,0), ZIndex=5,
        Font=Enum.Font.GothamBold, Text="▶",
        TextColor3=Color3.fromRGB(255,255,255), TextScaled=true,
    })
    Btn.MouseButton1Click:Connect(fn)
    return Btn
end

makeActionButton(13, "💾 Save Checkpoints", saveCheckpoints)
makeActionButton(14, "📂 Load Checkpoints", loadCheckpoints)

-- ── Right panel: LimitsFrame (slot saves) ────────────────────────────────────
local LimitsFrame = set(Instance.new("Frame"), {
    Name="LimitsFrame", Parent=ThisFrame,
    AnchorPoint=Vector2.new(1,0), BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0.95,0,0.15,0), Size=UDim2.new(0.4,0,0.699,0),
})
set(Instance.new("UICorner"), {Parent=LimitsFrame})

-- "Current Obby:" header
local CurrentObbyHeader = set(Instance.new("TextLabel"), {
    Name="CurrentObby", Parent=LimitsFrame,
    AnchorPoint=Vector2.new(0.5,0.5), BackgroundTransparency=1,
    BorderColor3=Color3.fromRGB(27,42,53),
    Position=UDim2.new(0.5,0,0.05,0), Size=UDim2.new(1,0,0.1,-1), ZIndex=4,
    Font=Enum.Font.SourceSansBold, Text="Current Obby:",
    TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextWrapped=true,
})
set(Instance.new("Frame"), {
    Parent=CurrentObbyHeader,
    BackgroundColor3=Color3.fromRGB(150,150,150), BorderSizePixel=0,
    Position=UDim2.new(0,0,2,0), Size=UDim2.new(1,0,0,1),
})

-- ObbyId: shows current obby id or "No obby loaded!"
local InfoLabel = set(Instance.new("TextLabel"), {
    Name="ObbyId", Parent=LimitsFrame,
    AnchorPoint=Vector2.new(0.5,0.5), BackgroundTransparency=1,
    BorderColor3=Color3.fromRGB(27,42,53),
    Position=UDim2.new(0.5,0,0.15,0), Size=UDim2.new(1,0,0.1,-1), ZIndex=4,
    Font=Enum.Font.SourceSansBold, Text="No obby loaded!",
    TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextWrapped=true,
})

-- Slot ScrollingFrame
local SlotScroll = set(Instance.new("ScrollingFrame"), {
    Active=true, Parent=LimitsFrame,
    AnchorPoint=Vector2.new(0.5,0.5), BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0.5,0,0.65,0), Size=UDim2.new(1,0,0.9,0),
    CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollBarThickness=8,
})
set(Instance.new("UIListLayout"), {Parent=SlotScroll, SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,1)})

-- "Saves" label
set(Instance.new("TextLabel"), {
    Name="1ATitle", Parent=SlotScroll,
    BackgroundTransparency=1, BorderColor3=Color3.fromRGB(27,42,53),
    Size=UDim2.new(1,-10,0,20), ZIndex=4, LayoutOrder=0,
    Font=Enum.Font.SourceSansBold, Text="Saves",
    TextColor3=Color3.fromRGB(50,50,50), TextScaled=true, TextWrapped=true,
})

-- 1BFrame: slot row container
local SlotContainer = set(Instance.new("Frame"), {
    Name="1BFrame", Parent=SlotScroll,
    BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.new(1,-10,0,0), AutomaticSize=Enum.AutomaticSize.Y, LayoutOrder=1,
})
set(Instance.new("UIListLayout"), {Parent=SlotContainer, SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,2)})

-- Status label
local SlotStatus = set(Instance.new("TextLabel"), {
    Parent=LimitsFrame, AnchorPoint=Vector2.new(0.5,1),
    BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0.5,0,1,0), Size=UDim2.new(1,0,0.08,0), ZIndex=4,
    Font=Enum.Font.SourceSansBold, Text="",
    TextColor3=Color3.fromRGB(100,100,100), TextScaled=true, TextWrapped=true,
})
local function setSlotStatus(msg, isError)
    SlotStatus.Text = msg
    SlotStatus.TextColor3 = isError and Color3.fromRGB(200,50,50) or Color3.fromRGB(50,150,50)
    task.delay(3, function() if SlotStatus.Text == msg then SlotStatus.Text = "" end end)
end

-- Bottom Save + Load buttons (on ThisFrame, matching G2L SaveButton/LoadButton_3)
local BottomSaveBtn = set(Instance.new("TextButton"), {
    Name="SaveButton", Parent=ThisFrame,
    AnchorPoint=Vector2.new(0,1),
    BackgroundColor3=Color3.fromRGB(85,170,255), BorderColor3=Color3.fromRGB(27,42,53),
    Position=UDim2.new(0.55,0,0.95,0), Size=UDim2.new(0.19,0,0.075,0),
    ZIndex=3, Font=Enum.Font.SourceSans, Text="",
})
set(Instance.new("UICorner"), {Parent=BottomSaveBtn})
set(Instance.new("TextLabel"), {
    Parent=BottomSaveBtn, AnchorPoint=Vector2.new(0.5,0.5), BackgroundTransparency=1,
    Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(1,-5,1,-5), ZIndex=5,
    Font=Enum.Font.Cartoon, Text="Save Checkpoints",
    TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextWrapped=true,
})

local BottomLoadBtn = set(Instance.new("TextButton"), {
    Name="LoadButton", Parent=ThisFrame,
    AnchorPoint=Vector2.new(1,1),
    BackgroundColor3=Color3.fromRGB(0,255,0), BorderColor3=Color3.fromRGB(27,42,53),
    Position=UDim2.new(0.95,0,0.95,0), Size=UDim2.new(0.19,0,0.075,0),
    ZIndex=3, Font=Enum.Font.SourceSans, Text="",
})
set(Instance.new("UICorner"), {Parent=BottomLoadBtn})
set(Instance.new("TextLabel"), {
    Parent=BottomLoadBtn, AnchorPoint=Vector2.new(0.5,0.5), BackgroundTransparency=1,
    Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(1,-5,1,-5), ZIndex=5,
    Font=Enum.Font.Cartoon, Text="Load Checkpoints",
    TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextWrapped=true,
})

-- Rename popup (parented to MenuFrame so it overlays everything)
local RenamePopup = set(Instance.new("Frame"), {
    Parent=MenuFrame, AnchorPoint=Vector2.new(0.5,0.5),
    BackgroundColor3=Color3.fromRGB(255,255,255), BorderSizePixel=0,
    Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(0.5,0,0.25,0),
    Visible=false, ZIndex=10,
})
set(Instance.new("UICorner"), {Parent=RenamePopup})
set(Instance.new("TextLabel"), {
    Parent=RenamePopup, BackgroundTransparency=1,
    Position=UDim2.new(0,0,0,0), Size=UDim2.new(1,0,0.3,0), ZIndex=11,
    Font=Enum.Font.GothamBold, Text="Rename slot",
    TextColor3=Color3.fromRGB(50,50,50), TextScaled=true,
})
local RenameBox = set(Instance.new("TextBox"), {
    Parent=RenamePopup, AnchorPoint=Vector2.new(0.5,0.5),
    BackgroundColor3=Color3.fromRGB(220,220,220), BorderSizePixel=0,
    Position=UDim2.new(0.5,0,0.55,0), Size=UDim2.new(0.85,0,0.28,0),
    ZIndex=11, Font=Enum.Font.Gotham,
    PlaceholderText="Enter name...", Text="",
    TextColor3=Color3.fromRGB(30,30,30), TextScaled=true, ClearTextOnFocus=true,
})
set(Instance.new("UICorner"), {Parent=RenameBox, CornerRadius=UDim.new(0,4)})
local RenameConfirm = set(Instance.new("TextButton"), {
    Parent=RenamePopup, AnchorPoint=Vector2.new(0.5,1),
    BackgroundColor3=Color3.fromRGB(0,150,80), BorderSizePixel=0,
    Position=UDim2.new(0.5,0,1,-4), Size=UDim2.new(0.5,0,0.26,0),
    ZIndex=11, Font=Enum.Font.GothamBold, Text="Confirm",
    TextColor3=Color3.fromRGB(255,255,255), TextScaled=true,
})
set(Instance.new("UICorner"), {Parent=RenameConfirm, CornerRadius=UDim.new(0,4)})
local _renameCallback = nil
RenameConfirm.MouseButton1Click:Connect(function()
    if _renameCallback then _renameCallback(RenameBox.Text) end
    RenamePopup.Visible = false
end)
local function promptRename(currentName, callback)
    RenameBox.Text = currentName or ""
    _renameCallback = callback
    RenamePopup.Visible = true
    RenameBox:CaptureFocus()
end

-- ── Slot data & row management ────────────────────────────────────────────────
local slotData  = {}
local slotRows  = {}
local slotCount = 0

local function slotExists(obbyId, slotNum)
    return obbyId and obbyId ~= "" and isfile and isfile(slotFilePath(obbyId, slotNum)) or false
end

local function refreshRow(i)
    local row = slotRows[i]; if not row then return end
    local sd  = slotData[i]; if not sd  then return end
    local exists  = slotExists(sd.obbyId, sd.slotNum)
    local info    = parseCurrentObby()
    local isMatch = info and sd.obbyId ~= "" and info.obbyId == sd.obbyId
    local canLoad = exists and isMatch
    row.NameLabel.Text = sd.displayName ~= "" and sd.displayName or ("Slot "..i)
    row.SubLabel.Text  = exists and ("ID: "..sd.obbyId.." #"..sd.slotNum) or "Empty"
    row.SubLabel.TextColor3 = exists and Color3.fromRGB(100,100,100) or Color3.fromRGB(150,150,150)
    row.LoadBtn.BackgroundColor3  = canLoad and Color3.fromRGB(0,255,0)   or Color3.fromRGB(180,180,180)
    row.LoadBtn.Active            = canLoad
    row.SaveBtn.BackgroundColor3  = Color3.fromRGB(85,170,255)
    row.DeleteBtn.BackgroundColor3 = exists and Color3.fromRGB(255,0,0) or Color3.fromRGB(180,180,180)
    row.DeleteBtn.Active           = exists
end

local function makeSlotRow(i, sd)
    local Row = set(Instance.new("Frame"), {
        Name="Slot"..i, Parent=SlotContainer,
        BackgroundColor3=Color3.fromRGB(255,255,255),
        BorderColor3=Color3.fromRGB(0,0,0), BorderSizePixel=0,
        Size=UDim2.new(1,0,0,54), LayoutOrder=i,
    })
    local NameLabel = set(Instance.new("TextLabel"), {
        Name="Slot1", Parent=Row, BackgroundTransparency=1,
        BorderColor3=Color3.fromRGB(27,42,53),
        Position=UDim2.new(0.025,0,0,0), Size=UDim2.new(1,0,0.5,0), ZIndex=4,
        Font=Enum.Font.SourceSans,
        Text=sd and sd.displayName ~= "" and sd.displayName or ("Slot "..i),
        TextColor3=Color3.fromRGB(50,50,50), TextScaled=true, TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,
    })
    NameLabel.InputBegan:Connect(function(inp)
        if inp.UserInputType ~= Enum.UserInputType.MouseButton1
        and inp.UserInputType ~= Enum.UserInputType.Touch then return end
        promptRename(slotData[i] and slotData[i].displayName or "", function(newName)
            if slotData[i] then
                slotData[i].displayName = newName
                ensureSlotDir()
                local names = {}
                local raw = fileRead(SLOT_DIR.."/names.json")
                if raw then names = jsonDecode(raw) or {} end
                names[tostring(i)] = newName
                fileWrite(SLOT_DIR.."/names.json", encodeVal(names))
                refreshRow(i)
            end
        end)
    end)
    local SubLabel = set(Instance.new("TextLabel"), {
        Name="Slot1Sub", Parent=NameLabel, BackgroundTransparency=1,
        Position=UDim2.new(0,0,0.9,0), Size=UDim2.new(0.75,0,0.75,0), ZIndex=4,
        Font=Enum.Font.SourceSans,
        Text=sd and slotExists(sd.obbyId, sd.slotNum) and ("ID: "..sd.obbyId.." #"..sd.slotNum) or "Empty",
        TextColor3=Color3.fromRGB(150,150,150), TextScaled=true, TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,
    })
    local function makeBtn(name, emoji, xPos, bg)
        local btn = set(Instance.new("TextButton"), {
            Name=name, Parent=Row, AnchorPoint=Vector2.new(0,1),
            BackgroundColor3=bg, BorderColor3=Color3.fromRGB(27,42,53),
            Position=UDim2.new(xPos,0,0.85,0), Size=UDim2.new(0.2,0,0.75,0),
            ZIndex=3, Font=Enum.Font.SourceSans, Text="",
        })
        set(Instance.new("UICorner"), {Parent=btn})
        set(Instance.new("TextLabel"), {
            Parent=btn, AnchorPoint=Vector2.new(0.5,0.5), BackgroundTransparency=1,
            Position=UDim2.new(0.5,0,0.55,0), Size=UDim2.new(1,-5,1,-5), ZIndex=5,
            Font=Enum.Font.Cartoon, Text=emoji,
            TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextWrapped=true,
        })
        return btn
    end
    local saveBtn   = makeBtn("SaveBtn",   "💾", 0.36, Color3.fromRGB(85,170,255))
    local loadBtn   = makeBtn("LoadBtn",   "📂", 0.58, Color3.fromRGB(180,180,180))
    local deleteBtn = makeBtn("DeleteBtn", "🗑️", 0.80, Color3.fromRGB(180,180,180))

    saveBtn.MouseButton1Click:Connect(function()
        local info = parseCurrentObby()
        if not info then setSlotStatus("⚠ No obby loaded", true); return end
        slotData[i] = slotData[i] or {displayName=""}
        slotData[i].obbyId  = info.obbyId
        slotData[i].slotNum = info.slot
        local ok = saveSlot(info.obbyId, info.slot, i)
        setSlotStatus(ok and "✔ Saved slot "..i or "⚠ Saved slot "..i.." (origin missing)", not ok)
        refreshRow(i)
    end)
    loadBtn.MouseButton1Click:Connect(function()
        local sd2 = slotData[i]
        if not sd2 or not slotExists(sd2.obbyId, sd2.slotNum) then
            setSlotStatus("⚠ Slot "..i.." is empty", true); return end
        local info = parseCurrentObby()
        if not info then setSlotStatus("⚠ Not in an obby", true); return end
        if info.obbyId ~= sd2.obbyId then
            setSlotStatus("⚠ Wrong obby (need "..sd2.obbyId..")", true); return end
        local ok2, msg = loadSlot(sd2.obbyId, sd2.slotNum)
        setSlotStatus(ok2 and "✔ "..msg or "✘ "..msg, not ok2)
    end)
    deleteBtn.MouseButton1Click:Connect(function()
        local sd2 = slotData[i]
        if not sd2 or not slotExists(sd2.obbyId, sd2.slotNum) then
            setSlotStatus("⚠ Slot "..i.." is empty", true); return end
        deleteSlot(sd2.obbyId, sd2.slotNum)
        slotData[i].obbyId  = ""
        slotData[i].slotNum = ""
        ensureSlotDir()
        local manifest = {}
        local raw = fileRead(SLOT_DIR.."/manifest.json")
        if raw then manifest = jsonDecode(raw) or {} end
        manifest[tostring(i)] = nil
        fileWrite(SLOT_DIR.."/manifest.json", encodeVal(manifest))
        setSlotStatus("🗑 Slot "..i.." deleted")
        refreshRow(i)
    end)

    slotRows[i] = {Frame=Row, NameLabel=NameLabel, SubLabel=SubLabel,
                   SaveBtn=saveBtn, LoadBtn=loadBtn, DeleteBtn=deleteBtn}
end

-- AddSlot row (always at bottom)
local AddSlotFrame = set(Instance.new("Frame"), {
    Name="AddSlot", Parent=SlotContainer, BackgroundColor3=Color3.fromRGB(255,255,255),
    BorderSizePixel=0, Size=UDim2.new(1,0,0,41), LayoutOrder=99999,
})
local AddSlotBtn = set(Instance.new("TextButton"), {
    Name="AddSlot", Parent=AddSlotFrame, AnchorPoint=Vector2.new(0,1),
    BackgroundColor3=Color3.fromRGB(200,200,200), BorderColor3=Color3.fromRGB(27,42,53),
    Position=UDim2.new(0.44,0,0.8,0), Size=UDim2.new(0.12,0,0.55,0),
    ZIndex=3, Font=Enum.Font.SourceSans, Text="",
})
set(Instance.new("UICorner"), {Parent=AddSlotBtn, CornerRadius=UDim.new(0,3)})
set(Instance.new("TextLabel"), {
    Parent=AddSlotBtn, AnchorPoint=Vector2.new(0.5,0.5), BackgroundTransparency=1,
    Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(1,-5,1,-5), ZIndex=5,
    Font=Enum.Font.Cartoon, Text="➕",
    TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextWrapped=true,
})

local function addSlot(sd)
    slotCount += 1
    local i = slotCount
    slotData[i] = sd or {obbyId="", slotNum="", displayName=""}
    makeSlotRow(i, slotData[i])
    AddSlotFrame.LayoutOrder = slotCount + 1
    return i
end

AddSlotBtn.MouseButton1Click:Connect(function()
    addSlot(nil)
    ensureSlotDir()
    local manifest = {}
    local raw = fileRead(SLOT_DIR.."/manifest.json")
    if raw then manifest = jsonDecode(raw) or {} end
    manifest["count"] = slotCount
    fileWrite(SLOT_DIR.."/manifest.json", encodeVal(manifest))
end)

-- Bottom Save: new slot + save
BottomSaveBtn.MouseButton1Click:Connect(function()
    local info = parseCurrentObby()
    if not info then setSlotStatus("⚠ No obby loaded", true); return end
    local i = addSlot({obbyId=info.obbyId, slotNum=info.slot, displayName=""})
    local ok = saveSlot(info.obbyId, info.slot, i)
    ensureSlotDir()
    local manifest = {}
    local raw = fileRead(SLOT_DIR.."/manifest.json")
    if raw then manifest = jsonDecode(raw) or {} end
    manifest[tostring(i)] = {obbyId=info.obbyId, slotNum=info.slot}
    manifest["count"] = slotCount
    fileWrite(SLOT_DIR.."/manifest.json", encodeVal(manifest))
    setSlotStatus(ok and "✔ Saved new slot "..i or "⚠ Saved slot "..i.." (origin missing)", not ok)
    refreshRow(i)
end)

-- Bottom Load: most recent matching slot
BottomLoadBtn.MouseButton1Click:Connect(function()
    local info = parseCurrentObby()
    if not info then setSlotStatus("⚠ No obby loaded", true); return end
    for i = slotCount, 1, -1 do
        local sd = slotData[i]
        if sd and slotExists(sd.obbyId, sd.slotNum) and sd.obbyId == info.obbyId then
            local ok2, msg = loadSlot(sd.obbyId, sd.slotNum)
            setSlotStatus(ok2 and "✔ "..msg or "✘ "..msg, not ok2)
            return
        end
    end
    setSlotStatus("⚠ No saved slot for this obby", true)
end)

-- ── Populate slots from manifest ──────────────────────────────────────────────
local function populateSlotData()
    for i = 1, slotCount do
        if slotRows[i] then slotRows[i].Frame:Destroy() end
    end
    slotRows = {}; slotData = {}; slotCount = 0
    local names = {}
    local rawN = fileRead(SLOT_DIR.."/names.json")
    if rawN then names = jsonDecode(rawN) or {} end
    local manifest = {}
    local rawM = fileRead(SLOT_DIR.."/manifest.json")
    if rawM then manifest = jsonDecode(rawM) or {} end
    local count = tonumber(manifest["count"]) or 0
    for i = 1, count do
        local entry = manifest[tostring(i)]
        addSlot({
            obbyId      = entry and entry.obbyId  or "",
            slotNum     = entry and entry.slotNum or "",
            displayName = names[tostring(i)] or "",
        })
    end
    if slotCount == 0 then addSlot(nil) end
    for i = 1, slotCount do refreshRow(i) end
    local info = parseCurrentObby()
    InfoLabel.Text = info and (info.obbyId.." #"..info.slot) or "No obby loaded!"
    InfoLabel.TextColor3 = info and Color3.fromRGB(0,150,0) or Color3.fromRGB(0,0,0)
end

-- ── Real-time obby watcher ────────────────────────────────────────────────────
local function onObbyChanged()
    local info = parseCurrentObby()
    InfoLabel.Text = info and (info.obbyId.." #"..info.slot) or "No obby loaded!"
    InfoLabel.TextColor3 = info and Color3.fromRGB(0,150,0) or Color3.fromRGB(0,0,0)
    for i = 1, slotCount do refreshRow(i) end
end
task.spawn(function()
    local loadObbyGui = plr.PlayerGui:WaitForChild("LoadObby", 30)
    if not loadObbyGui then return end
    local lbl = loadObbyGui:WaitForChild("CurrentObby", 30)
    if not lbl then return end
    lbl:GetPropertyChangedSignal("Text"):Connect(onObbyChanged)
    lbl:GetPropertyChangedSignal("Visible"):Connect(onObbyChanged)
    onObbyChanged()
end)

MenuFrame:GetPropertyChangedSignal("Visible"):Connect(function()
    if MenuFrame.Visible then populateSlotData() end
end)

-- ── Transparency / target box logic ──────────────────────────────────────────
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

-- ── Wire keybind rows to HUD labels ──────────────────────────────────────────
wirePause(pauseLabel,    pauseFunc,    function(v) pauseKey    = v end)
wireCreate(createLabel,  createFunc,   function(v) createKey   = v end)
wireDelete(deleteLabel,  deleteFunc,   function(v) deleteKey   = v end)
wireTeleport(tpLabel,    teleportFunc, function(v) teleportKey = v end)
wireMenu(menuLabel,      function() MenuFrame.Visible = not MenuFrame.Visible end,
    function(v) menuKey = v end)


-- ── TopbarPlus icon (opens/closes the settings menu) ────────────────────────
local _topbarOk, _topbarErr = pcall(function()
    local RS_mod = game:GetService("ReplicatedStorage")
    local Icon = require(RS_mod:WaitForChild("Icons"):WaitForChild("TopBarIcon"))
    local menuIcon = Icon.new()
    menuIcon:setImage("rbxassetid://7733960981")  -- generic settings cog; swap as needed
    menuIcon:setLabel("CP Menu")
    menuIcon:setOrder(1)
    menuIcon.selected:Connect(function()
        MenuFrame.Visible = true
    end)
    menuIcon.deselected:Connect(function()
        MenuFrame.Visible = false
    end)
    -- Keep icon state in sync if menu is closed via the X button
    MenuFrame:GetPropertyChangedSignal("Visible"):Connect(function()
        if not MenuFrame.Visible then
            menuIcon:deselect()
        end
    end)
end)
if not _topbarOk then
    warn("TopbarPlus icon failed to load: " .. tostring(_topbarErr))
end

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

-- ══════════════════════════════════════════════════════════════════════════════
-- SLOT SAVE SYSTEM  (game 2913303231 only)
-- ══════════════════════════════════════════════════════════════════════════════
if game.PlaceId == 2913303231 then

    -- ── Helpers ───────────────────────────────────────────────────────────────

    -- CurrentObby is a TextLabel in PlayerGui.LoadObby whose .Text is:
    -- "Obby | By PlayerName | 8395756666#5"
    -- Parse the obbyId and slot number from that text.
    local function parseCurrentObby()
        local loadObbyGui = plr.PlayerGui:FindFirstChild("LoadObby")
        if not loadObbyGui then return nil end
        local lbl = loadObbyGui:FindFirstChild("CurrentObby")
        if not lbl then return nil end
        -- If the label is hidden the player has left the obby
        if not lbl.Visible then return nil end
        -- Support both TextLabel.Text and any Value instance just in case
        local text = lbl:IsA("TextLabel") and lbl.Text or tostring(lbl.Value or "")
        local obbyId, slotNum = text:match("(%d+)#(%d+)")
        if not obbyId then return nil end
        -- Also try to find the obby folder in Workspace.Obbies for origin CFrame
        local folder = nil
        local obbies = Workspace:FindFirstChild("Obbies")
        if obbies then
            for _, slotModel in ipairs(obbies:GetChildren()) do
                local getObby = slotModel:FindFirstChild("GetObby")
                if getObby then
                    for _, desc in ipairs(getObby:GetDescendants()) do
                        if desc:IsA("TextLabel") and desc.Text:find(obbyId .. "#" .. slotNum, 1, true) then
                            folder = slotModel
                            break
                        end
                    end
                end
                if folder then break end
            end
        end
        return { obbyId = obbyId, slot = slotNum, raw = text, folder = folder }
    end

    -- Find the GetObby model for the currently loaded obby by matching the
    -- obby ID in the slot's nameplate TextLabels — not by proximity.
    -- This is reliable regardless of where the player is standing.
    local function findWorldSlotModel()
        local info = parseCurrentObby()
        if not info or not info.folder then return nil end
        return info.folder:FindFirstChild("GetObby")
    end

    -- Get the origin CFrame of a GetObby model using the Gate part.
    -- Gate is always present, always at the slot entrance, and its CFrame
    -- encodes both position and rotation (left side = identity, right side = 180deg Y).
    local function getOriginCF(getObby)
        local gate = getObby:FindFirstChild("Gate", true)
        if gate and gate:IsA("BasePart") then return gate.CFrame end
        -- Fallback: any basepart (Gate is always there so this should never run)
        for _, p in ipairs(getObby:GetDescendants()) do
            if p:IsA("BasePart") then return p.CFrame end
        end
        return CFrame.new()
    end

    -- Remap a CFrame saved in originCF-space into targetCF-space.
    -- Formula: targetCF * originCF:Inverse() * cf
    local function remapCF(cf, originCF, targetCF)
        return targetCF * originCF:Inverse() * cf
    end

    -- ── Per-slot file paths ───────────────────────────────────────────────────
    local SLOT_DIR = "AdvancedCP/slots"

    local function slotFilePath(obbyId, slotNum)
        return SLOT_DIR .. "/" .. obbyId .. "_" .. tostring(slotNum) .. ".json"
    end

    local function ensureSlotDir()
        ensureDir()  -- makes AdvancedCP/
        pcall(function()
            if isfolder and not isfolder(SLOT_DIR) then makefolder(SLOT_DIR) end
        end)
    end

    -- ── Save / Load for slots ─────────────────────────────────────────────────

    local function saveSlot(obbyId, slotNum)
        ensureSlotDir()
        local originCF
        local getObby = findWorldSlotModel()
        if getObby then
            originCF = getOriginCF(getObby)
        end
        local data = {
            obbyId      = obbyId,
            slot        = slotNum,
            counter     = cpCounter,
            originCF    = originCF and cf2t(originCF) or nil,
            checkpoints = {},
        }
        for _, cp in ipairs(CPFolder:GetChildren()) do
            if cp:IsA("BasePart") then
                data.checkpoints[#data.checkpoints+1] = serializeCP(cp)
            end
        end
        fileWrite(slotFilePath(obbyId, slotNum), encodeVal(data))
        -- Return whether origin was captured so caller can warn if missing
        return originCF ~= nil
    end

    local function loadSlot(obbyId, slotNum)
        local path = slotFilePath(obbyId, slotNum)
        local raw = fileRead(path)
        if not raw then return false, "No save found" end
        local data = jsonDecode(raw)
        if not data or not data.checkpoints then return false, "Corrupt save" end

        -- Determine remap: saved origin → current world slot origin
        local savedOriginCF = data.originCF and t2cf(data.originCF) or nil
        local currentOriginCF = nil
        local getObby = findWorldSlotModel()
        if getObby then currentOriginCF = getOriginCF(getObby) end

        -- Clear existing checkpoints
        for _, cp in ipairs(CPFolder:GetChildren()) do cp:Destroy() end
        cpCounter = 0

        for _, entry in ipairs(data.checkpoints) do
            cpCounter += 1
            local cp = createCheckpointPart()
            cp.Name = entry.name or ("CP_" .. cpCounter)

            local cf       = t2cf(entry.cframe)
            local stepped  = t2cf(entry.steppedCF)
            local cameraCF = t2cf(entry.cameraCF)

            -- Remap if we have both origins and they differ meaningfully
            if savedOriginCF and currentOriginCF then
                cf       = remapCF(cf,       savedOriginCF, currentOriginCF)
                stepped  = remapCF(stepped,  savedOriginCF, currentOriginCF)
                cameraCF = remapCF(cameraCF, savedOriginCF, currentOriginCF)
            end

            cp.CFrame = cf
            cp.CharacterCFrame.Value                  = cf
            cp.SteppedCFrame.Value                    = stepped
            cp.CameraCFrame.Value                     = cameraCF
            cp.CharacterAssemblyLinearVelocity.Value  = tv3(entry.linVel)
            cp.CharacterAssemblyAngularVelocity.Value = tv3(entry.angVel)
            cp.HumanoidStateType.Value                = entry.state or "Running"
            cp.Parent = CPFolder
        end
        cpCounter = tonumber(data.counter) or cpCounter
        return true, "Loaded " .. cpCounter .. " checkpoints"
    end

    local function deleteSlot(obbyId, slotNum)
        local path = slotFilePath(obbyId, slotNum)
        if isfile and isfile(path) then
            pcall(function() delfile(path) end)  -- delfile is standard on Synapse/KRNL/Fluxus
        end
    end

    local function slotExists(obbyId, slotNum)
        local path = slotFilePath(obbyId, slotNum)
        return isfile and isfile(path) or false
    end

    -- ── Slot UI ───────────────────────────────────────────────────────────────

    -- ── Right panel: LimitsFrame (slot saves, lives inside ThisFrame) ─────────
    -- This is part of the same SettingsFrame window — not a separate UI.
    -- Only added when PlaceId matches. The left panel (Menu scroll) still works.
    local LimitsFrame = set(Instance.new("Frame"), {
        Name="LimitsFrame", Parent=ThisFrame,
        AnchorPoint=Vector2.new(1,0), BackgroundTransparency=1, BorderSizePixel=0,
        Position=UDim2.new(0.95,0,0.15,0), Size=UDim2.new(0.4,0,0.7,0),
    })
    set(Instance.new("UICorner"), {Parent=LimitsFrame})

    -- "Current Obby:" header with divider line
    local CurrentObbyHeader = set(Instance.new("TextLabel"), {
        Name="CurrentObby", Parent=LimitsFrame,
        AnchorPoint=Vector2.new(0.5,0.5), BackgroundTransparency=1,
        BorderColor3=Color3.fromRGB(27,42,53),
        Position=UDim2.new(0.5,0,0.05,0), Size=UDim2.new(1,0,0.1,-1), ZIndex=4,
        Font=Enum.Font.SourceSansBold, Text="Current Obby:",
        TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextWrapped=true,
    })
    set(Instance.new("Frame"), {
        Parent=CurrentObbyHeader,
        BackgroundColor3=Color3.fromRGB(150,150,150), BorderSizePixel=0,
        Position=UDim2.new(0,0,2,0), Size=UDim2.new(1,0,0,1),
    })

    -- ObbyId label (updates in real time)
    local InfoLabel = set(Instance.new("TextLabel"), {
        Name="ObbyId", Parent=LimitsFrame,
        AnchorPoint=Vector2.new(0.5,0.5), BackgroundTransparency=1,
        BorderColor3=Color3.fromRGB(27,42,53),
        Position=UDim2.new(0.5,0,0.15,0), Size=UDim2.new(1,0,0.1,-1), ZIndex=4,
        Font=Enum.Font.SourceSansBold, Text="No obby loaded!",
        TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextWrapped=true,
    })

    -- Slot scrolling frame
    local SlotScroll = set(Instance.new("ScrollingFrame"), {
        Active=true, Parent=LimitsFrame,
        AnchorPoint=Vector2.new(0.5,0.5), BackgroundTransparency=1, BorderSizePixel=0,
        Position=UDim2.new(0.5,0,0.65,0), Size=UDim2.new(1,0,0.9,0),
        CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
        ScrollBarThickness=8,
    })
    set(Instance.new("UIListLayout"), {
        Parent=SlotScroll, SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0,1),
    })

    -- "Saves" title row
    set(Instance.new("TextLabel"), {
        Name="1ATitle", Parent=SlotScroll,
        BackgroundTransparency=1, BorderColor3=Color3.fromRGB(27,42,53),
        Size=UDim2.new(1,-10,0,20), ZIndex=4, LayoutOrder=0,
        Font=Enum.Font.SourceSansBold, Text="Saves",
        TextColor3=Color3.fromRGB(50,50,50), TextScaled=true, TextWrapped=true,
    })

    -- Slot rows container (1BFrame)
    local SlotContainer = set(Instance.new("Frame"), {
        Name="1BFrame", Parent=SlotScroll,
        BackgroundTransparency=1, BorderSizePixel=0,
        Size=UDim2.new(1,-10,0,0), AutomaticSize=Enum.AutomaticSize.Y,
        LayoutOrder=1,
    })
    set(Instance.new("UIListLayout"), {
        Parent=SlotContainer, SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0,2),
    })

    -- Status label
    local StatusLabel = set(Instance.new("TextLabel"), {
        Parent=LimitsFrame, AnchorPoint=Vector2.new(0.5,1),
        BackgroundTransparency=1, BorderSizePixel=0,
        Position=UDim2.new(0.5,0,1,0), Size=UDim2.new(1,0,0.08,0), ZIndex=4,
        Font=Enum.Font.SourceSansBold, Text="",
        TextColor3=Color3.fromRGB(100,100,100), TextScaled=true, TextWrapped=true,
    })

    local function setStatus(msg, isError)
        StatusLabel.Text = msg
        StatusLabel.TextColor3 = isError
            and Color3.fromRGB(200,50,50)
            or  Color3.fromRGB(50,150,50)
        task.delay(3, function()
            if StatusLabel.Text == msg then StatusLabel.Text = "" end
        end)
    end

    -- ── Rename popup (inside MenuFrame) ──────────────────────────────────────
    local RenamePopup = set(Instance.new("Frame"), {
        Parent=MenuFrame, AnchorPoint=Vector2.new(0.5,0.5),
        BackgroundColor3=Color3.fromRGB(255,255,255), BorderSizePixel=0,
        Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(0.5,0,0.25,0),
        Visible=false, ZIndex=10,
    })
    set(Instance.new("UICorner"), {Parent=RenamePopup})
    set(Instance.new("TextLabel"), {
        Parent=RenamePopup, BackgroundTransparency=1,
        Position=UDim2.new(0,0,0,0), Size=UDim2.new(1,0,0.3,0), ZIndex=11,
        Font=Enum.Font.GothamBold, Text="Rename slot",
        TextColor3=Color3.fromRGB(50,50,50), TextScaled=true,
    })
    local RenameBox = set(Instance.new("TextBox"), {
        Parent=RenamePopup, AnchorPoint=Vector2.new(0.5,0.5),
        BackgroundColor3=Color3.fromRGB(220,220,220), BorderSizePixel=0,
        Position=UDim2.new(0.5,0,0.55,0), Size=UDim2.new(0.85,0,0.28,0),
        ZIndex=11, Font=Enum.Font.Gotham,
        PlaceholderText="Enter name...", Text="",
        TextColor3=Color3.fromRGB(30,30,30), TextScaled=true, ClearTextOnFocus=true,
    })
    set(Instance.new("UICorner"), {Parent=RenameBox, CornerRadius=UDim.new(0,4)})
    local RenameConfirm = set(Instance.new("TextButton"), {
        Parent=RenamePopup, AnchorPoint=Vector2.new(0.5,1),
        BackgroundColor3=Color3.fromRGB(0,150,80), BorderSizePixel=0,
        Position=UDim2.new(0.5,0,1,-4), Size=UDim2.new(0.5,0,0.26,0),
        ZIndex=11, Font=Enum.Font.GothamBold, Text="Confirm",
        TextColor3=Color3.fromRGB(255,255,255), TextScaled=true,
    })
    set(Instance.new("UICorner"), {Parent=RenameConfirm, CornerRadius=UDim.new(0,4)})
    local _renameCallback = nil
    RenameConfirm.MouseButton1Click:Connect(function()
        if _renameCallback then _renameCallback(RenameBox.Text) end
        RenamePopup.Visible = false
    end)
    local function promptRename(currentName, callback)
        RenameBox.Text = currentName or ""
        _renameCallback = callback
        RenamePopup.Visible = true
        RenameBox:CaptureFocus()
    end

    -- ── Slot data & rows ──────────────────────────────────────────────────────
    local slotData  = {}
    local slotRows  = {}
    local slotCount = 0

    local function slotExists(obbyId, slotNum)
        return obbyId and obbyId ~= "" and isfile and isfile(slotFilePath(obbyId, slotNum)) or false
    end

    local function refreshRow(i)
        local row = slotRows[i]
        if not row then return end
        local sd = slotData[i]
        if not sd then return end
        local exists  = slotExists(sd.obbyId, sd.slotNum)
        local info    = parseCurrentObby()
        local isMatch = info and sd.obbyId ~= "" and info.obbyId == sd.obbyId
        local canLoad = exists and isMatch
        row.NameLabel.Text = sd.displayName ~= "" and sd.displayName or ("Slot " .. i)
        row.SubLabel.Text  = exists and ("ID: "..sd.obbyId.." #"..sd.slotNum) or "Empty"
        row.SubLabel.TextColor3 = exists
            and Color3.fromRGB(100,100,100) or Color3.fromRGB(150,150,150)
        row.LoadBtn.BackgroundColor3 = canLoad
            and Color3.fromRGB(0,255,0) or Color3.fromRGB(180,180,180)
        row.LoadBtn.Active   = canLoad
        row.SaveBtn.BackgroundColor3 = Color3.fromRGB(85,170,255)
        row.DeleteBtn.BackgroundColor3 = exists
            and Color3.fromRGB(255,0,0) or Color3.fromRGB(180,180,180)
        row.DeleteBtn.Active = exists
    end

    local function makeSlotRow(i, sd)
        local Row = set(Instance.new("Frame"), {
            Name="Slot"..i, Parent=SlotContainer,
            BackgroundColor3=Color3.fromRGB(255,255,255),
            BorderColor3=Color3.fromRGB(0,0,0), BorderSizePixel=0,
            Size=UDim2.new(1,0,0,54), LayoutOrder=i,
        })

        -- Name label (top-left, click to rename)
        local nameLabel = set(Instance.new("TextLabel"), {
            Name="Slot1", Parent=Row,
            BackgroundTransparency=1, BorderColor3=Color3.fromRGB(27,42,53),
            Position=UDim2.new(0.025,0,0,0), Size=UDim2.new(1,0,0.5,0), ZIndex=4,
            Font=Enum.Font.SourceSans,
            Text=sd and sd.displayName ~= "" and sd.displayName or ("Slot "..i),
            TextColor3=Color3.fromRGB(50,50,50), TextScaled=true, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
        })

        -- Sub label (obby ID or "Empty")
        local subLabel = set(Instance.new("TextLabel"), {
            Name="Slot1Sub", Parent=nameLabel,
            BackgroundTransparency=1, BorderColor3=Color3.fromRGB(27,42,53),
            Position=UDim2.new(0,0,0.9,0), Size=UDim2.new(0.75,0,0.75,0), ZIndex=4,
            Font=Enum.Font.SourceSans, Text="Empty",
            TextColor3=Color3.fromRGB(150,150,150), TextScaled=true, TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
        })

        nameLabel.InputBegan:Connect(function(inp)
            if inp.UserInputType ~= Enum.UserInputType.MouseButton1
            and inp.UserInputType ~= Enum.UserInputType.Touch then return end
            promptRename(slotData[i] and slotData[i].displayName or "", function(newName)
                if slotData[i] then
                    slotData[i].displayName = newName
                    ensureSlotDir()
                    local names = {}
                    local raw = fileRead(SLOT_DIR.."/names.json")
                    if raw then names = jsonDecode(raw) or {} end
                    names[tostring(i)] = newName
                    fileWrite(SLOT_DIR.."/names.json", encodeVal(names))
                    refreshRow(i)
                end
            end)
        end)

        -- Button factory (matches G2L slot buttons)
        local function makeBtn(name, emoji, xPos, bgColor)
            local btn = set(Instance.new("TextButton"), {
                Name=name, Parent=Row,
                AnchorPoint=Vector2.new(0,1),
                BackgroundColor3=bgColor, BorderColor3=Color3.fromRGB(27,42,53),
                Position=UDim2.new(xPos,0,0.85,0), Size=UDim2.new(0.2,0,0.75,0),
                ZIndex=3, Font=Enum.Font.SourceSans, Text="",
            })
            set(Instance.new("UICorner"), {Parent=btn})
            set(Instance.new("TextLabel"), {
                Parent=btn, AnchorPoint=Vector2.new(0.5,0.5),
                BackgroundTransparency=1, BorderColor3=Color3.fromRGB(27,42,53),
                Position=UDim2.new(0.5,0,0.55,0), Size=UDim2.new(1,-5,1,-5),
                ZIndex=5, Font=Enum.Font.Cartoon, Text=emoji,
                TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextWrapped=true,
            })
            return btn
        end

        local saveBtn   = makeBtn("SaveBtn",   "💾", 0.36, Color3.fromRGB(85,170,255))
        local loadBtn   = makeBtn("LoadBtn",   "📂", 0.58, Color3.fromRGB(180,180,180))
        local deleteBtn = makeBtn("DeleteBtn", "🗑️", 0.80, Color3.fromRGB(180,180,180))

        saveBtn.MouseButton1Click:Connect(function()
            local info = parseCurrentObby()
            if not info then setStatus("⚠ No obby loaded", true); return end
            slotData[i] = slotData[i] or {displayName=""}
            slotData[i].obbyId  = info.obbyId
            slotData[i].slotNum = info.slot
            local gotOrigin = saveSlot(info.obbyId, info.slot, i)
            setStatus(gotOrigin and "✔ Saved slot "..i or "⚠ Saved slot "..i.." (origin missing)", not gotOrigin)
            refreshRow(i)
        end)

        loadBtn.MouseButton1Click:Connect(function()
            local sd2 = slotData[i]
            if not sd2 or not slotExists(sd2.obbyId, sd2.slotNum) then
                setStatus("⚠ Slot "..i.." is empty", true); return
            end
            local info = parseCurrentObby()
            if not info then setStatus("⚠ Not in an obby", true); return end
            if info.obbyId ~= sd2.obbyId then
                setStatus("⚠ Wrong obby (need ID: "..sd2.obbyId..")", true); return
            end
            local ok, msg = loadSlot(sd2.obbyId, sd2.slotNum)
            setStatus(ok and "✔ "..msg or "✘ "..msg, not ok)
        end)

        deleteBtn.MouseButton1Click:Connect(function()
            local sd2 = slotData[i]
            if not sd2 or not slotExists(sd2.obbyId, sd2.slotNum) then
                setStatus("⚠ Slot "..i.." is empty", true); return
            end
            deleteSlot(sd2.obbyId, sd2.slotNum)
            slotData[i].obbyId  = ""
            slotData[i].slotNum = ""
            ensureSlotDir()
            local manifest = {}
            local raw = fileRead(SLOT_DIR.."/manifest.json")
            if raw then manifest = jsonDecode(raw) or {} end
            manifest[tostring(i)] = nil
            fileWrite(SLOT_DIR.."/manifest.json", encodeVal(manifest))
            setStatus("🗑 Slot "..i.." deleted")
            refreshRow(i)
        end)

        slotRows[i] = {
            Frame=Row, NameLabel=nameLabel, SubLabel=subLabel,
            SaveBtn=saveBtn, LoadBtn=loadBtn, DeleteBtn=deleteBtn,
        }
    end

    -- AddSlot row (always pinned at bottom of SlotContainer)
    local AddSlotFrame = set(Instance.new("Frame"), {
        Name="AddSlot", Parent=SlotContainer,
        BackgroundColor3=Color3.fromRGB(255,255,255), BorderSizePixel=0,
        Size=UDim2.new(1,0,0,41), LayoutOrder=99999,
    })
    local AddSlotBtn = set(Instance.new("TextButton"), {
        Name="AddSlot", Parent=AddSlotFrame,
        AnchorPoint=Vector2.new(0,1),
        BackgroundColor3=Color3.fromRGB(200,200,200), BorderColor3=Color3.fromRGB(27,42,53),
        Position=UDim2.new(0.44,0,0.8,0), Size=UDim2.new(0.12,0,0.55,0),
        ZIndex=3, Font=Enum.Font.SourceSans, Text="",
    })
    set(Instance.new("UICorner"), {Parent=AddSlotBtn, CornerRadius=UDim.new(0,3)})
    set(Instance.new("TextLabel"), {
        Parent=AddSlotBtn, AnchorPoint=Vector2.new(0.5,0.5),
        BackgroundTransparency=1, BorderColor3=Color3.fromRGB(27,42,53),
        Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(1,-5,1,-5),
        ZIndex=5, Font=Enum.Font.Cartoon, Text="➕",
        TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextWrapped=true,
    })

    local function persistManifest()
        ensureSlotDir()
        local manifest = {}
        local raw = fileRead(SLOT_DIR.."/manifest.json")
        if raw then manifest = jsonDecode(raw) or {} end
        manifest["count"] = slotCount
        for i = 1, slotCount do
            local sd = slotData[i]
            if sd and sd.obbyId ~= "" then
                manifest[tostring(i)] = {obbyId=sd.obbyId, slotNum=sd.slotNum}
            end
        end
        fileWrite(SLOT_DIR.."/manifest.json", encodeVal(manifest))
    end

    local function addSlot(sd)
        slotCount += 1
        local i = slotCount
        slotData[i] = sd or {obbyId="", slotNum="", displayName=""}
        makeSlotRow(i, slotData[i])
        AddSlotFrame.LayoutOrder = slotCount + 1
        return i
    end

    AddSlotBtn.MouseButton1Click:Connect(function()
        addSlot(nil)
        persistManifest()
    end)

    -- ── Bottom buttons (on ThisFrame, matches G2L SaveButton / LoadButton) ────
    local BottomSaveBtn = set(Instance.new("TextButton"), {
        Name="SaveButton", Parent=ThisFrame,
        AnchorPoint=Vector2.new(0,1),
        BackgroundColor3=Color3.fromRGB(85,170,255), BorderColor3=Color3.fromRGB(27,42,53),
        Position=UDim2.new(0.55,0,0.95,0), Size=UDim2.new(0.19,0,0.075,0),
        ZIndex=3, Font=Enum.Font.SourceSans, Text="",
    })
    set(Instance.new("UICorner"), {Parent=BottomSaveBtn})
    set(Instance.new("TextLabel"), {
        Parent=BottomSaveBtn, AnchorPoint=Vector2.new(0.5,0.5),
        BackgroundTransparency=1, Position=UDim2.new(0.5,0,0.5,0),
        Size=UDim2.new(1,-5,1,-5), ZIndex=5,
        Font=Enum.Font.Cartoon, Text="Save Checkpoints",
        TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextWrapped=true,
    })
    BottomSaveBtn.MouseButton1Click:Connect(function()
        local info = parseCurrentObby()
        if not info then setStatus("⚠ No obby loaded", true); return end
        local i = addSlot({obbyId=info.obbyId, slotNum=info.slot, displayName=""})
        local gotOrigin = saveSlot(info.obbyId, info.slot, i)
        persistManifest()
        setStatus(gotOrigin and "✔ Saved new slot "..i or "⚠ Saved slot "..i.." (origin missing)", not gotOrigin)
        refreshRow(i)
    end)

    local BottomLoadBtn = set(Instance.new("TextButton"), {
        Name="LoadButton", Parent=ThisFrame,
        AnchorPoint=Vector2.new(1,1),
        BackgroundColor3=Color3.fromRGB(0,255,0), BorderColor3=Color3.fromRGB(27,42,53),
        Position=UDim2.new(0.95,0,0.95,0), Size=UDim2.new(0.19,0,0.075,0),
        ZIndex=3, Font=Enum.Font.SourceSans, Text="",
    })
    set(Instance.new("UICorner"), {Parent=BottomLoadBtn})
    set(Instance.new("TextLabel"), {
        Parent=BottomLoadBtn, AnchorPoint=Vector2.new(0.5,0.5),
        BackgroundTransparency=1, Position=UDim2.new(0.5,0,0.5,0),
        Size=UDim2.new(1,-5,1,-5), ZIndex=5,
        Font=Enum.Font.Cartoon, Text="Load Checkpoints",
        TextColor3=Color3.fromRGB(0,0,0), TextScaled=true, TextWrapped=true,
    })
    BottomLoadBtn.MouseButton1Click:Connect(function()
        local info = parseCurrentObby()
        if not info then setStatus("⚠ No obby loaded", true); return end
        for i = slotCount, 1, -1 do
            local sd = slotData[i]
            if sd and slotExists(sd.obbyId, sd.slotNum) and sd.obbyId == info.obbyId then
                local ok, msg = loadSlot(sd.obbyId, sd.slotNum)
                setStatus(ok and "✔ "..msg or "✘ "..msg, not ok)
                return
            end
        end
        setStatus("⚠ No saved slot for this obby", true)
    end)

    -- ── Populate slot rows from manifest on MenuFrame open ────────────────────
    local function populateSlotData()
        for i = 1, slotCount do
            if slotRows[i] then slotRows[i].Frame:Destroy() end
        end
        slotRows = {}; slotData = {}; slotCount = 0

        local names = {}
        local rawNames = fileRead(SLOT_DIR.."/names.json")
        if rawNames then names = jsonDecode(rawNames) or {} end

        local manifest = {}
        local rawManifest = fileRead(SLOT_DIR.."/manifest.json")
        if rawManifest then manifest = jsonDecode(rawManifest) or {} end

        local count = tonumber(manifest["count"]) or 0
        for i = 1, count do
            local entry = manifest[tostring(i)]
            addSlot({
                obbyId      = entry and entry.obbyId  or "",
                slotNum     = entry and entry.slotNum or "",
                displayName = names[tostring(i)] or "",
            })
        end
        if slotCount == 0 then addSlot(nil) end

        for i = 1, slotCount do refreshRow(i) end

        local info = parseCurrentObby()
        InfoLabel.Text = info
            and (info.obbyId .. " #" .. info.slot) or "No obby loaded!"
        InfoLabel.TextColor3 = info
            and Color3.fromRGB(0,150,0) or Color3.fromRGB(0,0,0)
    end

    -- ── Real-time obby watcher ────────────────────────────────────────────────
    local function onObbyChanged()
        local info = parseCurrentObby()
        InfoLabel.Text = info
            and (info.obbyId .. " #" .. info.slot) or "No obby loaded!"
        InfoLabel.TextColor3 = info
            and Color3.fromRGB(0,150,0) or Color3.fromRGB(0,0,0)
        for i = 1, slotCount do refreshRow(i) end
    end

    task.spawn(function()
        local loadObbyGui = plr.PlayerGui:WaitForChild("LoadObby", 30)
        if not loadObbyGui then return end
        local lbl = loadObbyGui:WaitForChild("CurrentObby", 30)
        if not lbl then return end
        lbl:GetPropertyChangedSignal("Text"):Connect(onObbyChanged)
        lbl:GetPropertyChangedSignal("Visible"):Connect(onObbyChanged)
        onObbyChanged()
    end)

    -- Populate when settings window opens
    MenuFrame:GetPropertyChangedSignal("Visible"):Connect(function()
        if MenuFrame.Visible then populateSlotData() end
    end)

end  -- end game ID check
