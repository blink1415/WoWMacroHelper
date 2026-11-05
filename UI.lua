local ADDON, ns = ...
local Builder = ns.Builder

local PANEL_WIDTH, PANEL_HEIGHT = 270, 482
local ICON_QUESTION_MARK = 134400
local MACRO_NAME_MAX = 16
local EMPTY_SLOT_TEXTURE = "Interface\\PaperDoll\\UI-Backpack-EmptySlot"

-- Ground-targeted spells (first rank IDs; ranks share a name). Resolved to
-- localized names on first use.
local GROUND_SPELL_IDS = {
	10,    -- Blizzard
	2120,  -- Flamestrike
	5740,  -- Rain of Fire
	16914, -- Hurricane
	1510,  -- Volley
	1543,  -- Flare
}

-- Classes that want /startattack on by default for offensive spells.
local MELEE_CLASSES = { WARRIOR = true, ROGUE = true, PALADIN = true }

-- Auto-repeat ranged attack: hunters use Auto Shot, everyone else wand Shoot.
local AUTO_SHOT_ID, SHOOT_ID = 75, 5019

local IsAddOnLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
local LoadAddOn = C_AddOns and C_AddOns.LoadAddOn or LoadAddOn

-- WoW Forever (16001) only exposes the macro slot limits through Constants;
-- Classic Era still has the old globals.
local MACRO_CONSTS = Constants and Constants.MacroConsts
local MAX_ACCOUNT = (MACRO_CONSTS and MACRO_CONSTS.MAX_ACCOUNT_MACROS) or MAX_ACCOUNT_MACROS or 120
local MAX_CHARACTER = (MACRO_CONSTS and MACRO_CONSTS.MAX_CHARACTER_MACROS) or MAX_CHARACTER_MACROS or 18

local playerClass
local panel

local state = {
	main = nil,
	lockRank = false,
	target = "target",
	showTooltip = true,
	startAttack = false,
	stopCasting = false,
	petAttack = false,
	startShoot = false,
	shootName = "Shoot",
	trinket13 = false,
	trinket14 = false,
	mods = {
		shift = { target = "off" },
		ctrl = { target = "off" },
		alt = { target = "off" },
	},
}

local function Print(msg)
	print("|cff33ff99Macro Helper:|r " .. msg)
end

local groundNames
local function IsGroundTargeted(name)
	if not groundNames then
		groundNames = {}
		for _, id in ipairs(GROUND_SPELL_IDS) do
			local info = C_Spell.GetSpellInfo(id)
			if info then
				groundNames[info.name] = true
			end
		end
	end
	return groundNames[name] or false
end

local function SpellAction(spellID)
	local info = spellID and C_Spell.GetSpellInfo(spellID)
	if not info then
		return nil
	end
	local harm = C_Spell.IsSpellHarmful(spellID)
	local help = C_Spell.IsSpellHelpful(spellID)
	return {
		name = info.name,
		icon = info.iconID,
		rank = C_Spell.GetSpellSubtext(spellID),
		kind = (harm and not help and "harm") or (help and not harm and "help") or nil,
		ground = IsGroundTargeted(info.name),
	}
end

local function ItemAction(itemID, link)
	local name = (link and link:match("%[(.-)%]")) or C_Item.GetItemNameByID(itemID)
	if not name then
		return nil
	end
	return { name = name, icon = C_Item.GetItemIconByID(itemID), isItem = true }
end

local function ActionFromCursor()
	local cursorType, a, b, c = GetCursorInfo()
	if cursorType == "spell" then
		-- Returns "spell", bookSlot, bookType, spellID.
		local spellID = c
		if not spellID and GetSpellBookItemInfo then
			spellID = select(2, GetSpellBookItemInfo(a, b))
		end
		return SpellAction(spellID)
	elseif cursorType == "item" then
		return ItemAction(a, b)
	end
end

local function CurrentBody()
	return Builder.Build(state)
end

