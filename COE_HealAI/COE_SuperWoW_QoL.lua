-- COE_SuperWoW_QoL.lua
-- SuperWoW-powered Quality of Life features for HealAI
-- 1) Totem Range Overview Panel - shows how many group members are in range of active totems
-- 2) Tank Distance Hint - shows distance to configured tank(s)
-- 3) Shield Reminder - shows shield buff status (does NOT require SuperWoW)
-- Features 1 & 2 require SuperWoW's UnitPosition API and are purely informational.

COE_QoL = COE_QoL or {};

-- Constants (MUST be defined before OnUpdate handler uses them)
local TOTEM_RANGE_YARDS = 30;
local TANK_DISTANCE_UPDATE_INTERVAL = 0.3;
local TOTEM_UPDATE_INTERVAL = 0.5;
local SHIELD_UPDATE_INTERVAL = 0.3;  -- Shield reminder update interval

-- Shield names to detect (for tooltip scanning)
local SHIELD_NAMES = {
    "Lightning Shield",
    "Water Shield", 
    "Earth Shield",
};

-- State tracking
COE_QoL.lastTankUpdate = 0;
COE_QoL.lastTotemUpdate = 0;
COE_QoL.lastShieldUpdate = 0;

-- Per-element totem anchors (set when totem is dropped)
-- Format: TotemAnchors["Earth"] = {x = 123.4, y = 567.8}
COE_QoL.TotemAnchors = {};

function COE_QoL:HasPositionAPI()
    return UnitPosition and type(UnitPosition) == "function";
end

function COE_QoL:GetDistance(unit1, unit2)
    if not self:HasPositionAPI() then return nil end
    if not UnitExists(unit1) or not UnitExists(unit2) then return nil end
    
    local x1, y1 = UnitPosition(unit1);
    local x2, y2 = UnitPosition(unit2);
    
    if not x1 or not x2 then return nil end
    
    local dx = x1 - x2;
    local dy = y1 - y2;
    
    return math.sqrt(dx * dx + dy * dy);
end

-- Get distance from a fixed point (anchor) to a unit
function COE_QoL:GetDistanceFromAnchor(anchorX, anchorY, unit)
    if not self:HasPositionAPI() then return nil end
    if not anchorX or not anchorY then return nil end
    if not UnitExists(unit) then return nil end
    
    local x2, y2 = UnitPosition(unit);
    if not x2 then return nil end
    
    local dx = anchorX - x2;
    local dy = anchorY - y2;
    
    return math.sqrt(dx * dx + dy * dy);
end

function COE_QoL:IsInGroup()
    return GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0;
end

function COE_QoL:IsTotemActive(element)
    if not COE or not COE.ActiveTotems then return false end
    
    local totem = COE.ActiveTotems[element];
    if not totem then return false end
    
    if COE_Totem and COE_Totem.IsTimerActive then
        return COE_Totem:IsTimerActive(totem);
    end
    
    return false;
end

--[[ ----------------------------------------------------------------
    Record totem anchor position when a totem is dropped.
    Called from our hook on COE_Totem:ActivatePendingTotem
-------------------------------------------------------------------]]
function COE_QoL:RecordTotemAnchor(element)
    if not self:HasPositionAPI() then return end
    if not element then return end
    
    local x, y = UnitPosition("player");
    if not x then return end
    
    self.TotemAnchors[element] = {x = x, y = y};
    
    if COE and COE.DebugMode then
        COE:DebugMessage(string.format("QoL: %s totem anchor set at (%.1f, %.1f)", element, x, y));
    end
end

--[[ ----------------------------------------------------------------
    Clear totem anchor when totem expires/is destroyed
-------------------------------------------------------------------]]
function COE_QoL:ClearTotemAnchor(element)
    if not element then return end
    
    self.TotemAnchors[element] = nil;
    
    if COE and COE.DebugMode then
        COE:DebugMessage("QoL: " .. element .. " totem anchor cleared");
    end
