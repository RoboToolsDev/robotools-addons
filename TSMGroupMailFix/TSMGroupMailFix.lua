-- TSM Group Mail Fix: one click at the mailbox = one mail of flagged items to the right alt.
-- The flag logic lives in TSM. Retune your sources there and this follows along.
-- /gmf for commands, /gmf opt for the options panel.

local ADDON_NAME = "TSMGroupMailFix"
local TITLE = "TSM Group Mail Fix"
local ICON = "Interface\\Icons\\INV_Letter_15"
local MAX_ATTACH = ATTACHMENTS_MAX_SEND or 12
local LEGACY_PROFILE = "Default" -- v1.4-1.6 shared profile name, kept for migration

-- One row per Send button. flag is the default TSM source (changeable per profile).
-- Add a row here to mail another flag to another alt.
local KINDS = {
  { key = "ah", label = "AH", flag = "zpostaucnow" },
  { key = "de", label = "DE", flag = "zdenow" },
}

local DEFAULT_DNM_GROUPS = { "DNS" }

local buttons, pending = {}, false
local bar, mailOpen = nil, false -- bar holds the Send buttons; follows whichever mail UI is showing
local settingsCategory, optionsPanel, minimapIcon
local ReloadOptions -- set once the panel exists

local function Print(msg)
  print("|cff33ff99" .. TITLE .. "|r: " .. msg)
end

local function Copy(t)
  local out = {}
  for k, v in pairs(t or {}) do out[k] = type(v) == "table" and Copy(v) or v end
  return out
end

