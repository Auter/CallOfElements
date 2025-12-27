--[[

	CALL OF ELEMENTS
	The All-In-One Shaman Addon
	
	by Wyverex (2006)

	Healing Module
]]

if( not COE_Heal ) then
	COE_Heal = {};
end


--[[ ----------------------------------------------------------------
	COE_Heal.Thresholds stores different healing thresholds
	
	HealingNeeded - A target is only healed if it has less than
		this health ratio

	OverrideTarget - If a friendly target is active and a heal is
		attempted, this target is only healed if no party/raid
		member is below this health ration threshold
-------------------------------------------------------------------]]
COE_Heal["Thresholds"] = { HealingNeeded = 0.85, OverrideTarget = 0.5 };


--[[ =============================================================================================
		
							A N T I - S P A M   T R A C K I N G

	Prevents rapid back-to-back heals on the same target when spamming the heal key.
	Tracks the last heal target and time, and skips re-selecting them if they're now healthy.
================================================================================================]]

COE_Heal.LastHealTarget = nil;      -- Unit ID of last heal target
COE_Heal.LastHealTime = 0;          -- GetTime() when last heal was cast
COE_Heal.ANTISPAM_WINDOW = 2.0;     -- Seconds to consider for anti-spam (roughly one cast time)


--[[ =============================================================================================
		
							T A R G E T   S A V E / R E S T O R E

	HealAI must NEVER change the player's target as a side effect of healing.
	These helpers capture and restore the exact target state before/after casting.
	
	We do NOT use TargetLastEnemy() or TargetLastTarget() - they are unreliable.
	Instead, we explicitly save who/what we were targeting and restore it exactly.
================================================================================================]]

COE_Heal.SavedTargetName = nil;     -- Name of saved target (for re-targeting)
COE_Heal.SavedTargetUnit = nil;     -- Unit ID hint (party1, raid5, etc.) if available
COE_Heal.SavedHadTarget = false;    -- Did we have a target before?

--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:SaveCurrentTarget
	
	PURPOSE: Saves the player's current target so it can be restored
	after HealAI finishes casting.
	
	Captures:
	- Whether player had a target
	- The target's name (for finding them again)
	- A unit ID hint if we can determine one
-------------------------------------------------------------------]]
function COE_Heal:SaveCurrentTarget()
	COE_Heal.SavedHadTarget = UnitExists("target");
	COE_Heal.SavedTargetName = nil;
	COE_Heal.SavedTargetUnit = nil;
	
	if COE_Heal.SavedHadTarget then
		COE_Heal.SavedTargetName = UnitName("target");
		
		-- Try to find a stable unit ID for this target
		-- Check if it's the player
		if UnitIsUnit("target", "player") then
			COE_Heal.SavedTargetUnit = "player";
		-- Check if it's player's pet
		elseif UnitExists("pet") and UnitIsUnit("target", "pet") then
			COE_Heal.SavedTargetUnit = "pet";
		else
			-- Check party members
			for i = 1, GetNumPartyMembers() do
				if UnitIsUnit("target", "party" .. i) then
					COE_Heal.SavedTargetUnit = "party" .. i;
					break;
				end
				if UnitExists("partypet" .. i) and UnitIsUnit("target", "partypet" .. i) then
					COE_Heal.SavedTargetUnit = "partypet" .. i;
					break;
				end
			end
			
			-- Check raid members if not found in party
			if not COE_Heal.SavedTargetUnit then
				for i = 1, GetNumRaidMembers() do
					if UnitIsUnit("target", "raid" .. i) then
						COE_Heal.SavedTargetUnit = "raid" .. i;
						break;
					end
					if UnitExists("raidpet" .. i) and UnitIsUnit("target", "raidpet" .. i) then
						COE_Heal.SavedTargetUnit = "raidpet" .. i;
						break;
					end
				end
			end
			
			-- If still not found, it might be an enemy or NPC
			-- We'll use TargetByName as fallback (works for visible units)
			if not COE_Heal.SavedTargetUnit then
				COE_Heal.SavedTargetUnit = nil;  -- Will use name-based targeting
			end
		end
	end
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:RestoreSavedTarget
	
	PURPOSE: Restores the player's target to exactly what it was
	before HealAI started.
	
	Rules:
	- If player had no target: ClearTarget()
	- If player had a target: restore that exact target
	
	This NEVER uses TargetLastEnemy/TargetLastTarget - those are
	unreliable and can target the wrong thing.
-------------------------------------------------------------------]]
function COE_Heal:RestoreSavedTarget()
	if not COE_Heal.SavedHadTarget then
		-- Player had no target - clear any target we created
		if UnitExists("target") then
			ClearTarget();
		end
		return;
	end
	
	-- Player had a target - restore it
	if COE_Heal.SavedTargetUnit then
		-- We have a unit ID - use it directly (most reliable)
		if UnitExists(COE_Heal.SavedTargetUnit) then
			TargetUnit(COE_Heal.SavedTargetUnit);
			return;
		end
	end
	
	-- Fallback: use TargetByName if we have a name
	-- This works for any visible unit (friendly, enemy, NPC)
	if COE_Heal.SavedTargetName then
		TargetByName(COE_Heal.SavedTargetName);
		
		-- Verify it worked
		if UnitExists("target") and UnitName("target") == COE_Heal.SavedTargetName then
			return;  -- Success
		end
	end
	
	-- Last resort: if nothing worked and we had a target before,
	-- try not to leave the player with no target if they had one
	-- (this shouldn't happen in normal gameplay)
	COE:DebugMessage("Warning: Could not restore previous target");
end


--[[ =============================================================================================
		
							U N R E A C H A B L E   U N I T   T R A C K I N G

	Prevents repeatedly selecting the same out-of-range unit across keypresses.
	If a unit fails CanReachForCast(), they get a temporary penalty.
================================================================================================]]

COE_Heal.UnreachableUnits = {};     -- Table of { [unitName] = timestamp }
COE_Heal.UNREACHABLE_PENALTY_TIME = 3.0;  -- Seconds to penalize unreachable units


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:MarkUnreachable
	
	PURPOSE: Mark a unit as temporarily unreachable
-------------------------------------------------------------------]]
function COE_Heal:MarkUnreachable(unit)
	if not unit then return end
	local name = UnitName(unit);
	if name then
		COE_Heal.UnreachableUnits[name] = GetTime();
		COE:DebugMessage("Marked " .. name .. " as unreachable for " .. COE_Heal.UNREACHABLE_PENALTY_TIME .. "s");
	end
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:IsRecentlyUnreachable
	
	PURPOSE: Check if a unit was recently marked unreachable
	
	Returns: true if unit should be penalized, false otherwise
-------------------------------------------------------------------]]
function COE_Heal:IsRecentlyUnreachable(unit)
	if not unit then return false end
	local name = UnitName(unit);
	if not name then return false end
	
	local markedTime = COE_Heal.UnreachableUnits[name];
	if not markedTime then return false end
	
	local elapsed = GetTime() - markedTime;
	if elapsed < COE_Heal.UNREACHABLE_PENALTY_TIME then
		return true;
	else
		-- Expired, clean up
		COE_Heal.UnreachableUnits[name] = nil;
		return false;
	end
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:CleanupUnreachableCache
	
	PURPOSE: Remove expired entries from unreachable cache
-------------------------------------------------------------------]]
function COE_Heal:CleanupUnreachableCache()
	local now = GetTime();
	for name, timestamp in pairs(COE_Heal.UnreachableUnits) do
		if (now - timestamp) >= COE_Heal.UNREACHABLE_PENALTY_TIME then
			COE_Heal.UnreachableUnits[name] = nil;
		end
	end
end


--[[ =============================================================================================
		
							S U P E R W O W   I N T E G R A T I O N

	SuperWoW is a modified client that provides additional APIs for range and LoS checking.
	Detection: Check for SuperWoW global version string or specific API functions.
	
	If SuperWoW is NOT present:
	- All range/LoS checks return true (assume in range, in LoS)
	- No errors, addon works exactly as before
	
	If SuperWoW IS present:
	- Use UnitXP API for range checking
	- Use UnitXP API for line-of-sight checking
	- Filter out-of-range/LoS targets before healing
================================================================================================]]

COE_Heal.SuperWoWAvailable = false;
COE_Heal.SuperWoWChecked = false;
COE_Heal.HasPositionAPI = false;  -- Specifically tracks UnitPosition for Chain Heal

--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:CheckSuperWoW
	
	PURPOSE: Safely detects if SuperWoW is available
	
	SuperWoW provides several APIs. We check for any of:
	1. SUPERWOW_VERSION global
	2. UnitXP function (range/LoS API)
	3. UnitPosition function (position API - needed for Chain Heal clustering)
	4. SpellInfo function
	
	For Chain Heal specifically, we need UnitPosition.
-------------------------------------------------------------------]]
function COE_Heal:CheckSuperWoW()
	if COE_Heal.SuperWoWChecked then
		return COE_Heal.SuperWoWAvailable;
	end
	
	COE_Heal.SuperWoWChecked = true;
	COE_Heal.SuperWoWAvailable = false;
	COE_Heal.HasPositionAPI = false;
	
	-- Check each SuperWoW indicator and log results
	local versionCheck = (SUPERWOW_VERSION ~= nil);
	local unitXPCheck = (type(UnitXP) == "function");
	local unitPositionCheck = (type(UnitPosition) == "function");
	local spellInfoCheck = (type(SpellInfo) == "function");
	
	-- Verbose debug output for each check
	COE:DebugMessage("SuperWoW detection:");
	COE:DebugMessage("  SUPERWOW_VERSION = " .. tostring(SUPERWOW_VERSION or "nil"));
	COE:DebugMessage("  type(UnitXP) = " .. type(UnitXP));
	COE:DebugMessage("  type(UnitPosition) = " .. type(UnitPosition));
	COE:DebugMessage("  type(SpellInfo) = " .. type(SpellInfo));
	
	-- Track UnitPosition specifically (needed for Chain Heal)
	if unitPositionCheck then
		COE_Heal.HasPositionAPI = true;
		COE:DebugMessage("  -> UnitPosition available (Chain Heal clustering ENABLED)");
	else
		COE:DebugMessage("  -> UnitPosition NOT available (Chain Heal clustering DISABLED)");
	end
	
	-- SuperWoW is available if ANY of these checks pass
	if versionCheck or unitXPCheck or unitPositionCheck or spellInfoCheck then
		COE_Heal.SuperWoWAvailable = true;
		
		local detected = {};
		if versionCheck then table.insert(detected, "VERSION=" .. tostring(SUPERWOW_VERSION)) end
		if unitXPCheck then table.insert(detected, "UnitXP") end
		if unitPositionCheck then table.insert(detected, "UnitPosition") end
		if spellInfoCheck then table.insert(detected, "SpellInfo") end
		
		COE:DebugMessage("  RESULT: SuperWoW DETECTED via " .. table.concat(detected, ", "));
		return true;
	end
	
	COE:DebugMessage("  RESULT: SuperWoW NOT detected");
	return false;
end

--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:HasSuperWoWPositionAPI
	
	PURPOSE: Checks if UnitPosition is available (needed for Chain Heal)
	
	This is called by ShouldUseChainHeal() to determine if we can
	measure distances between party members.
-------------------------------------------------------------------]]
function COE_Heal:HasSuperWoWPositionAPI()
	-- Make sure we've done the check
	if not COE_Heal.SuperWoWChecked then
		COE_Heal:CheckSuperWoW();
	end
	return COE_Heal.HasPositionAPI;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:IsUnitInRange
	
	PURPOSE: Checks if unit is in range for healing spells
	
	Returns: 
	  true = definitely in range
	  false = definitely out of range
	  nil = unknown (API unavailable or returned garbage)
	
	SuperWoW API: UnitXP("unit", "range") returns distance in yards
	Healing Wave range is 40 yards
	
	SANITY CHECK: Any distance > 200 yards is treated as garbage data
	(no WoW map is that large, indicates API malfunction)
-------------------------------------------------------------------]]
function COE_Heal:IsUnitInRange(unit)
	-- Self is always in range
	if UnitIsUnit(unit, "player") then
		return true;
	end
	
	-- If SuperWoW not available, return nil (unknown)
	if not COE_Heal:CheckSuperWoW() then
		return nil;
	end
	
	if not UnitExists(unit) then
		return false;
	end
	
	-- Try SuperWoW range check
	if UnitXP then
		local success, distance = pcall(function()
			return UnitXP(unit, "range");
		end);
		
		if success and distance and type(distance) == "number" then
			-- SANITY CHECK: distances > 200 yards are garbage data
			if distance > 200 then
				COE:DebugMessage("Range check: " .. (UnitName(unit) or unit) .. " returned invalid distance " .. math.floor(distance) .. " - treating as unknown");
				return nil;  -- Unknown, not "out of range"
			end
			
			-- Valid distance - check against 40 yard healing range
			local inRange = (distance <= 40);
			if not inRange then
				COE:DebugMessage("Range check: " .. (UnitName(unit) or unit) .. " is " .. math.floor(distance) .. " yards (out of range)");
			end
			return inRange;
		end
	end
	
	-- Fallback: use CheckInteractDistance (less accurate but works)
	-- 4 = 28 yards (follow distance), good enough for healing
	if CheckInteractDistance(unit, 4) then
		return true;
	end
	
	-- Can't determine range - return nil (unknown)
	return nil;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:IsUnitInLineOfSight
	
	PURPOSE: Checks if unit is in line of sight
	
	Returns:
	  true = definitely in LoS
	  false = definitely NOT in LoS
	  nil = unknown (API unavailable)
	
	SuperWoW API: UnitXP("unit", "los") returns boolean
-------------------------------------------------------------------]]
function COE_Heal:IsUnitInLineOfSight(unit)
	-- Self is always in LoS
	if UnitIsUnit(unit, "player") then
		return true;
	end
	
	-- If SuperWoW not available, return nil (unknown)
	if not COE_Heal:CheckSuperWoW() then
		return nil;
	end
	
	if not UnitExists(unit) then
		return false;
	end
	
	-- Try SuperWoW LoS check
	if UnitXP then
		local success, hasLoS = pcall(function()
			return UnitXP(unit, "los");
		end);
		
		if success and hasLoS ~= nil then
			if not hasLoS then
				COE:DebugMessage("LoS check: " .. (UnitName(unit) or unit) .. " is out of line of sight");
			end
			return hasLoS;
		end
	end
	
	-- Can't determine LoS - return nil (unknown)
	return nil;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:IsUnitReachable
	
	PURPOSE: Combined range + LoS check
	
	Returns:
	  true = definitely reachable (in range AND in LoS)
	  false = definitely NOT reachable
	  nil = unknown (treat as potentially reachable)
-------------------------------------------------------------------]]
function COE_Heal:IsUnitReachable(unit)
	-- Self is always reachable
	if UnitIsUnit(unit, "player") then
		return true;
	end
	
	local rangeResult = COE_Heal:IsUnitInRange(unit);
	local losResult = COE_Heal:IsUnitInLineOfSight(unit);
	
	-- If either check returns definite FALSE, unit is unreachable
	if rangeResult == false then
		return false;
	end
	if losResult == false then
		return false;
	end
	
	-- If both return TRUE, unit is definitely reachable
	if rangeResult == true and losResult == true then
		return true;
	end
	
	-- Otherwise, at least one is unknown - return nil (unknown)
	return nil;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:CanReachForCast
	
	PURPOSE: FINAL authoritative range check before casting
	
	This uses Blizzard's native API (CheckInteractDistance) as the
	final gate. Even if SuperWoW returned "unknown", this check
	determines if we can actually reach the target.
	
	Returns: true if we can cast on this unit, false otherwise
	
	Vanilla 1.12 API:
	- CheckInteractDistance(unit, 4) = 28 yards (follow distance)
	- Healing Wave has 40 yard range, so this is conservative
	- UnitIsVisible(unit) = checks if unit model is rendered
	
	We use multiple checks and require ALL to pass for non-self targets