end


--[[ ================================================================
    TOTEM RANGE OVERVIEW PANEL
================================================================ ]]--

function COE_QoL:CreateTotemRangeFrame()
    if COE_TotemRangeFrame then return end
    
    local frame = CreateFrame("Frame", "COE_TotemRangeFrame", UIParent);
    frame:SetWidth(100);
    frame:SetHeight(80);
    frame:SetPoint("CENTER", UIParent, "CENTER", 200, 100);
    frame:SetMovable(true);
    frame:EnableMouse(true);
    frame:SetClampedToScreen(true);
    frame:RegisterForDrag("LeftButton");
    
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    });
    frame:SetBackdropColor(0, 0, 0, 0.7);
    
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
    title:SetPoint("TOP", frame, "TOP", 0, -6);
    title:SetText("Totem Range");
    title:SetTextColor(1, 0.82, 0);
    frame.title = title;
    
    local elements = {"Earth", "Fire", "Water", "Air"};
    local yOffset = -22;
    frame.elementTexts = {};
    
    for i, element in ipairs(elements) do
        local line = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
        line:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, yOffset);
        line:SetText(element .. ": --");
        line:SetJustifyH("LEFT");
        frame.elementTexts[element] = line;
        yOffset = yOffset - 12;
    end
    
    frame:SetScript("OnDragStart", function()
        this:StartMoving();
    end);
    
    frame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing();
        COE_QoL:SaveTotemRangePosition();
    end);
    
    frame:Hide();
end

function COE_QoL:SaveTotemRangePosition()
    if not COE_TotemRangeFrame then return end
    if not COEFramePositions then COEFramePositions = {} end
    
    COEFramePositions.TotemRange = COEFramePositions.TotemRange or {};
    COEFramePositions.TotemRange.x = COE_TotemRangeFrame:GetLeft() or 0;
    COEFramePositions.TotemRange.y = COE_TotemRangeFrame:GetTop() or 0;
end

function COE_QoL:RestoreTotemRangePosition()
    if not COE_TotemRangeFrame then return end
    if not COEFramePositions then return end
    if not COEFramePositions.TotemRange then return end
    
    local pos = COEFramePositions.TotemRange;
    if pos.x and pos.y and pos.x ~= 0 and pos.y ~= 0 then
        COE_TotemRangeFrame:ClearAllPoints();
        COE_TotemRangeFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y);
    end
end

--[[ ----------------------------------------------------------------
    Count group members in range of a specific element's totem anchor
    Returns: inRange, total, debugInfo
-------------------------------------------------------------------]]
function COE_QoL:CountMembersInRangeForElement(element)
    local inRange = 0;
    local total = 0;
    local debugInfo = {};
    
    if not self:HasPositionAPI() then
        return 0, 0, {"No UnitPosition API"};
    end
    
    -- Get the anchor for this element
    local anchor = self.TotemAnchors[element];
    if not anchor then
        return 0, 0, {"No anchor for " .. element};
    end
    
    table.insert(debugInfo, string.format("  Anchor: (%.1f, %.1f)", anchor.x, anchor.y));
    
    local numRaid = GetNumRaidMembers();
    if numRaid > 0 then
        for i = 1, numRaid do
            local unit = "raid" .. i;
            if UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
                total = total + 1;
                local dist = self:GetDistanceFromAnchor(anchor.x, anchor.y, unit);
                if dist then
                    local inRangeStr = (dist <= TOTEM_RANGE_YARDS) and "YES" or "NO";
                    table.insert(debugInfo, string.format("    %s: %.1fy %s", UnitName(unit) or unit, dist, inRangeStr));
                    if dist <= TOTEM_RANGE_YARDS then
                        inRange = inRange + 1;
                    end
                else
                    table.insert(debugInfo, string.format("    %s: NO POSITION", UnitName(unit) or unit));
                end
            end
        end
    else
        local numParty = GetNumPartyMembers();
        
        -- Check player distance from anchor (NOT always in range!)
        total = 1;
        local playerDist = self:GetDistanceFromAnchor(anchor.x, anchor.y, "player");
        if playerDist then
            local inRangeStr = (playerDist <= TOTEM_RANGE_YARDS) and "YES" or "NO";
            table.insert(debugInfo, string.format("    %s: %.1fy %s", UnitName("player") or "player", playerDist, inRangeStr));
            if playerDist <= TOTEM_RANGE_YARDS then
                inRange = inRange + 1;
            end
        else
            table.insert(debugInfo, "    player: NO POSITION");
        end
        
        for i = 1, numParty do
            local unit = "party" .. i;
            if UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
                total = total + 1;
                local dist = self:GetDistanceFromAnchor(anchor.x, anchor.y, unit);
                if dist then
                    local inRangeStr = (dist <= TOTEM_RANGE_YARDS) and "YES" or "NO";
                    table.insert(debugInfo, string.format("    %s: %.1fy %s", UnitName(unit) or unit, dist, inRangeStr));
                    if dist <= TOTEM_RANGE_YARDS then
                        inRange = inRange + 1;
                    end
                else
                    table.insert(debugInfo, string.format("    %s: NO POSITION", UnitName(unit) or unit));
                end
            end
        end
    end
    
    return inRange, total, debugInfo;
