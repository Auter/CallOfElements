**This is a fork of MarcelineVQ's Call of Elements, extended with a smart
healing module. The addon provides comprehensive Shaman tools
including totem management, intelligent healing assistance, accessibility, and quality-of-life features.**

This fork was originally  created to support handheld / controller users, it now functions fully on PC.

NOTE: This addon is a work in progress. Features may change, and some rough
edges remain. Feedback and bug reports are welcome.

Designed for Vanilla 1.12 clients, with optional support for:
  - HealComm-1.0 (incoming heals awareness to avoid overhealing)
  - SuperWoW (chain heal logic, line-of-sight, and position checking)

**Extract the archive
Copy "COE_HealAI" folder into your "<WOW FOLDER>/Interface/Addons/" directory**


**CONFIGURATION:**
Use /coe or the keybind to open the configuration dialog.
  
  The Totem tab contains all of the original COE features.
  
  The Healing tab contains all HealAI settings organized into sub-tabs:
  
  - Core: Enable/disable, tank names, ToT fallback
    
  - Thresholds: Top-up, emergency, and tank emergency percentages
    
  - Chain Heal: Enable and configure multi-target healing
    
  - Dispels: Poison/disease handling and throttle settings
    
  - Raid: Group filters and SuperWoW distance features
    
  - Advanced: HealComm options, spam mode, spell selection
  
Macro **/run Coa_HealAI()** to call function, or set keybind from default blizzard UI
    
This project is:

a work in progress

provided for free

a community fork of a fork

not affiliated with Blizzard or any private server

All credit and original copyright remain with the original Call of Elements authors and previous maintainers.

**FAQ**

**Does this addon heal automatically?**

No. It does not press buttons for you and cannot act without keypresses.

It assists with decision making when you press the HealAI keybind by:

choosing appropriate heal ranks

evaluating raid damage

optionally selecting ideal Chain Heal targets

respecting your configured thresholds

You still control:

when healing happens

movement

totems

cooldowns

**Is this a bot?**

No.
It runs entirely inside the standard WoW addon API and relies on your input.

However: different servers interpret their rules differently.
If you’re unsure about server policy, ask staff before using.

**Is this only for handheld / Steam Deck / Ally users?**

No — it runs perfectly on PC too.

**Can I turn features off?**

Yes. Nearly everything is configurable:

You can choose exactly how much help you want.

**Do I need SuperWoW?**

No — but it unlocks extra features.

Without it:

those features stay hidden

rest of the addon works normally

**Will I get banned for using it?**

We cannot provide enforcement advice.

Important points:

addon runs inside WoW API

requires user input

no background automation

no injected code or memory editing

no 3rd-party programs

If you are worried about account action:

don’t use it

**Who is this addon for?**

handheld players

people with physical accessibility needs

people who struggle with UI micromanagement

brand new healers learning basics

casual players who want support tools

It is not intended for everyone.
