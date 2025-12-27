--[[

	CALL OF ELEMENTS
	The All-In-One Shaman Addon
	
	by Wyverex (2006)
        by laytya (2018-2022)

]]

if( not COE ) then 
	COE = {};
end 

local has_superwow = SetAutoloot and true or false

COE_VERSION = 2.9

COECOL_TOTEMWARNING = 1;
COECOL_TOTEMDESTROYED = 2;
COECOL_TOTEMCLEANSING = 3;

--[[ ----------------------------------------------------------------
	When DebugMode is set to true, all DebugMessage calls will
	write a debug message into the chat frame
-------------------------------------------------------------------]]
COE["DebugMode"] = false;


--[[ ----------------------------------------------------------------
	These variables control frame updates
	UpdateInterval sets the interval in seconds after which a 
	frame is updated
	ForceUpdate can be used as input into Update handlers to force
	an update regardless of the current timer
-------------------------------------------------------------------]]
COE["UpdateInterval"] = 0.1;
COE["ForceUpdate"] = COE.UpdateInterval * 2; 


--[[ ----------------------------------------------------------------
	The AdvisorInterval controls how often the party/raid is
	scanned for debuffs that are curable by totems
	The AdvisorWarningInterval controls how often the player is
	notified about existing debuffs
-------------------------------------------------------------------]]
COE["AdvisorInterval"] = 1;
COE["AdvisorWarningInterval"] = 7;


--[[ ----------------------------------------------------------------
	METHOD: COE:Init
	
	PURPOSE: Loads submodules and initializes data
-------------------------------------------------------------------]]
function COE:Init()
	
	-- load only for shamans
	-- ----------------------
	local _, EnglishClass = UnitClass( "player" );
	if( EnglishClass ~= "SHAMAN" ) then
		COE:Message(COESTR_NOTASHAMAN);
		COE.Initialized = false;
	else
		COE.Initialized = true;
		COE:Message("Call of Elements v"..COE_VERSION.." mod CFM /coe");
		this:RegisterEvent( "VARIABLES_LOADED" );
		if has_superwow then
			this:RegisterEvent( "UNIT_MODEL_CHANGED" );
		end
	
		-- register shell command
		-- -----------------------
		SlashCmdList["COE"] = COEProcessShellCommand;
    	SLASH_COE1="/coe";
    	SLASH_HB1="/hb";
    	SLASH_HEALBRAIN1="/healbrain";
    	SlashCmdList["HB"] = COEProcessShellCommand;
    	SlashCmdList["HEALBRAIN"] = COEProcessShellCommand;
		
	end

end


--[[ ----------------------------------------------------------------
	METHOD: COE:OnEvent
	
	PURPOSE: Handles frame events
-------------------------------------------------------------------]]
function COE:OnEvent( event )

	if( event == "VARIABLES_LOADED" ) then
		-- fix saved variables if this update has to do so
		-- ------------------------------------------------
		COE:FixSavedVariables();
		
		-- Initialize SuperWoW QoL features
		if COE_QoL and COE_QoL.Initialize then
			COE_QoL:Initialize();
		end
	elseif event == "UNIT_MODEL_CHANGED" then
		if not UnitIsUnit(arg1.."owner","player") then return end

		local _,_,totem_name = string.find(UnitName(arg1), "^(.- Totem)")
		if not totem_name then return end

		for element,totem in COE.ActiveTotems do
			if totem.SpellName == totem_name then
				COE.ActiveTotems[element].guid = arg1
				break
			end
		end
	end
end


--[[ ----------------------------------------------------------------
	METHOD: COE:Message
	
	PURPOSE: Adds a message to the default chat frame
-------------------------------------------------------------------]]
function COE:Message( msg )
	DEFAULT_CHAT_FRAME:AddMessage( "[COE] " .. msg, 0.93, 0.83, 0.45 );
end;


--[[ ----------------------------------------------------------------
	METHOD: COE:DebugMessage
	
	PURPOSE: Adds a debug message to the default chat frame if
		debug mode is enabled
-------------------------------------------------------------------]]
function COE:DebugMessage( msg )
	if( COE.DebugMode ) then
		DEFAULT_CHAT_FRAME:AddMessage( "[COE] " .. msg, 0.5, 0.5, 0.5 );
	end
end;


--[[ ----------------------------------------------------------------
	METHOD: COE:Notification
	
	PURPOSE: Adds a message to the error frame in the upper
		screen center
-------------------------------------------------------------------]]
function COE:Notification( msg, color )

	local col;

	-- choose color
	-- -------------
	if( color == COECOL_TOTEMWARNING ) then
		col = { r = 0, g = 0.6, b = 1 };
	elseif( color == COECOL_TOTEMDESTROYED ) then
		col = { r = 1, g = 0.4, b = 0 };
	elseif( color == COECOL_TOTEMCLEANSING ) then
		col = { r = 0, g = 1, b = 0.4 };
	else
		col = { r = 1, g = 1, b = 1 };
	end

	-- add message
	-- ------------
	UIErrorsFrame:AddMessage( msg, col.r, col.g, col.b, 1.0, UIERRORS_HOLD_TIME );
	
