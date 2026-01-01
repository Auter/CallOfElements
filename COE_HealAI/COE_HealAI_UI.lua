-- COE_HealAI_UI.lua
-- HealAI UI (Vanilla 1.12) - Lua-based injection into Call Of Elements "Healing" tab
-- Smart healing module with tank priority, HealComm integration, and spam mode

local HB = {}
HB.inited = false
HB.uiBuilt = false
HB.activeTab = "CORE"

local function HB_Trim(s)
    if not s then return "" end
    s = tostring(s)
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

-- ============================================================
-- Helper functions for Spam Spell Selection UI
-- (Must be defined early so they can be called from HB_Save/HB_Refresh)
-- ============================================================
local function HB_GetMaxRankForSpellType(spellType)
    if not COE or not COE.HealData then return 10 end
    local data = COE.HealData[spellType]
    if data and table.getn(data) > 0 then
        return table.getn(data)
    end
    return 10  -- Default max if spells not scanned yet
end

local function HB_UpdateSpellTypeButton()
    if not COE_HB_SpamSpellType then return end
    local spellType = COE_HB_SpamSpellType.selected or "Wave"
    local displayName = (spellType == "Lesser") and "Lesser Healing Wave" or "Healing Wave"
    COE_HB_SpamSpellType:SetText(displayName)
end

local function HB_UpdateRankSliderRange()
    if not COE_HB_SpamRankSlider then return end
    local spellType = "Wave"
    if COE_HB_SpamSpellType then
        spellType = COE_HB_SpamSpellType.selected or "Wave"
    end
    local maxRank = HB_GetMaxRankForSpellType(spellType)
    COE_HB_SpamRankSlider:SetMinMaxValues(0, maxRank)
    -- Update the High label
    local highLabel = getglobal(COE_HB_SpamRankSlider:GetName().."High")
    if highLabel then highLabel:SetText(tostring(maxRank)) end
end

local function HB_UpdateRankLabel()
    if not COE_HB_SpamRankValue then return end
    local rank = 0
    if COE_HB_SpamRankSlider then
        rank = math.floor((COE_HB_SpamRankSlider:GetValue() or 0) + 0.5)
    end
    if rank == 0 then
        COE_HB_SpamRankValue:SetText("Max")
    else
        COE_HB_SpamRankValue:SetText("Rank " .. rank)
    end
end

local function HB_ToggleSpellType()
    if not COE_HB_SpamSpellType then return end
    if COE_HB_SpamSpellType.selected == "Wave" then
        COE_HB_SpamSpellType.selected = "Lesser"
    else
        COE_HB_SpamSpellType.selected = "Wave"
    end
    HB_UpdateSpellTypeButton()
    HB_UpdateRankSliderRange()
    -- Reset rank to 0 (max) when changing spell type
    if COE_HB_SpamRankSlider then
        COE_HB_SpamRankSlider:SetValue(0)
    end
    -- Note: HB_Save() will be called by the button's OnClick handler after this
end

-- ============================================================
-- End of early helper functions
-- ============================================================

local function HB_EnsureDefaults()
    -- Ensure COE_Saved exists (may be called before VARIABLES_LOADED during OnShow)
    if not COE_Saved then COE_Saved = {} end

    if COE_Saved.HB_Enable == nil then COE_Saved.HB_Enable = 0 end
    if COE_Saved.HB_TankName == nil then COE_Saved.HB_TankName = "" end
    if COE_Saved.HB_OffTankName == nil then COE_Saved.HB_OffTankName = "" end
    if COE_Saved.HB_UseToT == nil then COE_Saved.HB_UseToT = 1 end

    if COE_Saved.HB_TopUp == nil then COE_Saved.HB_TopUp = 85 end
    if COE_Saved.HB_Emergency == nil then COE_Saved.HB_Emergency = 55 end
    
    -- Tank emergency override
    if COE_Saved.HB_TankEmergencyEnable == nil then COE_Saved.HB_TankEmergencyEnable = 0 end  -- Off by default
    if COE_Saved.HB_TankEmergencyThreshold == nil then COE_Saved.HB_TankEmergencyThreshold = 30 end  -- 30%
    if COE_Saved.HB_TankEmergencyIgnoreHealComm == nil then COE_Saved.HB_TankEmergencyIgnoreHealComm = 1 end  -- On by default

    if COE_Saved.HB_ChainHealEnable == nil then COE_Saved.HB_ChainHealEnable = 1 end
    if COE_Saved.HB_ChainHealMinTargets == nil then COE_Saved.HB_ChainHealMinTargets = 3 end
    if COE_Saved.HB_ChainHealThreshold == nil then COE_Saved.HB_ChainHealThreshold = 60 end
    if COE_Saved.HB_ChainPreferTankBounce == nil then COE_Saved.HB_ChainPreferTankBounce = 1 end

    if COE_Saved.HB_DispelPoison == nil then COE_Saved.HB_DispelPoison = 1 end
    if COE_Saved.HB_DispelDisease == nil then COE_Saved.HB_DispelDisease = 1 end
    if COE_Saved.HB_DispelHPGate == nil then COE_Saved.HB_DispelHPGate = 70 end
    if COE_Saved.HB_DispelTankOnly == nil then COE_Saved.HB_DispelTankOnly = 0 end
    if COE_Saved.HB_DispelSelfFirst == nil then COE_Saved.HB_DispelSelfFirst = 1 end
    if COE_Saved.HB_DispelThrottle == nil then COE_Saved.HB_DispelThrottle = 0 end  -- 0 = no throttle

    if COE_Saved.HB_RaidOnly == nil then COE_Saved.HB_RaidOnly = 0 end
    if COE_Saved.HB_IgnorePets == nil then COE_Saved.HB_IgnorePets = 1 end
    if COE_Saved.HB_PrioritizeTank == nil then COE_Saved.HB_PrioritizeTank = 1 end

    if COE_Saved.HB_GroupPrio == nil then
        COE_Saved.HB_GroupPrio = {}
        local i
        for i=1,8 do COE_Saved.HB_GroupPrio[i] = 1 end
    else
        local i
        for i=1,8 do
            if COE_Saved.HB_GroupPrio[i] == nil then COE_Saved.HB_GroupPrio[i] = 1 end
        end
    end

    -- HealComm options
    if COE_Saved.HB_UseHealComm == nil then COE_Saved.HB_UseHealComm = 1 end
    if COE_Saved.HB_ConservativeHealComm == nil then COE_Saved.HB_ConservativeHealComm = 0 end  -- Off by default
    if COE_Saved.HB_HealCommMode == nil then COE_Saved.HB_HealCommMode = "RANK_ADJUST" end  -- Default: adjust rank
    if COE_Saved.HB_SpamMode == nil then COE_Saved.HB_SpamMode = 1 end  -- Controller spam
    
    -- Spam heal spell selection
    if COE_Saved.HB_SpamSpellType == nil then COE_Saved.HB_SpamSpellType = "Wave" end  -- "Wave" or "Lesser"
    if COE_Saved.HB_SpamSpellRank == nil then COE_Saved.HB_SpamSpellRank = 0 end  -- 0 = max rank
    
    -- SuperWoW QoL features
    if COE_Saved.HB_ShowTotemRange == nil then COE_Saved.HB_ShowTotemRange = 0 end  -- Off by default
    if COE_Saved.HB_ShowTankDistance == nil then COE_Saved.HB_ShowTankDistance = 0 end  -- Off by default
    if COE_Saved.HB_ShieldReminder == nil then COE_Saved.HB_ShieldReminder = 0 end  -- Off by default
