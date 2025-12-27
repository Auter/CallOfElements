================================================================================
CALL OF ELEMENTS - HEALAI FORK
Shaman Helper for World of Warcraft 1.12 (Vanilla / Classic-era)
================================================================================

This is a fork of MarcelineVQ's Call of Elements fork, extended with a smart
healing module called HealAI. The addon provides comprehensive Shaman tools
including totem management and intelligent healing automation.

This fork originally started as an accessibility project for handheld and
controller users (one-button healing for limited inputs), but works fully
on standard PC setups as well.

NOTE: This addon is a work in progress. Features may change, and some rough
edges remain. Feedback and bug reports are welcome.

Designed for Vanilla 1.12 clients, with optional support for:
  - HealComm-1.0 (incoming heals awareness to avoid overhealing)
  - SuperWoW (enhanced range, line-of-sight, and position checking)

Additional refactoring and iteration performed with the assistance of Claude.


KEY FEATURES
================================================================================

ORIGINAL CALL OF ELEMENTS FEATURES:
  - Totem bars with per-element customization
  - Totem sets for one-button multi-totem casting
  - Totem timers with expiration notifications
  - Totem advisor for poison/disease/fear detection
  - PVP auto-switching totem sets per enemy class

HEALAI SMART HEALING:
  - One-button smart heal that prioritizes tanks and low-HP targets
  - Configurable thresholds for top-up and emergency healing
  - Tank priority with emergency override for critical situations
  - HealComm integration to avoid massive overheals
  - SuperWoW range/LoS checking to prevent failed casts
  - Anti-spam logic to avoid wasting mana on double-heals

TANK EMERGENCY OVERRIDE:
  - Distinct emergency threshold specifically for tanks
  - Forces fast direct heals when tank is critically low
  - Skips Chain Heal logic to commit fully to tank survival
  - Optional HealComm bypass for emergency situations

SPAM / MAINTENANCE MODE:
  - Optional mode for repeated heals on tank/ToT/self
  - Configurable spell type and rank for mana efficiency
  - Bypasses normal anti-spam logic for intentional focus healing

CHAIN HEAL LOGIC:
  - Group-aware clustering (bounces only within same party/subgroup)
  - Configurable minimum injured targets before triggering
  - Smart anchor selection based on HP and clustering
  - Requires SuperWoW for accurate distance calculations

DISPEL SYSTEM:
  - Handles Poison and Disease with Cure Poison / Cure Disease
  - Optional HP gate (only dispel if target is above threshold)
  - Configurable throttle to prevent dispel spam
  - Tank priority for dispels

SUPERWOW QOL FEATURES:
  - Totem Range Overview panel (shows group members in range per element)
  - Tank Distance Hint (shows distance to configured tank)
  - Both require SuperWoW's UnitPosition API


USAGE
================================================================================

KEYBINDINGS:
  - "HealAI (Smart One-Button)" - Main healing keybind
  - "HealAI Dispel Only" - Dedicated dispel keybind
  - Legacy keybinds (Threshold Heal, Fast Heal) still work

SMART HEAL vs SPAM MODE:
  Smart Heal (default): Intelligently selects the best target based on HP,
  tank priority, and incoming heals. Uses appropriate spell rank.
  
  Spam Mode: Repeatedly heals your configured target (tank/ToT/self) with
  a specific spell and rank. Useful for tank maintenance in predictable fights.

CONFIGURATION:
  Use /coe or the keybind to open the configuration dialog.
  The Healing tab contains all HealAI settings organized into sub-tabs:
    - Core: Enable/disable, tank names, ToT fallback
    - Thresholds: Top-up, emergency, and tank emergency percentages
    - Chain Heal: Enable and configure multi-target healing
    - Dispels: Poison/disease handling and throttle settings
    - Raid: Group filters and SuperWoW distance features
    - Advanced: HealComm options, spam mode, spell selection


ENVIRONMENT / COMPATIBILITY
================================================================================

  - World of Warcraft 1.12 (classic-era / Vanilla) client
  - Optional: HealComm-1.0 for incoming heal awareness
  - Optional: SuperWoW for enhanced range/LoS/position checking

The addon functions fully without HealComm or SuperWoW, but benefits from
both when available. Some features (Chain Heal clustering, distance panels)
require SuperWoW and will be disabled without it.


SLASH COMMANDS
================================================================================

  /coe              - Open configuration dialog
  /coe config       - Open configuration dialog
  /coe reload       - Reload totems and healing spells
  /coe reset        - Reset timers and active set
  /coe debug        - Toggle debug messages
  /coe superwow     - Check SuperWoW detection status

Totem commands:
  /coe throwset     - Throw the active totem set (macro only)
  /coe nextset      - Switch to next totem set
  /coe priorset     - Switch to previous totem set
  /coe set <n>   - Switch to named set (case-sensitive)
  /coe restartset   - Restart the active set
  /coe advised      - Throw the advised totem (macro only)


INSTALLATION
================================================================================

Extract the COE_HealAI folder to your Interface\AddOns\ directory.
The addon includes Chronos (required for timer functionality).

Note: COE only loads for Shaman characters.


CREDITS
================================================================================

Original Addon:
  Call of Elements by Wyverex (2006)
  http://coe.wyverex-cave.net

Fork:
  MarcelineVQ's Call of Elements fork

This Fork:
  HealAI extension and additional features
  Maintained by the current fork author
  Refactoring performed with the assistance of Claude

Thanks to:
  - Totem Timers, Frowning Circle, Totem Menu, Gypsy Mod authors
  - CTRaid, Healer/Nuker addon authors for inspiration
  - Chronos addon authors for timing functions
  - The WoW classic community for testing and feedback


LEGAL NOTICE
================================================================================

This is a community fork-of-a-fork project. All original Call of Elements
authors retain their respective copyrights. This fork is provided free of
charge for personal, non-commercial use. No warranty is provided.
