--[[
    CompassLoc | compassloc.lua
    Author: Mage

    Overview: Release addon entry point: draggable anchor, per-character settings and
              lifecycle.
    Scope: Exposes positioning controls only; delegates writes to the guarded native backend.
]]

addon.name = 'compassloc'
addon.author = 'Mage'
addon.version = '1.0'
addon.desc = 'Reposition the native FFXI compass with a saved draggable anchor.'

require('common')
local bit = require('bit')
local settings = require('settings')
local core = require('core')
local memory = require('safe_memory')
local config = settings.load(T({
    module = 'FFXiMain.dll',
    enabled = false,
    positioned = false,
    ax = 0,
    ay = 0,
    anchor = T({ x = 0, y = 0 }),
}))
local imgui = require('imgui')
local position = require('position')
local ui = { false }
local dirty, suspended, last_object, last_width, last_height, last_check =
    false, false, nil, nil, nil, 0
local image, anchor = nil, nil

local function say(message)
    print('[CompassLoc] ' .. message)
end

local function restore_native(restore_layout)
    if anchor then
        say(anchor:release(restore_layout))
        anchor = nil
    end
end

settings.register('settings', 'compassloc_settings', function(s)
    local ok, err = pcall(restore_native, false)
    if not ok then
        say('Restoration refused: ' .. tostring(err))
        suspended = true
        return
    end
    ui[1], dirty, suspended, last_object = false, false, false, nil
    config = s
    image = nil
end)

local function scan()
    image = nil
    local base = ashita.memory.get_base(config.module)
    assert(base and base ~= 0, 'Module not loaded: ' .. config.module)
    image = core.image(memory.read, base)
end

local function viewport()
    local size = imgui.GetIO().DisplaySize
    local w, h = position.xy(size)
    if not w or not h or w <= 1 or h <= 1 then
        return nil, nil
    end
    assert(w <= 32768 and h <= 32768, 'Viewport outside native coordinate range')
    return w, h
end

local function enable()
    assert(not suspended, 'Override suspended after an error; use /cloc disable then /cloc enable')
    assert(
        AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus() == 2,
        'Requires a fully logged-in character'
    )

    if not image then
        scan()
    end

    if not anchor then
        anchor = require('native').new(image, memory.read)
    end

    if anchor:object() == 0 then
        return false, 'Discovered compass global holds a null object; retry after login/zoning'
    end

    local object, x, y = anchor:position()
    local w, h = viewport()
    if not w then
        return false, 'ImGui viewport unavailable; check display initialization'
    end

    if not config.positioned then
        config.ax, config.ay = position.normalize(x, y, w, h)
        config.positioned = true
    end

    x, y = position.resolve(config.ax, config.ay, w, h)
    if not anchor.active then
        say(anchor:start(x, y))
    else
        anchor:move(x, y)
    end

    last_object, last_width, last_height = object, w, h
    config.anchor.x, config.anchor.y = x, y
    config.enabled = true
    return true
end

local function require_enable()
    local ok, reason = enable()
    assert(ok, reason)
end

local function disable()
    restore_native()
    config.enabled = false
    suspended = false
    ui[1] = false
    settings.save()
    dirty = false
end

local function move(x, y)
    local w, h = viewport()
    assert(w, 'Viewport unavailable')
    config.ax, config.ay = position.normalize(x, y, w, h)
    config.positioned = true
    local tx, ty = position.resolve(config.ax, config.ay, w, h)
    assert(anchor and anchor.active, 'Enable the anchor first')
    anchor:move(tx, ty)
    config.anchor.x, config.anchor.y = tx, ty
    dirty = os.time()
end

local function help()
    say('/cloc or /compassloc: toggle the draggable anchor; close to keep your position.')
    say('/cloc enable; disable; reset; set <x> <y>; help')
end