-------------------------------------------------------------------]]
function COE_Heal:CanReachForCast(unit)
	-- Self is always reachable
	if UnitIsUnit(unit, "player") then
		return true;
	end
	
	-- Unit must exist
	if not UnitExists(unit) then
		COE:DebugMessage("CanReachForCast: " .. tostring(unit) .. " does not exist");
		return false;
	end
	
	-- Unit must be visible (rendered in game world)
	if not UnitIsVisible(unit) then
		COE:DebugMessage("CanReachForCast: " .. (UnitName(unit) or unit) .. " is not visible");
		return false;
	end
	
	-- Unit must be connected (for players)
	if UnitIsPlayer(unit) and not UnitIsConnected(unit) then
		COE:DebugMessage("CanReachForCast: " .. (UnitName(unit) or unit) .. " is disconnected");
		return false;
	end
	
	-- CheckInteractDistance is the authoritative Blizzard range check
	-- distIndex 4 = 28 yards (follow distance) - conservative for 40 yard heals
	-- If this fails, we definitely cannot heal them
	if not CheckInteractDistance(unit, 4) then
		COE:DebugMessage("CanReachForCast: " .. (UnitName(unit) or unit) .. " failed CheckInteractDistance (>28 yards)");
		return false;
	end
	
	-- If SuperWoW says definitely out of range, trust it
	local superWowRange = COE_Heal:IsUnitInRange(unit);
	if superWowRange == false then
		COE:DebugMessage("CanReachForCast: " .. (UnitName(unit) or unit) .. " failed SuperWoW range check");
		return false;
	end
	
	-- If SuperWoW says definitely out of LoS, trust it
	local superWowLoS = COE_Heal:IsUnitInLineOfSight(unit);
	if superWowLoS == false then
		COE:DebugMessage("CanReachForCast: " .. (UnitName(unit) or unit) .. " failed SuperWoW LoS check");
		return false;
	end
	
	-- All checks passed
	return true;
end


--[[ =============================================================================================
		
							D I S P E L   T H R O T T L E

	Prevents dispel spam that starves healing.
	Tracks time of last dispel, enforces minimum delay between dispels.
================================================================================================]]

COE_Heal.LastDispelTime = 0;

--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:CanDispelNow
	
	PURPOSE: Checks if enough time has passed since last dispel
	
	Returns: true if dispel is allowed, false if throttled
-------------------------------------------------------------------]]
function COE_Heal:CanDispelNow()
	local throttleTime = 0;
	if COE_Saved and COE_Saved.HB_DispelThrottle then
		throttleTime = COE_Saved.HB_DispelThrottle;
	end
	
	-- If throttle is 0, always allow
	if throttleTime <= 0 then
		return true;
	end
	
	local now = GetTime();
	local elapsed = now - COE_Heal.LastDispelTime;
	
	if elapsed >= throttleTime then
		return true;
	end
	
	COE:DebugMessage("Dispel throttled: " .. string.format("%.1f", throttleTime - elapsed) .. "s remaining");
	return false;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:RecordDispel
	
	PURPOSE: Records the time of a successful dispel
-------------------------------------------------------------------]]
function COE_Heal:RecordDispel()
	COE_Heal.LastDispelTime = GetTime();
end


--[[ =============================================================================================
		
					H E A L   P R E D I C T I O N   H E L P E R S
					
	Inspired by QuickHeal's Shaman logic. Provides accurate heal amount prediction
	accounting for:
	- +Healing gear bonus with proper spell coefficients
	- Sub-level-20 penalty factors for downranked spells
	- Healing Way buff stacks on target
	- Healing debuffs (Mortal Strike, Veil of Shadow, etc.)
	- Combat vs out-of-combat damage padding
	- Nature's Swiftness detection
	- Tidal Focus talent (mana cost reduction)
	
	These helpers improve rank selection to pick the optimal spell for the situation.
================================================================================================]]

--[[ ----------------------------------------------------------------
	SPELL COEFFICIENTS
	
	+Healing bonus scales based on spell cast time.
	Formula: coefficient = cast_time / 3.5
	
	LHW = 1.5s cast = 42.86%
	HW = 3.0s cast = 85.71%
	Chain Heal = special coefficient (Turtle WoW: 0.6142)
-------------------------------------------------------------------]]
COE_Heal.SpellCoefficients = {
	["Lesser"] = 1.5 / 3.5,   -- 0.4286 (42.86%)
	["Wave"]   = 3.0 / 3.5,   -- 0.8571 (85.71%)
	["Chain"]  = 0.6142,      -- Turtle WoW specific coefficient
};

--[[ ----------------------------------------------------------------
	SUB-LEVEL-20 PENALTY FACTORS
	
	Spells learned before level 20 receive reduced +healing benefit.
	Formula: penalty = 1 - ((20 - levelLearned) * 0.0375)
	
	Only applies to Healing Wave ranks 1-4:
	- Rank 1: Level 1  -> penalty = 0.2875
	- Rank 2: Level 6  -> penalty = 0.475
	- Rank 3: Level 12 -> penalty = 0.7
	- Rank 4: Level 18 -> penalty = 0.925
	- Rank 5+: Level 20+ -> no penalty (1.0)
	
	LHW and Chain Heal are learned at 20+, no penalty.
-------------------------------------------------------------------]]
COE_Heal.PenaltyFactors = {
	["Wave"] = {
		[1] = 0.2875,  -- Level 1
		[2] = 0.475,   -- Level 6
		[3] = 0.7,     -- Level 12
		[4] = 0.925,   -- Level 18
		-- Rank 5+ = 1.0 (no penalty, not in table)
	},
	["Lesser"] = {},  -- LHW learned at level 20, no penalties
	["Chain"] = {},   -- Chain Heal learned at level 40, no penalties
};

--[[ ----------------------------------------------------------------
	HEALING DEBUFF MODIFIERS
	
	Maps debuff icon textures to healing reduction percentages.
	When a target has these debuffs, their effective heal need is
	increased to compensate for reduced healing received.
	
	Format: [iconName] = reduction_percent (0.0 to 1.0)
	Example: 0.5 = 50% healing reduction
-------------------------------------------------------------------]]
COE_Heal.HealingDebuffs = {
	-- Mortal Strike effects (50% reduction)
	["Ability_Warrior_SavageBlow"] = 0.5,     -- Mortal Strike (Warrior)
	["Ability_Warrior_DecisiveStrike"] = 0.5, -- Mortal Strike variant
	
	-- Mortal Wound effects (50% reduction, sometimes variable)
	["Ability_CriticalStrike"] = 0.5,         -- Mortal Wound (various mobs)
	
	-- Veil of Shadow / Curse effects (variable, often 75%)
	["Spell_Shadow_GatherShadows"] = 0.75,    -- Veil of Shadow, Gehenna's Curse
	
	-- Blood Fury (Orc racial - 25% reduction to self)
	["Ability_Rogue_FeignDeath0"] = 0.25,     -- Blood Fury
	
	-- Hex of Weakness (Priest - 20% reduction)
	["Spell_Shadow_FingerOfDeath"] = 0.2,     -- Hex of Weakness
	
	-- Brood Affliction: Green (BWL - 50% reduction)
	["INV_Misc_Head_Dragon_Green"] = 0.5,     -- Brood Affliction: Green
	
	-- Necrotic Poison (90% reduction - Naxx)
	["Ability_Creature_Poison_03"] = 0.9,     -- Necrotic Poison
};

--[[ ----------------------------------------------------------------
	COMBAT PADDING FACTORS
	
	When in combat, targets are actively taking damage during cast.
	We inflate heal need to account for this:
	- Fast spells (LHW): aim for 90% of deficit (k = 0.9)
	- Slow spells (HW): aim for 80% of deficit (K = 0.8)
	
	This means we pick slightly larger ranks during combat.
-------------------------------------------------------------------]]
COE_Heal.CombatPadding = {
	["Lesser"] = 0.90,  -- Fast 1.5s cast
	["Wave"]   = 0.80,  -- Slow 3.0s cast
	["Chain"]  = 0.80,  -- 2.5s cast, treat as slow
};


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:GetHealingBonus
	
	PURPOSE: Returns +healing bonus from equipped gear
	
	If ItemBonusLib is available (Ace library), uses it for accuracy.
	Otherwise returns 0 (no bonus estimation without library).
	
	Returns: +healing value (integer)
-------------------------------------------------------------------]]
function COE_Heal:GetHealingBonus()
	-- Try ItemBonusLib first (most accurate)
	if AceLibrary and AceLibrary.HasInstance then
		local success, hasLib = pcall(function()
			return AceLibrary:HasInstance("ItemBonusLib-1.0");
		end);
		
		if success and hasLib then
			local itemBonus = AceLibrary("ItemBonusLib-1.0");
			if itemBonus and itemBonus.GetBonus then
				local bonus = itemBonus:GetBonus("HEAL");
				if bonus and bonus > 0 then
					return bonus;
				end
			end
		end
	end
	
	-- Fallback: return 0 (no +healing estimation without library)
	-- Could potentially scan gear tooltips here, but that's complex
	return 0;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:GetTidalFocusMod
	
	PURPOSE: Returns mana cost modifier from Tidal Focus talent
	
	Tidal Focus (Restoration tree, tier 1, position 2):
	- Reduces mana cost of healing spells by 1% per rank
	- 5/5 = 5% reduction = 0.95 multiplier
	
	Returns: multiplier (0.95 to 1.0)
-------------------------------------------------------------------]]
function COE_Heal:GetTidalFocusMod()
	-- GetTalentInfo(tabIndex, talentIndex)
	-- Restoration = tab 3, Tidal Focus = talent 2
	local _, _, _, _, rank = GetTalentInfo(3, 2);
	
	if rank and rank > 0 then
		return 1 - (rank / 100);  -- 5/5 = 0.95
	end
	
	return 1.0;  -- No talent points
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:HasNaturesSwiftness
	
	PURPOSE: Checks if Nature's Swiftness buff is active
	
	When NS is active, the next nature spell is instant cast.
	This means we should prefer HW (bigger heal) over LHW.
	
	Buff icon: Spell_Nature_RavenForm
	
	Returns: true if NS active, false otherwise
-------------------------------------------------------------------]]
function COE_Heal:HasNaturesSwiftness()
	local i = 1;
	while true do
		local texture = UnitBuff("player", i);
		if not texture then return false end
		if string.find(texture, "Spell_Nature_RavenForm") then
			return true;
		end
		i = i + 1;
	end
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:GetHealingWayMod
	
	PURPOSE: Returns healing bonus from Healing Way stacks on target
	
	Healing Way talent: Each HW cast adds a stack (max 3).
	Each stack increases subsequent HW healing by 6%.
	3 stacks = 18% bonus = 1.18 multiplier
	
	Buff icon: Spell_Nature_HealingWay
	
	Returns: multiplier (1.0, 1.06, 1.12, or 1.18)
-------------------------------------------------------------------]]
function COE_Heal:GetHealingWayMod(unit)
	if not UnitExists(unit) then return 1.0 end
	
	local i = 1;
	while true do
		local texture, stacks = UnitBuff(unit, i);
		if not texture then break end
		if string.find(texture, "Spell_Nature_HealingWay") then
			local stackCount = stacks or 1;
			return 1 + (0.06 * stackCount);  -- 6% per stack
		end
		i = i + 1;
	end
	
	return 1.0;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:GetTargetHealModifier
	
	PURPOSE: Returns healing modifier caused by debuffs on target
	
	Scans target's debuffs for known healing reduction effects.
	Multiple debuffs stack multiplicatively.
	
	Example: Mortal Strike (50%) = 0.5 modifier
	         Veil of Shadow (75%) = 0.25 modifier
	         Both together = 0.5 * 0.25 = 0.125 modifier
	
	Returns: multiplier (0.0 to 1.0, lower = more healing needed)
-------------------------------------------------------------------]]
function COE_Heal:GetTargetHealModifier(unit)
	if not UnitExists(unit) then return 1.0 end
	
	local modifier = 1.0;
	local i = 1;
	local foundDebuffs = {};
	
	while true do
		local texture, stacks = UnitDebuff(unit, i);
		if not texture then break end
		
		-- Extract icon name from full texture path
		-- Format: Interface\Icons\IconName
		local iconName = nil;
		local _, _, extracted = string.find(texture, "Interface\\Icons\\(.+)");
		if extracted then
			iconName = extracted;
		end
		
		if iconName and COE_Heal.HealingDebuffs[iconName] then
			local reduction = COE_Heal.HealingDebuffs[iconName];
			modifier = modifier * (1 - reduction);
			table.insert(foundDebuffs, iconName .. "(" .. (reduction * 100) .. "%)");
		end
		
		i = i + 1;
	end
	
	if modifier < 1.0 then
		COE:DebugMessage("Heal debuff on " .. (UnitName(unit) or unit) .. 
			": modifier=" .. string.format("%.2f", modifier) .. 
			" (" .. table.concat(foundDebuffs, ", ") .. ")");
	end
	
	return modifier;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:PredictHealAmount
	
	PURPOSE: Predicts actual heal amount for a specific spell
	
	Accounts for:
	- Base heal from spell data (COE.HealData)
	- +Healing bonus with spell coefficient
	- Sub-level-20 penalty factor
	- Healing Way stacks on target (for HW only)
	
	Parameters:
	- spellType: "Lesser", "Wave", or "Chain"
	- rank: spell rank (1-10)
	- targetUnit: unit ID for Healing Way check (optional)
	
	Returns: predicted heal amount (integer)
-------------------------------------------------------------------]]
function COE_Heal:PredictHealAmount(spellType, rank, targetUnit)
	-- Get base heal from spell data
	local spellData = COE.HealData[spellType];
	if not spellData or not spellData[rank] then
		return 0;
	end
	
	local baseHeal = spellData[rank].AvgAmount;
	
	-- Get +healing bonus
	local bonus = self:GetHealingBonus();
	local coefficient = self.SpellCoefficients[spellType] or 0;
	
	-- Apply sub-level-20 penalty if applicable
	local penalty = 1.0;
	if self.PenaltyFactors[spellType] and self.PenaltyFactors[spellType][rank] then
		penalty = self.PenaltyFactors[spellType][rank];
	end
	
	-- Calculate +healing contribution
	local bonusHeal = bonus * coefficient * penalty;
	
	-- Calculate total heal
	local totalHeal = baseHeal + bonusHeal;
	
	-- Apply Healing Way modifier (only for Healing Wave)
	if spellType == "Wave" and targetUnit then
		local hwMod = self:GetHealingWayMod(targetUnit);
		if hwMod > 1.0 then
			totalHeal = totalHeal * hwMod;
			COE:DebugMessage("Healing Way on " .. (UnitName(targetUnit) or targetUnit) .. 
				": " .. string.format("%.0f", hwMod * 100 - 100) .. "% bonus");
		end
	end
	
	return math.floor(totalHeal);
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:GetAdjustedHealNeed
	
	PURPOSE: Calculates heal need adjusted for debuffs and combat
	
	Adjustments:
	1. Healing debuffs: Inflate heal need to compensate for reduced healing
	   Example: 1000 HP missing + Mortal Strike (50%) = need 2000 HP heal
	
	2. Combat padding: Inflate heal need to account for incoming damage
	   Example: 1000 HP missing in combat with HW = need ~1250 HP heal
	
	Parameters:
	- unit: unit ID of heal target
	- rawDeficit: raw HP missing
	- spellType: "Lesser", "Wave", or "Chain" (for combat padding)
	- inCombat: whether player or target is in combat
	
	Returns: adjusted heal need (integer)