end

function COE_QoL:UpdateTotemRangeDisplay()
    if not COE_TotemRangeFrame then return end
    if not COE_TotemRangeFrame:IsVisible() then return end
    
    if not self:IsInGroup() then
        local elements = {"Earth", "Fire", "Water", "Air"};
        for _, element in ipairs(elements) do
            local line = COE_TotemRangeFrame.elementTexts[element];
            if line then
                line:SetText("");
                line:Hide();
            end
        end
        if COE_TotemRangeFrame.title then
            COE_TotemRangeFrame.title:SetText("Totem Range\n(not in group)");
        end
        return;
    end
    
    if COE_TotemRangeFrame.title then
        COE_TotemRangeFrame.title:SetText("Totem Range");
    end
    
    if COE and COE.DebugMode then
        COE:DebugMessage("Totem Range Update (per-element anchors):");
    end
    
    local elements = {"Earth", "Fire", "Water", "Air"};
    for _, element in ipairs(elements) do
        local line = COE_TotemRangeFrame.elementTexts[element];
        if line then
            line:Show();
            
            local isActive = self:IsTotemActive(element);
            local hasAnchor = (self.TotemAnchors[element] ~= nil);
            
            if COE and COE.DebugMode then
                COE:DebugMessage("  " .. element .. ": active=" .. tostring(isActive) .. ", hasAnchor=" .. tostring(hasAnchor));
            end
            
            if isActive and hasAnchor then
                local inRange, total, debugInfo = self:CountMembersInRangeForElement(element);
                
                if COE and COE.DebugMode then
                    for _, info in ipairs(debugInfo) do
                        COE:DebugMessage(info);
                    end
                    COE:DebugMessage("  -> " .. element .. ": " .. inRange .. "/" .. total);
                end
                
                line:SetText(element .. ": " .. inRange .. "/" .. total);
                if total > 0 then
                    if inRange == total then
                        line:SetTextColor(0.3, 1, 0.3);
                    elseif inRange >= total / 2 then
                        line:SetTextColor(1, 1, 0.3);
                    else
                        line:SetTextColor(1, 0.3, 0.3);
                    end
                else
                    line:SetTextColor(0.5, 0.5, 0.5);
                end
            else
                -- No active totem or no anchor recorded
                line:SetText(element .. ": --");
                line:SetTextColor(0.5, 0.5, 0.5);
            end
        end
    end
end