local function SetMain(action)
	state.main = action
	if action then
		-- Sensible defaults for the new spell; the user can change them after.
		if action.ground then
			state.target = "cursor"
		elseif action.kind == "harm" then
			state.target = "mouseover"
		elseif action.kind == "help" then
			state.target = "mouseoverself"
		else
			state.target = "target"
		end
		state.startAttack = action.kind == "harm" and MELEE_CLASSES[playerClass] or false
		state.startShoot = action.kind == "harm" and playerClass == "HUNTER" or false
	end
	panel:Refresh()
end

-- Panel actions --------------------------------------------------------------

local function SelectedMacroIndex()
	local index = MacroFrame:GetSelectedIndex()
	local count = select(PanelTemplates_GetSelectedTab(MacroFrame), GetNumMacros())
	if index and index <= count then
		return index
	end
end

local function SaveToSelected()
	if InCombatLockdown() then
		Print("Macros can't be edited in combat.")
		return
	end
	if not SelectedMacroIndex() then
		Print("Select a macro on the left first, or use New Macro.")
		return
	end
	-- Go through Blizzard's editor so its save path and display stay in sync.
	MacroFrameText:SetText(CurrentBody())
	MacroFrame.textChanged = 1
	MacroFrame:SaveMacro()
end

local function CreateNewMacro()
	if InCombatLockdown() then
		Print("Macros can't be created in combat.")
		return
	end
	MacroFrame:SaveMacro()

	local perCharacter = PanelTemplates_GetSelectedTab(MacroFrame) == 2
	local numAccount, numCharacter = GetNumMacros()
	if (perCharacter and numCharacter >= MAX_CHARACTER)
		or (not perCharacter and numAccount >= MAX_ACCOUNT) then
		Print("No free macro slots on this tab.")
		return
	end

	-- Trim to the name limit without leaving half a UTF-8 character.
	local name = state.main.name
	if #name > MACRO_NAME_MAX then
		name = name:sub(1, MACRO_NAME_MAX):gsub("[\192-\255][\128-\191]*$", "")
	end

	local index = CreateMacro(name, ICON_QUESTION_MARK, CurrentBody(), perCharacter)
	MacroFrame:Update()
	if index then
		MacroFrame:SelectMacro(index - MacroFrame.macroBase, true)
		Print(("Created macro \"%s\". Drag its icon to your action bar."):format(name))
	end
end

-- Widgets ----------------------------------------------------------------------

local function SetTooltip(frame, title, text)
	frame:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title)
		if text then
			GameTooltip:AddLine(text, 1, 1, 1, true)
		end
		GameTooltip:Show()
	end)
	frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- A drop target for spells and items. Right-click clears it.
local function CreateSlot(parent, size, onChange)
	local slot = CreateFrame("Button", nil, parent)
	slot:SetSize(size, size)
	slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	slot.icon = slot:CreateTexture(nil, "ARTWORK")
	slot.icon:SetAllPoints()
	slot:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

	local function Accept()
		local action = ActionFromCursor()
		if action then
			ClearCursor()
			onChange(action)
		end
	end
	slot:SetScript("OnReceiveDrag", Accept)
	slot:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			onChange(nil)
		elseif GetCursorInfo() then
			Accept()
		end
	end)

	function slot:SetDisplay(action, placeholder)
		if action then
			self.icon:SetTexture(action.icon or ICON_QUESTION_MARK)
			self.icon:SetDesaturated(false)
			self.icon:SetAlpha(1)
		elseif placeholder then
			self.icon:SetTexture(placeholder.icon or ICON_QUESTION_MARK)
			self.icon:SetDesaturated(true)
			self.icon:SetAlpha(0.4)
		else
			self.icon:SetTexture(EMPTY_SLOT_TEXTURE)
			self.icon:SetDesaturated(false)
			self.icon:SetAlpha(1)
		end
	end

	return slot
end