end

local function HB_SetTankFromTarget(which)
    if not UnitExists("target") then return end
    local n = UnitName("target")
    if not n then return end
    n = HB_Trim(n)
    if which == "OFF" then
        if COE_HB_OffTankEdit then COE_HB_OffTankEdit:SetText(n) end
    else
        if COE_HB_TankEdit then COE_HB_TankEdit:SetText(n) end
    end
end

local function HB_Save()
    if not COE_Saved then return end
    HB_EnsureDefaults()

    if COE_HB_EnableHealBrain then 
        COE_Saved.HB_Enable = (COE_HB_EnableHealBrain:GetChecked() and 1 or 0)
    end
    if COE_HB_TankEdit then COE_Saved.HB_TankName = HB_Trim(COE_HB_TankEdit:GetText()) end
    if COE_HB_OffTankEdit then COE_Saved.HB_OffTankName = HB_Trim(COE_HB_OffTankEdit:GetText()) end
    if COE_HB_UseToT then COE_Saved.HB_UseToT = (COE_HB_UseToT:GetChecked() and 1 or 0) end

    -- NOTE: TopUp and Emergency sliders save themselves in OnValueChanged
    -- We just update the display text here if needed
    if COE_HB_TopUpSlider and COE_HB_TopUpValue then
        COE_HB_TopUpValue:SetText((COE_Saved.HB_TopUp or 85) .. "%")
    end
    if COE_HB_EmergSlider and COE_HB_EmergValue then
        COE_HB_EmergValue:SetText((COE_Saved.HB_Emergency or 55) .. "%")
    end

    if COE_HB_ChainEnable then COE_Saved.HB_ChainHealEnable = (COE_HB_ChainEnable:GetChecked() and 1 or 0) end
    if COE_HB_ChainMinSlider then
        local v = math.floor((COE_HB_ChainMinSlider:GetValue() or 3) + 0.5)
        if v < 2 then v = 2 end
        if v > 5 then v = 5 end
        COE_Saved.HB_ChainHealMinTargets = v
        if COE_HB_ChainMinValue then COE_HB_ChainMinValue:SetText(v) end
    end
    if COE_HB_ChainHP then
        local v = math.floor((COE_HB_ChainHP:GetValue() or 60) + 0.5)
        if v < 30 then v = 30 end
        if v > 95 then v = 95 end
        COE_Saved.HB_ChainHealThreshold = v
        if COE_HB_ChainHPValue then COE_HB_ChainHPValue:SetText(v .. "%") end
    end
    if COE_HB_ChainPreferTank then COE_Saved.HB_ChainPreferTankBounce = (COE_HB_ChainPreferTank:GetChecked() and 1 or 0) end

    if COE_HB_DispelPoison then COE_Saved.HB_DispelPoison = (COE_HB_DispelPoison:GetChecked() and 1 or 0) end
    if COE_HB_DispelDisease then COE_Saved.HB_DispelDisease = (COE_HB_DispelDisease:GetChecked() and 1 or 0) end
    if COE_HB_DispelTankOnly then COE_Saved.HB_DispelTankOnly = (COE_HB_DispelTankOnly:GetChecked() and 1 or 0) end
    if COE_HB_DispelSelfFirst then COE_Saved.HB_DispelSelfFirst = (COE_HB_DispelSelfFirst:GetChecked() and 1 or 0) end
    -- NOTE: DispelGate slider saves itself in OnValueChanged
    if COE_HB_DispelGate and COE_HB_DispelGateValue then
        COE_HB_DispelGateValue:SetText((COE_Saved.HB_DispelHPGate or 70) .. "%")
    end
    -- NOTE: DispelThrottle slider saves itself in OnValueChanged
    if COE_HB_DispelThrottle and COE_HB_DispelThrottleValue then
        local v = COE_Saved.HB_DispelThrottle or 0
        COE_HB_DispelThrottleValue:SetText(v == 0 and "None" or (v .. "s"))
    end

    if COE_HB_IgnorePets then COE_Saved.HB_IgnorePets = (COE_HB_IgnorePets:GetChecked() and 1 or 0) end
    if COE_HB_PrioritizeTank then COE_Saved.HB_PrioritizeTank = (COE_HB_PrioritizeTank:GetChecked() and 1 or 0) end
    
    -- Tank emergency override saves
    if COE_HB_TankEmergencyEnable then COE_Saved.HB_TankEmergencyEnable = (COE_HB_TankEmergencyEnable:GetChecked() and 1 or 0) end
    if COE_HB_TankEmergIgnoreHealComm then COE_Saved.HB_TankEmergencyIgnoreHealComm = (COE_HB_TankEmergIgnoreHealComm:GetChecked() and 1 or 0) end
    -- NOTE: TankEmergSlider saves itself in OnValueChanged

    if COE_HB_GroupChecks then
        local i
        for i=1,8 do
            local cb = COE_HB_GroupChecks[i]
            if cb then COE_Saved.HB_GroupPrio[i] = (cb:GetChecked() and 1 or 0) end
        end
    end

    -- HealComm saves
    if COE_HB_UseHealComm then COE_Saved.HB_UseHealComm = (COE_HB_UseHealComm:GetChecked() and 1 or 0) end
    if COE_HB_ConservativeHealComm then COE_Saved.HB_ConservativeHealComm = (COE_HB_ConservativeHealComm:GetChecked() and 1 or 0) end
    if COE_HB_HealCommModeBtn then
        COE_Saved.HB_HealCommMode = COE_HB_HealCommModeBtn.selected or "RANK_ADJUST"
    end
    if COE_HB_SpamMode then 
        COE_Saved.HB_SpamMode = (COE_HB_SpamMode:GetChecked() and 1 or 0)
    end
    
    -- Spam spell selection saves
    if COE_HB_SpamSpellType then
        COE_Saved.HB_SpamSpellType = COE_HB_SpamSpellType.selected or "Wave"
    end
    if COE_HB_SpamRankSlider then
        local v = math.floor((COE_HB_SpamRankSlider:GetValue() or 0) + 0.5)
        COE_Saved.HB_SpamSpellRank = v
        HB_UpdateRankLabel()
    end
    
    -- SuperWoW QoL saves
    if COE_HB_ShowTotemRange then 
        COE_Saved.HB_ShowTotemRange = (COE_HB_ShowTotemRange:GetChecked() and 1 or 0)
        if COE_QoL then
            COE_QoL:SetTotemRangeVisible(COE_Saved.HB_ShowTotemRange == 1)
        end
    end
    if COE_HB_ShowTankDistance then 
        COE_Saved.HB_ShowTankDistance = (COE_HB_ShowTankDistance:GetChecked() and 1 or 0)
        if COE_QoL then
            COE_QoL:SetTankDistanceVisible(COE_Saved.HB_ShowTankDistance == 1)
        end
    end
    -- Shield Reminder (not SuperWoW-dependent)
    if COE_HB_ShieldReminder then
        COE_Saved.HB_ShieldReminder = (COE_HB_ShieldReminder:GetChecked() and 1 or 0)
        if COE_QoL then
            COE_QoL:SetShieldReminderVisible(COE_Saved.HB_ShieldReminder == 1)
        end
    end
end