function COE_QoL:SetTotemRangeVisible(visible)
    if not COE_TotemRangeFrame then
        self:CreateTotemRangeFrame();
    end
    
    if not self:HasPositionAPI() then
        COE_TotemRangeFrame:Hide();
        return;
    end
    
    if visible then
        self:RestoreTotemRangePosition();
        COE_TotemRangeFrame:Show();
        self:UpdateTotemRangeDisplay();
    else
        COE_TotemRangeFrame:Hide();
    end
end


--[[ ================================================================
    TANK DISTANCE HINT FRAME
================================================================ ]]--

function COE_QoL:CreateTankDistanceFrame()
    if COE_TankDistanceFrame then return end
    
    local frame = CreateFrame("Frame", "COE_TankDistanceFrame", UIParent);
    frame:SetWidth(90);
    frame:SetHeight(24);
    frame:SetPoint("CENTER", UIParent, "CENTER", -200, 100);
    frame:SetMovable(true);
    frame:EnableMouse(true);
    frame:SetClampedToScreen(true);
    frame:RegisterForDrag("LeftButton");
    
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    });
    frame:SetBackdropColor(0, 0, 0, 0.7);
    
    local text = frame:CreateFontString("COE_TankDistanceText", "OVERLAY", "GameFontNormal");
    text:SetPoint("CENTER", frame, "CENTER", 0, 0);
    text:SetText("Tank: --");
    
    frame:SetScript("OnDragStart", function()
        this:StartMoving();
    end);
    
    frame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing();
        COE_QoL:SaveTankDistancePosition();
    end);
    
    frame:Hide();
end

function COE_QoL:SaveTankDistancePosition()
    if not COE_TankDistanceFrame then return end
    if not COEFramePositions then COEFramePositions = {} end
    
    COEFramePositions.TankDistance = COEFramePositions.TankDistance or {};
    COEFramePositions.TankDistance.x = COE_TankDistanceFrame:GetLeft() or 0;
    COEFramePositions.TankDistance.y = COE_TankDistanceFrame:GetTop() or 0;
end

function COE_QoL:RestoreTankDistancePosition()
    if not COE_TankDistanceFrame then return end
    if not COEFramePositions then return end
    if not COEFramePositions.TankDistance then return end
    
    local pos = COEFramePositions.TankDistance;
    if pos.x and pos.y and pos.x ~= 0 and pos.y ~= 0 then
        COE_TankDistanceFrame:ClearAllPoints();
        COE_TankDistanceFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y);
    end
end

function COE_QoL:FindTankUnit(tankName)
    if not tankName or tankName == "" then return nil end
    
    local lowerName = string.lower(tankName);
    
    local numRaid = GetNumRaidMembers();
    if numRaid > 0 then
        for i = 1, numRaid do
            local unit = "raid" .. i;
            if UnitExists(unit) then
                local name = UnitName(unit);
                if name and string.lower(name) == lowerName then
                    return unit;
                end
            end
        end
    else
        local playerName = UnitName("player");
        if playerName and string.lower(playerName) == lowerName then
            return "player";
        end
        
        local numParty = GetNumPartyMembers();
        for i = 1, numParty do
            local unit = "party" .. i;
            if UnitExists(unit) then
                local name = UnitName(unit);
                if name and string.lower(name) == lowerName then
                    return unit;
                end
            end
        end
    end
    
    return nil;
end

