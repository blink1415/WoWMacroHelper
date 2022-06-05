SLASH_MACROHELPER1 = "/macrohelper"

SLASH_STARTATTACK1 = "/attackmacro"
SLASH_TARGET1 = "/targetmacro"

local function createStartAttack(ability)
    print("Creating macro for " .. ability)
    local macro = [[
#showtooltip
/startattack 
]]
    macro = macro .. "/cast " .. ability
    local id, err = pcall(CreateMacro, ability, "INV_Misc_QuestionMark", macro, 1)

    if id ~= true then
        print("Unable to create macro. There's possibly too many character-specific macros already created.")
    end
end

local function createTarget(target)
    print("Creating macro for " .. target)
    macro = "/target " .. target
    macro = macro .. "/run SetRaidTarget('target', 8);"
    local id, err = pcall(CreateMacro, target, "INV_Misc_QuestionMark", macro, 1)

    if id ~= true then
        print("Unable to create macro. There's possibly too many character-specific macros already created.")
    end
end

local function printHelp()
    print("/attackmacro [ability] - Creates a new startattack macro for given ability")
    print("/targetmacro [targetName] - Creates a new target macro for given target")
end

SlashCmdList["MACROHELPER"] = printHelp
SlashCmdList["STARTATTACK"] = createStartAttack
SlashCmdList["TARGET"] = createTarget