local function HB_Refresh()
    if not COE_Saved then return end
    HB_EnsureDefaults()

    if COE_HB_EnableHealBrain then COE_HB_EnableHealBrain:SetChecked(COE_Saved.HB_Enable == 1) end
    if COE_HB_TankEdit then COE_HB_TankEdit:SetText(COE_Saved.HB_TankName or "") end
    if COE_HB_OffTankEdit then COE_HB_OffTankEdit:SetText(COE_Saved.HB_OffTankName or "") end
    if COE_HB_UseToT then COE_HB_UseToT:SetChecked(COE_Saved.HB_UseToT == 1) end

    if COE_HB_TopUpSlider then
        local v = tonumber(COE_Saved.HB_TopUp) or 85
        if v < 50 then v = 50 end
        if v > 100 then v = 100 end
        COE_HB_TopUpSlider:SetValue(v)
        if COE_HB_TopUpValue then COE_HB_TopUpValue:SetText(v .. "%") end
    end
    if COE_HB_EmergSlider then
        local v = tonumber(COE_Saved.HB_Emergency) or 55
        if v < 10 then v = 10 end
        if v > 90 then v = 90 end
        COE_HB_EmergSlider:SetValue(v)
        if COE_HB_EmergValue then COE_HB_EmergValue:SetText(v .. "%") end
    end

    if COE_HB_ChainEnable then COE_HB_ChainEnable:SetChecked(COE_Saved.HB_ChainHealEnable == 1) end
    if COE_HB_ChainMinSlider then
        local v = tonumber(COE_Saved.HB_ChainHealMinTargets) or 3
        if v < 2 then v = 2 end
        if v > 5 then v = 5 end
        COE_HB_ChainMinSlider:SetValue(v)
        if COE_HB_ChainMinValue then COE_HB_ChainMinValue:SetText(v) end
    end
    if COE_HB_ChainHP then
        local v = tonumber(COE_Saved.HB_ChainHealThreshold) or 60
        if v < 30 then v = 30 end
        if v > 95 then v = 95 end
        COE_HB_ChainHP:SetValue(v)
        if COE_HB_ChainHPValue then COE_HB_ChainHPValue:SetText(v .. "%") end
    end
    if COE_HB_ChainPreferTank then COE_HB_ChainPreferTank:SetChecked(COE_Saved.HB_ChainPreferTankBounce == 1) end

    if COE_HB_DispelPoison then COE_HB_DispelPoison:SetChecked(COE_Saved.HB_DispelPoison == 1) end
    if COE_HB_DispelDisease then COE_HB_DispelDisease:SetChecked(COE_Saved.HB_DispelDisease == 1) end
    if COE_HB_DispelTankOnly then COE_HB_DispelTankOnly:SetChecked(COE_Saved.HB_DispelTankOnly == 1) end
    if COE_HB_DispelSelfFirst then COE_HB_DispelSelfFirst:SetChecked(COE_Saved.HB_DispelSelfFirst == 1) end
    if COE_HB_DispelGate then
        local v = tonumber(COE_Saved.HB_DispelHPGate) or 70
        if v < 10 then v = 10 end
        if v > 100 then v = 100 end
        COE_HB_DispelGate:SetValue(v)
        if COE_HB_DispelGateValue then COE_HB_DispelGateValue:SetText(v .. "%") end
    end
    if COE_HB_DispelThrottle then
        local v = tonumber(COE_Saved.HB_DispelThrottle) or 0
        if v < 0 then v = 0 end
        if v > 5 then v = 5 end
        COE_HB_DispelThrottle:SetValue(v)
        if COE_HB_DispelThrottleValue then COE_HB_DispelThrottleValue:SetText(v == 0 and "None" or (v .. "s")) end
    end

    if COE_HB_IgnorePets then COE_HB_IgnorePets:SetChecked(COE_Saved.HB_IgnorePets == 1) end
    if COE_HB_PrioritizeTank then COE_HB_PrioritizeTank:SetChecked(COE_Saved.HB_PrioritizeTank == 1) end
    
    -- Tank emergency override refresh
    if COE_HB_TankEmergencyEnable then COE_HB_TankEmergencyEnable:SetChecked(COE_Saved.HB_TankEmergencyEnable == 1) end
    if COE_HB_TankEmergIgnoreHealComm then COE_HB_TankEmergIgnoreHealComm:SetChecked(COE_Saved.HB_TankEmergencyIgnoreHealComm == 1) end
    if COE_HB_TankEmergSlider then
        local v = tonumber(COE_Saved.HB_TankEmergencyThreshold) or 30
        if v < 10 then v = 10 end
        if v > 50 then v = 50 end
        COE_HB_TankEmergSlider:SetValue(v)
        if COE_HB_TankEmergValue then COE_HB_TankEmergValue:SetText(v .. "%") end
    end

    if COE_HB_GroupChecks then
        local i
        for i=1,8 do
            local cb = COE_HB_GroupChecks[i]
            if cb then cb:SetChecked((COE_Saved.HB_GroupPrio and COE_Saved.HB_GroupPrio[i] == 1) and true or false) end
        end
    end

    -- HealComm refresh
    if COE_HB_UseHealComm then COE_HB_UseHealComm:SetChecked(COE_Saved.HB_UseHealComm == 1) end
    if COE_HB_ConservativeHealComm then COE_HB_ConservativeHealComm:SetChecked(COE_Saved.HB_ConservativeHealComm == 1) end
    if COE_HB_HealCommModeBtn then
        COE_HB_HealCommModeBtn.selected = COE_Saved.HB_HealCommMode or "RANK_ADJUST"
        local modeText = (COE_HB_HealCommModeBtn.selected == "TRUST") and "Trust (skip only)" or "Adjust rank"
        COE_HB_HealCommModeBtn:SetText(modeText)
    end
    if COE_HB_SpamMode then COE_HB_SpamMode:SetChecked(COE_Saved.HB_SpamMode == 1) end
    
    -- Spam spell selection refresh
    if COE_HB_SpamSpellType then
        COE_HB_SpamSpellType.selected = COE_Saved.HB_SpamSpellType or "Wave"
        HB_UpdateSpellTypeButton()
    end
    if COE_HB_SpamRankSlider then
        HB_UpdateRankSliderRange()
        local v = tonumber(COE_Saved.HB_SpamSpellRank) or 0
        COE_HB_SpamRankSlider:SetValue(v)
        HB_UpdateRankLabel()
    end
    
    -- SuperWoW QoL refresh
    if COE_HB_ShowTotemRange then 
        COE_HB_ShowTotemRange:SetChecked(COE_Saved.HB_ShowTotemRange == 1)
    end
    if COE_HB_ShowTankDistance then 
        COE_HB_ShowTankDistance:SetChecked(COE_Saved.HB_ShowTankDistance == 1)
    end
    if COE_HB_ShieldReminder then
        COE_HB_ShieldReminder:SetChecked(COE_Saved.HB_ShieldReminder == 1)
    end
end

local function HB_SetButtonStyle(btn, selected)
    if not btn then return end
    if selected then
        btn:SetTextColor(1, 1, 0.3)
    else
        btn:SetTextColor(1, 1, 1)
    end
end