-------------------------------------------------------------------]]
function COE_Heal:GetAdjustedHealNeed(unit, rawDeficit, spellType, inCombat)
	local adjustedNeed = rawDeficit;
	
	-- 1. Adjust for healing debuffs
	local healMod = self:GetTargetHealModifier(unit);
	if healMod < 1.0 and healMod > 0 then
		-- Inflate heal need: if only 50% heals land, need 2x heal
		adjustedNeed = adjustedNeed / healMod;
		COE:DebugMessage("Debuff-adjusted heal need: " .. math.floor(rawDeficit) .. 
			" -> " .. math.floor(adjustedNeed) .. " (mod=" .. string.format("%.2f", healMod) .. ")");
	end
	
	-- 2. Apply combat padding (inflate for incoming damage during cast)
	if inCombat and spellType then
		local padding = self.CombatPadding[spellType];
		if padding and padding < 1.0 then
			-- Divide by padding factor to inflate
			-- padding=0.8 means we want to heal 125% of deficit
			adjustedNeed = adjustedNeed / padding;
			COE:DebugMessage("Combat-padded heal need: " .. 
				math.floor(rawDeficit / healMod) .. " -> " .. math.floor(adjustedNeed) .. 
				" (padding=" .. padding .. ")");
		end
	end
	
	return math.floor(adjustedNeed);
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:CanAffordSpell
	
	PURPOSE: Checks if player has enough mana for a spell
	
	Accounts for Tidal Focus talent (mana cost reduction).
	
	Parameters:
	- spellData: spell table entry from COE.HealData
	
	Returns: true if affordable, false if not enough mana
-------------------------------------------------------------------]]
function COE_Heal:CanAffordSpell(spellData)
	if not spellData or not spellData.Mana then
		return false;
	end
	
	local baseCost = spellData.Mana;
	local tfMod = self:GetTidalFocusMod();
	local effectiveCost = baseCost * tfMod;
	
	return UnitMana("player") >= effectiveCost;
end


--[[ =============================================================================================
		
							C O N S E R V A T I V E   H E A L C O M M

	Cancels heals that would result in heavy overheal (>95% HP after heal lands).
	Only applies to normal healing, NOT to spam/maintenance mode.
	
	1.12 Constraints:
	- SpellStopCasting() can be called from secure code
	- We hook SPELLCAST_START to track our healing
	- We use OnUpdate to monitor predicted HP during cast
================================================================================================]]

COE_Heal.CurrentCast = nil;  -- { targetName, healAmount, startTime, endTime }
COE_Heal.ConservativeFrame = nil;  -- OnUpdate frame for monitoring

--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:InitConservativeHealComm
	
	PURPOSE: Creates the monitoring frame for conservative HealComm
-------------------------------------------------------------------]]
function COE_Heal:InitConservativeHealComm()
	if COE_Heal.ConservativeFrame then return end
	
	COE_Heal.ConservativeFrame = CreateFrame("Frame", "COE_ConservativeHealCommFrame", UIParent);
	COE_Heal.ConservativeFrame:Hide();
	
	COE_Heal.ConservativeFrame:SetScript("OnUpdate", function()
		COE_Heal:ConservativeOnUpdate();
	end);
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:StartTrackingCast
	
	PURPOSE: Called when we start casting a heal
	Records cast info for conservative monitoring
-------------------------------------------------------------------]]
function COE_Heal:StartTrackingCast(targetUnit, healAmount, castTime)
	-- Only track if conservative mode is enabled
	if not COE_Saved or COE_Saved.HB_ConservativeHealComm ~= 1 then
		return;
	end
	
	-- Don't track in spam mode (spam bypasses HealComm)
	if COE_Saved.HB_SpamMode == 1 then
		return;
	end
	
	-- Don't track if HealComm is disabled
	if COE_Saved.HB_UseHealComm ~= 1 then
		return;
	end
	
	local targetName = UnitName(targetUnit);
	if not targetName then return end
	
	local now = GetTime();
	COE_Heal.CurrentCast = {
		targetName = targetName,
		targetUnit = targetUnit,
		healAmount = healAmount,
		startTime = now,
		endTime = now + (castTime or 2.5)
	};
	
	-- Start monitoring
	COE_Heal:InitConservativeHealComm();
	COE_Heal.ConservativeFrame:Show();
	
	COE:DebugMessage("Conservative: Tracking " .. healAmount .. " heal on " .. targetName);
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:StopTrackingCast
	
	PURPOSE: Called when cast ends (success, cancel, or interrupt)
-------------------------------------------------------------------]]
function COE_Heal:StopTrackingCast()
	COE_Heal.CurrentCast = nil;
	if COE_Heal.ConservativeFrame then
		COE_Heal.ConservativeFrame:Hide();
	end
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:ConservativeOnUpdate
	
	PURPOSE: Monitors predicted HP during cast, cancels if overheal
	
	Predicted HP calculation:
	- currentHP + incomingHeals (from HealComm) + ourHeal
	- If predicted > 95% of maxHP, cancel cast
-------------------------------------------------------------------]]
function COE_Heal:ConservativeOnUpdate()
	if not COE_Heal.CurrentCast then
		COE_Heal:StopTrackingCast();
		return;
	end
	
	local cast = COE_Heal.CurrentCast;
	local now = GetTime();
	
	-- Cast finished naturally
	if now >= cast.endTime then
		COE_Heal:StopTrackingCast();
		return;
	end
	
	-- Find the target unit
	local targetUnit = nil;
	
	-- First check if original unit still matches
	if cast.targetUnit and UnitExists(cast.targetUnit) then
		local name = UnitName(cast.targetUnit);
		if name == cast.targetName then
			targetUnit = cast.targetUnit;
		end
	end
	
	-- Search for target by name if needed
	if not targetUnit then
		-- Check player
		if UnitName("player") == cast.targetName then
			targetUnit = "player";
		else
			-- Check party/raid
			for i = 1, GetNumPartyMembers() do
				if UnitName("party" .. i) == cast.targetName then
					targetUnit = "party" .. i;
					break;
				end
			end
			if not targetUnit then
				for i = 1, GetNumRaidMembers() do
					if UnitName("raid" .. i) == cast.targetName then
						targetUnit = "raid" .. i;
						break;
					end
				end
			end
		end
	end
	
	if not targetUnit then
		-- Target not found, stop tracking
		COE_Heal:StopTrackingCast();
		return;
	end
	
	-- Calculate predicted HP at landing
	local currentHP = UnitHealth(targetUnit);
	local maxHP = UnitHealthMax(targetUnit);
	local incomingHeal = COE_Heal:GetIncomingHeal(targetUnit);  -- From other healers
	local ourHeal = cast.healAmount;
	
	local predictedHP = currentHP + incomingHeal + ourHeal;
	local predictedRatio = predictedHP / maxHP;
	
	-- Check if we'd overheal past 95%
	if predictedRatio > 0.95 then
		-- Calculate how much overheal
		local overheal = predictedHP - maxHP;
		local overhealPct = (overheal / ourHeal) * 100;
		
		-- Only cancel if significant overheal (>50% of our heal wasted)
		if overhealPct > 50 then
			COE:DebugMessage("Conservative: Canceling heal - predicted " .. 
				math.floor(predictedRatio * 100) .. "% HP (" .. 
				math.floor(overhealPct) .. "% overheal)");
			
			-- Cancel the cast
			SpellStopCasting();
			COE_Heal:StopTrackingCast();
		end
	end
end


--[[ =============================================================================================
		
							H E A L C O M M   I N T E G R A T I O N

================================================================================================]]

-- HealComm state
COE_Heal.HealCommAvailable = false;
COE_Heal.HealCommChecked = false;
COE_Heal.HealCommLib = nil;  -- Reference to the HealComm-1.0 library

--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:CheckHealComm
	
	PURPOSE: Checks if HealComm-1.0 addon is loaded via AceLibrary
	
	HealComm-1.0 API:
	  - HealComm:getHeal(unitName) - Returns total incoming heal amount
	  - HealComm:getNumHeals(unitName) - Returns number of incoming heals
-------------------------------------------------------------------]]
function COE_Heal:CheckHealComm()
	if COE_Heal.HealCommChecked then
		return COE_Heal.HealCommAvailable;
	end
	
	COE_Heal.HealCommChecked = true;
	COE_Heal.HealCommAvailable = false;
	COE_Heal.HealCommLib = nil;
	
	-- HealComm-1.0 uses AceLibrary
	if AceLibrary and AceLibrary.HasInstance and AceLibrary:HasInstance("HealComm-1.0") then
		COE_Heal.HealCommLib = AceLibrary("HealComm-1.0");
		if COE_Heal.HealCommLib and COE_Heal.HealCommLib.getHeal then
			COE_Heal.HealCommAvailable = true;
			COE:DebugMessage("HealComm-1.0 detected via AceLibrary");
		end
	end
	
	if not COE_Heal.HealCommAvailable then
		COE:DebugMessage("HealComm not detected");
	end
	
	return COE_Heal.HealCommAvailable;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:GetIncomingHeal
	
	PURPOSE: Gets the amount of incoming healing on a unit from HealComm
	Returns: number (0 if HealComm not available or no incoming heals)
-------------------------------------------------------------------]]
function COE_Heal:GetIncomingHeal(unit)
	-- Check if HealComm integration is enabled
	if not COE_Saved or COE_Saved.HB_UseHealComm ~= 1 then
		return 0;
	end
	
	-- Check if HealComm is available
	if not COE_Heal:CheckHealComm() then
		return 0;
	end
	
	if not COE_Heal.HealCommLib then
		return 0;
	end
	
	-- Get unit name for HealComm lookup (HealComm uses player names)
	local unitName = UnitName(unit);
	if not unitName then return 0 end
	
	-- Use HealComm-1.0 API: getHeal(unitName)
	local incoming = COE_Heal.HealCommLib:getHeal(unitName) or 0;
	
	return incoming;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:GetEffectiveDeficit
	
	PURPOSE: Calculates the effective health deficit after accounting
		for incoming heals from HealComm
	Returns: effectiveDeficit (can be 0 or negative if overhealing)
-------------------------------------------------------------------]]
function COE_Heal:GetEffectiveDeficit(unit)
	local curHealth = UnitHealth(unit);
	local maxHealth = UnitHealthMax(unit);
	local deficit = maxHealth - curHealth;
	
	local incoming = COE_Heal:GetIncomingHeal(unit);
	local effectiveDeficit = deficit - incoming;
	
	if incoming > 0 then
		COE:DebugMessage(UnitName(unit) .. ": deficit " .. deficit .. ", incoming " .. incoming .. ", effective " .. effectiveDeficit);
	end
	
	return effectiveDeficit;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:GetHealCommData
	
	PURPOSE: Returns full HealComm data for advanced logic
	
	Returns table:
	{
		missingHP = raw missing HP,
		incoming = incoming heals from HealComm,
		effectiveDeficit = missingHP - incoming,
		safetyBuffer = 10% of maxHP,
		maxHP = max health
	}
-------------------------------------------------------------------]]
function COE_Heal:GetHealCommData(unit)
	local curHealth = UnitHealth(unit);
	local maxHealth = UnitHealthMax(unit);
	if maxHealth == 0 then maxHealth = 1 end  -- Prevent div by zero
	
	local missingHP = maxHealth - curHealth;
	local incoming = COE_Heal:GetIncomingHeal(unit);
	local effectiveDeficit = missingHP - incoming;
	local safetyBuffer = 0.10 * maxHealth;  -- 10% of max HP
	
	return {
		missingHP = missingHP,
		incoming = incoming,
		effectiveDeficit = effectiveDeficit,
		safetyBuffer = safetyBuffer,
		maxHP = maxHealth
	};
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:ShouldSkipDueToHealComm
	
	PURPOSE: Determines if a NON-TANK target should be skipped
		because incoming heals are sufficient (with 10% safety buffer)
	
	RULES:
	- Only applies to non-tanks
	- Uses 10% max HP as safety buffer
	- If effectiveDeficit <= safetyBuffer, target is "covered"
	
	Returns: true if should skip, false if should heal
-------------------------------------------------------------------]]
function COE_Heal:ShouldSkipDueToHealComm(unit, isTank)
	-- NEVER skip tanks due to HealComm
	if isTank then
		return false;
	end
	
	-- Check if HealComm is enabled
	if not COE_Saved or COE_Saved.HB_UseHealComm ~= 1 then
		return false;
	end
	
	local data = COE_Heal:GetHealCommData(unit);
	
	-- If no incoming heals, don't skip
	if data.incoming <= 0 then
		return false;
	end
	
	-- 10% safety buffer: skip only if effective deficit is very small
	if data.effectiveDeficit <= data.safetyBuffer then
		COE:DebugMessage("HealComm skip: " .. (UnitName(unit) or unit) .. 
			" (deficit=" .. math.floor(data.missingHP) .. 
			", incoming=" .. math.floor(data.incoming) .. 
			", effective=" .. math.floor(data.effectiveDeficit) .. 
			", buffer=" .. math.floor(data.safetyBuffer) .. ")");
		return true;
	end
	
	return false;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:GetClampedDeficitForRank
	
	PURPOSE: In RANK_ADJUST mode, returns a clamped deficit for
		rank selection that accounts for incoming heals but doesn't
		under-heal too aggressively
	
	RULES:
	- For tanks: clamp to at least 50% of raw missing HP
	- For non-tanks: clamp to at least 20% of raw missing HP
	- This prevents choosing tiny heals when someone is badly hurt
	
	Returns: deficit value to use for rank selection
-------------------------------------------------------------------]]
function COE_Heal:GetClampedDeficitForRank(unit, isTank)
	-- If HealComm is disabled or not in RANK_ADJUST mode, use raw deficit
	if not COE_Saved or COE_Saved.HB_UseHealComm ~= 1 then
		local maxHP = UnitHealthMax(unit);
		return maxHP - UnitHealth(unit);
	end
	
	local mode = COE_Saved.HB_HealCommMode or "RANK_ADJUST";
	if mode ~= "RANK_ADJUST" then
		-- TRUST mode: don't adjust rank, use raw deficit
		local maxHP = UnitHealthMax(unit);
		return maxHP - UnitHealth(unit);
	end
	
	local data = COE_Heal:GetHealCommData(unit);
	
	-- No incoming heals? Use raw deficit
	if data.incoming <= 0 then
		return data.missingHP;
	end
	
	-- Calculate clamped deficit
	local minRatio = isTank and 0.50 or 0.20;
	local minDeficit = minRatio * data.missingHP;
	local clampedDeficit = math.max(data.effectiveDeficit, minDeficit);
	
	if clampedDeficit ~= data.missingHP then
		COE:DebugMessage("HealComm rank adjust: " .. (UnitName(unit) or unit) .. 
			" raw=" .. math.floor(data.missingHP) .. 
			", clamped=" .. math.floor(clampedDeficit) ..
			" (" .. (isTank and "tank 50%" or "non-tank 20%") .. " floor)");
	end
	
	return clampedDeficit;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:Init
	
	PURPOSE: Registers events
-------------------------------------------------------------------]]
function COE_Heal:Init()

	-- addon loaded?
	-- --------------
	if( not COE.Initialized ) then
		return;
	end

	this:RegisterEvent( "PLAYER_ENTERING_WORLD" );

end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:OnEvent
	
	PURPOSE: Handles In-Game events
-------------------------------------------------------------------]]
function COE_Heal:OnEvent( event )

	if( event == "PLAYER_ENTERING_WORLD" ) then
		-- load healing spells
		-- --------------------
		COE:ScanHealingSpells();
	end

end

--[[ =============================================================================================

						P U B L I C   H E A L I N G   F U N C T I O N S 

================================================================================================]]