function COE_QoL:UpdateTankDistanceDisplay()
    if not COE_TankDistanceFrame then return end
    if not COE_TankDistanceFrame:IsVisible() then return end
    
    if not self:HasPositionAPI() then
        COE_TankDistanceFrame:Hide();
        return;
    end
    
    local tankUnit = nil;
    local label = "Tank";
    
    if COE_Saved and COE_Saved.HB_TankName and COE_Saved.HB_TankName ~= "" then
        tankUnit = self:FindTankUnit(COE_Saved.HB_TankName);
    end
    
    if not tankUnit and COE_Saved and COE_Saved.HB_OffTankName and COE_Saved.HB_OffTankName ~= "" then
        tankUnit = self:FindTankUnit(COE_Saved.HB_OffTankName);
        if tankUnit then
            label = "OT";
        end
    end
    
    if not tankUnit then
        COE_TankDistanceText:SetText("Tank: --");
        COE_TankDistanceText:SetTextColor(0.5, 0.5, 0.5);
        return;
    end
    
    local dist = self:GetDistance("player", tankUnit);
    
    if not dist then
        COE_TankDistanceText:SetText(label .. ": --");
        COE_TankDistanceText:SetTextColor(0.5, 0.5, 0.5);
        return;
    end
    
    local distText = string.format("%.0f", dist);
    COE_TankDistanceText:SetText(label .. ": " .. distText .. "y");
    
    if dist <= 30 then
        COE_TankDistanceText:SetTextColor(0.3, 1, 0.3);
    elseif dist <= 38 then
        COE_TankDistanceText:SetTextColor(1, 1, 0.3);
    else
        COE_TankDistanceText:SetTextColor(1, 0.3, 0.3);
    end
end

function COE_QoL:SetTankDistanceVisible(visible)
    if not COE_TankDistanceFrame then
        self:CreateTankDistanceFrame();
    end
    
    if not self:HasPositionAPI() then
        COE_TankDistanceFrame:Hide();
        return;
    end
    
    if visible then
        self:RestoreTankDistancePosition();
        COE_TankDistanceFrame:Show();
        self:UpdateTankDistanceDisplay();
    else
        COE_TankDistanceFrame:Hide();
    end
end


--[[ ================================================================
    ONUPDATE HANDLER - Throttled updates for all QoL features
================================================================ ]]--

function COE_QoL:OnUpdate(elapsed)
    local now = GetTime();
    
    -- SuperWoW-dependent features
    if self:HasPositionAPI() then
        if COE_Saved and COE_Saved.HB_ShowTankDistance == 1 then
            if now - (self.lastTankUpdate or 0) >= TANK_DISTANCE_UPDATE_INTERVAL then
                self.lastTankUpdate = now;
                self:UpdateTankDistanceDisplay();
            end
        end
        
        if COE_Saved and COE_Saved.HB_ShowTotemRange == 1 then
            if now - (self.lastTotemUpdate or 0) >= TOTEM_UPDATE_INTERVAL then
                self.lastTotemUpdate = now;
                self:UpdateTotemRangeDisplay();
            end
        end
    end
    
    -- Shield Reminder (does NOT require SuperWoW)
    if COE_Saved and COE_Saved.HB_ShieldReminder == 1 then
        if now - (self.lastShieldUpdate or 0) >= SHIELD_UPDATE_INTERVAL then
            self.lastShieldUpdate = now;
            COE_HealAI_UpdateShieldReminder();
        end
    end
end


--[[ ================================================================
    HOOK: COE_Totem:ActivatePendingTotem
    Record totem anchor position when totem is dropped
================================================================ ]]--

function COE_QoL:HookTotemActivation()
    if not COE_Totem or not COE_Totem.ActivatePendingTotem then
        if COE and COE.DebugMode then
            COE:DebugMessage("QoL: Cannot hook ActivatePendingTotem - not found");
        end
        return;
    end
    
    if COE_Totem.__QoL_Hooked then return end
    COE_Totem.__QoL_Hooked = true;
    
    local original = COE_Totem.ActivatePendingTotem;
    COE_Totem.ActivatePendingTotem = function(self, totem)
        -- Call original first
        original(self, totem);
        
        -- Now record the anchor for this element
        if totem and COE and COE.TotemPendings then
            -- Note: After original() call, TotemPendings[totem] may be cleared
            -- But we can get the element from the totem object or ActiveTotems
            local element = nil;
            
            -- Try to find which element this totem belongs to
            if COE.ActiveTotems then
                for elem, activeTotem in pairs(COE.ActiveTotems) do
                    if activeTotem == totem then
                        element = elem;
                        break;
                    end
                end
            end
            
            if element and COE_QoL then
                COE_QoL:RecordTotemAnchor(element);
            end
        end
    end
    
    if COE and COE.DebugMode then
        COE:DebugMessage("QoL: Hooked COE_Totem:ActivatePendingTotem for anchor tracking");
    end
