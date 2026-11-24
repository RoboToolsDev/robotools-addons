-- TSM Craft Links: a "Link Mats" button on TSM's Crafting window.
-- Pick a queued craft (or all of them) and its mats go into the chat box as links with counts.
-- Nothing is sent for you: you press Enter. Long lists are split into 255-character parts.

local TITLE = "TSM Craft Links"
local MAX_CHAT = 255
local MAX_ROWS = 20
local ROW_H = 18
local ALL_KEY = "ALL"

local button, popup, statusText
local rows = {}
local anchorFrame
local pendingParts, pendingKey, pendingIndex = nil, nil, 0

local function Print(msg)
  print("|cff33ff99" .. TITLE .. "|r: " .. msg)
end

local function SetStatus(text)
  if statusText then statusText:SetText(text or "") end
end

local function ResetPending()
  pendingParts, pendingKey, pendingIndex = nil, nil, 0
end

-- ============================================================================
-- TSM data
-- ============================================================================

-- Queued crafts: { recipe = "r:123", item = "i:456" or nil, num = 3 }
local function GetQueue()
  local list = {}
  local ok = pcall(function()
    for _, recipeString, itemString, num in TSM_API.CraftingQueueIterator() do
      if type(recipeString) == "string" and recipeString:match("^r:%d+") and type(num) == "number" and num > 0 then
        list[#list + 1] = { recipe = recipeString, item = type(itemString) == "string" and itemString or nil, num = num }
      end
    end
  end)
  if not ok then return {} end
  return list
end

local function ItemName(itemString)
  local ok, name = pcall(TSM_API.GetItemName, itemString)
  return (ok and name) or itemString
end

-- The recipe's spell name (used for enchants, which have no crafted item)
local function RecipeName(recipe)
  local spellID = tonumber(recipe:match("^r:(%d+)"))
  return spellID and ((C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID))
    or (GetSpellInfo and GetSpellInfo(spellID)))
end

-- Display text for a queued craft: the crafted item's link, or the recipe's spell name (enchants)
local function CraftLabel(q)
  if q.item then
    local ok, link = pcall(TSM_API.GetItemLink, q.item)
    if ok and link then return link end
  end
  return RecipeName(q.recipe) or q.recipe
end

local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local RequestLoad = C_Item and C_Item.RequestLoadItemDataByID

-- A real Blizzard item link. TSM_API.GetItemLink hand-builds links ("|Hitem:123|h"),
-- which look fine in UI but the chat server silently drops messages containing them.
-- Returns link, name; or nil, nil, true while the client is still loading the item.
local function ChatLink(itemString)
  local id = tonumber(itemString:match("^i:(%d+)"))
  if not id then return nil end
  local name, link = GetInfo(id)
  if link then return link, name end
  if RequestLoad then RequestLoad(id) end
  return nil, nil, true
end