--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:BestHeal
	
	PURPOSE: Determines the party/raid member with the lowest
		health ratio and attempts to heal him with the best
		possible heal spell but still tries to be as mana
		efficient as possible
-------------------------------------------------------------------]]
function COE_Heal:BestHeal()

	COE_Heal:Heal( "best" );
	
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:BattleHeal
	
	PURPOSE: Determines the party/raid member with the lowest
		health ratio and attempts to heal him with the heal spell 
		that has the shortest possible cast time but still heals
		him a good amount.
		If Nature's Swiftness is active, it uses BestHeal instead 
-------------------------------------------------------------------]]
function COE_Heal:BattleHeal()

	COE_Heal:Heal( "battle" );
		
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:Heal
	
	PURPOSE: Performs the healing logic
	
	Emergency Threshold: If anyone is below this %, use fast heal (Lesser HW)
	Top-up Threshold: Only heal if someone is below this %
-------------------------------------------------------------------]]
function COE_Heal:Heal( type )

	-- Clean up expired unreachable entries
	COE_Heal:CleanupUnreachableCache();

	-- first determine the target to be healed
	-- ----------------------------------------
	local healResult = COE_Heal:DetermineHealTarget();
	
	-- Get thresholds from HealAI settings
	local topUpThreshold = 0.85;
	local emergencyThreshold = 0.55;
	
	if COE_Saved then
		if COE_Saved.HB_TopUp then
			topUpThreshold = COE_Saved.HB_TopUp / 100;
		end
		if COE_Saved.HB_Emergency then
			emergencyThreshold = COE_Saved.HB_Emergency / 100;
		end
	end
	
	-- Get the candidate list
	local candidates = healResult.candidates or {};
	
	-- If no candidates at all, nothing to heal
	if table.getn(candidates) == 0 then
		COE:Message( COESTR_NOHEALING );
		return;
	end
	
	-- Iterate through candidates until we find one that passes CanReachForCast
	local target = nil;
	local targetIndex = 0;
	
	for i, c in ipairs(candidates) do
		-- Check if above top-up threshold (no healing needed)
		if c.ratio > topUpThreshold then
			COE:DebugMessage("Candidate " .. i .. " (" .. c.unit .. ") at " .. 
				math.floor(c.ratio * 100) .. "% > top-up threshold - skipping");
		else
			-- Check if reachable
			if UnitIsUnit(c.unit, "player") then
				-- Self is always reachable
				target = c;
				targetIndex = i;
				break;
			else
				local canReach = COE_Heal:CanReachForCast(c.unit);
				if canReach then
					target = c;
					targetIndex = i;
					break;
				else
					-- Mark as unreachable for future presses
					COE_Heal:MarkUnreachable(c.unit);
					COE:DebugMessage("Candidate " .. i .. " (" .. (UnitName(c.unit) or c.unit) .. 
						") failed range check - trying next");
				end
			end
		end
	end
	
	-- If no reachable target found
	if not target then
		COE:Message("All targets out of range or healthy - skipping heal");
		COE:DebugMessage("No reachable candidates below top-up threshold");
		return;
	end
	
	COE:DebugMessage("Selected candidate " .. targetIndex .. ": " .. (UnitName(target.unit) or target.unit) .. 
		" at " .. math.floor(target.ratio * 100) .. "%");

	local deficit = target.max - target.current;
	
	-- In RANK_ADJUST mode, use clamped deficit for rank selection
	-- This accounts for incoming heals while preventing under-healing
	local deficitForRank = deficit;
	if target.clampedDeficitForRank and target.clampedDeficitForRank ~= deficit then
		deficitForRank = target.clampedDeficitForRank;
		COE:DebugMessage("HealComm RANK_ADJUST: using clamped deficit " .. 
			math.floor(deficitForRank) .. " instead of raw " .. math.floor(deficit));
	end
	
	-- Check if in combat (player or target)
	local inCombat = UnitAffectingCombat("player") or UnitAffectingCombat(target.unit);
	
	-- Determine spell type for combat padding
	local spellTypeHint = (target.inTankEmergency or target.ratio < emergencyThreshold) and "Lesser" or "Wave";
	
	-- Apply QuickHeal-inspired adjustments to heal need:
	-- 1. Healing debuffs (Mortal Strike, etc.) - inflate need to compensate
	-- 2. Combat padding - inflate need for incoming damage during cast
	local adjustedDeficit = COE_Heal:GetAdjustedHealNeed(target.unit, deficitForRank, spellTypeHint, inCombat);
	
	if adjustedDeficit ~= deficitForRank then
		COE:DebugMessage("Adjusted heal need: " .. math.floor(deficitForRank) .. 
			" -> " .. math.floor(adjustedDeficit) .. " (debuffs/combat padding)");
	end
	
	COE:DebugMessage( "Attempting to heal " .. target.unit .. " at " .. math.floor(target.ratio * 100) .. 
		"% (missing: " .. deficit .. ", for rank: " .. math.floor(adjustedDeficit) .. ")" );

	-- Determine spell type based on emergency threshold
	-- If target is in emergency (below emergency threshold), use fast heal
	-- Tank emergency override also uses fast heal
	local id, spell, rank;
	
	if target.inTankEmergency then
		-- TANK EMERGENCY OVERRIDE: Use fast heal (use RAW deficit for emergency)
		-- But still apply debuff/combat adjustments
		local emergencyDeficit = COE_Heal:GetAdjustedHealNeed(target.unit, deficit, "Lesser", inCombat);
		COE:DebugMessage("TANK EMERGENCY OVERRIDE: Using fast heal for tank");
		id, spell, rank = COE_Heal:DetermineBattleSpell( emergencyDeficit, target.unit );
	elseif target.ratio < emergencyThreshold then
		-- EMERGENCY: Use fast heal (Lesser Healing Wave / BattleHeal)
		-- Use adjusted deficit for emergencies
		local emergencyDeficit = COE_Heal:GetAdjustedHealNeed(target.unit, deficit, "Lesser", inCombat);
		COE:DebugMessage("EMERGENCY: " .. math.floor(target.ratio * 100) .. "% < " .. math.floor(emergencyThreshold * 100) .. "% - using fast heal");
		id, spell, rank = COE_Heal:DetermineBattleSpell( emergencyDeficit, target.unit );
	else
		-- Normal: Use efficient heal (Healing Wave / BestHeal)
		-- Here we use the adjusted deficit
		if type == "best" then
			id, spell, rank = COE_Heal:DetermineBestSpell( COE.HealData.Sorted, adjustedDeficit, target.unit );
		else
			id, spell, rank = COE_Heal:DetermineBattleSpell( adjustedDeficit, target.unit );
		end
	end
	
	if( not id ) then
		return;
	end
	
	COE:DebugMessage( "Using " .. spell .. " (Rank " .. rank .. ")" );
	
	-- is the spell usable?
	-- ---------------------
	local start, duration = GetSpellCooldown( id, BOOKTYPE_SPELL );
	if( start > 0 or duration > 0 ) then
		COE:Message( spell .. COESTR_HEALCOOLDOWN );
		return;
	end
	
	-- NOTE: Range check already done in the candidate loop above
	-- If we got here, target.unit is confirmed reachable
	
	-- ANTI-SPAM: Record this heal target and time
	COE_Heal.LastHealTarget = target.unit;
	COE_Heal.LastHealTime = GetTime();
	
	-- cast spell
	-- -----------
	-- In Vanilla 1.12, we need to target the unit BEFORE casting for helpful spells
	-- IMPORTANT: Save and restore original target exactly (never steal player's target)
	COE_Heal:SaveCurrentTarget();
	
	-- Target the heal recipient
	TargetUnit(target.unit);
	
	COE:Message( string.format( COESTR_HEALING, UnitName( target.unit ), spell, rank ) );
	CastSpell( id, BOOKTYPE_SPELL );
	
	-- Restore player's original target exactly
	COE_Heal:RestoreSavedTarget();


end


--[[ =============================================================================================
		
							H E A L I N G   L O G I C 

================================================================================================]]

--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:DetermineHealTarget
	
	PURPOSE: Determines the party/raid member with 
		the lowest health ratio which can also be the player himself
		
		HealAI Core settings:
		- Tank priority (HB_TankName, HB_OffTankName)
		- Target-of-Target fallback (HB_UseToT)
		- Prioritize tanks (HB_PrioritizeTank)
		- Ignore pets (HB_IgnorePets)
		- Group Priority (HB_GroupPrio) - only heal members in checked groups
		- Tank Emergency Override (HB_TankEmergencyEnable, HB_TankEmergencyThreshold)
		
	Parameters:
		useHealComm - if true, skip targets with sufficient incoming heals
		              spam mode should pass false to bypass HealComm suppression
		isSpamMode  - if true, disable anti-spam penalty (allow repeated heals on same target)
		              spam/maintenance mode should pass true
-------------------------------------------------------------------]]
function COE_Heal:DetermineHealTarget(useHealComm, isSpamMode)
	
	-- Default useHealComm to true for normal healing
	if useHealComm == nil then useHealComm = true end
	-- Default isSpamMode to false for normal healing
	if isSpamMode == nil then isSpamMode = false end
	
	local toBeHealed = { target = nil, ratio = 1.0, current = 0, max = 0, tankEmergency = false };
	
	-- Get HealAI settings
	local tankName = "";
	local offTankName = "";
	local useToT = false;
	local prioritizeTank = false;
	local ignorePets = true;
	local emergencyThreshold = 0.55;
	local groupPrio = nil;
	
	-- Tank emergency override settings
	local tankEmergencyEnable = false;
	local tankEmergencyThreshold = 0.30;
	local tankEmergencyIgnoreHealComm = false;
	
	-- Check if HealComm should actually be used
	local applyHealComm = useHealComm and COE_Saved and COE_Saved.HB_UseHealComm == 1;
	
	if COE_Saved then
		tankName = COE_Saved.HB_TankName or "";
		offTankName = COE_Saved.HB_OffTankName or "";
		useToT = (COE_Saved.HB_UseToT == 1);
		prioritizeTank = (COE_Saved.HB_PrioritizeTank == 1);
		ignorePets = (COE_Saved.HB_IgnorePets == 1);
		groupPrio = COE_Saved.HB_GroupPrio;
		if COE_Saved.HB_Emergency then
			emergencyThreshold = COE_Saved.HB_Emergency / 100;
		end
		
		-- Tank emergency override
		tankEmergencyEnable = (COE_Saved.HB_TankEmergencyEnable == 1);
		if COE_Saved.HB_TankEmergencyThreshold then
			tankEmergencyThreshold = COE_Saved.HB_TankEmergencyThreshold / 100;
		end
		tankEmergencyIgnoreHealComm = (COE_Saved.HB_TankEmergencyIgnoreHealComm == 1);
	end
	
	-- Helper function to check if unit is a pet/guardian/totem
	-- Returns true if unit is NOT a real player character
	-- Used for filtering when "ignore pets" is enabled
	local function IsPet(unit)
		if not UnitExists(unit) then return false end
		
		-- Players are never pets
		if UnitIsPlayer(unit) then return false end
		
		-- Units accessed via pet unit IDs (pet, partypetN, raidpetN) are always pets
		-- This is the most reliable check in Vanilla
		if string.find(unit, "pet") then
			return true;
		end
		
		-- Check if this is a player's pet (has an owner who is a player)
		-- In Vanilla, UnitCreatureFamily returns family for hunter pets
		local creatureFamily = UnitCreatureFamily(unit);
		if creatureFamily then
			-- This is a hunter pet or similar
			return true;
		end
		
		-- Check creature type for warlock pets and other summons
		local ctype = UnitCreatureType(unit);
		if ctype == "Demon" then
			return true;  -- Warlock pet
		end
		if ctype == "Beast" then
			-- Could be a hunter pet
			return true;
		end
		if ctype == "Totem" then
			return true;  -- Shaman totem (shouldn't be heal targets anyway)
		end
		if ctype == "Elemental" then
			-- Could be a mage water elemental or shaman elemental
			return true;
		end
		
		-- In Vanilla, pets typically don't have a player class
		local _, class = UnitClass(unit);
		if not class or class == "" then
			return true;  -- No class = likely a pet/NPC
		end
		
		return false;
	end
	
	-- Helper to check if a pet belongs to a group member (for safety filtering)
	local function IsGroupMemberPet(unit)
		if not UnitExists(unit) then return false end
		
		-- Player's own pet
		if UnitIsUnit(unit, "pet") then return true end
		
		-- Check party pets
		for i = 1, GetNumPartyMembers() do
			if UnitIsUnit(unit, "partypet" .. i) then return true end
		end
		
		-- Check raid pets
		for i = 1, GetNumRaidMembers() do
			if UnitIsUnit(unit, "raidpet" .. i) then return true end
		end
		
		return false;
	end
	
	-- Helper function to check if unit matches tank name
	local function IsTank(unit)
		if not UnitExists(unit) then return false end
		local name = UnitName(unit);
		if not name then return false end
		name = string.lower(name);
		if tankName ~= "" and name == string.lower(tankName) then return true end
		if offTankName ~= "" and name == string.lower(offTankName) then return true end
		return false;
	end
	
	-- Helper to get raid subgroup for a unit
	local function GetUnitGroup(unit)
		if not UnitExists(unit) then return 0 end
		local name = UnitName(unit);
		if not name then return 0 end
		
		for i = 1, GetNumRaidMembers() do
			local raidName, _, subgroup = GetRaidRosterInfo(i);
			if raidName == name then
				return subgroup;
			end
		end
		return 0;  -- Not in raid or not found
	end
	
	-- Helper to check if unit's group is enabled in group priority
	local function IsGroupEnabled(unit)
		-- If no group priority set, or not in raid, allow all
		if not groupPrio then return true end
		if GetNumRaidMembers() == 0 then return true end
		
		-- Player and tanks always allowed
		if UnitIsUnit(unit, "player") then return true end
		if IsTank(unit) then return true end
		
		local group = GetUnitGroup(unit);
		if group == 0 then return true end  -- Not in raid, allow
		
		return (groupPrio[group] == 1);
	end
	
	-- Helper to get Target-of-Target as tank if no tank names set
	local function GetToTTank()
		if not useToT then return nil end
		if tankName ~= "" or offTankName ~= "" then return nil end
		if UnitExists("targettarget") and UnitIsFriend("player", "targettarget") then
			return "targettarget";
		end
		return nil;
	end
	
	-- Store candidates: { unit, ratio, current, max, isTank }
	local candidates = {};
	
	-- Helper to add a candidate
	local function AddCandidate(unit)
		if not UnitExists(unit) then return end
		if UnitIsDeadOrGhost(unit) then return end
		
		-- Check connection (only for players)
		if UnitIsPlayer(unit) and not UnitIsConnected(unit) then return end
		
		-- Check pet filter
		if ignorePets and IsPet(unit) then return end
		
		-- Check group priority (for raid members)
		if not IsGroupEnabled(unit) then return end
		
		local curHealth = UnitHealth(unit);
		local maxHealth = UnitHealthMax(unit);
		if curHealth == 0 or maxHealth == 0 then return end
		
		local curRatio = curHealth / maxHealth;
		local isTank = IsTank(unit);
		
		-- Check if this is the ToT tank
		local totTank = GetToTTank();
		if totTank and UnitIsUnit(unit, totTank) then
			isTank = true;
		end
		
		-- Check if this tank is in emergency (for override feature)
		local inTankEmergency = false;
		if isTank and tankEmergencyEnable and curRatio <= tankEmergencyThreshold then
			inTankEmergency = true;
			COE:DebugMessage("TANK EMERGENCY OVERRIDE: " .. (UnitName(unit) or unit) .. " at " .. math.floor(curRatio * 100) .. "%");
		end
		
		-- HealComm logic with 10% safety buffer
		-- RULES:
		-- 1. Tank emergency with ignore HealComm: bypass HealComm entirely
		-- 2. Tanks: NEVER skip due to HealComm (they stay valid candidates)
		-- 3. Non-tanks: skip if effectiveDeficit <= 10% max HP (safety buffer)
		local effectiveDeficit = maxHealth - curHealth;
		local clampedDeficitForRank = effectiveDeficit;  -- For rank selection
		local shouldApplyHealComm = applyHealComm;
		
		if inTankEmergency and tankEmergencyIgnoreHealComm then
			shouldApplyHealComm = false;  -- Bypass HealComm completely for emergency tank
			COE:DebugMessage("Tank emergency: Bypassing HealComm for " .. (UnitName(unit) or unit));
		end
		
		if shouldApplyHealComm then
			-- Check if we should SKIP this target (non-tanks only, with 10% buffer)
			if COE_Heal:ShouldSkipDueToHealComm(unit, isTank) then
				return;  -- Skip this non-tank, they have enough incoming heals
			end
			
			-- Get clamped deficit for rank selection (in RANK_ADJUST mode)
			clampedDeficitForRank = COE_Heal:GetClampedDeficitForRank(unit, isTank);
			effectiveDeficit = COE_Heal:GetEffectiveDeficit(unit);
		end
		
		-- ANTI-SPAM CHECK: If we just healed this target and they're now above top-up threshold,
		-- give them a temporary penalty so we pick someone else who needs it more
		-- NOTE: This is BYPASSED in spam mode - spam mode intentionally allows repeated heals
		local antiSpamPenalty = false;
		if not isSpamMode and COE_Heal.LastHealTarget and COE_Heal.LastHealTime then
			local timeSinceLastHeal = GetTime() - COE_Heal.LastHealTime;
			if timeSinceLastHeal < COE_Heal.ANTISPAM_WINDOW then
				-- Check if this is the same unit we just healed
				if UnitIsUnit(unit, COE_Heal.LastHealTarget) then
					-- Get top-up threshold
					local topUpThreshold = 0.85;
					if COE_Saved and COE_Saved.HB_TopUp then
						topUpThreshold = COE_Saved.HB_TopUp / 100;
					end
					-- If they're now above top-up threshold, mark them for penalty
					if curRatio >= topUpThreshold then
						antiSpamPenalty = true;
						COE:DebugMessage("Anti-spam: " .. (UnitName(unit) or unit) .. 
							" was just healed and is now at " .. math.floor(curRatio * 100) .. 
							"% - deprioritizing");
					end
				end
			end
		end
		
		-- UNREACHABLE PENALTY: If this unit recently failed CanReachForCast, penalize them
		local unreachablePenalty = COE_Heal:IsRecentlyUnreachable(unit);
		if unreachablePenalty then
			COE:DebugMessage("Unreachable penalty: " .. (UnitName(unit) or unit) .. " recently failed range check - deprioritizing");
		end
		
		-- SuperWoW: Check range and LoS (hint layer, not authoritative)
		-- Returns: true = reachable, false = unreachable, nil = unknown
		local reachability = COE_Heal:IsUnitReachable(unit);
		
		-- If DEFINITELY out of range/LoS per SuperWoW, skip entirely
		if reachability == false then
			COE:DebugMessage("Skipping " .. (UnitName(unit) or unit) .. " - out of range or LoS (SuperWoW)");
			return;  -- Don't add to candidates
		end
		
		-- If reachable OR unknown, add as valid candidate
		-- (unknown means SuperWoW not available or returned garbage - assume reachable)
		local candidateData = {
			unit = unit,
			ratio = curRatio,
			current = curHealth,
			max = maxHealth,
			isTank = isTank,
			inTankEmergency = inTankEmergency,
			effectiveDeficit = effectiveDeficit,
			clampedDeficitForRank = clampedDeficitForRank,  -- For RANK_ADJUST mode
			antiSpamPenalty = antiSpamPenalty,
			unreachablePenalty = unreachablePenalty
		};
		
		table.insert(candidates, candidateData);
	end
	
	-- Always check the player first (self is ALWAYS reachable)
	AddCandidate("player");
	
	-- Check player's own pet (if any)
	if not ignorePets then
		AddCandidate("pet");
	end
	
	-- Check party members and their pets
	local i;
	for i = 1, GetNumPartyMembers() do
		AddCandidate("party" .. i);
		-- Check party member's pet (if any and pets not ignored)
		if not ignorePets then
			AddCandidate("partypet" .. i);
		end
	end
	
	-- Check raid members and their pets
	for i = 1, GetNumRaidMembers() do
		AddCandidate("raid" .. i);
		-- Check raid member's pet (if any and pets not ignored)
		if not ignorePets then
			AddCandidate("raidpet" .. i);
		end
	end
	
	-- Check if tank name was set but no tank found (warning)
	local tankFound = false;
	for _, c in ipairs(candidates) do
		if c.isTank then tankFound = true; break; end
	end
	if (tankName ~= "" or offTankName ~= "") and not tankFound and (GetNumPartyMembers() > 0 or GetNumRaidMembers() > 0) then
		-- Only warn once per session
		if not COE_Heal.TankWarningShown then
			COE:Message("Warning: Tank '" .. (tankName ~= "" and tankName or offTankName) .. "' not found in group!");
			COE_Heal.TankWarningShown = true;
		end
	else
		COE_Heal.TankWarningShown = false;  -- Reset when tank is found
	end
	
	-- NOTE: Player is always added as a candidate (self is always reachable)
	-- If no other candidates exist, player will be selected by normal priority logic
	
	-- Now select the best target
	-- Priority logic:
	-- 0. TANK EMERGENCY OVERRIDE: If tank is below tankEmergencyThreshold, absolute top priority
	-- 1. If tank is in EMERGENCY (below normal emergency threshold), heal tank first
	-- 2. If prioritizeTank is on, prefer tank UNLESS a non-tank is significantly more injured
	-- 3. Otherwise, heal lowest HP (considering penalties)
	
	-- Tuning constant: How much lower must a non-tank be to override tank priority
	local TANK_PRIORITY_HP_MARGIN = 0.20;  -- 20% HP difference required
	
	-- SCORING FUNCTION: Lower score = higher priority
	-- Score components:
	--   Base: HP ratio (0.0 to 1.0)
	--   Tank emergency override: -2.0 (absolute top priority)
	--   Tank emergency (below threshold): -1.0
	--   Tank priority bonus: -0.1 (small bias toward tanks)
	--   Anti-spam penalty: +0.7 (strongly deprioritize recently topped-up targets)
	--   Unreachable penalty: +1.0 (large penalty, but still in list)
	--
	-- Example: Player A is at 95% (just healed) with anti-spam: score = 0.95 + 0.7 = 1.65
	--          Player B is at 60%: score = 0.60
	--          Player B will be chosen (lower score wins)
	local function CalculateScore(c)
		local score = c.ratio;
		
		-- Tank emergency override = absolute priority
		if c.inTankEmergency then
			score = score - 2.0;
		-- Tank below emergency threshold
		elseif c.isTank and c.ratio < emergencyThreshold then
			score = score - 1.0;
		-- Tank priority bias (only if no non-tank is critically lower)
		elseif c.isTank and prioritizeTank and c.ratio < 1.0 then
			score = score - 0.1;
		end
		
		-- Penalties
		if c.antiSpamPenalty then
			score = score + 0.7;  -- Strong penalty to avoid double-healing topped players
		end
		if c.unreachablePenalty then
			score = score + 1.0;
		end
		
		return score;
	end
	
	-- Calculate scores for all candidates
	for _, c in ipairs(candidates) do
		c.score = CalculateScore(c);
	end
	
	-- Sort candidates by score (lowest = best)
	table.sort(candidates, function(a, b)
		return a.score < b.score;
	end);
	
	-- Check for tank priority override by critically injured non-tank
	-- If best candidate is a tank due to priority, but a non-tank is critically lower, swap
	if table.getn(candidates) >= 2 then
		local best = candidates[1];
		if best.isTank and prioritizeTank and not best.inTankEmergency then
			-- Find lowest non-tank
			for i = 2, table.getn(candidates) do
				local c = candidates[i];
				if not c.isTank then
					-- Check if non-tank should override
					if c.ratio < emergencyThreshold then
						-- Non-tank is in emergency, move to front
						table.remove(candidates, i);
						table.insert(candidates, 1, c);
						COE:DebugMessage("Non-tank " .. c.unit .. " is in EMERGENCY - overrides tank priority");
						break;
					elseif (best.ratio - c.ratio) >= TANK_PRIORITY_HP_MARGIN then
						-- Non-tank is significantly lower
						table.remove(candidates, i);
						table.insert(candidates, 1, c);
						COE:DebugMessage("Non-tank " .. c.unit .. " is " .. 
							math.floor((best.ratio - c.ratio) * 100) .. "% lower - overrides tank priority");
						break;
					end
					break;  -- Only check first non-tank
				end
			end
		end
	end
	
	-- Return the full sorted candidate list
	-- The caller will iterate through and pick the first reachable one
	toBeHealed.candidates = candidates;
	
	-- Also set the "best" target for backwards compatibility (first in list)
	local selected = candidates[1];
	
	-- Fallback to player if nothing found
	if not selected then
		local curHealth = UnitHealth("player");
		local maxHealth = UnitHealthMax("player");
		toBeHealed.target = "player";
		toBeHealed.ratio = curHealth / maxHealth;
		toBeHealed.current = curHealth;
		toBeHealed.max = maxHealth;
		toBeHealed.tankEmergency = false;
	else
		toBeHealed.target = selected.unit;
		toBeHealed.ratio = selected.ratio;
		toBeHealed.current = selected.current;
		toBeHealed.max = selected.max;
		toBeHealed.tankEmergency = selected.inTankEmergency or false;
	end
	
	-- Check friendly target override (original behavior)
	-- NOTE: Do NOT override if we have a tank in emergency!
	if not toBeHealed.tankEmergency and UnitExists("target") and UnitIsFriend("player", "target") then
		local curHealth = UnitHealth("target");
		local maxHealth = UnitHealthMax("target");
		if curHealth > 0 and maxHealth > 0 then
			local curRatio = curHealth / maxHealth;
			
			if curRatio < toBeHealed.ratio then
				if UnitInParty("target") or UnitInRaid("target") then
					toBeHealed.target = "target";
					toBeHealed.ratio = curRatio;
					toBeHealed.current = curHealth;
					toBeHealed.max = maxHealth;
				elseif toBeHealed.ratio > COE_Heal.Thresholds.OverrideTarget then
					toBeHealed.target = "target";
					toBeHealed.ratio = curRatio;
					toBeHealed.current = curHealth;
					toBeHealed.max = maxHealth;
				end
			end
		end
	end

	-- Round ratio to 2 digits
	toBeHealed.ratio = math.floor(toBeHealed.ratio * 100) / 100;
	
	return toBeHealed;

end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:DetermineBestSpell
	
	PURPOSE: Determines the spell to be used to heal the given
		health deficit. Uses smart rank selection with QuickHeal-inspired
		heal prediction:
		
		1. Predicts actual heal amount (base + +healing + coefficients)
		2. Accounts for Healing Way stacks on target
		3. Uses Tidal Focus talent for mana cost calculations
		4. Finds the lowest rank that can fully cover the deficit
		5. If no rank covers it, use highest rank we can afford
		
	If spelltable is passed, uses ONLY that table.
	If spelltable is nil or COE.HealData.Sorted, uses Wave preferentially.
	
	Parameters:
	- spelltable: COE.HealData.Wave, COE.HealData.Lesser, or COE.HealData.Sorted
	- healamount: raw health deficit to heal
	- targetUnit: (optional) unit ID for Healing Way detection
	
	Respects Max Downrank setting:
	- 0 = only use max rank (no downranking)
	- 3 = can use up to 3 ranks below max (e.g., ranks 7-10 if max is 10)
-------------------------------------------------------------------]]
function COE_Heal:DetermineBestSpell( spelltable, healamount, targetUnit )

	-- Determine which table(s) to use
	local useWave = true;
	local useLesser = true;
	
	-- If a specific table is passed (Lesser or Wave), use only that
	if spelltable == COE.HealData.Lesser then
		useWave = false;
		useLesser = true;
	elseif spelltable == COE.HealData.Wave then
		useWave = true;
		useLesser = false;
	end
	-- If Sorted or nil, use both (Wave preferred)
	
	local waveTable = COE.HealData.Wave;
	local lesserTable = COE.HealData.Lesser;
	
	-- Check we have spells
	local hasWave = waveTable and table.getn(waveTable) > 0;
	local hasLesser = lesserTable and table.getn(lesserTable) > 0;
	
	if not hasWave and not hasLesser then
		return nil;
	end
	
	-- Get Tidal Focus modifier for mana cost calculations
	local tfMod = COE_Heal:GetTidalFocusMod();
	
	-- Get +healing bonus for prediction
	local healingBonus = COE_Heal:GetHealingBonus();
	if healingBonus > 0 then
		COE:DebugMessage("Using +healing bonus: " .. healingBonus);
	end
	
	local bestSpell = nil;
	
	-- Helper function to find best spell from a table with prediction
	-- Smart healing: find lowest rank that covers deficit using predicted heal amounts
	local function FindBestFromTable(tbl, spellType)
		if not tbl or table.getn(tbl) == 0 then return nil end
		
		local found = nil;
		
		-- First pass: find lowest rank that covers deficit
		for i = 1, table.getn(tbl) do
			local spell = tbl[i];
			
			-- Use predicted heal amount instead of base AvgAmount
			local predictedHeal = COE_Heal:PredictHealAmount(spellType, spell.Rank, targetUnit);
			
			-- Check mana with Tidal Focus
			local effectiveCost = spell.Mana * tfMod;
			
			if predictedHeal >= healamount then
				if UnitMana("player") >= effectiveCost then
					found = spell;
					found.PredictedHeal = predictedHeal;  -- Store for debug
					break;
				end
			end
		end
		
		-- Second pass: if nothing covers it, use highest rank we can afford
		if not found then
			for i = table.getn(tbl), 1, -1 do
				local spell = tbl[i];
				local effectiveCost = spell.Mana * tfMod;
				if UnitMana("player") >= effectiveCost then
					found = spell;
					found.PredictedHeal = COE_Heal:PredictHealAmount(spellType, spell.Rank, targetUnit);
					break;
				end
			end
		end
		
		return found;
	end
	
	-- Use the appropriate table(s)
	if useLesser and hasLesser and not useWave then
		-- ONLY Lesser (for emergency/battle heal)
		bestSpell = FindBestFromTable(lesserTable, "Lesser");
	elseif useWave and hasWave and not useLesser then
		-- ONLY Wave
		bestSpell = FindBestFromTable(waveTable, "Wave");
	else
		-- Both available, prefer Wave (more efficient)
		if useWave and hasWave then
			bestSpell = FindBestFromTable(waveTable, "Wave");
		end
		if not bestSpell and useLesser and hasLesser then
			bestSpell = FindBestFromTable(lesserTable, "Lesser");
		end
	end
	
	if bestSpell then
		-- Enhanced debug: show prediction info
		local predictedHeal = bestSpell.PredictedHeal or bestSpell.AvgAmount;
		COE:DebugMessage("Rank Selection: deficit=" .. math.floor(healamount) .. 
			", chose " .. bestSpell.Type .. " R" .. bestSpell.Rank .. 
			" (base=" .. math.floor(bestSpell.AvgAmount) .. 
			", predicted=" .. math.floor(predictedHeal) .. 
			", mana=" .. bestSpell.Mana .. ")");
		return bestSpell.SpellID, bestSpell.Type, bestSpell.Rank;
	end
	
	-- Out of mana
	COE:Message(COESTR_HEALOOM);
	return nil;