end

--[[ ----------------------------------------------------------------
    Initialize QoL features - called after VARIABLES_LOADED
-------------------------------------------------------------------]]
function COE_QoL:Initialize()
    local updateFrame = CreateFrame("Frame", "COE_QoL_UpdateFrame", UIParent);
    updateFrame:SetScript("OnUpdate", function()
        COE_QoL:OnUpdate(arg1);
    end);
    
    self:CreateTotemRangeFrame();
    self:CreateTankDistanceFrame();
    self:CreateShieldReminderFrame();  -- NEW: Shield Reminder
    
    -- Hook totem activation for anchor tracking
    self:HookTotemActivation();
    
    if COE_Saved then
        if COE_Saved.HB_ShowTotemRange == 1 then
            self:SetTotemRangeVisible(true);
        end
        if COE_Saved.HB_ShowTankDistance == 1 then
            self:SetTankDistanceVisible(true);
        end
        if COE_Saved.HB_ShieldReminder == 1 then
            self:SetShieldReminderVisible(true);
        end
    end
    
    if self:HasPositionAPI() then
        if COE and COE.DebugMode then
            COE:DebugMessage("COE_QoL: UnitPosition available, QoL features enabled");
        end
    end
end


--[[ ================================================================
    SHIELD REMINDER FEATURE
    
    Displays a simple indicator showing if Water/Lightning/Earth Shield
    is active on the player. Uses standard UnitBuff API (no SuperWoW required).
    
    Visual states:
    - "Shield – Active <Name>(<stacks>)" (green): shield with 4+ stacks
    - "Shield – Low <Name>(<stacks>)" (yellow): shield with 1-3 stacks
    - "Shield – MISSING" (red): no shield buff detected
    
    Shield types tracked:
    - Lightning Shield (standard Shaman shield)
    - Water Shield (restoration talent)
    - Earth Shield (Turtle WoW custom, if present)
================================================================ ]]--

-- NOTE: SHIELD_UPDATE_INTERVAL, SHIELD_NAMES, and COE_QoL.lastShieldUpdate 
-- are defined at the TOP of this file to ensure they exist before OnUpdate runs