-- "Mats for [Item] x3: " (the craft count only when it's more than 1).
-- Enchants have no item, so they use the recipe name. Second return: item info still loading.
local function MessagePrefix(key, entries)
  if key == ALL_KEY then return "Mats for all queued crafts: " end
  local q = entries[1]
  local label, loading
  if q.item then
    local link, name, isLoading = ChatLink(q.item)
    label, loading = link or name, isLoading
  end
  label = label or RecipeName(q.recipe) or "this craft"
  local count = q.num > 1 and ("x" .. q.num) or ""
  return "Mats for " .. label .. count .. ": ", loading
end

-- Total mats for the given queue entries (everything needed, regardless of what you own).
-- Second return is true if some item info is still loading (try again in a moment).
local function CollectMats(entries)
  local need = {}
  for _, q in ipairs(entries) do
    local mats = {}
    if pcall(TSM_API.GetCraftingQueueItemMaterials, q.recipe, mats) then
      for itemString, qty in pairs(mats) do
        need[itemString] = (need[itemString] or 0) + qty * q.num
      end
    end
  end
  local out, loading = {}, false
  for itemString, num in pairs(need) do
    num = math.ceil(num)
    if num > 0 then
      local link, name, isLoading = ChatLink(itemString)
      if isLoading then loading = true end
      name = name or ItemName(itemString)
      -- Unlinkable (not a normal item): plain text, which chat always accepts
      out[#out + 1] = { link = link or name, name = name, num = num }
    end
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out, loading
end

-- Text you'd actually see in chat: link codes stripped, "[Black Pearl] x1"
local function VisibleText(s)
  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cnIQ%d:", ""):gsub("|cn[^:|]*:", "")
  s = s:gsub("|H.-|h", ""):gsub("|h", ""):gsub("|r", ""):gsub("|A.-|a", "")
  return s
end

-- Limits from the real chat box, so a part is exactly what you could type yourself.
-- Modern clients cap the *visible* text at 255 and allow more raw bytes for links.
local function ChatLimits()
  local editBox = (DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox) or ChatFrame1EditBox
  local visible, raw = MAX_CHAT, MAX_CHAT
  if editBox then
    local v = editBox.GetVisibleTextByteLimit and editBox:GetVisibleTextByteLimit()
    if v and v > 0 then
      visible = v
      local b = editBox.GetMaxBytes and editBox:GetMaxBytes()
      local l = editBox.GetMaxLetters and editBox:GetMaxLetters()
      raw = (b and b > 0 and b - 1) or (l and l > 0 and l) or 1000
    else
      local l = editBox.GetMaxLetters and editBox:GetMaxLetters()
      if l and l > 0 then visible, raw = l, l end
    end
  end
  return visible, raw
end

local function Fits(text, visibleLimit, rawLimit)
  return #text <= rawLimit and #VisibleText(text) <= visibleLimit
end

-- "Mats for [Item] x3: [Mat] x4, [Mat] x1" split into chat-sized parts.
-- Every mat shows its count, even x1. Later parts start with "(cont.)".
local function BuildParts(mats, prefix)
  local visibleLimit, rawLimit = ChatLimits()
  local parts, line, count = {}, prefix or "", 0
  for _, m in ipairs(mats) do
    local piece = m.link .. "x" .. m.num
    local candidate = count == 0 and (line .. piece) or (line .. ", " .. piece)
    if count > 0 and not Fits(candidate, visibleLimit, rawLimit) then
      parts[#parts + 1] = line
      line, count = "(cont.) " .. piece, 1
    else
      line, count = candidate, count + 1
    end
  end
  if count > 0 then parts[#parts + 1] = line end
  return parts
end

-- ============================================================================
-- Chat
-- ============================================================================

local GetActiveChat = ChatEdit_GetActiveWindow or (ChatFrameUtil and ChatFrameUtil.GetActiveWindow)
local GetLastChat = ChatEdit_GetLastActiveWindow or (ChatFrameUtil and ChatFrameUtil.GetLastActiveWindow)
local OpenChat = ChatFrame_OpenChat or (ChatFrameUtil and ChatFrameUtil.OpenChat)
local SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

local CHAT_LABELS = {
  SAY = "Say", YELL = "Yell", EMOTE = "Emote", PARTY = "Party", RAID = "Raid",
  RAID_WARNING = "Raid Warning", INSTANCE_CHAT = "Instance", GUILD = "Guild", OFFICER = "Officer",
}

-- The channel your chat box is set to right now (what Enter would send to)
local function CurrentChat()
  local editBox = (GetActiveChat and GetActiveChat()) or (GetLastChat and GetLastChat())
    or (DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox) or ChatFrame1EditBox
  if not editBox then return end
  local chatType = editBox:GetAttribute("chatType") or "SAY"
  local target, label
  if chatType == "WHISPER" or chatType == "BN_WHISPER" then
    target = editBox:GetAttribute("tellTarget")
    label = "whisper to " .. (target or "?")
  elseif chatType == "CHANNEL" then
    target = editBox:GetAttribute("channelTarget")
    local _, name = GetChannelName(target or 0)
    label = name and (target .. ". " .. name) or ("channel " .. tostring(target))
  else
    label = CHAT_LABELS[chatType] or chatType
  end
  return chatType, target, label
end

-- Fallback: drop the text in the chat box and let you press Enter
local function PutInChatBox(text)
  local editBox = GetActiveChat and GetActiveChat()
  if editBox then
    editBox:SetText(text)
  elseif OpenChat then
    OpenChat(text)
  else
    Print(text)
  end
end

-- Posts to your current channel. Returns a short description of where it went.
-- Must run from a click (hardware event): Say/Yell/Emote/channels require one.
local function Post(text, toChatBox)
  local chatType, target, label = CurrentChat()
  local canSend = SendChat and chatType and chatType ~= "BN_WHISPER"
    and not ((chatType == "WHISPER" or chatType == "CHANNEL") and not target)
  if toChatBox or not canSend then
    PutInChatBox(text)
    return nil
  end
  SendChat(text, chatType, nil, target)
  return label
end

local function LinkFor(key, toChatBox)
  local queue = GetQueue()
  local entries = {}
  if key == ALL_KEY then
    entries = queue
  else
    for _, q in ipairs(queue) do
      if q.recipe == key then entries[1] = q end
    end
  end
  if #entries == 0 then
    SetStatus("|cffff6666That's no longer in the queue.|r")
    ResetPending()
    return
  end

  if pendingKey ~= key or not pendingParts or pendingIndex >= #pendingParts then
    local mats, loading = CollectMats(entries)
    local prefix, prefixLoading = MessagePrefix(key, entries)
    if loading or prefixLoading then
      SetStatus("Loading item info from the server. Click again in a second.")
      ResetPending()
      return
    end
    if #mats == 0 then
      SetStatus("No materials found.")
      ResetPending()
      return
    end
    pendingParts, pendingKey, pendingIndex = BuildParts(mats, prefix), key, 0
  end

  pendingIndex = pendingIndex + 1
  local where = Post(pendingParts[pendingIndex], toChatBox)
  local total = #pendingParts
  local done = where and ("Posted to " .. where) or "In the chat box. Press Enter to send"
  if total == 1 then
    SetStatus(done .. ".")
  elseif pendingIndex < total then
    SetStatus(("Part %d of %d: %s. Click again for part %d."):format(pendingIndex, total, done, pendingIndex + 1))
  else
    SetStatus(("Last part (%d of %d): %s."):format(pendingIndex, total, done))
  end
end

-- ============================================================================
-- Popup
-- ============================================================================

local function GetRow(i)
  if rows[i] then return rows[i] end
  local row = CreateFrame("Button", nil, popup)
  row:SetHeight(ROW_H)
  row:SetPoint("TOPLEFT", popup, "TOPLEFT", 10, -56 - (i - 1) * ROW_H)
  row:SetPoint("RIGHT", popup, "RIGHT", -10, 0)
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  row.text:SetPoint("LEFT", 4, 0)
  row.text:SetPoint("RIGHT", -4, 0)
  row.text:SetJustifyH("LEFT")
  row.text:SetWordWrap(false)
  row:SetScript("OnClick", function(self)
    if self.key then LinkFor(self.key, IsShiftKeyDown()) end
  end)
  rows[i] = row
  return row
end

local function RefreshPopup()
  ResetPending()
  local queue = GetQueue()
  local shown = 0
  local function AddRow(text, key)
    shown = shown + 1
    local row = GetRow(shown)
    row.text:SetText(text)
    row.key = key
    row:SetEnabled(key ~= nil)
    row:Show()
  end

  if #queue == 0 then
    AddRow("|cff888888The crafting queue is empty.|r", nil)
  else
    if #queue > 1 then
      AddRow(("|cffffd100All queued items (%d crafts)|r"):format(#queue), ALL_KEY)
    end
    for i, q in ipairs(queue) do
      if shown >= MAX_ROWS then
        AddRow(("|cff888888+%d more (use All queued items)|r"):format(#queue - i + 1), nil)
        break
      end
      AddRow(CraftLabel(q) .. "  x" .. q.num, q.recipe)
    end
  end
  for i = shown + 1, #rows do rows[i]:Hide() end

  popup:SetHeight(56 + shown * ROW_H + 44)
  local _, _, label = CurrentChat()
  popup.sub:SetText("Click: post to your current chat (" .. (label or "?") .. "). Shift-click: chat box only.")
  SetStatus("")
end

local function CreatePopup()
  popup = CreateFrame("Frame", "TSMCraftLinksPopup", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  popup:SetSize(380, 120)
  popup:SetFrameStrata("DIALOG")
  popup:SetClampedToScreen(true)
  popup:EnableMouse(true)
  popup:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  popup:SetBackdropColor(0, 0, 0, 0.92)
  popup:Hide()
  tinsert(UISpecialFrames, "TSMCraftLinksPopup") -- Esc closes it

  local title = popup:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  title:SetPoint("TOPLEFT", 12, -10)
  title:SetText("Link mats (full list for the queued amount)")

  local close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 0, 0)

  local sub = popup:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
  sub:SetPoint("RIGHT", popup, "RIGHT", -12, 0)
  sub:SetJustifyH("LEFT")
  popup.sub = sub

  statusText = popup:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  statusText:SetPoint("BOTTOMLEFT", 12, 12)
  statusText:SetPoint("BOTTOMRIGHT", -12, 12)
  statusText:SetJustifyH("LEFT")

  popup:SetScript("OnShow", RefreshPopup)
end

local function TogglePopup()
  if popup:IsShown() then popup:Hide() return end
  popup:ClearAllPoints()
  if anchorFrame then
    popup:SetPoint("TOPLEFT", anchorFrame, "TOPRIGHT", 4, 0)
  else
    popup:SetPoint("CENTER")
  end
  popup:Show()
end

-- ============================================================================
-- Button on TSM's Crafting window
-- ============================================================================

local function CreateButton()
  button = CreateFrame("Button", nil, UIParent, "UIPanelButtonTemplate")
  button:SetSize(100, 22)
  button:SetText("Link Mats")
  button:SetScript("OnClick", TogglePopup)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(TITLE)
    GameTooltip:AddLine("Post the mats for a queued craft to your current chat.", 1, 1, 1)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", GameTooltip_Hide)
  button:Hide()
end

-- TSM calls this with (true, frame) when its Crafting window opens and (false) when it closes.
local function OnCraftingUI(shown, frame)
  if shown and frame then
    anchorFrame = frame
    button:ClearAllPoints()
    button:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -8, 2)
    button:SetFrameStrata(frame:GetFrameStrata())
    button:SetFrameLevel(frame:GetFrameLevel() + 20)
    button:Show()
  else
    anchorFrame = nil
    button:Hide()
    popup:Hide()
  end
end

-- ============================================================================
-- Events + slash command
-- ============================================================================

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self)
  self:UnregisterEvent("PLAYER_LOGIN") -- one-time setup
  CreatePopup()
  CreateButton()
  local ok, err = pcall(TSM_API.RegisterUICallback, "CRAFTING", "TSMCraftLinks:LinkMatsButton", OnCraftingUI)
  if not ok then Print("Couldn't attach to TSM's Crafting window: " .. tostring(err)) end
end)

SLASH_TSMCRAFTLINKS1 = "/tcl"
SlashCmdList.TSMCRAFTLINKS = function(msg)
  if strtrim(msg or ""):lower() == "debug" then
    local editBox = (DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox) or ChatFrame1EditBox
    local function Call(name) return editBox and editBox[name] and editBox[name](editBox) end
    local visible, raw = ChatLimits()
    Print(("Chat box: visibleLimit=%s maxBytes=%s maxLetters=%s -> using visible %d, raw %d")
      :format(tostring(Call("GetVisibleTextByteLimit")), tostring(Call("GetMaxBytes")),
        tostring(Call("GetMaxLetters")), visible, raw))
    return
  end
  if popup then TogglePopup() end
end