end;


--[[ ----------------------------------------------------------------
	METHOD: COE:ToggleConfigFrame
	
	PURPOSE: Toggles the configuration dialog
-------------------------------------------------------------------]]
function COE:ToggleConfigFrame()
	
	if( COE_ConfigFrame:IsVisible() ) then
		COE_Config:CloseDialog()
	else
		COE_ConfigFrame:Show();
	end

	PlaySound( "igMainMenuOption" );

end


--[[ ----------------------------------------------------------------
	METHOD: COEProcessShellCommand
	
	PURPOSE: Executes the entered shell command
-------------------------------------------------------------------]]
function COEProcessShellCommand( msg )

	local _,_,msg,arg = string.find(msg,"(%S*)%s?(.*)")

	if( msg == "" or msg == "config" ) then
		COE:ToggleConfigFrame();
		
	elseif( msg == "list" ) then
		COE:DisplayShellCommands();
		
	elseif( msg == "nextset" ) then
		COE_Totem:SwitchToNextSet();
		
	elseif( msg == "priorset" ) then
		COE_Totem:SwitchToPriorSet();

	elseif( msg == "throwset" or msg == "forcethrowset" ) then
		COE_Totem:ThrowSet(arg, msg == "forcethrowset");
		
	elseif( msg == "restartset" ) then
		COE_Totem:ResetSetCycle();
		
	elseif( msg == "reset" ) then
		COE_Totem:ResetTimers();
		
	elseif( msg == "reload" ) then
		COE_Totem:Rescan();
		
	elseif( msg == "resetframes" ) then
		COE_Totem:ResetFrames();

	elseif( msg == "advised" ) then
		COE_Totem:ThrowAdvisedTotem();
		
	elseif( msg == "resetordering" ) then
		COE_DisplayedTotems = {};
		COE_Totem:Rescan();
		
	elseif( msg == "bestheal" ) then
		COE_Heal:BestHeal();
		
	elseif( msg == "battleheal" ) then
		COE_Heal:BattleHeal();

	elseif( msg == "healbrain" or msg == "heal" ) then
		COE_Heal:HealBrain();

	elseif( msg == "spamheal" or msg == "spam" ) then
		COE_Heal:SpamHeal();
		
	elseif( msg == "spellinfo" ) then
		-- Show current spam spell configuration
		local info = COE_Heal:GetSpamSpellInfo();
		local modeStr = (COE_Saved and COE_Saved.HB_SpamMode == 1) and "SPAM" or "THRESHOLD";
		COE:Message("Mode: " .. modeStr .. " | Spell: " .. info.name .. " Rank " .. info.rank .. "/" .. info.maxRank);
		if info.mana > 0 then
			COE:Message("  Mana: " .. info.mana .. " | Avg Heal: " .. math.floor(info.avgHeal));
		end

	elseif (msg == "debug") then
		COE.DebugMode = not COE.DebugMode;
		COE:Message("Debug mode: " .. (COE.DebugMode and "ON" or "OFF"));

	elseif (msg == "dispel") then
		COE_Heal:Dispel();

	elseif (msg == "superwow") then
		-- Force re-check SuperWoW detection and show results
		COE:Message("=== SuperWoW Detection ===");
		COE_Heal.SuperWoWChecked = false;  -- Reset to force re-check
		COE_Heal.SuperWoWAvailable = false;
		COE_Heal.HasPositionAPI = false;
		
		-- Show raw type checks
		COE:Message("Raw checks:");
		COE:Message("  SUPERWOW_VERSION = " .. tostring(SUPERWOW_VERSION or "nil"));
		COE:Message("  type(UnitXP) = " .. type(UnitXP));
		COE:Message("  type(UnitPosition) = " .. type(UnitPosition));
		COE:Message("  type(SpellInfo) = " .. type(SpellInfo));
		
		-- Run the detection
		local result = COE_Heal:CheckSuperWoW();
		
		COE:Message("Detection result:");
		COE:Message("  SuperWoWAvailable = " .. tostring(COE_Heal.SuperWoWAvailable));
		COE:Message("  HasPositionAPI = " .. tostring(COE_Heal.HasPositionAPI));
		COE:Message("  Chain Heal smart mode = " .. (COE_Heal.HasPositionAPI and "ENABLED" or "DISABLED"));
		
		-- Show QoL features status
		local hasPos = (UnitPosition and type(UnitPosition) == "function");
		COE:Message("QoL Features:");
		COE:Message("  Totem Range Overview = " .. (hasPos and "AVAILABLE" or "UNAVAILABLE"));
		COE:Message("  Tank Distance Hint = " .. (hasPos and "AVAILABLE" or "UNAVAILABLE"));

	elseif (msg == "dumpsv" or msg == "debugsv") then
		-- Debug command to check SavedVariables state
		COE:Message("=== SavedVariables Debug ===");
		if COE_Saved then
			COE:Message("COE_Saved: TABLE (exists)");
			COE:Message("  HB_Enable=" .. tostring(COE_Saved.HB_Enable));
			COE:Message("  HB_TankName=" .. tostring(COE_Saved.HB_TankName));
			COE:Message("  HB_TopUp=" .. tostring(COE_Saved.HB_TopUp));
			COE:Message("  HB_Emergency=" .. tostring(COE_Saved.HB_Emergency));
			COE:Message("  HB_SpamMode=" .. tostring(COE_Saved.HB_SpamMode));
			COE:Message("  HB_HealCommMode=" .. tostring(COE_Saved.HB_HealCommMode));
			COE:Message("  HB_SpamSpellType=" .. tostring(COE_Saved.HB_SpamSpellType));
			COE:Message("  HB_SpamSpellRank=" .. tostring(COE_Saved.HB_SpamSpellRank));
			-- Count total keys
			local count = 0;
			for k,v in pairs(COE_Saved) do count = count + 1 end
			COE:Message("  Total keys: " .. count);
		else
			COE:Message("COE_Saved: NIL (not restored!)");
		end
		if COE_SavedTotemSets then
			COE:Message("COE_SavedTotemSets: TABLE");
		else
			COE:Message("COE_SavedTotemSets: NIL");
		end
		if COEFramePositions then
			COE:Message("COEFramePositions: TABLE");
		else
			COE:Message("COEFramePositions: NIL");
		end

	elseif (msg == "set") then
		if( arg ) then
			COE_Totem:SwitchToSet( arg );
		end
	end  	