--[[ ----------------------------------------------------------------
    FUNCTION: COE_HealAI_GetShieldState
    
    PURPOSE: Robust shield detection that never returns nil for stacks
    
    Parameters:
    - unit: unit ID (typically "player")
    
    Returns:
    - state: "MISSING", "LOW", or "OK"
    - shieldName: name of active shield, or nil if missing
    - stacks: stack count (integer, ALWAYS returns a number, never nil)
-------------------------------------------------------------------]]
function COE_HealAI_GetShieldState(unit)
    -- Default return values - stacks is ALWAYS a number
    local state = "MISSING";
    local shieldName = nil;
    local stacks = 0;
    
    -- Early out if unit doesn't exist
    if not unit or not UnitExists(unit) then
        if COE and COE.DebugMode then
            COE:DebugMessage("ShieldReminder: unit doesn't exist");
        end
        return state, shieldName, stacks;
    end
    
    -- Scan all buffs on the unit
    local buffIndex = 1;
    while buffIndex <= 40 do  -- Safety limit
        local texture, stackCount = UnitBuff(unit, buffIndex);
        if not texture then 
            break;  -- No more buffs
        end
        
        -- CRITICAL: Safely normalize stack count to a number (never nil)
        local safeStacks = 0;
        if stackCount ~= nil and type(stackCount) == "number" then
            safeStacks = stackCount;
        end
        
        -- Try to get buff name via tooltip
        local buffName = nil;
        if COETotemTT then
            COETotemTT:SetOwner(UIParent, "ANCHOR_NONE");
            COETotemTT:ClearLines();
            COETotemTT:SetUnitBuff(unit, buffIndex);
            if COETotemTTTextLeft1 then
                buffName = COETotemTTTextLeft1:GetText();
            end
        end
        
        -- Check if this buff matches any of our tracked shields
        if buffName and type(buffName) == "string" then
            for _, shieldPattern in ipairs(SHIELD_NAMES) do
                if string.find(buffName, shieldPattern) then
                    -- Found a shield!
                    shieldName = buffName;
                    stacks = safeStacks;  -- Already guaranteed to be a number
                    
                    -- Determine state based on stack count
                    -- SAFE: stacks is guaranteed to be a number here
                    if stacks >= 1 and stacks <= 3 then
                        state = "LOW";
                    elseif stacks > 3 then
                        state = "OK";
                    else
                        -- stacks == 0: treat as OK (some shields don't show stacks)
                        state = "OK";
                    end
                    
                    if COE and COE.DebugMode then
                        COE:DebugMessage("ShieldReminder: Found " .. shieldName .. " stacks=" .. tostring(stacks) .. " state=" .. state);
                    end
                    
                    return state, shieldName, stacks;
                end
            end
        end
        
        buffIndex = buffIndex + 1;
    end
    
    -- No shield found
    if COE and COE.DebugMode then
        COE:DebugMessage("ShieldReminder: No shield buff found");
    end
    return state, shieldName, stacks;
end


--[[ ----------------------------------------------------------------
    Create Shield Reminder Frame
    
    Creates a movable frame that auto-sizes to fit the text content.
-------------------------------------------------------------------]]
function COE_QoL:CreateShieldReminderFrame()
    if COE_ShieldReminderFrame then return end
    
    local frame = CreateFrame("Frame", "COE_ShieldReminderFrame", UIParent);
    frame:SetWidth(180);  -- Will be auto-adjusted
    frame:SetHeight(28);
    frame:SetPoint("CENTER", UIParent, "CENTER", -200, 100);
    frame:SetMovable(true);
    frame:EnableMouse(true);
    frame:SetClampedToScreen(true);
    frame:RegisterForDrag("LeftButton");
    
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    });
    frame:SetBackdropColor(0, 0, 0, 0.8);
    
    -- Single status text line - centered in frame
    local statusText = frame:CreateFontString("COE_ShieldReminderStatus", "OVERLAY", "GameFontNormal");
    statusText:SetPoint("CENTER", frame, "CENTER", 0, 0);
    statusText:SetText("Shield – MISSING");
    statusText:SetTextColor(1, 0.1, 0.1);  -- Red default
    
    frame:SetScript("OnDragStart", function()
        this:StartMoving();
    end);
    
    frame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing();
        COE_QoL:SaveShieldReminderPosition();
    end);
    
    frame:Hide();
end


function COE_QoL:SaveShieldReminderPosition()
    if not COE_ShieldReminderFrame then return end
    if not COEFramePositions then COEFramePositions = {} end
    
    COEFramePositions.ShieldReminder = COEFramePositions.ShieldReminder or {};
    COEFramePositions.ShieldReminder.x = COE_ShieldReminderFrame:GetLeft() or 0;
    COEFramePositions.ShieldReminder.y = COE_ShieldReminderFrame:GetTop() or 0;
end


function COE_QoL:RestoreShieldReminderPosition()
    if not COE_ShieldReminderFrame then return end
    if not COEFramePositions then return end
    if not COEFramePositions.ShieldReminder then return end
    
    local pos = COEFramePositions.ShieldReminder;
    if pos.x and pos.y and pos.x ~= 0 and pos.y ~= 0 then
        COE_ShieldReminderFrame:ClearAllPoints();
        COE_ShieldReminderFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y);
    end
end