-- A button that cycles through modes: left-click forward, right-click back.
local function CreateCycle(parent, width, modes, get, set)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, 22)
	button:SetNormalFontObject("GameFontNormalSmall")
	button:SetHighlightFontObject("GameFontHighlightSmall")
	button:SetDisabledFontObject("GameFontDisableSmall")
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:SetScript("OnClick", function(_, mouseButton)
		local current = 1
		for i, mode in ipairs(modes) do
			if mode.key == get() then
				current = i
			end
		end
		local step = mouseButton == "RightButton" and -1 or 1
		set(modes[(current - 1 + step) % #modes + 1].key)
		panel:Refresh()
	end)

	function button:Refresh()
		for _, mode in ipairs(modes) do
			if mode.key == get() then
				self:SetText(mode.label)
			end
		end
	end

	return button
end

local function CreateCheck(parent, label, key, tooltip)
	local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	check:SetSize(22, 22)
	check.Text:SetFontObject("GameFontHighlightSmall")
	check.Text:SetText(label)
	check:SetScript("OnClick", function(self)
		state[key] = self:GetChecked() and true or false
		panel:Refresh()
	end)
	function check:Refresh()
		self:SetChecked(state[key])
	end
	SetTooltip(check, label, tooltip)
	return check
end

-- Panel ------------------------------------------------------------------------

local function Reanchor()
	if not panel then
		return
	end
	-- If another panel (usually the spellbook) sits right of the macro window,
	-- move past it so dragging spells across isn't blocked.
	local anchor = MacroFrame
	local center = GetUIPanel and GetUIPanel("center")
	if center and center ~= MacroFrame and center:IsShown() and GetUIPanel("left") == MacroFrame then
		anchor = center
	end
	panel:ClearAllPoints()
	panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 2, 0)
end

local function CreatePanel()
	panel = CreateFrame("Frame", "MacroHelperPanel", MacroFrame, "BackdropTemplate")
	panel:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
	panel:SetClampedToScreen(true)
	panel:EnableMouse(true)
	panel:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("TOP", 0, -16)
	title:SetText("Macro Helper")

	-- Main spell
	local mainSlot = CreateSlot(panel, 40, SetMain)
	mainSlot:SetPoint("TOPLEFT", 18, -36)
	SetTooltip(mainSlot, "Main ability",
		"Drag a spell (from your spellbook or action bars) or an item here. Right-click to clear.")

	local mainName = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	mainName:SetPoint("TOPLEFT", mainSlot, "TOPRIGHT", 8, -4)
	mainName:SetWidth(PANEL_WIDTH - 90)
	mainName:SetJustifyH("LEFT")
	mainName:SetWordWrap(false)

	local mainInfo = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	mainInfo:SetPoint("TOPLEFT", mainName, "BOTTOMLEFT", 0, -4)
	mainInfo:SetJustifyH("LEFT")

	local input = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	input:SetSize(140, 20)
	input:SetPoint("TOPLEFT", 24, -82)
	input:SetAutoFocus(false)
	local inputHint = input:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	inputHint:SetPoint("LEFT", 2, 0)
	inputHint:SetText("or type a spell name")
	local function UpdateHint()
		inputHint:SetShown(input:GetText() == "" and not input:HasFocus())
	end
	input:SetScript("OnEditFocusGained", UpdateHint)
	input:SetScript("OnEditFocusLost", UpdateHint)
	input:SetScript("OnTextChanged", UpdateHint)
	input:SetScript("OnEscapePressed", input.ClearFocus)
	input:SetScript("OnEnterPressed", function(self)
		local text = strtrim(self:GetText())
		local info = text ~= "" and C_Spell.GetSpellInfo(text)
		if info then
			SetMain(SpellAction(info.spellID))
			self:SetText("")
			self:ClearFocus()
		else
			Print(("Unknown spell \"%s\"."):format(text))
		end
	end)

	local lockRank = CreateCheck(panel, "Lock rank", "lockRank",
		"Cast this exact rank (e.g. for downranked heals) instead of the highest you know.")
	lockRank:SetPoint("LEFT", input, "RIGHT", 6, 0)

	-- Targeting
	local targetLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	targetLabel:SetPoint("TOPLEFT", 18, -112)
	targetLabel:SetText("Target")
	local targetCycle = CreateCycle(panel, 190, Builder.TARGET_MODES,
		function() return state.target end,
		function(value) state.target = value end)
	targetCycle:SetPoint("TOPLEFT", 62, -106)
	SetTooltip(targetCycle, "Targeting",
		"Who the spell is cast on, tried left to right. Left-click for the next option, right-click for the previous.")

	-- Extra lines
	local checks = {
		CreateCheck(panel, "#showtooltip", "showTooltip", "Show the spell's icon and tooltip on the action bar."),
		CreateCheck(panel, "/startattack", "startAttack", "Start melee auto-attack on your target."),
		CreateCheck(panel, "/stopcasting", "stopCasting", "Cancel your current cast first. Good for interrupts."),
		CreateCheck(panel, "/petattack", "petAttack", "Send your pet in."),
		CreateCheck(panel, "Trinket 1", "trinket13", "/use 13: use your top trinket first."),
		CreateCheck(panel, "Trinket 2", "trinket14", "/use 14: use your bottom trinket first."),
		CreateCheck(panel, "Start shooting", "startShoot",
			"Start your wand (or Auto Shot for hunters) after the spell. Uses ! so pressing it again won't stop shooting."),
	}
	for i, check in ipairs(checks) do
		local column = (i - 1) % 2
		local row = math.floor((i - 1) / 2)
		check:SetPoint("TOPLEFT", 16 + column * 120, -134 - row * 22)
	end

	-- Modifier rows
	local modHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	modHeader:SetPoint("TOPLEFT", 18, -228)
	modHeader:SetText("Modifier keys")

	local modRows = {}
	for i, mod in ipairs(Builder.MODIFIERS) do
		local y = -244 - (i - 1) * 26
		local row = state.mods[mod]

		local label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		label:SetPoint("TOPLEFT", 18, y - 6)
		label:SetText(mod:sub(1, 1):upper() .. mod:sub(2))

		local slot = CreateSlot(panel, 22, function(action)
			row.action = action
			if action and row.target == "off" then
				row.target = "same"
			end
			panel:Refresh()
		end)
		slot:SetPoint("TOPLEFT", 56, y)
		SetTooltip(slot, "Spell while holding " .. mod,
			"Drag a different spell or item here, or leave empty to use the main ability. Right-click to clear.")

		local cycle = CreateCycle(panel, 170, Builder.MOD_MODES,
			function() return row.target end,
			function(value) row.target = value end)
		cycle:SetPoint("TOPLEFT", 84, y)

		modRows[mod] = { slot = slot, cycle = cycle }
	end

	-- Preview
	local previewLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	previewLabel:SetPoint("TOPLEFT", 18, -328)
	previewLabel:SetText("Preview")

	local counter = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	counter:SetPoint("TOPRIGHT", -18, -328)

	local previewBox = CreateFrame("Frame", nil, panel, "TooltipBackdropTemplate")
	previewBox:SetPoint("TOPLEFT", 14, -342)
	previewBox:SetPoint("BOTTOMRIGHT", -14, 42)

	local preview = previewBox:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	preview:SetPoint("TOPLEFT", 8, -8)
	preview:SetPoint("BOTTOMRIGHT", -8, 8)
	preview:SetJustifyH("LEFT")
	preview:SetJustifyV("TOP")

	-- Buttons
	local saveButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	saveButton:SetSize(116, 22)
	saveButton:SetPoint("BOTTOMLEFT", 16, 16)
	saveButton:SetText("Save to Selected")
	saveButton:SetScript("OnClick", SaveToSelected)
	SetTooltip(saveButton, "Save to Selected", "Replace the text of the macro selected on the left.")

	local newButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	newButton:SetSize(116, 22)
	newButton:SetPoint("BOTTOMRIGHT", -16, 16)
	newButton:SetText("New Macro")
	newButton:SetScript("OnClick", CreateNewMacro)
	SetTooltip(newButton, "New Macro", "Create a new macro on the current tab (General or Character).")

	function panel:Refresh()
		local main = state.main
		mainSlot:SetDisplay(main)
		if main then
			mainName:SetText(main.name)
			local details = main.isItem and "Item"
				or (main.kind == "harm" and "Offensive")
				or (main.kind == "help" and "Helpful")
				or "Neutral"
			if main.rank and main.rank ~= "" then
				details = details .. ", " .. main.rank
			end
			mainInfo:SetText(details)
		else
			mainName:SetText("Drag a spell here")
			mainInfo:SetText("")
		end

		local hasRank = main and main.rank and main.rank:find("%d")
		lockRank:SetEnabled(hasRank and true or false)
		lockRank:Refresh()
		targetCycle:Refresh()
		for _, check in ipairs(checks) do
			check:Refresh()
		end
		for mod, widgets in pairs(modRows) do
			widgets.slot:SetDisplay(state.mods[mod].action, main)
			widgets.cycle:Refresh()
		end

		local body = CurrentBody()
		if body then
			local length = #body
			preview:SetText(body)
			counter:SetText(("%d / %d"):format(length, Builder.MAX_LENGTH))
			if length > Builder.MAX_LENGTH then
				counter:SetTextColor(1, 0.2, 0.2)
			else
				counter:SetTextColor(1, 1, 1)
			end
		else
			preview:SetText("")
			counter:SetText("")
		end
		local valid = body ~= nil and #body <= Builder.MAX_LENGTH
		saveButton:SetEnabled(valid)
		newButton:SetEnabled(valid)
	end

	panel:SetScript("OnShow", Reanchor)
	panel:SetShown(not MacroHelperDB.hidden)
	Reanchor()
	panel:Refresh()

	if UpdateUIPanelPositions then
		hooksecurefunc("UpdateUIPanelPositions", Reanchor)
	end

	-- Toggle button in the gap of the macro window's bottom button row.
	local toggle = CreateFrame("Button", nil, MacroFrame, "UIPanelButtonTemplate")
	toggle:SetSize(80, 22)
	toggle:SetPoint("LEFT", MacroDeleteButton, "RIGHT", 4, 0)
	toggle:SetText("Helper")
	toggle:SetScript("OnClick", function()
		panel:SetShown(not panel:IsShown())
		MacroHelperDB.hidden = not panel:IsShown()
	end)
end

-- Loading ----------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, _, name)
	if name == ADDON then
		MacroHelperDB = MacroHelperDB or {}
		playerClass = select(2, UnitClass("player"))
		local shootID = playerClass == "HUNTER" and AUTO_SHOT_ID or SHOOT_ID
		local shootInfo = C_Spell.GetSpellInfo(shootID)
		state.shootName = (shootInfo and shootInfo.name)
			or (playerClass == "HUNTER" and "Auto Shot" or "Shoot")
		if IsAddOnLoaded("Blizzard_MacroUI") then
			CreatePanel()
		end
	elseif name == "Blizzard_MacroUI" and MacroHelperDB and not panel then
		CreatePanel()
	end
end)

SLASH_MACROHELPER1 = "/macrohelper"
SlashCmdList.MACROHELPER = function()
	if not MacroFrame then
		if MacroFrame_LoadUI then
			MacroFrame_LoadUI()
		elseif UIParentLoadAddOn then
			UIParentLoadAddOn("Blizzard_MacroUI")
		else
			LoadAddOn("Blizzard_MacroUI")
		end
	end
	if not MacroFrame then
		Print("Couldn't load the macro window.")
		return
	end
	ShowUIPanel(MacroFrame)
	if panel then
		panel:Show()
		MacroHelperDB.hidden = false
	end
end