end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:DetermineBattleSpell
	
	PURPOSE: Determines the the spell to be used to heal possibly
		healmount of health but uses the least casting time
		possible. That is, we use Lesser Healing Wave whenever
		possible.
		
		If Nature's Swiftness is active, prefer Healing Wave
		to maximize the instant cast heal.
		
	Parameters:
	- healamount: raw health deficit to heal
	- targetUnit: (optional) unit ID for Healing Way detection
-------------------------------------------------------------------]]
function COE_Heal:DetermineBattleSpell( healamount, targetUnit )

	-- do we possess the lesser wave?
	-- -------------------------------
	if( table.getn( COE.HealData.Lesser ) == 0 ) then
		return COE_Heal:DetermineBestSpell( COE.HealData.Sorted, healamount, targetUnit );
	end

	-- Check for Nature's Swiftness
	-- If NS is active, prefer HW for maximum instant heal
	if COE_Heal:HasNaturesSwiftness() then
		COE:DebugMessage("Nature's Swiftness active: preferring Healing Wave for max heal");
		return COE_Heal:DetermineBestSpell( COE.HealData.Wave, healamount, targetUnit );
	end
	
	-- Use Lesser Healing Wave (fast cast)
	return COE_Heal:DetermineBestSpell( COE.HealData.Lesser, healamount, targetUnit );