--[[ ----------------------------------------------------------------
    FUNCTION: COE_HealAI_UpdateShieldReminder
    
    PURPOSE: Updates the shield reminder display
    
    Display format:
    - Shield active: "Water Shield (7)" 
    - Shield missing: "MISSING"
    
    Visual behavior:
    - In combat: Full opacity, colored text (green/yellow/red)
    - Out of combat: 30% frame opacity, grey text
-------------------------------------------------------------------]]
function COE_HealAI_UpdateShieldReminder()
    -- Early out if frame doesn't exist
    if not COE_ShieldReminderFrame then return end
    
    -- Early out and hide if feature is disabled
    if not COE_Saved or COE_Saved.HB_ShieldReminder ~= 1 then
        COE_ShieldReminderFrame:Hide();
        return;
    end
    
    -- Make sure frame is visible
    if not COE_ShieldReminderFrame:IsVisible() then
        COE_ShieldReminderFrame:Show();
    end
    
    -- Get shield state using robust helper (stacks is ALWAYS a number)
    local state, shieldName, stacks = COE_HealAI_GetShieldState("player");
    
    -- SAFETY: Ensure stacks is a number
    stacks = stacks or 0;
    if type(stacks) ~= "number" then
        stacks = 0;
    end
    
    -- Check combat state
    local inCombat = UnitAffectingCombat("player");
    
    -- Get the status text element
    local statusText = COE_ShieldReminderStatus;
    if not statusText then return end
    
    -- Build display text and determine color
    local displayText = "";
    local r, g, b = 1, 1, 1;
    
    if state == "MISSING" then
        -- No shield
        displayText = "MISSING";
        r, g, b = 1, 0.1, 0.1;  -- Red
        
    elseif state == "LOW" then
        -- Low stacks (1-3) - Yellow
        local displayName = shieldName or "Shield";
        displayText = displayName .. " (" .. tostring(stacks) .. ")";
        r, g, b = 1, 0.9, 0.2;  -- Yellow
        
    else  -- state == "OK"
        -- Healthy shield - Green
        local displayName = shieldName or "Shield";
        if stacks > 0 then
            displayText = displayName .. " (" .. tostring(stacks) .. ")";
        else
            displayText = displayName;
        end
        r, g, b = 0.2, 1, 0.2;  -- Green
    end
    
    -- Apply combat-based styling
    if inCombat then
        -- In combat: full opacity, colored text
        COE_ShieldReminderFrame:SetAlpha(1.0);
        statusText:SetTextColor(r, g, b);
    else
        -- Out of combat: 30% opacity, grey text
        COE_ShieldReminderFrame:SetAlpha(0.3);
        statusText:SetTextColor(0.7, 0.7, 0.7);  -- Grey
    end
    
    -- Update text
    statusText:SetText(displayText);
    
    -- Auto-size frame to fit text with padding
    local textWidth = statusText:GetStringWidth() or 80;
    local frameWidth = textWidth + 24;  -- 12px padding on each side
    if frameWidth < 80 then frameWidth = 80 end  -- Minimum width (smaller now)
    if frameWidth > 250 then frameWidth = 250 end  -- Maximum width
    COE_ShieldReminderFrame:SetWidth(frameWidth);
end


--[[ ----------------------------------------------------------------
    METHOD: COE_QoL:UpdateShieldReminderDisplay
    
    PURPOSE: Wrapper for backwards compatibility with OnUpdate handler
-------------------------------------------------------------------]]
function COE_QoL:UpdateShieldReminderDisplay()
    COE_HealAI_UpdateShieldReminder();
end


function COE_QoL:SetShieldReminderVisible(visible)
    if not COE_ShieldReminderFrame then
        self:CreateShieldReminderFrame();
    end
    
    if visible then
        self:RestoreShieldReminderPosition();
        COE_ShieldReminderFrame:Show();
        COE_HealAI_UpdateShieldReminder();
    else
        COE_ShieldReminderFrame:Hide();
    end
end
