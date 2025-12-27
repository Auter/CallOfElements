--[[

	CALL OF ELEMENTS
	The All-In-One Shaman Addon
	
	by Wyverex (2006)

	Healing Module Data
]]

if( not COE ) then
	COE = {};
end

--[[ ----------------------------------------------------------------
	COE.HealData contains a list of all heal spells that the 
	player possesses
-------------------------------------------------------------------]]
COE["HealData"] = {};
COE.HealData["Wave"] = {};
COE.HealData["Lesser"] = {};
COE.HealData["Sorted"] = {};

--[[ ----------------------------------------------------------------
	COE.DefClassHealth contains an estimation of average player
	health by class. Stolen directly from PaladinAssistant :)
	Shaman added with a first estimation
-------------------------------------------------------------------]]
COE["DefClassHealth"] = {
	["WARRIOR"]	= { L1=30,	L60=4100 },
	["SHAMAN"]	= { L1=30,	L60=3500 },
	["ROGUE"]	= { L1=30,	L60=3100 },
	["HUNTER"]	= { L1=30,	L60=3100 },
	["DRUID"]	= { L1=30,	L60=3100 },
	["WARLOCK"]	= { L1=30,	L60=2300 },
	["MAGE"]	= { L1=30,	L60=2200 },
	["PRIEST"]	= { L1=30,	L60=2100 }
};

--[[ ----------------------------------------------------------------
	METHOD: COE:CreateHealingSpell
	
	PURPOSE: Creates a new healing spell object with default values
-------------------------------------------------------------------]]
function COE:CreateHealingSpell()
	return { SpellID = 0, Type = "", Rank = 0, Mana = 0, MinAmount = 0, 
		MaxAmount = 0, AvgAmount = 0, Efficiency = 0 };
end

--[[ ----------------------------------------------------------------
	METHOD: COE:ScanHealingSpells
	
	PURPOSE: Scans the player's spellbook for healing spells and 
		calculates efficiency (heal per mana)
-------------------------------------------------------------------]]
function COE:ScanHealingSpells()
	COE.HealData.Wave = {};
	COE.HealData.Lesser = {};
	COE.HealData.Sorted = {};

	local i = 1;
	while true do
		local spellName, spellRank = GetSpellName(i, BOOKTYPE_SPELL);
		if not spellName then break end

		local valid = true;
		local heal = COE:CreateHealingSpell();

		-- Check for Lesser Healing Wave FIRST (more specific)
		-- then Healing Wave (less specific pattern)
		if string.find(string.lower(spellName), "lesser healing wave") then
			heal.Type = "Lesser";
		elseif string.find(string.lower(spellName), "healing wave") then
			heal.Type = "Wave";
		else
			valid = false;
		end

		if valid then
			-- Extract spell ID
			heal.SpellID = i;

			-- Use tooltip to get mana cost and heal amount
			COETotemTT:SetOwner(UIParent, "ANCHOR_NONE");
			COETotemTT:SetSpell(i, BOOKTYPE_SPELL);
			
			local text = COETotemTTTextLeft2 and COETotemTTTextLeft2:GetText();
			if text then
				local _, _, manaCost = string.find(text, "(%d+) Mana");
				if manaCost then
					heal.Mana = tonumber(manaCost);
				else
					valid = false;
				end
			else
				valid = false;
			end
			
			if valid then
				text = COETotemTTTextLeft4 and COETotemTTTextLeft4:GetText();
				if text then
					local _, _, minHeal = string.find(text, "(%d+) to");
					local _, _, maxHeal = string.find(text, "to (%d+)");
					if minHeal and maxHeal then
						heal.MinAmount = tonumber(minHeal);
						heal.MaxAmount = tonumber(maxHeal);
					else
						valid = false;
					end
				else
					valid = false;
				end
			end

			-- Calculate average and efficiency if valid
			if valid then
				heal.AvgAmount = (heal.MinAmount + heal.MaxAmount) / 2;
				heal.Efficiency = heal.AvgAmount / heal.Mana; -- Heal per mana
				heal.Rank = table.getn(COE.HealData[heal.Type]) + 1;

				table.insert(COE.HealData[heal.Type], heal);
				table.insert(COE.HealData.Sorted, heal);

				COE:DebugMessage("Found healing spell: " .. spellName .. " (Rank " .. heal.Rank .. ", Efficiency: " .. string.format("%.2f", heal.Efficiency) .. ")");
			end
		end

		i = i + 1;
	end

	-- Sort by efficiency
	table.sort(COE.HealData.Sorted, function(a, b)
		return a.Efficiency > b.Efficiency;
	end);
end