end


--[[ =============================================================================================
		
					H E A L B R A I N   O N E - B U T T O N   S Y S T E M

================================================================================================]]

--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:HealBrain
	
	PURPOSE: Unified one-button healing system.
	
	When Spam Mode is OFF:
		- Uses original BestHeal logic with thresholds
		- Finds lowest HP target below threshold
		- Uses most efficient spell for the health deficit
		
	When Spam Mode is ON:
		- Ignores thresholds completely
		- Uses your configured spell/rank
		- Casts on lowest HP target (or friendly target if selected)
		- Silent when casting (no threshold messages)
		- Controller-optimized for spamming
-------------------------------------------------------------------]]
function COE_Heal:HealBrain()

	-- Check if HealAI is enabled (default to enabled if not set)
	if COE_Saved and COE_Saved.HB_Enable == 0 then
		COE:Message("HealAI is disabled. Enable it in /coe config -> Healing tab");
		return;
	end
	
	-- STEP 1: Check for dispellable debuffs first
	-- Only if at least one dispel type is enabled
	local dispelPoison = (COE_Saved and COE_Saved.HB_DispelPoison == 1);
	local dispelDisease = (COE_Saved and COE_Saved.HB_DispelDisease == 1);
	
	if dispelPoison or dispelDisease then
		-- Check dispel throttle first
		if COE_Heal:CanDispelNow() then
			-- Make sure we have dispel spells scanned
			if not COE_Heal.DispelSpells.CurePoison and not COE_Heal.DispelSpells.CureDisease then
				COE_Heal:ScanDispelSpells();
			end
			
			-- Try to find and dispel a target
			local dispelResult = COE_Heal:FindDispelTarget();
			if dispelResult then
				-- Get the right spell
				local spellID = nil;
				local spellName = "";
				
				if dispelResult.debuffType == "Poison" and COE_Heal.DispelSpells.CurePoison then
					spellID = COE_Heal.DispelSpells.CurePoison;
					spellName = "Cure Poison";
				elseif dispelResult.debuffType == "Disease" and COE_Heal.DispelSpells.CureDisease then
					spellID = COE_Heal.DispelSpells.CureDisease;
					spellName = "Cure Disease";
				end
				
				if spellID then
					-- Check cooldown
					local start, duration = GetSpellCooldown(spellID, BOOKTYPE_SPELL);
					if start == 0 or duration == 0 then
						-- IMPORTANT: Save target before any casting
						COE_Heal:SaveCurrentTarget();
						
						-- Cast dispel and record time
						COE:DebugMessage("Dispelling " .. dispelResult.debuffType .. " from " .. 
							(UnitName(dispelResult.target) or dispelResult.target));
						CastSpell(spellID, BOOKTYPE_SPELL);
						SpellTargetUnit(dispelResult.target);
						COE_Heal:RecordDispel();  -- Record time for throttle
						
						-- Restore original target
						COE_Heal:RestoreSavedTarget();
						return;  -- Dispel takes priority, exit here
					end
				end
			end
		end
		-- If throttled, fall through to healing
	end
	
	-- STEP 2: Check if Chain Heal should be used (multiple injured targets)
	-- BUT: Skip Chain Heal if tank emergency override is active
	local skipChainForTankEmergency = false;
	if COE_Saved and COE_Saved.HB_TankEmergencyEnable == 1 then
		-- Quick check if any tank is in emergency
		local tankEmergThreshold = (COE_Saved.HB_TankEmergencyThreshold or 30) / 100;
		local tankName = string.lower(COE_Saved.HB_TankName or "");
		local offTankName = string.lower(COE_Saved.HB_OffTankName or "");
		
		-- Check function
		local function CheckTankEmergency(unit)
			if not UnitExists(unit) then return false end
			if UnitIsDeadOrGhost(unit) then return false end
			local name = string.lower(UnitName(unit) or "");
			if (tankName ~= "" and name == tankName) or (offTankName ~= "" and name == offTankName) then
				local maxHP = UnitHealthMax(unit);
				if maxHP == 0 then return false end
				local ratio = UnitHealth(unit) / maxHP;
				if ratio <= tankEmergThreshold then
					COE:DebugMessage("Tank " .. UnitName(unit) .. " is in emergency (" .. 
						math.floor(ratio * 100) .. "%) - skipping Chain Heal");
					return true;
				end
			end
			return false;
		end
		
		-- Check player, party, raid for tank in emergency
		if CheckTankEmergency("player") then
			skipChainForTankEmergency = true;
		end
		if not skipChainForTankEmergency then
			for i = 1, GetNumPartyMembers() do
				if CheckTankEmergency("party" .. i) then
					skipChainForTankEmergency = true;
					break;
				end
			end
		end
		if not skipChainForTankEmergency then
			for i = 1, GetNumRaidMembers() do
				if CheckTankEmergency("raid" .. i) then
					skipChainForTankEmergency = true;
					break;
				end
			end
		end
	end
	
	if not skipChainForTankEmergency then
		local useChain, chainTarget = COE_Heal:ShouldUseChainHeal();
		if useChain and chainTarget then
			if COE_Heal:CastChainHeal(chainTarget) then
				return;  -- Chain Heal cast, exit here
			end
		else
			COE:DebugMessage("Chain Heal not selected (useChain=" .. tostring(useChain) .. ")");
		end
	else
		COE:DebugMessage("Chain Heal skipped: tank emergency active");
	end
	
	-- STEP 3: No dispel or chain heal needed, proceed with single-target healing
	local spamMode = (COE_Saved and COE_Saved.HB_SpamMode == 1);
	
	if spamMode then
		COE_Heal:DoSpamHeal();
	else
		COE_Heal:BestHeal();
	end

end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:DoSpamHeal
	
	PURPOSE: Smart spam heal logic:
		- Uses configured spell/rank for small top-ups
		- Auto-upgrades to stronger heal if deficit > preset heal amount
		- Ignores top-up threshold (heals anyone below 100%)
		- BYPASSES HealComm suppression (spam mode always heals)
		- BYPASSES anti-spam penalty (spam mode allows repeated heals on same target)
		- ALWAYS ignores pets (spam mode is for tank/group maintenance only)
-------------------------------------------------------------------]]
function COE_Heal:DoSpamHeal()
	
	-- Clean up expired unreachable entries
	COE_Heal:CleanupUnreachableCache();
	
	-- Find the target to heal
	-- Pass useHealComm=false to bypass HealComm filtering
	-- Pass isSpamMode=true to bypass anti-spam penalty
	local healResult = COE_Heal:DetermineHealTarget(false, true);
	
	-- Get thresholds
	local topUpThreshold = 0.85;
	local emergencyThreshold = 0.55;
	if COE_Saved then
		if COE_Saved.HB_TopUp then topUpThreshold = COE_Saved.HB_TopUp / 100 end
		if COE_Saved.HB_Emergency then emergencyThreshold = COE_Saved.HB_Emergency / 100 end
	end
	
	-- Get the candidate list
	local candidates = healResult.candidates or {};
	
	-- If no candidates at all, nothing to heal
	if table.getn(candidates) == 0 then
		return;  -- Silent return in spam mode
	end
	
	-- Helper: check if unit is a pet (spam mode ALWAYS ignores pets)
	local function IsPetUnit(unit)
		if not unit then return false end
		-- Pet unit IDs contain "pet" (pet, partypet1, raidpet5, etc.)
		if string.find(unit, "pet") then return true end
		return false
	end
	
	-- Iterate through candidates until we find one that passes CanReachForCast
	-- In spam mode: allow healing healthy targets, but SKIP PETS
	local target = nil;
	
	for i, c in ipairs(candidates) do
		-- SPAM MODE: Always skip pets regardless of "ignore pets" setting
		if IsPetUnit(c.unit) then
			-- Skip silently
		elseif UnitIsUnit(c.unit, "player") then
			-- Self is always reachable
			target = c;
			break;
		else
			local canReach = COE_Heal:CanReachForCast(c.unit);
			if canReach then
				target = c;
				break;
			else
				-- Mark as unreachable for future presses
				COE_Heal:MarkUnreachable(c.unit);
				COE:DebugMessage("SpamHeal: " .. (UnitName(c.unit) or c.unit) .. " failed range check - trying next");
			end
		end
	end
	
	-- If no reachable target found
	if not target then
		COE:DebugMessage("SpamHeal: No reachable candidates");
		return;  -- Silent return in spam mode
	end
	
	-- Calculate health deficit
	local deficit = target.max - target.current;
	
	-- Get configured spell type and rank
	local spellType = (COE_Saved and COE_Saved.HB_SpamSpellType) or "Wave";
	local spellRank = (COE_Saved and COE_Saved.HB_SpamSpellRank) or 0;
	
	-- Get the spell data table
	local spellTable = COE.HealData[spellType];
	if not spellTable or table.getn(spellTable) == 0 then
		COE:Message("No " .. (spellType == "Lesser" and "Lesser Healing Wave" or "Healing Wave") .. " spells found! Try /coe reload");
		return;
	end
	
	-- Determine base rank to use
	local maxRank = table.getn(spellTable);
	local useRank = spellRank;
	
	if useRank == 0 or useRank > maxRank then
		useRank = maxRank;
	end
	
	-- Get the preset spell info
	local presetSpell = spellTable[useRank];
	if not presetSpell then
		COE:Message("Spell rank " .. useRank .. " not found!");
		return;
	end
	
	-- Determine which spell to use based on target HP
	local spell = presetSpell;
	
	if target.ratio >= topUpThreshold then
		-- Target is healthy (above threshold) - use preset spell for topping up / pre-healing
		-- This allows spam healing even at 100%
		spell = presetSpell;
		COE:DebugMessage("SpamMode: Target healthy, using preset R" .. useRank);
	elseif target.ratio < emergencyThreshold then
		-- EMERGENCY: Target is critically low - use fast heal with smart rank
		-- Switch to Lesser Healing Wave for speed
		local lesserTable = COE.HealData.Lesser;
		if lesserTable and table.getn(lesserTable) > 0 then
			-- Find best Lesser HW rank for the deficit
			spell = nil;
			for i = 1, table.getn(lesserTable) do
				local s = lesserTable[i];
				if s.AvgAmount >= deficit and UnitMana("player") >= s.Mana then
					spell = s;
					break;
				end
			end
			-- If nothing covers it, use max Lesser rank
			if not spell then
				for i = table.getn(lesserTable), 1, -1 do
					local s = lesserTable[i];
					if UnitMana("player") >= s.Mana then
						spell = s;
						break;
					end
				end
			end
			if spell then
				COE:DebugMessage("EMERGENCY: Using Lesser HW R" .. spell.Rank);
			else
				spell = presetSpell;  -- Fallback
			end
		else
			-- No Lesser HW, upgrade regular heal
			spell = presetSpell;
			for i = useRank + 1, maxRank do
				local s = spellTable[i];
				if s and s.AvgAmount >= deficit and UnitMana("player") >= s.Mana then
					spell = s;
					break;
				end
			end
		end
	else
		-- Target is below threshold but not emergency - smart upgrade
		if deficit > presetSpell.AvgAmount then
			-- Need a stronger heal
			COE:DebugMessage("Deficit " .. math.floor(deficit) .. " > preset heal " .. math.floor(presetSpell.AvgAmount) .. ", upgrading...");
			
			-- Find lowest rank that covers the deficit
			local upgraded = false;
			for i = useRank + 1, maxRank do
				local higherSpell = spellTable[i];
				if higherSpell and higherSpell.AvgAmount >= deficit then
					if UnitMana("player") >= higherSpell.Mana then
						spell = higherSpell;
						upgraded = true;
						COE:DebugMessage("Upgraded to Rank " .. i);
						break;
					end
				end
			end
			
			-- If nothing covers it, use max rank
			if not upgraded then
				local maxSpell = spellTable[maxRank];
				if maxSpell and UnitMana("player") >= maxSpell.Mana then
					spell = maxSpell;
					COE:DebugMessage("Using max rank " .. maxRank);
				end
			end
		end
	end
	
	-- Check cooldown
	local start, duration = GetSpellCooldown(spell.SpellID, BOOKTYPE_SPELL);
	if start > 0 and duration > 0 then
		return;  -- Silent return, on cooldown
	end
	
	-- Check mana
	if UnitMana("player") < spell.Mana then
		COE:Message(COESTR_HEALOOM);
		return;
	end
	
	-- Build spell name for display
	local spellName = spell.Type == "Lesser" and "Lesser Healing Wave" or "Healing Wave";
	
	COE:DebugMessage("SpamHeal: " .. spellName .. " R" .. spell.Rank .. " on " .. 
		(UnitName(target.unit) or target.unit) .. " (" .. math.floor(target.ratio * 100) .. "%, deficit " .. math.floor(deficit) .. ")");
	
	-- NOTE: Range check already done in the candidate loop above
	-- If we got here, target.unit is confirmed reachable
	
	-- ANTI-SPAM: Record this heal target and time
	COE_Heal.LastHealTarget = target.unit;
	COE_Heal.LastHealTime = GetTime();
	
	-- Cast the spell
	-- In Vanilla 1.12, we need to target the unit BEFORE casting for helpful spells
	-- IMPORTANT: Save and restore original target exactly (never steal player's target)
	COE_Heal:SaveCurrentTarget();
	
	-- Target the heal recipient
	TargetUnit(target.unit);
	
	CastSpell(spell.SpellID, BOOKTYPE_SPELL);
	
	-- Restore player's original target exactly
	COE_Heal:RestoreSavedTarget();

end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:SpamHeal
	
	PURPOSE: Alias for HealBrain() for backwards compatibility
-------------------------------------------------------------------]]
function COE_Heal:SpamHeal()
	COE_Heal:HealBrain();
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:GetSpamSpellInfo
	
	PURPOSE: Returns info about the currently configured spam spell
		for display purposes
-------------------------------------------------------------------]]
function COE_Heal:GetSpamSpellInfo()
	
	local spellType = "Wave";
	local spellRank = 0;
	
	if COE_Saved then
		spellType = COE_Saved.HB_SpamSpellType or "Wave";
		spellRank = COE_Saved.HB_SpamSpellRank or 0;
	end
	
	local spellTable = COE.HealData[spellType];
	local maxRank = 0;
	if spellTable then
		maxRank = table.getn(spellTable);
	end
	
	local useRank = spellRank;
	if useRank == 0 or useRank > maxRank then
		useRank = maxRank;
	end
	
	local spellName = (spellType == "Lesser") and "Lesser Healing Wave" or "Healing Wave";
	
	local spell = nil;
	if spellTable and useRank > 0 then
		spell = spellTable[useRank];
	end
	
	return {
		name = spellName,
		type = spellType,
		rank = useRank,
		maxRank = maxRank,
		mana = spell and spell.Mana or 0,
		avgHeal = spell and spell.AvgAmount or 0,
		spellID = spell and spell.SpellID or 0
	};
