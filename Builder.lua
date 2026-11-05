-- Pure macro-text generation. No UI and no game state beyond what's passed in,
-- so it can be tested outside the client.
local _, ns = ...
ns = ns or {}

local Builder = {}
ns.Builder = Builder

Builder.MAX_LENGTH = 255

-- Targeting modes, in the order the UI cycles through them.
Builder.TARGET_MODES = {
	{ key = "target",        label = "Current target" },
	{ key = "mouseover",     label = "Mouseover > target" },
	{ key = "mouseoverself", label = "Mouseover > target > self" },
	{ key = "cursor",        label = "At cursor (ground)" },
	{ key = "focus",         label = "Focus > target" },
	{ key = "self",          label = "Self" },
}

-- Modifier rows get two extra modes: disabled, and "same targeting as the main spell".
Builder.MOD_MODES = { { key = "off", label = "Off" }, { key = "same", label = "Same targeting" } }
for _, mode in ipairs(Builder.TARGET_MODES) do
	table.insert(Builder.MOD_MODES, mode)
end

Builder.MODIFIERS = { "shift", "ctrl", "alt" }

-- kind is "harm", "help" or nil (neutral / both).
local function UnitCondition(kind)
	if kind == "harm" or kind == "help" then
		return kind .. ",nodead"
	end
	return "exists,nodead"
end

-- Returns the list of conditional groups for a targeting mode. Each entry is the text
-- inside one pair of brackets; "" means an unconditional group.
function Builder.TargetGroups(mode, kind)
	local cond = UnitCondition(kind)
	-- Self-cast fallback makes no sense for offensive spells (e.g. a modifier
	-- row inheriting a heal's targeting).
	if mode == "mouseoverself" and kind == "harm" then
		mode = "mouseover"
	end
	if mode == "mouseover" then
		return { "@mouseover," .. cond, "" }
	elseif mode == "mouseoverself" then
		return { "@mouseover," .. cond, cond, "@player" }
	elseif mode == "cursor" then
		return { "@cursor" }
	elseif mode == "focus" then
		return { "@focus," .. cond, "" }
	elseif mode == "self" then
		return { "@player" }
	end
	return { "" }
end

-- Renders one "/cast" clause: conditional groups (each prefixed with an optional
-- modifier condition) followed by the action name.
local function Clause(groups, prefix, action)
	if not prefix and #groups == 1 and groups[1] == "" then
		return action
	end
	local parts = {}
	for i, group in ipairs(groups) do
		local cond = prefix or ""
		if group ~= "" then
			cond = (cond ~= "" and (cond .. ",") or "") .. group
		end
		parts[i] = "[" .. cond .. "]"
	end
	return table.concat(parts) .. " " .. action
end

-- action = { name = "Fireball", rank = "Rank 3", kind = "harm", isItem = false }
function Builder.ActionText(action, lockRank)
	if lockRank and action.rank and action.rank:find("%d") then
		return action.name .. "(" .. action.rank .. ")"
	end
	return action.name
end

--[[
opts = {
	main = action,
	lockRank = bool,
	target = mode key,
	showTooltip, startAttack, stopCasting, petAttack, trinket13, trinket14 = bool,
	startShoot = bool, shootName = auto-repeat ranged spell (default "Shoot"),
	mods = { shift = { action = action|nil, target = mod mode key }, ... },
}
Returns the macro body, or nil when there's no main action.
]]
function Builder.Build(opts)
	local main = opts.main
	if not main then
		return nil
	end

	local lines = {}
	if opts.showTooltip then
		lines[#lines + 1] = "#showtooltip"
	end
	if opts.stopCasting then
		lines[#lines + 1] = "/stopcasting"
	end
	if opts.trinket13 then
		lines[#lines + 1] = "/use 13"
	end
	if opts.trinket14 then
		lines[#lines + 1] = "/use 14"
	end
	if opts.startAttack then
		lines[#lines + 1] = "/startattack"
	end
	if opts.petAttack then
		lines[#lines + 1] = "/petattack"
	end

	-- Modifier clauses come first: the first matching clause wins.
	local clauses = {}
	local usesItem = main.isItem
	for _, mod in ipairs(Builder.MODIFIERS) do
		local row = opts.mods and opts.mods[mod]
		if row and row.target and row.target ~= "off" then
			local action = row.action or main
			local mode = row.target == "same" and opts.target or row.target
			usesItem = usesItem or action.isItem
			clauses[#clauses + 1] = Clause(Builder.TargetGroups(mode, action.kind), "mod:" .. mod,
				Builder.ActionText(action, opts.lockRank))
		end
	end
	clauses[#clauses + 1] = Clause(Builder.TargetGroups(opts.target, main.kind), nil,
		Builder.ActionText(main, opts.lockRank))

	-- /use handles both items and spells, so switch to it if any clause is an item.
	lines[#lines + 1] = (usesItem and "/use " or "/cast ") .. table.concat(clauses, "; ")

	-- After the main cast: wand Shoot triggers the global cooldown, so putting it
	-- first would block the spell. "!" stops a second press toggling it off.
	if opts.startShoot then
		lines[#lines + 1] = "/cast !" .. (opts.shootName or "Shoot")
	end

	return table.concat(lines, "\n")
end

return Builder