end


--[[ ----------------------------------------------------------------
	METHOD: COE:DisplayShellCommands
	
	PURPOSE: Shows a list of all shell commands
-------------------------------------------------------------------]]
function COE:DisplayShellCommands()

	COE:Message( COESHELL_INTRO );
	COE:Message( COESHELL_CONFIG );
	COE:Message( COESHELL_LIST );
	COE:Message( COESHELL_NEXTSET );
	COE:Message( COESHELL_PRIORSET );
	COE:Message( COESHELL_SET );
	COE:Message( COESHELL_RESTARTSET );
	COE:Message( COESHELL_RESET );
	COE:Message( COESHELL_RESETFRAMES );
	COE:Message( COESHELL_RESETORDERING );
	COE:Message( COESHELL_RELOAD );
	COE:Message( COESHELL_MACRONOTE );
	COE:Message( COESHELL_THROWSET );
	COE:Message( COESHELL_ADVISED );

end


--[[ ----------------------------------------------------------------
	METHOD: COE:FixSavedVariables
	
	PURPOSE: Called on VARIABLES_LOADED to:
		1. Initialize SavedVariables tables with defaults
		2. Fix any version-specific issues
		3. Register with Cosmos if available
-------------------------------------------------------------------]]
function COE:FixSavedVariables()

	-- FIRST: Initialize all SavedVariables tables
	-- This MUST happen here, after WoW has restored saved data
	COE_Config:InitSavedVariables();
	COE_Config:InitTotemSets();
	COE_Totem:InitFramePositions();

	-- is the version stored in the saved variables?
	-- ----------------------------------------------
	if( not COE_Config:GetSaved( COEOPT_VERSION ) ) then
		-- this is version <= v1.6
		-- ------------------------
		COE_Config:SetOption( COEOPT_VERSION, 1.6 );
	end
	
	local version = COE_Config:GetSaved( COEOPT_VERSION );
	
	if( version == 1.6 ) then
		-- fix localized cast order in 1.7
		-- --------------------------------
		COE:Fix_CastOrderLocalization();
		
		COE:Message( COESTR_UDATEDSAVED .. "1.7" );
		COE_Config:SetOption( COEOPT_VERSION, 1.7 );
		version = COE_Config:GetSaved( COEOPT_VERSION );
	end

	if( version == 1.7 ) then
		-- fix cast order again to due to a typo
		-- --------------------------------------
		COE:Fix_CastOrderLocalization();
	
		COE:Message( COESTR_UDATEDSAVED .. "1.8" );
		COE_Config:SetOption( COEOPT_VERSION, 1.8 );
		version = COE_Config:GetSaved( COEOPT_VERSION );
	end
	
	-- fix totem set element strings
	-- ------------------------------
	COE:Fix_CastOrderLocalization2();

	COE_Config:SetOption( COEOPT_VERSION, 2.1 );
    
	-- Cosmos support
	if(EarthFeature_AddButton) then 
		
		EarthFeature_AddButton(
			{ id = BINDING_HEADER_CALLOFELEMENTS;
			name = BINDING_HEADER_CALLOFELEMENTS;
			subtext = "Version: " .. COE_VERSION; 
			tooltip = "";      
			icon = "Interface\\Icons\\INV_Misc_Idol_03";
			callback = COE.ToggleConfigFrame;
			test = nil;
			} )
	elseif (Cosmos_RegisterButton) then 
		Cosmos_RegisterButton(BINDING_HEADER_CALLOFELEMENTS, BINDING_HEADER_CALLOFELEMENTS, COE_VERSION, "Interface\\Icons\\INV_Misc_Idol_03", COE_ToggleConfigFrame);
	end        
end