end


--[[ =============================================================================================
		
							D I S P E L   L O G I C 

================================================================================================]]

-- Store dispel spell IDs (found on load)
COE_Heal.DispelSpells = {
	CurePoison = nil,
	CureDisease = nil
};

--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:ScanDispelSpells
	
	PURPOSE: Finds Cure Poison and Cure Disease spell IDs
-------------------------------------------------------------------]]
function COE_Heal:ScanDispelSpells()
	
	local i = 1;
	while true do
		local spellName = GetSpellName(i, BOOKTYPE_SPELL);
		if not spellName then break end
		
		if spellName == "Cure Poison" then
			COE_Heal.DispelSpells.CurePoison = i;
			COE:DebugMessage("Found Cure Poison at slot " .. i);
		elseif spellName == "Cure Disease" then
			COE_Heal.DispelSpells.CureDisease = i;
			COE:DebugMessage("Found Cure Disease at slot " .. i);
		end
		
		i = i + 1;
	end
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:HasDebuff
	
	PURPOSE: Checks if unit has a dispellable debuff (poison/disease)
	Returns: "Poison", "Disease", or nil
-------------------------------------------------------------------]]
function COE_Heal:HasDebuff(unit)
	
	if not UnitExists(unit) then return nil end
	
	local dispelPoison = (COE_Saved and COE_Saved.HB_DispelPoison == 1);
	local dispelDisease = (COE_Saved and COE_Saved.HB_DispelDisease == 1);
	
	local i = 1;
	while true do
		local texture, count, debuffType = UnitDebuff(unit, i);
		if not texture then break end
		
		if debuffType == "Poison" and dispelPoison then
			return "Poison";
		elseif debuffType == "Disease" and dispelDisease then
			return "Disease";
		end
		
		i = i + 1;
	end
	
	return nil;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:FindDispelTarget
	
	PURPOSE: Finds the best target to dispel based on settings
	Returns: { target, debuffType } or nil
-------------------------------------------------------------------]]
function COE_Heal:FindDispelTarget()
	
	local tankOnly = (COE_Saved and COE_Saved.HB_DispelTankOnly == 1);
	local selfFirst = (COE_Saved and COE_Saved.HB_DispelSelfFirst == 1);
	local hpGate = 70;
	if COE_Saved and COE_Saved.HB_DispelHPGate then
		hpGate = COE_Saved.HB_DispelHPGate;
	end
	
	local tankName = (COE_Saved and COE_Saved.HB_TankName) or "";
	local offTankName = (COE_Saved and COE_Saved.HB_OffTankName) or "";
	
	-- Helper to check if unit is tank
	local function IsTank(unit)
		if not UnitExists(unit) then return false end
		local name = UnitName(unit);
		if not name then return false end
		name = string.lower(name);
		if tankName ~= "" and name == string.lower(tankName) then return true end
		if offTankName ~= "" and name == string.lower(offTankName) then return true end
		return false;
	end
	
	-- Helper to check unit
	local function CheckUnit(unit)
		if not UnitExists(unit) then return nil end
		if UnitIsDeadOrGhost(unit) then return nil end
		if UnitIsPlayer(unit) and not UnitIsConnected(unit) then return nil end
		
		-- Check HP gate (only dispel if HP is above gate %)
		local maxHP = UnitHealthMax(unit);
		if maxHP == 0 then return nil end
		local ratio = UnitHealth(unit) / maxHP;
		if ratio * 100 < hpGate then return nil end
		
		-- Tank only mode
		if tankOnly and not IsTank(unit) and not UnitIsUnit(unit, "player") then
			return nil;
		end
		
		local debuffType = COE_Heal:HasDebuff(unit);
		if debuffType then
			return { target = unit, debuffType = debuffType };
		end
		return nil;
	end
	
	-- Self first
	if selfFirst then
		local result = CheckUnit("player");
		if result then return result end
	end
	
	-- Tanks
	if tankName ~= "" then
		for i = 1, GetNumRaidMembers() do
			local name = UnitName("raid" .. i);
			if name and string.lower(name) == string.lower(tankName) then
				local result = CheckUnit("raid" .. i);
				if result then return result end
			end
		end
		for i = 1, GetNumPartyMembers() do
			local name = UnitName("party" .. i);
			if name and string.lower(name) == string.lower(tankName) then
				local result = CheckUnit("party" .. i);
				if result then return result end
			end
		end
	end
	
	-- Self (if not selfFirst)
	if not selfFirst then
		local result = CheckUnit("player");
		if result then return result end
	end
	
	-- Party members
	for i = 1, GetNumPartyMembers() do
		local result = CheckUnit("party" .. i);
		if result then return result end
	end
	
	-- Raid members
	for i = 1, GetNumRaidMembers() do
		local result = CheckUnit("raid" .. i);
		if result then return result end
	end
	
	return nil;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:Dispel
	
	PURPOSE: Finds and dispels a debuff from party/raid
-------------------------------------------------------------------]]
function COE_Heal:Dispel()
	
	-- Make sure we have dispel spells
	if not COE_Heal.DispelSpells.CurePoison and not COE_Heal.DispelSpells.CureDisease then
		COE_Heal:ScanDispelSpells();
	end
	
	-- Find target
	local result = COE_Heal:FindDispelTarget();
	
	if not result then
		COE:DebugMessage("No dispel target found");
		return false;
	end
	
	-- Get the right spell
	local spellID = nil;
	local spellName = "";
	
	if result.debuffType == "Poison" then
		spellID = COE_Heal.DispelSpells.CurePoison;
		spellName = "Cure Poison";
	elseif result.debuffType == "Disease" then
		spellID = COE_Heal.DispelSpells.CureDisease;
		spellName = "Cure Disease";
	end
	
	if not spellID then
		COE:Message("No " .. spellName .. " spell found!");
		return false;
	end
	
	-- Check cooldown
	local start, duration = GetSpellCooldown(spellID, BOOKTYPE_SPELL);
	if start > 0 and duration > 0 then
		COE:DebugMessage(spellName .. " on cooldown");
		return false;
	end
	
	-- FINAL RANGE CHECK before casting
	if not UnitIsUnit(result.target, "player") then
		local canReach = COE_Heal:CanReachForCast(result.target);
		if not canReach then
			COE:DebugMessage("Dispel target out of range: " .. (UnitName(result.target) or result.target));
			return false;  -- Do NOT cast
		end
	end
	
	-- Cast - use TargetUnit approach for Vanilla 1.12
	-- IMPORTANT: Save and restore original target exactly (never steal player's target)
	COE_Heal:SaveCurrentTarget();
	
	TargetUnit(result.target);
	
	COE:DebugMessage("Dispelling " .. result.debuffType .. " from " .. (UnitName(result.target) or result.target));
	CastSpell(spellID, BOOKTYPE_SPELL);
	
	-- Restore player's original target exactly
	COE_Heal:RestoreSavedTarget();
	
	return true;
end


--[[ =============================================================================================
		
							C H A I N   H E A L   L O G I C 

	Chain Heal bounces only hit members of the same PARTY (subgroup in raid).
	
	Algorithm:
	1. Scan all raid parties (groups 1-8)
	2. Count injured members below threshold in each party
	3. Select the party with the MOST injured members
	4. Within that party, pick the best anchor target:
	   - If "Prefer tank bounce" is on and tank is in that party, use tank
	   - Otherwise use lowest HP member in that party
	
	This maximizes Chain Heal efficiency by targeting clusters of damage.
================================================================================================]]

-- Store Chain Heal spell info
COE_Heal.ChainHealSpells = {};

--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:ScanChainHeal
	
	PURPOSE: Finds Chain Heal spell IDs and ranks
-------------------------------------------------------------------]]
function COE_Heal:ScanChainHeal()
	
	COE_Heal.ChainHealSpells = {};
	
	local i = 1;
	while true do
		local spellName, spellRank = GetSpellName(i, BOOKTYPE_SPELL);
		if not spellName then break end
		
		if spellName == "Chain Heal" then
			local rank = 1;
			if spellRank then
				local _, _, r = string.find(spellRank, "(%d+)");
				if r then rank = tonumber(r) end
			end
			
			-- Get mana cost from tooltip
			COETooltip:SetOwner(UIParent, "ANCHOR_NONE");
			COETooltip:SetSpell(i, BOOKTYPE_SPELL);
			local mana = 0;
			for line = 1, COETooltip:NumLines() do
				local text = getglobal("COETooltipTextLeft" .. line):GetText();
				if text then
					local _, _, m = string.find(text, "(%d+) Mana");
					if m then mana = tonumber(m) end
				end
			end
			
			table.insert(COE_Heal.ChainHealSpells, {
				SpellID = i,
				Rank = rank,
				Mana = mana,
				Type = "Chain"
			});
			
			COE:DebugMessage("Found Chain Heal Rank " .. rank .. " at slot " .. i);
		end
		
		i = i + 1;
	end
	
	-- Sort by rank
	table.sort(COE_Heal.ChainHealSpells, function(a, b)
		return a.Rank < b.Rank;
	end);
end


--[[ ----------------------------------------------------------------
	Chain Heal jump range is approximately 12.5 yards in Vanilla.
	We use a STRICT 11 yards to be conservative - CheckInteractDistance
	index 2 (trade range) is ~11 yards, so this matches our fallback.
-------------------------------------------------------------------]]
COE_Heal.CHAIN_HEAL_JUMP_RANGE = 11;


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:GetUnitDistance
	
	PURPOSE: Returns distance in yards between two units using SuperWoW's
	UnitPosition API. Returns nil if UnitPosition or coordinates unavailable.
	
	UnitPosition returns (x, y) in yards on the current map.
-------------------------------------------------------------------]]
function COE_Heal:GetUnitDistance(unit1, unit2)
	if not UnitExists(unit1) or not UnitExists(unit2) then return nil end
	
	-- Require UnitPosition API (SuperWoW)
	if not UnitPosition or type(UnitPosition) ~= "function" then
		return nil;
	end
	
	local x1, y1 = UnitPosition(unit1);
	local x2, y2 = UnitPosition(unit2);
	
	if not x1 or not x2 then return nil end
	
	local dx = x1 - x2;
	local dy = y1 - y2;
	
	return math.sqrt(dx * dx + dy * dy);
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:AreUnitsNearby
	
	PURPOSE: Checks if two units are close enough for Chain Heal jumps
	using SuperWoW's UnitPosition API.
	
	Returns: true if nearby, false if far, nil if distance unknown
-------------------------------------------------------------------]]
function COE_Heal:AreUnitsNearby(unit1, unit2, maxRange)
	if not UnitExists(unit1) or not UnitExists(unit2) then return false end
	if UnitIsUnit(unit1, unit2) then return true end  -- Same unit
	
	maxRange = maxRange or COE_Heal.CHAIN_HEAL_JUMP_RANGE;
	
	local dist = COE_Heal:GetUnitDistance(unit1, unit2);
	if dist then
		return dist <= maxRange;
	end
	
	-- Can't determine distance without UnitPosition
	return nil;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:CountNearbyInjured
	
	PURPOSE: Counts how many injured units are within chain jump range
	of a given anchor unit using SuperWoW distances.
	
	Parameters:
	- anchorUnit: The initial Chain Heal target
	- injuredUnits: Table of {unit=, ratio=} for injured units in the group
	- jumpRange: Max distance for chain jumps (default 11 yards)
	
	Returns: 
	- nearbyCount: units confirmed within jump range (including anchor)
	- unknownCount: units where distance couldn't be determined
-------------------------------------------------------------------]]
function COE_Heal:CountNearbyInjured(anchorUnit, injuredUnits, jumpRange)
	if not anchorUnit or not injuredUnits then return 0, 0 end
	jumpRange = jumpRange or COE_Heal.CHAIN_HEAL_JUMP_RANGE;
	
	local nearbyCount = 0;
	local unknownCount = 0;
	local farCount = 0;
	
	for _, injured in ipairs(injuredUnits) do
		if UnitIsUnit(injured.unit, anchorUnit) then
			-- Anchor itself always counts
			nearbyCount = nearbyCount + 1;
		else
			-- Get actual distance using SuperWoW
			local dist = COE_Heal:GetUnitDistance(anchorUnit, injured.unit);
			
			if dist then
				-- We have SuperWoW distance
				if dist <= jumpRange then
					nearbyCount = nearbyCount + 1;
					COE:DebugMessage("      " .. (UnitName(injured.unit) or "?") .. " dist=" .. string.format("%.1f", dist) .. "y -> NEAR");
				else
					farCount = farCount + 1;
					COE:DebugMessage("      " .. (UnitName(injured.unit) or "?") .. " dist=" .. string.format("%.1f", dist) .. "y -> FAR");
				end
			else
				-- Can't get distance - should not happen with SuperWoW
				unknownCount = unknownCount + 1;
				COE:DebugMessage("      " .. (UnitName(injured.unit) or "?") .. " dist=UNKNOWN");
			end
		end
	end
	
	return nearbyCount, unknownCount;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:IsGroupClustered
	
	PURPOSE: Checks if injured members in a group are clustered enough
	for effective Chain Heal bounces.
	
	IMPORTANT: Chain Heal jumps from the PRIMARY TARGET, not from the caster.
	We measure distances between injured party members to find if they're
	within ~11 yards of each other for chain jumps.
	
	Anchor selection priority:
	1. If tank preference ON and tank is in valid cluster -> tank (lowest HP among tanks)
	2. Otherwise -> lowest HP unit in valid cluster
	Tie-break: larger cluster size
	
	Parameters:
	- groupData: Group data from AnalyzeRaidGroups
	- minTargets: Minimum number of clustered targets required
	
	Returns: isClustered (bool), bestAnchor (unit), clusteredCount (number)