-- ============================================================================
-- Saved settings (TSMGroupMailFixDB)
--   profiles[name] = { alts = {ah, de}, flags = {ah, de}, dnmGroups = {...}, skipUngrouped }
--   assign["Horde - Roleplay PvP"] = profile name (nil = the realm - faction's own profile)
--   schema = 2 (v1.7+: profiles follow realm + faction, not character)
--   minimap = { hide, minimapPos }  (account-wide)
-- ============================================================================

local function DB() return TSMGroupMailFixDB end

local function IsForever()
  return WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT
end

-- Same as TSM v4.15.9 (LibTSMWoW/Source/Util/SessionInfo.lua): on Forever the
-- "realm" is always the ruleset name and GetRealmName() is never used.
-- Cached: the ruleset can't change mid-session, and Profile() asks for it constantly.
-- First call is at PLAYER_LOGIN (MigrateSchema), when the game rules are ready.
local cachedRealm
local function RealmName()
  if not cachedRealm then
    local name
    if IsForever() then
      local isRP = C_GameRules.IsGameRuleActive(Enum.GameRule.RPRuleset)
      local isPvP = C_GameRules.IsGameRuleActive(Enum.GameRule.PvPRuleset)
      if C_GameRules.IsGameRuleActive(Enum.GameRule.HardcoreRuleset) then name = "Hardcore"
      elseif isRP and isPvP then name = "Roleplay PvP"
      elseif isRP then name = "Roleplay"
      elseif isPvP then name = "PvP"
      else name = "Normal" end
    else
      name = GetRealmName()
    end
    if not name or name == "" then return "?" end -- not ready yet, don't cache
    cachedRealm = name
  end
  return cachedRealm
end

-- TSM's factionrealm format: "Horde - Roleplay PvP". Display only.
local function RealmFaction()
  return (UnitFactionGroup("player") or "?") .. " - " .. RealmName()
end

-- Full character name. Forever characters can have a surname ("Dha Bankha").
local function PlayerFullName()
  local name, surname = UnitName("player")
  if surname and surname ~= "" then
    local sep = Constants and Constants.CharacterNameSeparatorConsts
      and Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR or " "
    return name .. sep .. surname
  end
  return name or "?"
end

-- Key for "which profile does this character use". Matches TSM's disambiguated
-- name: just the full name on Forever (names are unique), Name-Realm elsewhere.
local function CharKey()
  if IsForever() then return PlayerFullName() end
  return (gsub(PlayerFullName() .. "-" .. (GetRealmName() or ""), "%s+", ""))
end

local function FillProfile(p)
  p.alts = p.alts or {}
  p.flags = p.flags or {}
  p.dnmGroups = p.dnmGroups or Copy(DEFAULT_DNM_GROUPS)
  if p.skipUngrouped == nil then p.skipUngrouped = false end
  return p
end

-- Each realm + faction uses its own profile ("Horde - Roleplay PvP") unless it was
-- pointed at another saved one. Every character there shares it.
local function ProfileName()
  local home = RealmFaction()
  local name = (DB().assign or {})[home]
  if name and DB().profiles[name] then return name end
  return home
end

local function Profile()
  local name = ProfileName()
  DB().profiles[name] = FillProfile(DB().profiles[name] or {})
  return DB().profiles[name]
end

local function ProfileNames()
  local names = {}
  Profile() -- make sure the current one exists
  for name in pairs(DB().profiles) do names[#names + 1] = name end
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  return names
end

-- Point this realm + faction at a profile (created if new)
local function UseProfile(name, copyFrom)
  if not DB().profiles[name] then
    DB().profiles[name] = FillProfile(copyFrom and Copy(copyFrom) or {})
  end
  DB().assign[RealmFaction()] = name ~= RealmFaction() and name or nil
end

-- Anything using it goes back to its own realm - faction profile
local function DeleteProfile(name)
  if name == ProfileName() then return false end
  DB().profiles[name] = nil
  for key, assigned in pairs(DB().assign) do
    if assigned == name then DB().assign[key] = nil end
  end
  return true
end

-- Set up = at least one alt filled in
local function IsSetUp(p)
  for _, kind in ipairs(KINDS) do
    if p.alts[kind.key] and p.alts[kind.key] ~= "" then return true end
  end
  return false
end

local function GetAlt(kind)
  local alt = Profile().alts[kind.key]
  if alt and alt ~= "" then return alt end
end

local function SetAlt(kind, name)
  name = strtrim(name or "")
  Profile().alts[kind.key] = name ~= "" and name or nil
end

local function GetFlag(kind)
  return Profile().flags[kind.key] or kind.flag
end

local function SetFlag(kind, v)
  v = strtrim(v or "")
  Profile().flags[kind.key] = (v ~= "" and v ~= kind.flag) and v or nil
end

local function DnmText()
  return table.concat(Profile().dnmGroups, ", ")
end

local function SetDnm(text)
  local list = {}
  for name in (text or ""):gmatch("[^,]+") do
    name = strtrim(name)
    if name ~= "" then list[#list + 1] = name end
  end
  Profile().dnmGroups = list
end

local function MigrateOldSettings()
  local db = DB()
  -- v1.1/1.2: profiles[realm - faction] = { ah, de } plus account-wide flags/skipGroups
  for key, p in pairs(db.profiles) do
    if not p.alts then
      db.profiles[key] = FillProfile({
        alts = { ah = p.ah, de = p.de },
        flags = Copy(db.flags),
        dnmGroups = db.skipGroups and Copy(db.skipGroups) or nil,
      })
    end
  end
  db.flags, db.skipGroups = nil, nil
end

-- v1.1-1.3 named profiles after "<realm> - <faction>" (v1.3.0 with a blank realm).
-- Rename this character's old profile to "Default" so the saved alts carry over.
-- Needs the player's faction, so it runs at PLAYER_LOGIN.
local function MigrateToDefaultProfile()
  local db = DB()
  if db.assign == nil then return end
  if not db.profiles[LEGACY_PROFILE] then
    local faction = UnitFactionGroup("player") or "?"
    local candidates = {}
    for _, key in ipairs({ RealmName() .. " - " .. faction, " - " .. faction }) do
      if db.assign[key] then candidates[#candidates + 1] = db.assign[key] end
      candidates[#candidates + 1] = key
    end
    local source
    for _, name in ipairs(candidates) do
      if db.profiles[name] then source = name break end
    end
    if not source then -- fall back to any profile that has an alt set
      for name, p in pairs(db.profiles) do
        if p.alts and (p.alts.ah or p.alts.de) then source = name break end
      end
    end
    if source then
      db.profiles[LEGACY_PROFILE], db.profiles[source] = db.profiles[source], nil
    end
  end
  -- Drop leftover blank-realm profiles from v1.3.0 (" - Horde")
  for name in pairs(db.profiles) do
    if name:match("^ %- ") then db.profiles[name] = nil end
  end
  db.assign = nil
end

-- v1.4-1.6 kept profiles per character (charProfile) with a shared "Default".
-- v1.7 keys them by realm + faction: point this realm + faction at what this
-- character was using, so existing setups carry over with no first-time popup.
local function MigrateSchema()
  local db = DB()
  if not db.schema then
    if db.assign then MigrateToDefaultProfile() end -- pre-1.4 data (sets assign to nil)
    db.assign = {}
    local name = db.charProfile and db.charProfile[CharKey()] or LEGACY_PROFILE
    if db.profiles[name] then db.assign[RealmFaction()] = name end
    db.charProfile = nil
    db.schema = 2
  end
  -- v1.8.2: the carried-over "Default" takes this realm + faction's name, so it matches
  -- the auto-naming. Only when nothing else uses "Default" and the realm's own profile is unused.
  if db.schema == 2 then
    local users = {}
    for key, name in pairs(db.assign) do
      if name == LEGACY_PROFILE then users[#users + 1] = key end
    end
    local home = users[1]
    local own = home and db.profiles[home]
    if #users == 1 and db.profiles[LEGACY_PROFILE] and not (own and IsSetUp(FillProfile(own))) then
      db.profiles[home], db.profiles[LEGACY_PROFILE] = db.profiles[LEGACY_PROFILE], nil
      db.assign[home] = nil
    end
    db.schema = 3
  end
end

-- ============================================================================
-- Bags + TSM
-- ============================================================================

-- Container API: C_Container on newer clients, old globals as fallback
local GetNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local PickupItem = (C_Container and C_Container.PickupContainerItem) or PickupContainerItem

local function GetSlotInfo(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if info then return info.hyperlink, info.isLocked, info.isBound, info.stackCount end
    return
  end
  local _, count, locked, _, _, _, link, _, _, _, isBound = GetContainerItemInfo(bag, slot)
  return link, locked, isBound, count
end

local function ToItemString(link)
  local itemString = TSM_API.ToItemString(link)
  if itemString then return itemString end
  local id = link:match("item:(%d+)")
  return id and ("i:" .. id)
end

-- False if the item is in a Do Not Mail group (or a subgroup of one),
-- or is ungrouped while "Skip ungrouped items" is on.
-- TSM group paths use ` between levels, e.g. "Farming`DNS"
local function PassesGroupRules(itemString, profile)
  local ok, path = pcall(TSM_API.GetGroupPathByItem, itemString)
  if not ok then path = nil end
  if not path then return not profile.skipUngrouped end
  for level in path:gmatch("[^`]+") do
    for _, dnm in ipairs(profile.dnmGroups) do
      if level == dnm then return false end
    end
  end
  return true
end

local function IsFlagged(itemString, flag)
  local ok, value = pcall(TSM_API.GetCustomPriceValue, flag, itemString)
  return ok and type(value) == "number" and value >= 1
end

-- Bags 0-4 plus the reagent bag on clients that have one (same as TSM's Container.lua on Forever)
local function LastBag()
  local reagent = Constants and Constants.InventoryConstants
    and Constants.InventoryConstants.NumReagentBagSlots or 0
  return NUM_BAG_SLOTS + reagent
end

-- Every unbound, unlocked bag slot whose flag is 1 and passes the group rules.
-- One pass over the bags for all the given kinds: lists[kind.key] = { {bag, slot, link, count}, ... }
local function Scan(kinds)
  local lists, flags, profile = {}, {}, Profile()
  for _, kind in ipairs(kinds) do
    lists[kind.key], flags[kind.key] = {}, GetFlag(kind)
  end
  for bag = 0, LastBag() do
    for slot = 1, (GetNumSlots(bag) or 0) do
      local link, locked, bound, count = GetSlotInfo(bag, slot)
      if link and not locked and not bound then
        local itemString = ToItemString(link)
        if itemString then
          local passes -- group rules only checked once, and only for flagged items
          for _, kind in ipairs(kinds) do
            if IsFlagged(itemString, flags[kind.key]) then
              if passes == nil then passes = PassesGroupRules(itemString, profile) end
              if passes then
                local list = lists[kind.key]
                list[#list + 1] = { bag, slot, link = link, count = count or 1 }
              end
            end
          end
        end
      end
    end
  end
  return lists
end

local function Collect(kind)
  return Scan({ kind })[kind.key]
end

-- ============================================================================
-- Mailbox buttons
-- ============================================================================

local function Refresh()
  if not mailOpen or not bar then return end
  local lists = Scan(KINDS)
  for _, kind in ipairs(KINDS) do
    local btn = buttons[kind.key]
    if btn then
      btn:SetText(("Send %s (%d)"):format(kind.label, #lists[kind.key]))
      btn:SetEnabled(not pending and GetAlt(kind) ~= nil)
    end
  end
end

local function ShowSendTab()
  if MailFrameTab_OnClick then
    MailFrameTab_OnClick(nil, 2)
  elseif MailFrameTab2 then
    MailFrameTab2:Click()
  end
end

local function SendBatch(kind)
  if pending then return end
  local alt = GetAlt(kind)
  if not alt then
    Print(("No %s alt set in profile \"%s\". /gmf opt to set one."):format(kind.label, ProfileName()))
    return
  end
  if alt:lower() == PlayerFullName():lower() then
    Print("That's you. Pick a different alt.")
    return
  end

  if MailFrame:IsShown() then ShowSendTab() end -- TSM's mail UI doesn't need Blizzard's Send tab
  for i = 1, MAX_ATTACH do
    if GetSendMailItem(i) then
      Print("A mail already has items attached. Send it or clear it first.")
      return
    end
  end

  local list = Collect(kind)
  if #list == 0 then
    Print("Nothing flagged for " .. kind.label .. ".")
    return
  end

  local attached = 0
  for i = 1, #list do
    if attached >= MAX_ATTACH then break end
    ClearCursor()
    PickupItem(list[i][1], list[i][2])
    ClickSendMailItemButton(attached + 1)
    if CursorHasItem() then
      ClearCursor() -- couldn't be mailed, skip it
    else
      attached = attached + 1
    end
  end
  if attached == 0 then return end

  pending = true
  Refresh()
  -- Never send gold or COD by accident (TSM does the same before its sends)
  SetSendMailMoney(0)
  SetSendMailCOD(0)
  SendMail(alt, "TSM " .. kind.label, "")
  local left = #list - attached
  Print(("Sent %d to %s.%s"):format(attached, alt,
    left > 0 and (" %d left, click again."):format(left) or ""))
end

-- Tooltip list of what the next click mails (first MAX_ATTACH stacks), grouped by item
local function AddSendPreview(tt, list)
  if #list == 0 then
    tt:AddLine("Nothing flagged in your bags.", 0.7, 0.7, 0.7)
    return
  end
  local batch = math.min(#list, MAX_ATTACH)
  local order, totals, stacks = {}, {}, {}
  for i = 1, batch do
    local link = list[i].link
    if not totals[link] then order[#order + 1] = link end
    totals[link] = (totals[link] or 0) + list[i].count
    stacks[link] = (stacks[link] or 0) + 1
  end
  tt:AddLine(("This mail (%d of %d stacks):"):format(batch, #list), 1, 0.82, 0)
  for _, link in ipairs(order) do
    local extra = stacks[link] > 1 and (" |cff888888(%d stacks)|r"):format(stacks[link]) or ""
    tt:AddLine(("%s x%d%s"):format(link, totals[link], extra), 1, 1, 1)
  end
  local left = #list - batch
  if left > 0 then
    tt:AddLine(("+%d more stacks on the next click(s)"):format(left), 0.7, 0.7, 0.7)
  end
end

-- TSM's Mailing window. TSM has no API callback for it, but every TSM window registers
-- itself in UISpecialFrames (so Esc closes it) and has a resize button.
local function FindTSMMailFrame()
  local ok, visible = pcall(TSM_API.IsUIVisible, "MAILING")
  if not ok or not visible then return end
  for _, name in ipairs(UISpecialFrames) do
    local frame = _G[name]
    if type(frame) == "table" and frame.resizeBtn and frame.resizeIcon
      and frame.IsShown and frame:IsShown() then
      return frame
    end
  end
end

-- Park the buttons next to whichever mail window is showing (Blizzard's or TSM's).
-- Runs a few times a second while the mailbox is open, since you can switch UIs.
-- currentAnchor = false means "not placed yet" (forces the first placement).
local currentAnchor
local function UpdateAnchor()
  -- Already attached to a window that's still up: nothing to do (Blizzard's wins if both show)
  if currentAnchor and currentAnchor:IsShown()
    and (currentAnchor == MailFrame or not MailFrame:IsShown()) then
    return
  end
  local target = MailFrame:IsShown() and MailFrame or FindTSMMailFrame()
  if target ~= currentAnchor then
    currentAnchor = target
    if target then
      bar:ClearAllPoints()
      bar:SetPoint("TOPLEFT", target, "TOPRIGHT", 4, -30)
      bar:SetFrameStrata(target:GetFrameStrata())
      bar:SetFrameLevel(target:GetFrameLevel() + 20)
    end
    for _, btn in pairs(buttons) do btn:SetShown(target ~= nil) end
  end
end

local function CreateButtons()
  bar = CreateFrame("Frame", nil, UIParent)
  bar:SetSize(120, 22 * #KINDS + 4 * (#KINDS - 1))
  bar:Hide()
  local elapsed = 0
  bar:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 0.2 then return end
    elapsed = 0
    UpdateAnchor()
  end)

  local prev
  for _, kind in ipairs(KINDS) do
    local btn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    btn:SetSize(120, 22)
    if prev then
      btn:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -4)
    else
      btn:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    end
    btn:SetScript("OnClick", function() SendBatch(kind) end)
    btn:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("Send " .. kind.label .. " to " .. (GetAlt(kind) or "|cffff6666no alt set|r"))
      AddSendPreview(GameTooltip, Collect(kind))
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(GetFlag(kind) .. " = 1  |  Profile: " .. ProfileName(), 0.6, 0.6, 0.6)
      GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", GameTooltip_Hide)
    buttons[kind.key] = btn
    prev = btn
  end
end

-- ============================================================================
-- Status + minimap button
-- ============================================================================

local function PrintStatus()
  local p = Profile()
  Print(("Profile \"%s\"  |cff888888(%s, %s)|r"):format(ProfileName(), PlayerFullName(), RealmFaction()))
  for _, kind in ipairs(KINDS) do
    Print(("  %s: %s -> %s"):format(kind.label, GetFlag(kind), GetAlt(kind) or "not set"))
  end
  Print("  Do Not Mail groups: " .. (DnmText() ~= "" and DnmText() or "none"))
  Print("  Skip ungrouped items: " .. (p.skipUngrouped and "on" or "off"))
end

local function SetMinimapHidden(hide)
  DB().minimap.hide = hide
  if minimapIcon then
    if hide then minimapIcon:Hide(ADDON_NAME) else minimapIcon:Show(ADDON_NAME) end
  end
end

local OpenOptions -- defined below

-- Uses the LibDataBroker/LibDBIcon copies TSM already loads. No button if they're missing.
local function CreateMinimapButton()
  if not LibStub then return end
  local ldb = LibStub("LibDataBroker-1.1", true)
  local dbicon = LibStub("LibDBIcon-1.0", true)
  if not ldb or not dbicon then return end
  local obj = ldb:NewDataObject(ADDON_NAME, {
    type = "launcher",
    text = TITLE,
    icon = ICON,
    OnClick = function(_, button)
      if button == "RightButton" then PrintStatus() else OpenOptions() end
    end,
    OnTooltipShow = function(tt)
      tt:AddLine(TITLE)
      tt:AddLine("Profile: " .. ProfileName(), 0.7, 0.7, 0.7)
      tt:AddLine(RealmFaction(), 0.7, 0.7, 0.7)
      tt:AddLine("Left-click: options", 1, 1, 1)
      tt:AddLine("Right-click: status", 1, 1, 1)
    end,
  })
  dbicon:Register(ADDON_NAME, obj, DB().minimap)
  minimapIcon = dbicon
end

-- ============================================================================
-- Options panel (Options > AddOns)
-- ============================================================================

local function SetStatus(fs, ok, text)
  fs:SetText(text or "")
  if ok then fs:SetTextColor(0.4, 1, 0.4) else fs:SetTextColor(1, 0.4, 0.4) end
end

local function CheckFlag(fs, flag)
  local ok, err = TSM_API.IsCustomPriceValid(flag)
  if ok then SetStatus(fs, true, "OK") else SetStatus(fs, false, err or "Not a valid TSM source") end
end

local function CheckGroups(fs)
  local known = {}
  for _, path in ipairs(TSM_API.GetGroupPaths({})) do
    for level in path:gmatch("[^`]+") do known[level] = true end
  end
  local missing = {}
  for _, name in ipairs(Profile().dnmGroups) do
    if not known[name] then missing[#missing + 1] = name end
  end
  if #missing == 0 then
    SetStatus(fs, true, #Profile().dnmGroups > 0 and "OK" or "")
  else
    SetStatus(fs, false, "No TSM group named: " .. table.concat(missing, ", "))
  end
end

local function Header(parent, anchor, text, gap)
  local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, gap or -22)
  fs:SetText(text)
  return fs
end

local function Note(parent, anchor, text)
  local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)
  fs:SetWidth(600)
  fs:SetJustifyH("LEFT")
  fs:SetText(text)
  return fs
end

-- Label + edit box + status text. Returns the label (for anchoring) and a loader.
local function EditRow(parent, anchor, label, getter, setter, check)
  local text = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  text:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -14)
  text:SetWidth(170)
  text:SetJustifyH("LEFT")
  text:SetText(label)

  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(180, 20)
  box:SetPoint("LEFT", text, "RIGHT", 8, 0)
  box:SetAutoFocus(false)

  local status = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  status:SetPoint("LEFT", box, "RIGHT", 10, 0)
  status:SetWidth(240)
  status:SetJustifyH("LEFT")

  local row = {}
  function row.Load()
    box:SetText(getter() or "")
    box:SetCursorPosition(0)
    if check then check(status) end
  end
  function row.IsDirty()
    return strtrim(box:GetText() or "") ~= strtrim(getter() or "")
  end
  function row.Commit()
    if row.IsDirty() then setter(box:GetText()) end
    row.Load()
  end
  box:SetScript("OnEnterPressed", function(self)
    row.Commit()
    self:ClearFocus()
    Refresh()
    if parent.UpdateSaveState then parent.UpdateSaveState() end
  end)
  box:SetScript("OnEscapePressed", function(self)
    row.Load()
    self:ClearFocus()
    if parent.UpdateSaveState then parent.UpdateSaveState() end
  end)
  box:SetScript("OnTextChanged", function()
    if parent.UpdateSaveState then parent.UpdateSaveState() end
  end)
  return text, row
end

local function CheckRow(parent, anchor, label, getter, setter)
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetSize(26, 26)
  holder:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)
  local cb = CreateFrame("CheckButton", nil, holder, "UICheckButtonTemplate")
  cb:SetSize(26, 26)
  cb:SetPoint("TOPLEFT", -4, 0)
  local text = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
  text:SetText(label)
  cb:SetScript("OnClick", function(self)
    setter(self:GetChecked() and true or false)
    Refresh()
  end)
  return holder, { Load = function() cb:SetChecked(getter()) end }
end

-- Profile names other than the active one (for Copy From and Delete)
local function OtherProfiles()
  local list, current = {}, ProfileName()
  for _, name in ipairs(ProfileNames()) do
    if name ~= current then list[#list + 1] = name end
  end
  return list
end

StaticPopupDialogs["TSMGMF_COPY_PROFILE"] = {
  text = "Copy every setting from \"%s\" into \"%s\"? This replaces its alts and settings.",
  button1 = ACCEPT,
  button2 = CANCEL,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  OnAccept = function(_, source)
    local target = ProfileName()
    DB().profiles[target] = FillProfile(Copy(DB().profiles[source]))
    Print(("Copied \"%s\" into \"%s\"."):format(source, target))
    if ReloadOptions then ReloadOptions() end
    Refresh()
  end,
}

StaticPopupDialogs["TSMGMF_RESET_PROFILE"] = {
  text = "Reset profile \"%s\" to the defaults? This clears its alts.",
  button1 = OKAY or "Okay",
  button2 = CANCEL,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  OnAccept = function(_, name)
    DB().profiles[name] = FillProfile({})
    Print(("Reset profile \"%s\" to the defaults."):format(name))
    if ReloadOptions then ReloadOptions() end
    Refresh()
  end,
}

StaticPopupDialogs["TSMGMF_DELETE_PROFILE"] = {
  text = "Delete profile \"%s\"? Anything using it goes back to its own realm - faction profile.",
  button1 = DELETE or "Delete",
  button2 = CANCEL,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  OnAccept = function(_, name)
    if DeleteProfile(name) then
      Print("Deleted profile \"" .. name .. "\". Now using \"" .. ProfileName() .. "\".")
    end
    if ReloadOptions then ReloadOptions() end
    Refresh()
  end,
}

local function SmallButton(parent, text, width)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetText(text)
  return b
end

-- Dropdown of profile names. With isSelected it's a pick-one list that shows the
-- choice (Set active profile); without, a pick-to-act menu (Copy From, Delete).
-- Uses the modern dropdown where the client has it, else the old UIDropDownMenu.
-- Returns the frame, an update function and the x offset to line it up with labels.
local dropdownCount = 0
local function ProfileDropdown(parent, width, placeholder, getList, isSelected, onPick)
  local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  if ok and dd and dd.SetupMenu then
    dd:SetWidth(width)
    if dd.SetDefaultText then dd:SetDefaultText(placeholder) end
    dd:SetupMenu(function(_, root)
      for _, name in ipairs(getList()) do
        if isSelected then
          root:CreateRadio(name, function() return isSelected(name) end, function() onPick(name) end)
        else
          root:CreateButton(name, function() onPick(name) end)
        end
      end
    end)
    return dd, function()
      dd:GenerateMenu()
      dd:SetEnabled(#getList() > 0)
    end, 0
  end
  dropdownCount = dropdownCount + 1
  dd = CreateFrame("Frame", "TSMGroupMailFixDropdown" .. dropdownCount, parent, "UIDropDownMenuTemplate")
  UIDropDownMenu_SetWidth(dd, width - 30)
  UIDropDownMenu_Initialize(dd, function(_, level)
    for _, name in ipairs(getList()) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = name
      info.notCheckable = not isSelected
      info.checked = isSelected and isSelected(name) or nil
      info.func = function() onPick(name); CloseDropDownMenus() end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  return dd, function()
    local text = placeholder
    if isSelected then
      for _, name in ipairs(getList()) do if isSelected(name) then text = name end end
    end
    UIDropDownMenu_SetText(dd, text)
    if #getList() > 0 then UIDropDownMenu_EnableDropDown(dd) else UIDropDownMenu_DisableDropDown(dd) end
  end, -16
end

local function CreateOptions()
  -- The page scrolls: everything lives in `panel`, a scroll child of `outer`
  local outer = CreateFrame("Frame")
  outer.name = TITLE
  local scroll = CreateFrame("ScrollFrame", nil, outer, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, -4)
  scroll:SetPoint("BOTTOMRIGHT", -28, 40) -- room for the Save bar
  local panel = CreateFrame("Frame", nil, scroll)
  panel:SetSize(650, 1000)
  scroll:SetScrollChild(panel)
  local rows = {}
  local function Add(anchor, row) rows[#rows + 1] = row; return anchor end

  local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText(TITLE .. "  |cff888888v" .. (GetMeta(ADDON_NAME, "Version") or "?") .. "|r")

  local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  desc:SetWidth(600)
  desc:SetJustifyH("LEFT")
  desc:SetText("Adds Send buttons to the mailbox. Each click mails up to " .. MAX_ATTACH ..
    " bag items whose TSM flag source returns 1 to that button's alt. Soulbound items are never sent. " ..
    "Type in a box, then click Save at the bottom (or press Enter to save just that box). " ..
    "Esc undoes typing; checkboxes and profile changes save instantly.")

  -- Save button + state text
  local saveBtn = SmallButton(outer, "Save", 90)
  saveBtn:SetPoint("BOTTOMRIGHT", outer, "BOTTOMRIGHT", -16, 10)
  saveBtn:Disable()
  local saveState = outer:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  saveState:SetPoint("RIGHT", saveBtn, "LEFT", -8, 0)
  local justSaved = false
  function panel.UpdateSaveState()
    local dirty = false
    for _, row in ipairs(rows) do
      if row.IsDirty and row.IsDirty() then dirty = true end
    end
    saveBtn:SetEnabled(dirty)
    if dirty then
      justSaved = false
      saveState:SetText("Unsaved changes")
      saveState:SetTextColor(1, 0.6, 0.1)
    elseif justSaved then
      saveState:SetText("Saved")
      saveState:SetTextColor(0.4, 1, 0.4)
    else
      saveState:SetText("")
    end
  end
  saveBtn:SetScript("OnClick", function()
    for _, row in ipairs(rows) do
      if row.Commit then row.Commit() end
    end
    justSaved = true
    ReloadOptions() -- also refreshes the Save state, now showing "Saved"
    Refresh()
    C_Timer.After(3, function() -- "Saved" fades back to nothing
      justSaved = false
      panel.UpdateSaveState()
    end)
  end)

  -- First-time setup line, right under the description so a new user sees it first
  local setupBanner = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  setupBanner:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
  setupBanner:SetWidth(600)
  setupBanner:SetJustifyH("LEFT")
  Add(setupBanner, { Load = function()
    setupBanner:SetText(IsSetUp(Profile()) and "" or
      ("First-time setup for %s: enter your AH and DE alts below, then click Save. " ..
      "DNS is already set as a Do Not Mail group."):format(RealmFaction()))
  end })

  -- Alts
  local anchor = Header(panel, setupBanner, "Alts")
  for _, kind in ipairs(KINDS) do
    anchor = Add(EditRow(panel, anchor, kind.label .. " alt",
      function() return Profile().alts[kind.key] end,
      function(v) SetAlt(kind, v) end))
  end

  -- What to skip
  anchor = Header(panel, anchor, "Never mail")
  anchor = Add(EditRow(panel, anchor, "Do Not Mail group(s)", DnmText, SetDnm, CheckGroups))
  anchor = Note(panel, anchor, "TSM group names, comma-separated. Subgroups count too. Default: DNS.")
  anchor = Add(CheckRow(panel, anchor, "Skip ungrouped items (not in any TSM group)",
    function() return Profile().skipUngrouped end,
    function(v) Profile().skipUngrouped = v end))

  -- Flag sources
  anchor = Header(panel, anchor, "TSM flag sources")
  for _, kind in ipairs(KINDS) do
    anchor = Add(EditRow(panel, anchor, kind.label .. " flag source",
      function() return GetFlag(kind) end,
      function(v) SetFlag(kind, v) end,
      function(fs) CheckFlag(fs, GetFlag(kind)) end))
  end
  anchor = Note(panel, anchor, "Any TSM custom source that returns 1 to send. Leave blank to reset to the default.")

  -- General (all profiles)
  anchor = Header(panel, anchor, "General (all profiles)")
  anchor = Add(CheckRow(panel, anchor, "Hide minimap button",
    function() return DB().minimap.hide end,
    SetMinimapHidden))

  -- Profile, laid out like the Ace3 profile panel most addons use: one column,
  -- a short description above each control.
  local profHeader = Header(panel, anchor, "Profile")
  local WIDTH = 400

  local function Desc(anchor, text, y)
    local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y or -12)
    fs:SetWidth(600)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
  end
  local function Label(anchor, text, y)
    local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y or -8)
    fs:SetText(text)
    return fs
  end

  -- Intro (+ first-time setup banner), then Reset Profile with the current profile beside it
  local profNote = Desc(profHeader, "", -8)
  local resetBtn = SmallButton(panel, "Reset Profile", 200)
  resetBtn:SetPoint("TOPLEFT", profNote, "BOTTOMLEFT", 0, -8)
  resetBtn:SetScript("OnClick", function()
    local name = ProfileName()
    StaticPopup_Show("TSMGMF_RESET_PROFILE", name, nil, name)
  end)
  local curText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  curText:SetPoint("LEFT", resetBtn, "RIGHT", 8, 0)

  -- New, or pick an existing profile
  local pickDesc = Desc(resetBtn, "Create a new profile by typing a name in the box and pressing Enter, " ..
    "or pick one of your saved profiles.", -14)
  local newLabel = Label(pickDesc, "New")
  local newBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
  newBox:SetSize(WIDTH, 20)
  newBox:SetAutoFocus(false)
  newBox:SetPoint("TOPLEFT", newLabel, "BOTTOMLEFT", 6, -4)
  newBox:SetScript("OnEnterPressed", function(self)
    local name = strtrim(self:GetText() or "")
    self:SetText("")
    self:ClearFocus()
    if name == "" then return end
    if DB().profiles[name] then
      Print("Switched to existing profile \"" .. name .. "\".")
    else
      Print("Created profile \"" .. name .. "\". " .. RealmFaction() .. " now uses it.")
    end
    UseProfile(name)
    ReloadOptions()
    Refresh()
  end)
  newBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)

  local activeLabel = Label(newLabel, "Set active profile", -34)
  local activeDD, activeUpdate, ddX = ProfileDropdown(panel, WIDTH, "", ProfileNames,
    function(name) return name == ProfileName() end,
    function(name) UseProfile(name); ReloadOptions(); Refresh() end)
  activeDD:SetPoint("TOPLEFT", activeLabel, "BOTTOMLEFT", ddX, -4)

  -- Copy From
  local copyDesc = Desc(activeLabel, "Copy the settings from another saved profile into the active one.", -40)
  local copyLabel = Label(copyDesc, "Copy From")
  local copyDD, copyUpdate = ProfileDropdown(panel, WIDTH, "", OtherProfiles, nil,
    function(name) StaticPopup_Show("TSMGMF_COPY_PROFILE", name, ProfileName(), name) end)
  copyDD:SetPoint("TOPLEFT", copyLabel, "BOTTOMLEFT", ddX, -4)

  -- Delete a Profile
  local delDesc = Desc(copyLabel, "Delete saved profiles you no longer use.", -40)
  local delLabel = Label(delDesc, "Delete a Profile")
  local delDD, delUpdate = ProfileDropdown(panel, WIDTH, "", OtherProfiles, nil,
    function(name) StaticPopup_Show("TSMGMF_DELETE_PROFILE", name, nil, name) end)
  delDD:SetPoint("TOPLEFT", delLabel, "BOTTOMLEFT", ddX, -4)

  local spacer = CreateFrame("Frame", nil, panel)
  spacer:SetSize(1, 1)
  spacer:SetPoint("TOPLEFT", delLabel, "BOTTOMLEFT", 0, -30)

  -- Copy From / Delete labels go grey when there's nothing to pick, like Ace3
  local function Grey(fs, enabled)
    if enabled then fs:SetTextColor(1, 0.82, 0) else fs:SetTextColor(0.5, 0.5, 0.5) end
  end

  Add(profNote, { Load = function()
    curText:SetText(("Current Profile: |cffffd100%s|r"):format(ProfileName()))
    profNote:SetText(("Each realm and faction gets its own profile automatically, shared by all your characters there " ..
      "(you're on %s). Reset Profile puts the active profile back to its defaults."):format(RealmFaction()))
    activeUpdate()
    copyUpdate()
    delUpdate()
    local others = #OtherProfiles() > 0
    Grey(copyLabel, others)
    Grey(delLabel, others)
  end })

  ReloadOptions = function()
    for _, row in ipairs(rows) do row.Load() end
    panel.UpdateSaveState()
  end
  outer:SetScript("OnShow", ReloadOptions)

  if Settings and Settings.RegisterCanvasLayoutCategory then
    settingsCategory = Settings.RegisterCanvasLayoutCategory(outer, TITLE)
    Settings.RegisterAddOnCategory(settingsCategory)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(outer)
  end
  optionsPanel = outer
end

OpenOptions = function()
  if settingsCategory and Settings and Settings.OpenToCategory then
    Settings.OpenToCategory(settingsCategory:GetID())
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(optionsPanel)
    InterfaceOptionsFrame_OpenToCategory(optionsPanel) -- old client bug: first call can land on the wrong page
  end
end

-- First login on a realm + faction with no alts set: open the options panel so the
-- user can fill them in. Waits until out of combat (the settings panel is protected).
local setupFrame = CreateFrame("Frame")
local function FirstTimeSetup()
  if IsSetUp(Profile()) then return end
  if InCombatLockdown() then
    setupFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    return
  end
  setupFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
  Print(("First-time setup for %s: enter your AH and DE alts, then click Save."):format(RealmFaction()))
  OpenOptions()
end
setupFrame:SetScript("OnEvent", FirstTimeSetup)

-- ============================================================================
-- Events
-- ============================================================================

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("MAIL_SHOW")
f:RegisterEvent("MAIL_CLOSED")
f:RegisterEvent("MAIL_SEND_SUCCESS")
f:RegisterEvent("MAIL_FAILED")
f:RegisterEvent("BAG_UPDATE_DELAYED")
f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    TSMGroupMailFixDB = TSMGroupMailFixDB or {}
    local db = TSMGroupMailFixDB
    db.profiles = db.profiles or {}
    db.minimap = db.minimap or { hide = false }
    MigrateOldSettings()
    CreateOptions()
  elseif event == "PLAYER_LOGIN" then
    MigrateSchema() -- must run before anything touches Profile()
    -- v1.0 saved one global AH/DE alt; move it into this character's profile
    local db = TSMGroupMailFixDB
    for _, kind in ipairs(KINDS) do
      if type(db[kind.key]) == "string" then
        if db[kind.key] ~= "" and not GetAlt(kind) then SetAlt(kind, db[kind.key]) end
        db[kind.key] = nil
      end
    end
    CreateMinimapButton()
    C_Timer.After(3, FirstTimeSetup) -- let the login screen settle first
  elseif event == "MAIL_SHOW" then
    if not bar then CreateButtons() end
    mailOpen = true
    currentAnchor = false
    bar:Show()
    UpdateAnchor() -- TSM's window appears a frame later; the bar's OnUpdate catches it
    Refresh()
  elseif event == "MAIL_CLOSED" then
    mailOpen, pending = false, false
    if bar then bar:Hide() end
  elseif event == "MAIL_SEND_SUCCESS" or event == "MAIL_FAILED" then
    pending = false
    Refresh()
  elseif event == "BAG_UPDATE_DELAYED" then
    Refresh()
  end
end)

-- ============================================================================
-- Slash commands: /gmf or /groupmailfix
-- ============================================================================

local function PrintHelp()
  Print("Commands (/gmf or /groupmailfix):")
  Print("  /gmf opt | options - open the options panel")
  Print("  /gmf status - show the current profile's settings")
  Print("  /gmf ah <name> - set the AH alt")
  Print("  /gmf de <name> - set the DE alt")
  Print("  /gmf dnm <group, group> - set Do Not Mail groups")
  Print("  /gmf ungrouped on | off - skip items not in any TSM group")
  Print("  /gmf profile <name> - switch this realm + faction to a profile (saves a copy if new)")
  Print("  /gmf profiles - list saved profiles")
  Print("  /gmf minimap - show or hide the minimap button")
end

SLASH_TSMGROUPMAILFIX1 = "/gmf"
SLASH_TSMGROUPMAILFIX2 = "/groupmailfix"
SlashCmdList.TSMGROUPMAILFIX = function(msg)
  local cmd, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()

  if cmd == "opt" or cmd == "options" then
    OpenOptions()
  elseif cmd == "status" then
    PrintStatus()
  elseif cmd == "dnm" then
    SetDnm(rest)
    Print("Do Not Mail groups: " .. (DnmText() ~= "" and DnmText() or "none"))
  elseif cmd == "ungrouped" and (rest == "on" or rest == "off") then
    Profile().skipUngrouped = rest == "on"
    Print("Skip ungrouped items: " .. rest)
  elseif cmd == "profile" and rest ~= "" then
    UseProfile(rest, DB().profiles[rest] == nil and Profile() or nil)
    Print("Now using profile \"" .. rest .. "\".")
  elseif cmd == "profiles" then
    local names = ProfileNames()
    for i, n in ipairs(names) do
      if n == ProfileName() then names[i] = n .. " (current)" end
    end
    Print("Profiles: " .. table.concat(names, ", "))
  elseif cmd == "minimap" then
    SetMinimapHidden(not DB().minimap.hide)
    Print("Minimap button " .. (DB().minimap.hide and "hidden." or "shown."))
  else
    local handled = false
    for _, kind in ipairs(KINDS) do
      if cmd == kind.key and rest ~= "" then
        SetAlt(kind, rest)
        Print(("%s alt set to %s (profile \"%s\")."):format(kind.label, rest, ProfileName()))
        handled = true
      end
    end
    if not handled then PrintHelp() return end
  end
  Refresh()
  if optionsPanel and optionsPanel:IsVisible() and ReloadOptions then ReloadOptions() end
end