local function HB_ShowTab(tabKey)
    HB.activeTab = tabKey

    if COE_HB_TabFrames then
        local k, f
        for k, f in pairs(COE_HB_TabFrames) do
            if f then
                if k == tabKey then f:Show() else f:Hide() end
            end
        end
    end
    if COE_HB_TabButtons then
        local k, b
        for k, b in pairs(COE_HB_TabButtons) do
            HB_SetButtonStyle(b, k == tabKey)
        end
    end
end

local function HB_CreateTabButton(parent, key, text, relTo, x, y)
    local b = CreateFrame("Button", nil, parent, "GameMenuButtonTemplate")
    b:SetHeight(18)
    b:SetWidth(88)
    if relTo then
        b:SetPoint("LEFT", relTo, "RIGHT", 6, 0)
    else
        b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    end
    b:SetText(text)
    b:SetScript("OnClick", function() HB_ShowTab(key) end)
    return b
end

local function HB_MakeHeader(fsParent, text, anchorTo, x, y)
    local t = fsParent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", anchorTo or fsParent, "TOPLEFT", x or 16, y or -12)
    t:SetText(text)
    return t
end

local function HB_CreateUI()
    if HB.uiBuilt then return end
    if not COE_ConfigHealingTabPanel then return end

    HB_EnsureDefaults()

    local panel = COE_ConfigHealingTabPanel

    -- Root container inside the panel (below the default header)
    local root = CreateFrame("Frame", "COE_HB_Root", panel)
    root:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -42)
    root:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -12, 12)

    -- Title
    local title = root:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", root, "TOPLEFT", 2, -2)
    title:SetText("HealAI")

    -- Internal tabs row
    COE_HB_TabButtons = {}
    local b1 = HB_CreateTabButton(root, "CORE", "Core", nil, 0, -28)
    local b2 = HB_CreateTabButton(root, "THRESH", "Thresholds", b1)
    local b3 = HB_CreateTabButton(root, "CHAIN", "Chain Heal", b2)

    -- second row so nothing goes off-screen on 4:3 / 1.12 layouts
    local b4 = HB_CreateTabButton(root, "DISPEL", "Dispel", nil, 0, -50)
    local b5 = HB_CreateTabButton(root, "RAID", "Raid", b4)
    local b6 = HB_CreateTabButton(root, "ADV", "Advanced", b5)  -- New tab for placeholders

    COE_HB_TabButtons["CORE"]=b1
    COE_HB_TabButtons["THRESH"]=b2
    COE_HB_TabButtons["CHAIN"]=b3
    COE_HB_TabButtons["DISPEL"]=b4
    COE_HB_TabButtons["RAID"]=b5
    COE_HB_TabButtons["ADV"]=b6

    -- Tab frames
    COE_HB_TabFrames = {}
    local function makeTab(name)
        local f = CreateFrame("Frame", nil, root)
        f:SetPoint("TOPLEFT", root, "TOPLEFT", 0, -74)  -- Adjusted for extra row
        f:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", 0, 0)
        f:Hide()
        COE_HB_TabFrames[name]=f
        return f
    end

    local tabCore = makeTab("CORE")
    local tabThr  = makeTab("THRESH")
    local tabChain= makeTab("CHAIN")
    local tabDisp = makeTab("DISPEL")
    local tabRaid = makeTab("RAID")
    local tabAdv  = makeTab("ADV")  -- New

    --------------------------------------------------------------------
    -- CORE TAB (polished spacing)
    --------------------------------------------------------------------
    HB_MakeHeader(tabCore, "Core Settings", tabCore, 8, -8)

    local enable = CreateFrame("CheckButton", "COE_HB_EnableHealBrain", tabCore, "UICheckButtonTemplate")
    enable:SetPoint("TOPLEFT", tabCore, "TOPLEFT", 14, -36)
    getglobal(enable:GetName().."Text"):SetText("Enable HealAI")
    enable:SetScript("OnClick", HB_Save)
    enable.tooltipText = "Enable HealAI healing system"

    local tankLabel = tabCore:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    tankLabel:SetPoint("TOPLEFT", enable, "BOTTOMLEFT", 6, -16)
    tankLabel:SetText("Main Tank name (optional):")

    local tankEdit = CreateFrame("EditBox", "COE_HB_TankEdit", tabCore, "InputBoxTemplate")
    tankEdit:SetPoint("TOPLEFT", tankLabel, "BOTTOMLEFT", -6, -8)
    tankEdit:SetWidth(210); tankEdit:SetHeight(20)
    tankEdit:SetAutoFocus(false)
    tankEdit:SetScript("OnEnterPressed", function() tankEdit:ClearFocus(); HB_Save(); end)
    tankEdit:SetScript("OnEscapePressed", function() tankEdit:ClearFocus(); HB_Refresh(); end)
    -- Tooltip for tank name field
    tankEdit:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Tank Name")
        GameTooltip:AddLine("Case-insensitive but must match the character's name exactly.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    tankEdit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local tankBtn = CreateFrame("Button", "COE_HB_SetTankBtn", tabCore, "GameMenuButtonTemplate")
    tankBtn:SetPoint("LEFT", tankEdit, "RIGHT", 10, 0)
    tankBtn:SetWidth(110); tankBtn:SetHeight(20)
    tankBtn:SetText("Set to Target")
    tankBtn:SetScript("OnClick", function() HB_SetTankFromTarget("MAIN"); HB_Save(); end)

    local otLabel = tabCore:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    otLabel:SetPoint("TOPLEFT", tankEdit, "BOTTOMLEFT", 6, -14)
    otLabel:SetText("Off-tank name (optional):")

    local otEdit = CreateFrame("EditBox", "COE_HB_OffTankEdit", tabCore, "InputBoxTemplate")
    otEdit:SetPoint("TOPLEFT", otLabel, "BOTTOMLEFT", -6, -8)
    otEdit:SetWidth(210); otEdit:SetHeight(20)
    otEdit:SetAutoFocus(false)
    otEdit:SetScript("OnEnterPressed", function() otEdit:ClearFocus(); HB_Save(); end)
    otEdit:SetScript("OnEscapePressed", function() otEdit:ClearFocus(); HB_Refresh(); end)
    -- Tooltip for off-tank name field
    otEdit:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Off-Tank Name")
        GameTooltip:AddLine("Case-insensitive but must match the character's name exactly.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    otEdit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local otBtn = CreateFrame("Button", "COE_HB_SetOffTankBtn", tabCore, "GameMenuButtonTemplate")
    otBtn:SetPoint("LEFT", otEdit, "RIGHT", 10, 0)
    otBtn:SetWidth(110); otBtn:SetHeight(20)
    otBtn:SetText("Set to Target")
    otBtn:SetScript("OnClick", function() HB_SetTankFromTarget("OFF"); HB_Save(); end)

    local tot = CreateFrame("CheckButton", "COE_HB_UseToT", tabCore, "UICheckButtonTemplate")
    tot:SetPoint("TOPLEFT", otEdit, "BOTTOMLEFT", 0, -12)  -- Reduced from -18
    getglobal(tot:GetName().."Text"):SetText("Use Target-of-Target if no tank names set")
    tot:SetScript("OnClick", HB_Save)
    tot.tooltipText = "If no tank name is set or tank is not found in group,|nHealBrain will use your target's target as a tank fallback."

    local prioTank = CreateFrame("CheckButton", "COE_HB_PrioritizeTank", tabCore, "UICheckButtonTemplate")
    prioTank:SetPoint("TOPLEFT", tot, "BOTTOMLEFT", 0, -2)  -- Reduced from -8
    getglobal(prioTank:GetName().."Text"):SetText("Prioritize tank(s) before others")
    prioTank:SetScript("OnClick", HB_Save)
    prioTank.tooltipText = "When enabled, tanks are healed before other raid members|neven if others have lower HP (unless in emergency)."

    local ignorePets = CreateFrame("CheckButton", "COE_HB_IgnorePets", tabCore, "UICheckButtonTemplate")
    ignorePets:SetPoint("TOPLEFT", prioTank, "BOTTOMLEFT", 0, -2)  -- Reduced from -8
    getglobal(ignorePets:GetName().."Text"):SetText("Ignore pets and guardians")
    ignorePets:SetScript("OnClick", HB_Save)
    ignorePets.tooltipText = "Skip pets, totems, and guardians when scanning for heal targets."

    -- Shield Reminder checkbox
    local shieldReminder = CreateFrame("CheckButton", "COE_HB_ShieldReminder", tabCore, "UICheckButtonTemplate")
    shieldReminder:SetPoint("TOPLEFT", ignorePets, "BOTTOMLEFT", 0, -2)  -- Tight spacing
    getglobal(shieldReminder:GetName().."Text"):SetText("Enable Shield Reminder")
    shieldReminder:SetScript("OnClick", HB_Save)
    shieldReminder.tooltipText = "Shows a small movable indicator for Water/Lightning/Earth Shield status.|nGreen = Active (4+ stacks), Yellow = Low (1-3 stacks), Red = Missing."

-- THRESHOLDS TAB (fixed function signature - no 'self')
HB_MakeHeader(tabThr, "Healing Thresholds", tabThr, 8, -8)
local topLabel = tabThr:CreateFontString(nil, "ARTWORK", "GameFontNormal")
topLabel:SetPoint("TOPLEFT", tabThr, "TOPLEFT", 14, -36)
topLabel:SetText("Top-up threshold (%):")
local top = CreateFrame("Slider", "COE_HB_TopUpSlider", tabThr, "OptionsSliderTemplate")
top:SetPoint("TOPLEFT", topLabel, "BOTTOMLEFT", 0, -10)
top:SetWidth(240)
top:SetMinMaxValues(50, 100)
top:SetValueStep(1)
top:SetValue(85)  -- Set initial value BEFORE OnValueChanged
getglobal(top:GetName().."Low"):SetText("50")
getglobal(top:GetName().."High"):SetText("100")
getglobal(top:GetName().."Text"):SetText("")
top.tooltipText = "Heal targets below this HP% (higher = more healing)"
local topVal = tabThr:CreateFontString("COE_HB_TopUpValue", "ARTWORK", "GameFontNormal")
topVal:SetPoint("LEFT", top, "RIGHT", 10, 0)
topVal:SetText("85%")
top:SetScript("OnValueChanged", function()
    local v = math.floor(this:GetValue() + 0.5)
    if v < 50 then v = 50 end
    if v > 100 then v = 100 end
    if COE_HB_TopUpValue then
        COE_HB_TopUpValue:SetText(v .. "%")
    end
    -- Only save if COE_Saved exists (after addon loaded)
    if COE_Saved then
        COE_Saved.HB_TopUp = v
    end
end)

local emergLabel = tabThr:CreateFontString(nil, "ARTWORK", "GameFontNormal")
emergLabel:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -18)
emergLabel:SetText("Emergency threshold (%):")
local emerg = CreateFrame("Slider", "COE_HB_EmergSlider", tabThr, "OptionsSliderTemplate")
emerg:SetPoint("TOPLEFT", emergLabel, "BOTTOMLEFT", 0, -10)
emerg:SetWidth(240)
emerg:SetMinMaxValues(10, 90)
emerg:SetValueStep(1)
emerg:SetValue(55)  -- Set initial value BEFORE OnValueChanged
getglobal(emerg:GetName().."Low"):SetText("10")
getglobal(emerg:GetName().."High"):SetText("90")
getglobal(emerg:GetName().."Text"):SetText("")
emerg.tooltipText = "Use fast heals (Lesser HW) for anyone below this %"
local emergVal = tabThr:CreateFontString("COE_HB_EmergValue", "ARTWORK", "GameFontNormal")
emergVal:SetPoint("LEFT", emerg, "RIGHT", 10, 0)
emergVal:SetText("55%")
emerg:SetScript("OnValueChanged", function()
    local v = math.floor(this:GetValue() + 0.5)
    if v < 10 then v = 10 end
    if v > 90 then v = 90 end
    if COE_HB_EmergValue then
        COE_HB_EmergValue:SetText(v .. "%")
    end
    -- Only save if COE_Saved exists (after addon loaded)
    if COE_Saved then
        COE_Saved.HB_Emergency = v
    end
end)

    --------------------------------------------------------------------
    -- TANK EMERGENCY OVERRIDE SECTION
    --------------------------------------------------------------------
    local tankEmergHeader = tabThr:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    tankEmergHeader:SetPoint("TOPLEFT", emerg, "BOTTOMLEFT", 0, -24)
    tankEmergHeader:SetText("Tank Emergency Override")
    tankEmergHeader:SetTextColor(1, 0.82, 0)  -- Gold color
    
    local tankEmergEnable = CreateFrame("CheckButton", "COE_HB_TankEmergencyEnable", tabThr, "UICheckButtonTemplate")
    tankEmergEnable:SetPoint("TOPLEFT", tankEmergHeader, "BOTTOMLEFT", -6, -8)
    getglobal(tankEmergEnable:GetName().."Text"):SetText("Enable tank emergency override")
    tankEmergEnable:SetScript("OnClick", HB_Save)
    tankEmergEnable.tooltipText = "When tank HP drops below threshold, they become|nabsolute top priority and receive fast heals.|nOnly affects named tanks (main/off-tank)."

    local tankEmergLabel = tabThr:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    tankEmergLabel:SetPoint("TOPLEFT", tankEmergEnable, "BOTTOMLEFT", 26, -10)
    tankEmergLabel:SetText("Tank emergency threshold (%):")

    local tankEmergSlider = CreateFrame("Slider", "COE_HB_TankEmergSlider", tabThr, "OptionsSliderTemplate")
    tankEmergSlider:SetPoint("TOPLEFT", tankEmergLabel, "BOTTOMLEFT", 0, -10)
    tankEmergSlider:SetWidth(200)
    tankEmergSlider:SetMinMaxValues(10, 50)
    tankEmergSlider:SetValueStep(5)
    tankEmergSlider:SetValue(30)
    getglobal(tankEmergSlider:GetName().."Low"):SetText("10%")
    getglobal(tankEmergSlider:GetName().."High"):SetText("50%")
    getglobal(tankEmergSlider:GetName().."Text"):SetText("")
    tankEmergSlider:SetScript("OnValueChanged", function()
        local v = math.floor(this:GetValue() + 0.5)
        if v < 10 then v = 10 end
        if v > 50 then v = 50 end
        if COE_HB_TankEmergValue then COE_HB_TankEmergValue:SetText(v .. "%") end
        if COE_Saved then
            COE_Saved.HB_TankEmergencyThreshold = v
        end
    end)
    tankEmergSlider.tooltipText = "Tank HP% below which emergency override activates.|nTank becomes absolute top priority."

    local tankEmergVal = tabThr:CreateFontString("COE_HB_TankEmergValue", "ARTWORK", "GameFontNormal")
    tankEmergVal:SetPoint("LEFT", tankEmergSlider, "RIGHT", 10, 0)
    tankEmergVal:SetText("30%")

    local tankEmergIgnoreHC = CreateFrame("CheckButton", "COE_HB_TankEmergIgnoreHealComm", tabThr, "UICheckButtonTemplate")
    tankEmergIgnoreHC:SetPoint("TOPLEFT", tankEmergSlider, "BOTTOMLEFT", -20, -10)
    getglobal(tankEmergIgnoreHC:GetName().."Text"):SetText("Ignore HealComm for emergency tank")
    tankEmergIgnoreHC:SetScript("OnClick", HB_Save)
    tankEmergIgnoreHC.tooltipText = "When enabled, always heal tank in emergency even if|nHealComm predicts incoming heals will cover them.|nEnsures tank is never skipped in critical moments."

    --------------------------------------------------------------------
    -- CHAIN TAB (added tooltips)
    --------------------------------------------------------------------
    HB_MakeHeader(tabChain, "Chain Heal", tabChain, 8, -8)

    -- SuperWoW requirement note - check for UnitPosition API
    local swNote = tabChain:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    swNote:SetPoint("TOPLEFT", tabChain, "TOPLEFT", 14, -30)
    swNote:SetWidth(280)
    swNote:SetJustifyH("LEFT")
    if UnitPosition and type(UnitPosition) == "function" then
        swNote:SetText("|cFF00FF00SuperWoW position API detected|r - smart Chain Heal is active.")
    else
        swNote:SetText("|cFFFF6600Note:|r Smart Chain Heal requires SuperWoW's UnitPosition API.\nWithout it, HealAI will not auto-cast Chain Heal.")
    end

    local chEnable = CreateFrame("CheckButton", "COE_HB_ChainEnable", tabChain, "UICheckButtonTemplate")
    chEnable:SetPoint("TOPLEFT", swNote, "BOTTOMLEFT", 0, -8)
    getglobal(chEnable:GetName().."Text"):SetText("Enable Chain Heal")
    chEnable:SetScript("OnClick", HB_Save)
    chEnable.tooltipText = "Use Chain Heal when conditions met (requires SuperWoW UnitPosition)"

    local minLabel = tabChain:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    minLabel:SetPoint("TOPLEFT", chEnable, "BOTTOMLEFT", 6, -16)
    minLabel:SetText("Minimum injured targets:")

    local minS = CreateFrame("Slider", "COE_HB_ChainMinSlider", tabChain, "OptionsSliderTemplate")
    minS:SetPoint("TOPLEFT", minLabel, "BOTTOMLEFT", 0, -10)
    minS:SetWidth(240)
    minS:SetMinMaxValues(2, 5)
    minS:SetValueStep(1)
    getglobal(minS:GetName().."Low"):SetText("2")
    getglobal(minS:GetName().."High"):SetText("5")
    getglobal(minS:GetName().."Text"):SetText("")
    minS:SetScript("OnValueChanged", function()
        local v = math.floor((minS:GetValue() or 3) + 0.5)
        if COE_HB_ChainMinValue then COE_HB_ChainMinValue:SetText(v) end
        HB_Save()
    end)
    minS.tooltipText = "Min targets for Chain Heal"

    local minVal = tabChain:CreateFontString("COE_HB_ChainMinValue", "ARTWORK", "GameFontNormal")
    minVal:SetPoint("LEFT", minS, "RIGHT", 10, 0)
    minVal:SetText("3")

    local hpLabel = tabChain:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    hpLabel:SetPoint("TOPLEFT", minS, "BOTTOMLEFT", 0, -18)
    hpLabel:SetText("Cast when targets are below (% HP):")

    local hpS = CreateFrame("Slider", "COE_HB_ChainHP", tabChain, "OptionsSliderTemplate")
    hpS:SetPoint("TOPLEFT", hpLabel, "BOTTOMLEFT", 0, -10)
    hpS:SetWidth(240)
    hpS:SetMinMaxValues(30, 95)
    hpS:SetValueStep(1)
    getglobal(hpS:GetName().."Low"):SetText("30")
    getglobal(hpS:GetName().."High"):SetText("95")
    getglobal(hpS:GetName().."Text"):SetText("")
    hpS:SetScript("OnValueChanged", function()
        local v = math.floor((hpS:GetValue() or 60) + 0.5)
        if COE_HB_ChainHPValue then COE_HB_ChainHPValue:SetText(v .. "%") end
        HB_Save()
    end)
    hpS.tooltipText = "HP threshold for Chain targets"

    local hpVal = tabChain:CreateFontString("COE_HB_ChainHPValue", "ARTWORK", "GameFontNormal")
    hpVal:SetPoint("LEFT", hpS, "RIGHT", 10, 0)
    hpVal:SetText("60%")

    local preferTank = CreateFrame("CheckButton", "COE_HB_ChainPreferTank", tabChain, "UICheckButtonTemplate")
    preferTank:SetPoint("TOPLEFT", hpS, "BOTTOMLEFT", 0, -18)
    getglobal(preferTank:GetName().."Text"):SetText("Prefer Chain Heal to start on tank")
    preferTank:SetScript("OnClick", HB_Save)

    --------------------------------------------------------------------
    -- DISPEL TAB (added tooltips)
    --------------------------------------------------------------------
    HB_MakeHeader(tabDisp, "Dispels", tabDisp, 8, -8)

    local dp = CreateFrame("CheckButton", "COE_HB_DispelPoison", tabDisp, "UICheckButtonTemplate")
    dp:SetPoint("TOPLEFT", tabDisp, "TOPLEFT", 14, -36)
    getglobal(dp:GetName().."Text"):SetText("Enable Cure Poison")
    dp:SetScript("OnClick", HB_Save)

    local dd = CreateFrame("CheckButton", "COE_HB_DispelDisease", tabDisp, "UICheckButtonTemplate")
    dd:SetPoint("TOPLEFT", dp, "BOTTOMLEFT", 0, -8)
    getglobal(dd:GetName().."Text"):SetText("Enable Cure Disease")
    dd:SetScript("OnClick", HB_Save)

    local tankOnly = CreateFrame("CheckButton", "COE_HB_DispelTankOnly", tabDisp, "UICheckButtonTemplate")
    tankOnly:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -8)
    getglobal(tankOnly:GetName().."Text"):SetText("Only dispel tank(s)")
    tankOnly:SetScript("OnClick", HB_Save)

    local selfFirst = CreateFrame("CheckButton", "COE_HB_DispelSelfFirst", tabDisp, "UICheckButtonTemplate")
    selfFirst:SetPoint("TOPLEFT", tankOnly, "BOTTOMLEFT", 0, -8)
    getglobal(selfFirst:GetName().."Text"):SetText("Dispel self first")
    selfFirst:SetScript("OnClick", HB_Save)

    local gateLabel = tabDisp:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    gateLabel:SetPoint("TOPLEFT", selfFirst, "BOTTOMLEFT", 6, -16)
    gateLabel:SetText("Only dispel if target is above (% HP):")

    local gate = CreateFrame("Slider", "COE_HB_DispelGate", tabDisp, "OptionsSliderTemplate")
    gate:SetPoint("TOPLEFT", gateLabel, "BOTTOMLEFT", 0, -10)
    gate:SetWidth(240)
    gate:SetMinMaxValues(10, 100)
    gate:SetValueStep(1)
    gate:SetValue(70)  -- Set initial value
    getglobal(gate:GetName().."Low"):SetText("10")
    getglobal(gate:GetName().."High"):SetText("100")
    getglobal(gate:GetName().."Text"):SetText("")
    gate:SetScript("OnValueChanged", function()
        local v = math.floor(this:GetValue() + 0.5)
        if v < 10 then v = 10 end
        if v > 100 then v = 100 end
        if COE_HB_DispelGateValue then COE_HB_DispelGateValue:SetText(v .. "%") end
        if COE_Saved then
            COE_Saved.HB_DispelHPGate = v
        end
    end)
    gate.tooltipText = "HP gate for dispels (avoid low HP waste)"

    local gateVal = tabDisp:CreateFontString("COE_HB_DispelGateValue", "ARTWORK", "GameFontNormal")
    gateVal:SetPoint("LEFT", gate, "RIGHT", 10, 0)
    gateVal:SetText("70%")

    -- Dispel Throttle slider
    local throttleLabel = tabDisp:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    throttleLabel:SetPoint("TOPLEFT", gate, "BOTTOMLEFT", 0, -18)
    throttleLabel:SetText("Min time between dispels (seconds):")

    local throttle = CreateFrame("Slider", "COE_HB_DispelThrottle", tabDisp, "OptionsSliderTemplate")
    throttle:SetPoint("TOPLEFT", throttleLabel, "BOTTOMLEFT", 0, -10)
    throttle:SetWidth(240)
    throttle:SetMinMaxValues(0, 5)
    throttle:SetValueStep(0.5)
    throttle:SetValue(0)  -- Default: no throttle
    getglobal(throttle:GetName().."Low"):SetText("0")
    getglobal(throttle:GetName().."High"):SetText("5")
    getglobal(throttle:GetName().."Text"):SetText("")
    throttle:SetScript("OnValueChanged", function()
        local v = this:GetValue()
        v = math.floor(v * 2 + 0.5) / 2  -- Round to 0.5
        if v < 0 then v = 0 end
        if v > 5 then v = 5 end
        if COE_HB_DispelThrottleValue then 
            COE_HB_DispelThrottleValue:SetText(v == 0 and "None" or (v .. "s"))
        end
        if COE_Saved then
            COE_Saved.HB_DispelThrottle = v
        end
    end)
    throttle.tooltipText = "Prevents dispel spam that starves healing.|n0 = No limit (dispel whenever found)|n2 = Wait 2 seconds between dispels"

    local throttleVal = tabDisp:CreateFontString("COE_HB_DispelThrottleValue", "ARTWORK", "GameFontNormal")
    throttleVal:SetPoint("LEFT", throttle, "RIGHT", 10, 0)
    throttleVal:SetText("None")

    --------------------------------------------------------------------
    -- RAID TAB (added tooltips)
    --------------------------------------------------------------------
    HB_MakeHeader(tabRaid, "Raid Group Filter", tabRaid, 8, -8)

    local info = tabRaid:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    info:SetPoint("TOPLEFT", tabRaid, "TOPLEFT", 14, -34)
    info:SetText("Only heal members in these groups:")

    COE_HB_GroupChecks = {}
    local startY = -54
    local i
    for i=1,8 do
        local cb = CreateFrame("CheckButton", "COE_HB_Group"..i, tabRaid, "UICheckButtonTemplate")

        local idx = (i - 1)
        local col = idx - math.floor(idx / 4) * 4
        local row = math.floor(idx / 4)

        cb:SetPoint("TOPLEFT", tabRaid, "TOPLEFT", 14 + (col * 90), startY - (row * 26))
        getglobal(cb:GetName().."Text"):SetText("Group "..i)
        cb:SetScript("OnClick", HB_Save)
        cb.tooltipText = "Include Group "..i.." in healing scan"

        COE_HB_GroupChecks[i]=cb
    end

    local note = tabRaid:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", tabRaid, "TOPLEFT", 14, startY - 60)
    note:SetText("Tanks and yourself are always healed regardless of group.")

    -- SuperWoW QoL Features Header
    local qolHeader = tabRaid:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    qolHeader:SetPoint("TOPLEFT", tabRaid, "TOPLEFT", 14, startY - 85)
    qolHeader:SetText("SuperWoW Distance Features:")
    qolHeader:SetTextColor(1, 0.82, 0)

    -- Tank Distance Hint (SuperWoW QoL feature)
    local tankDistCheck = CreateFrame("CheckButton", "COE_HB_ShowTankDistance", tabRaid, "UICheckButtonTemplate")
    tankDistCheck:SetPoint("TOPLEFT", qolHeader, "BOTTOMLEFT", 0, -6)
    getglobal(tankDistCheck:GetName().."Text"):SetText("Show tank distance hint")
    tankDistCheck:SetScript("OnClick", HB_Save)
    tankDistCheck.tooltipText = "Display a small movable frame showing distance to configured tank.|nHelps you stay in healing range."
    
    -- Totem Range Overview (SuperWoW QoL feature)
    local totemRangeCheck = CreateFrame("CheckButton", "COE_HB_ShowTotemRange", tabRaid, "UICheckButtonTemplate")
    totemRangeCheck:SetPoint("TOPLEFT", tankDistCheck, "BOTTOMLEFT", 0, -4)
    getglobal(totemRangeCheck:GetName().."Text"):SetText("Show totem range overview")
    totemRangeCheck:SetScript("OnClick", HB_Save)
    totemRangeCheck.tooltipText = "Display a movable panel showing how many group members|nare within range of your active totems."
    
    -- Note for both
    local qolNote = tabRaid:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    qolNote:SetPoint("TOPLEFT", totemRangeCheck, "BOTTOMLEFT", 26, -4)
    qolNote:SetText("Requires SuperWoW (UnitPosition)")
    qolNote:SetTextColor(0.5, 0.5, 0.5)

    --------------------------------------------------------------------
    -- ADVANCED TAB
    --------------------------------------------------------------------
    HB_MakeHeader(tabAdv, "Advanced Options", tabAdv, 8, -8)

    local healComm = CreateFrame("CheckButton", "COE_HB_UseHealComm", tabAdv, "UICheckButtonTemplate")
    healComm:SetPoint("TOPLEFT", tabAdv, "TOPLEFT", 14, -36)
    getglobal(healComm:GetName().."Text"):SetText("Use HealComm (skip/adjust based on incoming)")
    healComm:SetScript("OnClick", HB_Save)
    healComm.tooltipText = "Use HealComm data to avoid overhealing.|nRequires HealComm-1.0 addon.|nDoes NOT apply to spam mode."

    -- HealComm Mode toggle button (compact, on same line as checkbox label would overflow)
    local hcModeLabel = tabAdv:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    hcModeLabel:SetPoint("TOPLEFT", healComm, "BOTTOMLEFT", 26, -6)
    hcModeLabel:SetText("Mode:")
    
    local hcModeBtn = CreateFrame("Button", "COE_HB_HealCommModeBtn", tabAdv, "GameMenuButtonTemplate")
    hcModeBtn:SetPoint("LEFT", hcModeLabel, "RIGHT", 6, 0)
    hcModeBtn:SetWidth(110)
    hcModeBtn:SetHeight(18)
    hcModeBtn:SetText("Adjust rank")
    hcModeBtn.selected = "RANK_ADJUST"
    hcModeBtn:SetScript("OnClick", function()
        if hcModeBtn.selected == "RANK_ADJUST" then
            hcModeBtn.selected = "TRUST"
            hcModeBtn:SetText("Trust (skip only)")
        else
            hcModeBtn.selected = "RANK_ADJUST"
            hcModeBtn:SetText("Adjust rank")
        end
        HB_Save()
    end)
    hcModeBtn.tooltipText = "Trust (skip only): Just skip non-tanks with enough incoming heals.|nAdjust rank: Also downrank based on incoming heals."
    hcModeBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("HealComm Mode")
        GameTooltip:AddLine(hcModeBtn.tooltipText, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    hcModeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local conservativeHC = CreateFrame("CheckButton", "COE_HB_ConservativeHealComm", tabAdv, "UICheckButtonTemplate")
    conservativeHC:SetPoint("TOPLEFT", hcModeLabel, "BOTTOMLEFT", -6, -6)
    getglobal(conservativeHC:GetName().."Text"):SetText("Conservative: cancel near-full overheal")
    conservativeHC:SetScript("OnClick", HB_Save)
    conservativeHC.tooltipText = "Cancel heals mid-cast if predicted HP > 95%.|nPrevents heavy overhealing.|nRequires HealComm enabled.|nDoes NOT apply to spam mode."

    local spamMode = CreateFrame("CheckButton", "COE_HB_SpamMode", tabAdv, "UICheckButtonTemplate")
    spamMode:SetPoint("TOPLEFT", conservativeHC, "BOTTOMLEFT", -20, -6)
    getglobal(spamMode:GetName().."Text"):SetText("Spam mode (maintenance healing)")
    spamMode:SetScript("OnClick", HB_Save)
    spamMode.tooltipText = "ON: Uses preset spell below, ignores HealComm|nOFF: Smart healing with thresholds"

    --------------------------------------------------------------------
    -- SPAM SPELL SELECTION (NEW)
    --------------------------------------------------------------------
    local spamHeader = tabAdv:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    spamHeader:SetPoint("TOPLEFT", spamMode, "BOTTOMLEFT", 6, -20)
    spamHeader:SetText("Spam Spell (when spam mode ON):")
    spamHeader:SetTextColor(1, 0.82, 0)  -- Gold color for header
    
    -- Spell Type Button (toggles between Healing Wave and Lesser Healing Wave)
    local spellTypeLabel = tabAdv:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    spellTypeLabel:SetPoint("TOPLEFT", spamHeader, "BOTTOMLEFT", 0, -10)
    spellTypeLabel:SetText("Spell:")
    
    local spellTypeBtn = CreateFrame("Button", "COE_HB_SpamSpellType", tabAdv, "GameMenuButtonTemplate")
    spellTypeBtn:SetPoint("LEFT", spellTypeLabel, "RIGHT", 10, 0)
    spellTypeBtn:SetWidth(160)
    spellTypeBtn:SetHeight(22)
    spellTypeBtn:SetText("Healing Wave")
    spellTypeBtn.selected = "Wave"
    spellTypeBtn:SetScript("OnClick", function()
        HB_ToggleSpellType()
        HB_Save()
    end)
    spellTypeBtn.tooltipText = "Click to toggle between Healing Wave and Lesser Healing Wave"
    
    -- Rank Slider
    local rankLabel = tabAdv:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    rankLabel:SetPoint("TOPLEFT", spellTypeLabel, "BOTTOMLEFT", 0, -20)
    rankLabel:SetText("Rank:")
    
    local rankSlider = CreateFrame("Slider", "COE_HB_SpamRankSlider", tabAdv, "OptionsSliderTemplate")
    rankSlider:SetPoint("LEFT", rankLabel, "RIGHT", 10, 0)
    rankSlider:SetWidth(180)
    rankSlider:SetMinMaxValues(0, 10)
    rankSlider:SetValueStep(1)
    getglobal(rankSlider:GetName().."Low"):SetText("0 (Max)")
    getglobal(rankSlider:GetName().."High"):SetText("10")
    getglobal(rankSlider:GetName().."Text"):SetText("")
    rankSlider:SetScript("OnValueChanged", function()
        HB_UpdateRankLabel()
        HB_Save()
    end)
    rankSlider.tooltipText = "0 = Max available rank, or select specific rank"
    
    local rankVal = tabAdv:CreateFontString("COE_HB_SpamRankValue", "ARTWORK", "GameFontNormal")
    rankVal:SetPoint("LEFT", rankSlider, "RIGHT", 10, 0)
    rankVal:SetText("Max")
    
    -- Info text explaining one-button system
    local spamInfo = tabAdv:CreateFontString("COE_HB_SpamInfo", "ARTWORK", "GameFontDisableSmall")
    spamInfo:SetPoint("TOPLEFT", rankLabel, "BOTTOMLEFT", 0, -16)
    spamInfo:SetText("Bind 'HealBrain' key - uses spell above when spam ON,")
    
    local spamInfo2 = tabAdv:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    spamInfo2:SetPoint("TOPLEFT", spamInfo, "BOTTOMLEFT", 0, -2)
    spamInfo2:SetText("or BestHeal with thresholds when spam OFF.")

    -- Finalize
    HB.uiBuilt = true
    HB_ShowTab("CORE")
    HB_Refresh()
end

local function HB_OnHealingTab()
    HB_CreateUI()
    HB_Refresh()
end

-- Hook COE_Config:OnTabButtonClick safely (Vanilla)
local function HB_TryHook()
    if not COE_Config or not COE_Config.OnTabButtonClick then return end
    if COE_Config.__HB_Hooked then return end
    COE_Config.__HB_Hooked = true

    local old = COE_Config.OnTabButtonClick
    COE_Config.OnTabButtonClick = function(self, btn)
        old(self, btn)
        if btn and btn:GetName() == "COE_ConfigHealingTab" then
            HB_OnHealingTab()
        end
    end
end

-- Some clients load config later; try a few times
local f = CreateFrame("Frame")
local tries = 0
f:SetScript("OnUpdate", function()
    tries = tries + 1
    if tries > 200 then f:SetScript("OnUpdate", nil) return end
    if COE_Config and COE_Config.OnTabButtonClick then
        HB_TryHook()
        f:SetScript("OnUpdate", nil)
    end
end)



-- Extra safety: also inject when the Healing panel is shown, even if tab-click hook doesn't fire
local function HB_HookPanelOnShow()
    if not COE_ConfigHealingTabPanel then return end
    if COE_ConfigHealingTabPanel.__HB_OnShowHooked then return end
    COE_ConfigHealingTabPanel.__HB_OnShowHooked = true
    local old = COE_ConfigHealingTabPanel:GetScript("OnShow")
    COE_ConfigHealingTabPanel:SetScript("OnShow", function(self)
        if old then old(self) end
        HB_OnHealingTab()
    end)
end

-- Try to hook panel show as soon as possible
local f2 = CreateFrame("Frame")
local tries2 = 0
f2:SetScript("OnUpdate", function()
    tries2 = tries2 + 1
    if tries2 > 200 then f2:SetScript("OnUpdate", nil) return end
    if COE_ConfigHealingTabPanel then
        HB_HookPanelOnShow()
        -- If the panel is already visible, build immediately
        if COE_ConfigHealingTabPanel:IsVisible() then
            HB_OnHealingTab()
        end
        f2:SetScript("OnUpdate", nil)
    end
end)