-------------------------------------------------------------------]]
function COE_Heal:IsGroupClustered(groupData, minTargets)
	if not groupData or groupData.count < minTargets then
		COE:DebugMessage("Chain Heal REJECTED: group has " .. (groupData and groupData.count or 0) .. " injured, need " .. minTargets);
		return false, nil, 0;
	end
	
	local preferTank = (COE_Saved and COE_Saved.HB_ChainPreferTankBounce == 1);
	
	-- Build list of valid candidates (those meeting cluster requirement)
	local validCandidates = {};
	
	for _, member in ipairs(groupData.members) do
		local clusterSize, _ = COE_Heal:CountNearbyInjured(member.unit, groupData.members);
		
		if clusterSize >= minTargets then
			table.insert(validCandidates, {
				unit = member.unit,
				ratio = member.ratio,
				isTank = member.isTank,
				clusterSize = clusterSize,
				name = UnitName(member.unit) or "?"
			});
		end
	end
	
	if table.getn(validCandidates) == 0 then
		COE:DebugMessage("Chain Heal REJECTED: no candidate meets cluster requirement in group");
		return false, nil, 0;
	end
	
	-- Select anchor with priority system
	local bestAnchor = nil;
	
	if preferTank then
		-- Look for tank candidates first
		local tankCandidates = {};
		for _, c in ipairs(validCandidates) do
			if c.isTank then
				table.insert(tankCandidates, c);
			end
		end
		
		if table.getn(tankCandidates) > 0 then
			-- Pick tank with lowest HP (tie-break: largest cluster)
			bestAnchor = tankCandidates[1];
			for _, c in ipairs(tankCandidates) do
				if c.ratio < bestAnchor.ratio then
					bestAnchor = c;
				elseif c.ratio == bestAnchor.ratio and c.clusterSize > bestAnchor.clusterSize then
					bestAnchor = c;
				end
			end
		end
	end
	
	if not bestAnchor then
		-- Pick candidate with lowest HP (tie-break: largest cluster)
		bestAnchor = validCandidates[1];
		for _, c in ipairs(validCandidates) do
			if c.ratio < bestAnchor.ratio then
				bestAnchor = c;
			elseif c.ratio == bestAnchor.ratio and c.clusterSize > bestAnchor.clusterSize then
				bestAnchor = c;
			end
		end
	end
	
	-- Debug summary
	local anchorHpPct = math.floor(bestAnchor.ratio * 100);
	COE:DebugMessage("Chain Heal anchor chosen: " .. bestAnchor.name .. ", hp=" .. anchorHpPct .. 
		"%, cluster=" .. bestAnchor.clusterSize .. ", tankPref=" .. tostring(preferTank and bestAnchor.isTank));
	
	COE:DebugMessage("Chain Heal APPROVED: " .. bestAnchor.clusterSize .. " clustered within 11y of " .. bestAnchor.name);
	return true, bestAnchor.unit, bestAnchor.clusterSize;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:AnalyzeRaidGroups
	
	PURPOSE: Analyzes all raid groups to find which has most injured
	
	Returns: Table of groups with their injured counts and members
	{
		[groupNum] = {
			count = number of injured,
			members = { {unit, ratio, isTank}, ... },
			lowestUnit = unit with lowest HP,
			lowestRatio = lowest HP ratio,
			hasTank = true if tank is in this group
		}
	}
-------------------------------------------------------------------]]
function COE_Heal:AnalyzeRaidGroups(threshold)
	
	local groups = {};
	local tankName = (COE_Saved and COE_Saved.HB_TankName) or "";
	local offTankName = (COE_Saved and COE_Saved.HB_OffTankName) or "";
	
	-- Initialize groups 1-8
	for g = 1, 8 do
		groups[g] = {
			count = 0,
			members = {},
			lowestUnit = nil,
			lowestRatio = 1.0,
			hasTank = false
		};
	end
	
	-- Helper to check if unit is tank
	local function IsTank(unit)
		if not UnitExists(unit) then return false end
		local name = UnitName(unit);
		if not name then return false end
		name = string.lower(name);
		if tankName ~= "" and name == string.lower(tankName) then return true end
		if offTankName ~= "" and name == string.lower(offTankName) then return true end
		return false;
	end
	
	-- Helper to get raid subgroup
	local function GetSubgroup(unit)
		local name = UnitName(unit);
		if not name then return 0 end
		
		for i = 1, GetNumRaidMembers() do
			local raidName, _, subgroup = GetRaidRosterInfo(i);
			if raidName == name then
				return subgroup;
			end
		end
		return 0;
	end
	
	-- Scan raid members
	for i = 1, GetNumRaidMembers() do
		local unit = "raid" .. i;
		
		if UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
			if not UnitIsPlayer(unit) or UnitIsConnected(unit) then
				local curHP = UnitHealth(unit);
				local maxHP = UnitHealthMax(unit);
				
				if maxHP > 0 then
					local ratio = curHP / maxHP;
					local subgroup = GetSubgroup(unit);
					local isTank = IsTank(unit);
					
					if subgroup > 0 and subgroup <= 8 then
						-- Is this unit injured (below threshold)?
						if ratio < threshold then
							groups[subgroup].count = groups[subgroup].count + 1;
							
							table.insert(groups[subgroup].members, {
								unit = unit,
								ratio = ratio,
								isTank = isTank
							});
							
							-- Track lowest HP in this group
							if ratio < groups[subgroup].lowestRatio then
								groups[subgroup].lowestRatio = ratio;
								groups[subgroup].lowestUnit = unit;
							end
						end
						
						-- Track if tank is in this group (regardless of HP)
						if isTank then
							groups[subgroup].hasTank = true;
						end
					end
				end
			end
		end
	end
	
	return groups;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:FindBestChainHealTarget
	
	PURPOSE: Finds the best Chain Heal target by:
	1. Identifying the group with the most injured members
	2. Verifying they are clustered enough for chain bounces
	3. Selecting the best anchor in that group
	
	Returns: targetUnit, clusteredCount
-------------------------------------------------------------------]]
function COE_Heal:FindBestChainHealTarget(threshold, minTargets)
	
	local preferTank = (COE_Saved and COE_Saved.HB_ChainPreferTankBounce == 1);
	
	-- In a raid, analyze groups
	if GetNumRaidMembers() > 0 then
		local groups = COE_Heal:AnalyzeRaidGroups(threshold);
		
		-- Find groups with enough injured and check clustering
		-- Sort by injured count descending, then check clustering for each
		local sortedGroups = {};
		for g = 1, 8 do
			if groups[g].count >= minTargets then
				table.insert(sortedGroups, {group = g, data = groups[g]});
			end
		end
		
		-- Sort by count descending
		table.sort(sortedGroups, function(a, b)
			return a.data.count > b.data.count;
		end);
		
		-- Check each group for clustering, starting with most injured
		for _, sg in ipairs(sortedGroups) do
			local isClustered, anchor, clusteredCount = COE_Heal:IsGroupClustered(sg.data, minTargets);
			
			if isClustered and clusteredCount >= minTargets then
				COE:DebugMessage("Chain Heal: Group " .. sg.group .. " has " .. clusteredCount .. " clustered (of " .. sg.data.count .. " injured)");
				return anchor, clusteredCount;
			end
		end
		
		-- No group has enough clustered targets
		local bestCount = 0;
		for g = 1, 8 do
			if groups[g].count > bestCount then
				bestCount = groups[g].count;
			end
		end
		COE:DebugMessage("Chain Heal: No group with " .. minTargets .. "+ clustered targets");
		return nil, bestCount;
	end
	
	-- In a party (no raid), check clustering of injured party members
	local count = 0;
	local lowestUnit = nil;
	local lowestRatio = 1.0;
	local tankUnit = nil;
	local injuredMembers = {};  -- For clustering check
	
	local tankName = (COE_Saved and COE_Saved.HB_TankName) or "";
	local offTankName = (COE_Saved and COE_Saved.HB_OffTankName) or "";
	
	local function IsTank(unit)
		if not UnitExists(unit) then return false end
		local name = UnitName(unit);
		if not name then return false end
		name = string.lower(name);
		if tankName ~= "" and name == string.lower(tankName) then return true end
		if offTankName ~= "" and name == string.lower(offTankName) then return true end
		return false;
	end
	
	local function CheckUnit(unit)
		if not UnitExists(unit) then return end
		if UnitIsDeadOrGhost(unit) then return end
		if UnitIsPlayer(unit) and not UnitIsConnected(unit) then return end
		
		local maxHP = UnitHealthMax(unit);
		if maxHP == 0 then return end
		local ratio = UnitHealth(unit) / maxHP;
		local name = UnitName(unit) or unit;
		local hpPct = math.floor(ratio * 100);
		
		-- Debug: show each unit checked
		COE:DebugMessage("  CH scan: " .. name .. " (" .. unit .. ") = " .. hpPct .. "% (threshold=" .. math.floor(threshold*100) .. "%)");
		
		-- Use <= for threshold comparison (at or below threshold = injured)
		if ratio <= threshold then
			count = count + 1;
			local isTank = IsTank(unit);
			table.insert(injuredMembers, {unit = unit, ratio = ratio, isTank = isTank});
			
			COE:DebugMessage("    -> INJURED (below threshold)" .. (isTank and " [TANK]" or ""));
			
			if ratio < lowestRatio then
				lowestRatio = ratio;
				lowestUnit = unit;
			end
			
			if preferTank and isTank then
				tankUnit = unit;
			end
		else
			COE:DebugMessage("    -> healthy (above threshold)");
		end
	end
	
	-- Check player and party
	COE:DebugMessage("Chain Heal: Scanning party members...");
	CheckUnit("player");
	for i = 1, GetNumPartyMembers() do
		CheckUnit("party" .. i);
	end
	
	COE:DebugMessage("Chain Heal: Found " .. count .. " injured (need " .. minTargets .. ")");
	
	if count < minTargets then
		COE:DebugMessage("Chain Heal: Not enough injured - REJECTED");
		return nil, count;
	end
	
	-- SuperWoW is REQUIRED for Chain Heal (gated by ShouldUseChainHeal)
	-- Measure distances between injured units to find best anchor
	-- The anchor is the PRIMARY TARGET - Chain Heal jumps radiate from there
	
	COE:DebugMessage("Chain Heal: Checking clustering (need " .. minTargets .. " within 11y)...");
	
	-- Step 1: Build list of valid candidates (those meeting cluster requirement)
	local validCandidates = {};
	
	for _, member in ipairs(injuredMembers) do
		local clusterSize, unknown = COE_Heal:CountNearbyInjured(member.unit, injuredMembers);
		local name = UnitName(member.unit) or "?";
		local hpPct = math.floor(member.ratio * 100);
		
		COE:DebugMessage("  " .. name .. ": cluster=" .. clusterSize .. ", hp=" .. hpPct .. "%" .. 
			(member.isTank and " [TANK]" or ""));
		
		if clusterSize >= minTargets then
			table.insert(validCandidates, {
				unit = member.unit,
				ratio = member.ratio,
				isTank = member.isTank,
				clusterSize = clusterSize,
				name = name
			});
		end
	end
	
	if table.getn(validCandidates) == 0 then
		COE:DebugMessage("Chain Heal (party) REJECTED: no candidate meets cluster requirement");
		return nil, 0;
	end
	
	COE:DebugMessage("Chain Heal: " .. table.getn(validCandidates) .. " candidates meet cluster requirement");
	
	-- Step 2: Select anchor with priority system
	-- Priority: tank pref (if enabled) -> lowest HP -> largest cluster -> first in list
	local bestAnchor = nil;
	
	if preferTank then
		-- Step A: If tank preference is ON, look for tank candidates first
		local tankCandidates = {};
		for _, c in ipairs(validCandidates) do
			if c.isTank then
				table.insert(tankCandidates, c);
			end
		end
		
		if table.getn(tankCandidates) > 0 then
			-- Pick tank with lowest HP (tie-break: largest cluster)
			bestAnchor = tankCandidates[1];
			for _, c in ipairs(tankCandidates) do
				if c.ratio < bestAnchor.ratio then
					bestAnchor = c;
				elseif c.ratio == bestAnchor.ratio and c.clusterSize > bestAnchor.clusterSize then
					bestAnchor = c;
				end
			end
			COE:DebugMessage("Chain Heal: Tank preference active, selected tank anchor");
		end
	end
	
	if not bestAnchor then
		-- Step B: Pick candidate with lowest HP (tie-break: largest cluster)
		bestAnchor = validCandidates[1];
		for _, c in ipairs(validCandidates) do
			if c.ratio < bestAnchor.ratio then
				bestAnchor = c;
			elseif c.ratio == bestAnchor.ratio and c.clusterSize > bestAnchor.clusterSize then
				bestAnchor = c;
			end
		end
	end
	
	-- Debug summary
	local anchorHpPct = math.floor(bestAnchor.ratio * 100);
	COE:DebugMessage("Chain Heal anchor chosen: " .. bestAnchor.name .. ", hp=" .. anchorHpPct .. 
		"%, cluster=" .. bestAnchor.clusterSize .. ", tankPref=" .. tostring(preferTank and bestAnchor.isTank));
	
	COE:DebugMessage("Chain Heal (party) APPROVED: " .. bestAnchor.clusterSize .. " within 11y of " .. bestAnchor.name);
	return bestAnchor.unit, bestAnchor.clusterSize;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:ShouldUseChainHeal
	
	PURPOSE: Wrapper that determines if Chain Heal should be used
	
	IMPORTANT: Smart Chain Heal targeting requires SuperWoW's UnitPosition.
	Chain Heal jumps from the PRIMARY TARGET outward (~12.5y per jump),
	NOT from the caster. Without UnitPosition, we cannot measure
	distances between party members to verify clustering.
	
	Returns: true/false, targetUnit
-------------------------------------------------------------------]]
function COE_Heal:ShouldUseChainHeal()
	
	-- Check if Chain Heal is enabled
	if not COE_Saved or COE_Saved.HB_ChainHealEnable ~= 1 then
		COE:DebugMessage("Chain Heal: disabled in settings");
		return false, nil;
	end
	
	-- REQUIRE SuperWoW UnitPosition for smart Chain Heal targeting
	local hasPositionAPI = COE_Heal:HasSuperWoWPositionAPI();
	
	if not hasPositionAPI then
		COE:DebugMessage("Chain Heal: DISABLED (UnitPosition not available - need SuperWoW)");
		return false, nil;
	end
	
	-- Make sure we have Chain Heal spells
	if table.getn(COE_Heal.ChainHealSpells) == 0 then
		COE_Heal:ScanChainHeal();
	end
	
	if table.getn(COE_Heal.ChainHealSpells) == 0 then
		COE:DebugMessage("Chain Heal: no Chain Heal spell found in spellbook");
		return false, nil;
	end
	
	-- Get settings
	local minTargets = COE_Saved.HB_ChainHealMinTargets or 3;
	local hpThreshold = (COE_Saved.HB_ChainHealThreshold or 60) / 100;
	
	COE:DebugMessage("Chain Heal: settings threshold=" .. math.floor(hpThreshold*100) .. "%, minTargets=" .. minTargets);
	
	-- Find best target using group-based logic
	local targetUnit, injuredCount = COE_Heal:FindBestChainHealTarget(hpThreshold, minTargets);
	
	if targetUnit and injuredCount >= minTargets then
		COE:DebugMessage("Chain Heal APPROVED: " .. injuredCount .. " within 11y of " .. (UnitName(targetUnit) or "?"));
		return true, targetUnit;
	end
	
	COE:DebugMessage("Chain Heal REJECTED: best cluster=" .. (injuredCount or 0) .. ", need=" .. minTargets);
	return false, nil;
end


--[[ ----------------------------------------------------------------
	METHOD: COE_Heal:CastChainHeal
	
	PURPOSE: Casts Chain Heal on the specified target
-------------------------------------------------------------------]]
function COE_Heal:CastChainHeal(target)
	
	if not target then return false end
	
	-- Get max rank we can afford
	local spell = nil;
	for i = table.getn(COE_Heal.ChainHealSpells), 1, -1 do
		local s = COE_Heal.ChainHealSpells[i];
		if UnitMana("player") >= s.Mana then
			spell = s;
			break;
		end
	end
	
	if not spell then
		COE:Message(COESTR_HEALOOM);
		return false;
	end
	
	-- Check cooldown
	local start, duration = GetSpellCooldown(spell.SpellID, BOOKTYPE_SPELL);
	if start > 0 and duration > 0 then
		return false;
	end
	
	-- FINAL RANGE CHECK before casting
	if not UnitIsUnit(target, "player") then
		local canReach = COE_Heal:CanReachForCast(target);
		if not canReach then
			COE:DebugMessage("Chain Heal target out of range: " .. (UnitName(target) or target));
			return false;  -- Do NOT cast
		end
	end
	
	-- Cast - use TargetUnit approach for Vanilla 1.12
	-- IMPORTANT: Save and restore original target exactly (never steal player's target)
	COE_Heal:SaveCurrentTarget();
	
	TargetUnit(target);
	
	COE:DebugMessage("Chain Heal R" .. spell.Rank .. " on " .. (UnitName(target) or target));
	CastSpell(spell.SpellID, BOOKTYPE_SPELL);
	
	-- Restore player's original target exactly
	COE_Heal:RestoreSavedTarget();
	
	return true;
end