ashita.events.register('d3d_present', 'compassloc_present', function()
    local ok, err = pcall(function()
        if dirty and os.time() > dirty then
            settings.save()
            dirty = false
        end

        if os.clock() - last_check >= 0.5 then
            last_check = os.clock()
            if AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus() ~= 2 then
                if anchor then
                    restore_native(false)
                end
                last_object = nil
            elseif config.enabled and not suspended then
                if not anchor or not anchor.active then
                    enable()
                end

                if not anchor or not anchor.active or anchor:object() == 0 then
                    return
                end

                local object = anchor:position()
                local w, h = viewport()
                if not w then
                    return
                end

                if w ~= last_width or h ~= last_height then
                    enable()
                elseif object ~= last_object then
                    anchor:apply()
                    last_object = object
                end
            end
        end

        if not ui[1] or AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus() ~= 2 then
            return
        end

        if not anchor or not anchor.active or anchor:object() == 0 then
            return
        end

        local w, h = viewport()
        if not w then
            return
        end

        local x, y = position.resolve(config.ax, config.ay, w, h)

        -- Keep the control reachable; its button controls the native anchor,
        -- which is independent of this panel's clipped screen position.
        imgui.SetNextWindowPos(
            { math.max(0, math.min(x, w - 270)), math.max(0, math.min(y, h - 155)) },
            ImGuiCond_Always
        )
        imgui.SetNextWindowSize({ 270, 155 }, ImGuiCond_Always)
        local visible = imgui.Begin(
            'CompassLoc anchor',
            ui,
            bit.bor(
                ImGuiWindowFlags_NoResize,
                ImGuiWindowFlags_NoMove,
                ImGuiWindowFlags_NoSavedSettings
            )
        )
        local drawn, draw_err = pcall(function()
            if visible then
                imgui.Text(('Native origin: %d, %d'):format(x, y))
                imgui.Button('Drag here to move compass', { 245, 32 })
                if imgui.IsItemActive() and anchor and anchor.active then
                    local dx, dy = position.xy(imgui.GetIO().MouseDelta)
                    if dx ~= 0 or dy ~= 0 then
                        move(x + dx, y + dy)
                    end
                end
                imgui.Text('Close: keep position.')
                imgui.Text('/cloc disable: restore native.')
                if imgui.Button('Restore native position') then
                    disable()
                end
            end
        end)
        imgui.End()
        assert(drawn, draw_err)
    end)
    if not ok and not suspended then
        suspended = true
        ui[1] = false
        say('Anchor suspended: ' .. tostring(err))
        local restored, why = pcall(restore_native, false)
        if not restored then
            say('Restoration refused: ' .. tostring(why))
        end
    end
end)

ashita.events.register('load', 'compassloc_load', function()
    help()
    local ok, err = pcall(scan)
    if not ok then
        say('Scan refused: ' .. tostring(err))
    end
end)

ashita.events.register('command', 'compassloc_command', function(e)
    local args = e.command:args()
    if #args == 0 then
        return
    end
    local name = args[1]:lower()
    if name ~= '/cloc' and name ~= '/compassloc' then
        return
    end
    e.blocked = true
    local ok, err = pcall(function()
        local command = (args[2] or 'toggle'):lower()
        if command == 'toggle' and #args <= 2 then
            if not ui[1] then
                require_enable()
                settings.save()
            end
            ui[1] = not ui[1]
        elseif command == 'enable' and #args == 2 then
            require_enable()
            settings.save()
        elseif command == 'disable' and #args == 2 then
            disable()
        elseif command == 'set' and #args == 4 then
            local x, y = tonumber(args[3]), tonumber(args[4])
            assert(x and y, 'Coordinates must be numeric')
            require_enable()
            move(x, y)
            settings.save()
            dirty = false
        elseif command == 'reset' and #args == 2 then
            disable()
            config.positioned = false
            config.ax = 0
            config.ay = 0
            config.anchor.x = 0
            config.anchor.y = 0
            settings.save()
            say('Saved anchor reset; native positioning restored.')
        elseif command == 'help' and #args <= 2 then
            help()
        else
            error('Invalid syntax; use /cloc help')
        end
    end)
    if not ok then
        say('Operation refused: ' .. tostring(err))
    end
end)

ashita.events.register('unload', 'compassloc_unload', function()
    local ok, err = pcall(restore_native)
    if not ok then
        say('Restoration refused: ' .. tostring(err))
    end
    image = nil
    settings.save()
end)
