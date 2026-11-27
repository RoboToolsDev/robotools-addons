# RoboTools Addons

Small World of Warcraft addons and fixes for **WoW Forever**. The current ones work alongside [TradeSkillMaster](https://tradeskillmaster.com/) (TSM 4.15+) and need TSM installed.

| Addon | Version | What it does |
| --- | --- | --- |
| **TSM Group Mail Fix** | 1.9.0 | Adds Send AH and Send DE buttons to the mailbox (Blizzard's or TSM's). Each click mails up to 12 bag items that your TSM flag sources (`zpostaucnow`, `zdenow` by default) mark, to your AH or DE alt. Hover a button to see what's going out. Skips soulbound items and anything in a Do Not Mail group. |
| **TSM Craft Links** | 1.2.2 | Adds a Link Mats button above TSM's Crafting window. Click a queued craft and it posts `Mats for [Item]x3: [Mat]x2, ...` to whatever chat you're in. Shift-click drops it in the chat box instead. |

## Install

1. Close WoW.
2. Download the **[RoboTools Addons folder](https://drive.google.com/drive/folders/1A6f2IFsPDtPOCGIdeDhAtpYZ0bZHTMAD)** from Google Drive (download arrow at the top) and extract the zip.
3. Copy the `TSMGroupMailFix` and `TSMCraftLinks` folders into
   `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\`.
   Delete older versions of those folders first.
4. Launch WoW and make sure both are checked under AddOns.

## Setup

**TSM Group Mail Fix:** the settings window opens on its own the first time you log in on a realm and faction (or type `/gmf opt`). Enter your AH and DE alts, full name with surname, and click Save. `DNS` is set as a Do Not Mail group by default. Type `/gmf` for all commands.

**TSM Craft Links:** no setup. Open a profession in TSM, queue something, and click **Link Mats**. `/tcl` also opens the panel.

## Notes

- One hardware click per mail and per chat post; nothing is sent automatically, per Blizzard's addon rules.
- The flag sources come from the TSM custom sources in the full setup guide; any TSM source that returns 1 works.

## Found a bug?

[Report it here](https://github.com/RoboToolsDev/robotools-addons/issues/new/choose) (free GitHub account needed). A screenshot helps a lot.

Made by MrSKRobot, with assistance by Tobor (Claude).
