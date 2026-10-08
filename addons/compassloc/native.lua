--[[
    CompassLoc | native.lua
    Author: Mage

    Overview: Installs, updates and restores the native compass-origin override.
    Scope: Changes only guarded X/Y setter input bytes and reads six origin/layout bytes.
]]

local core = require('core')
local layout = core.layout
local M = {}
local function le(value, n)
    local s = ''
    for _ = 1, n do
        s = s .. string.char(value % 256)
        value = math.floor(value / 256)
    end
    return s
end

-- Share the exact original instruction recipe used for discovery.
local setter = require('discovery').setter
local function patch(value)
    -- Unchanged branch displacement + MOV CX,imm16 + NOP + store prefix.
    -- The five-byte source-load region and following store boundary are preserved.
    return string.char(0x09, 0x66, 0xB9) .. le(value, 2) .. string.char(0x90, 0x66, 0x89)
end

function M.new(image, read, swap, call, native_y)
    local native = require('discovery').resolve(image, read)
    local state = { owned = {}, active = false, original = nil }

    -- Discovered A1 operand: global compass-object pointer slot (read-only).
    local slot = native.slot

    -- Each setter is matched against the same discovered global slot and its
    -- specific object-field store. Only these two instruction sites may be changed.
    local axes = {
        { name = 'x', address = native.x_setter, field = layout.x },
        { name = 'y', address = native.y_setter, field = layout.y },
    }

    local function validate()
        native:validate()
        for i, a in ipairs(axes) do
            local original = setter(slot, a.field)
            local wanted = original
            if state.owned[i] then
                wanted = original:sub(1, layout.setter_patch_offset)
                    .. state.owned[i]
                    .. original:sub(layout.setter_patch_offset + layout.setter_patch_size + 1)
            end
            assert(
                read(a.address, #wanted) == wanted,
                'Setter ownership/expected-byte mismatch: ' .. a.name
            )
        end
    end

    local function current()
        local object = core.u32(read(slot, 4), 1)
        assert(object ~= 0, 'Compass object is null; retry after zoning/login')
        -- Copy only the native X, Y and drawing-offset WORDs (+0x28..+0x2D).
        local bytes = read(object + layout.x, layout.origin_size)
        assert(core.u32(read(slot, 4), 1) == object, 'Compass object changed during read')
        -- This copy starts at object +0x28, so the WORD indices are 1, 3 and 5.
        local x, y = core.u16(bytes, 1), core.u16(bytes, 3)
        assert(
            x <= 32767 and y <= 32767 and core.u16(bytes, 5) == layout.expected_draw_offset_y,
            'Unexpected compass layout'
        )
        return object, x, y
    end

    if not swap then
        swap = require('atomic_patch').swap
    end

    if not call or not native_y then
        local ffi = require('ffi')
        -- Complete guarded cdecl setters write only object +0x28/+0x2A.
        -- Phoenix evidence RVAs: X 0x21EE00, Y 0x21EE20.
        local fx = ffi.cast('void (__cdecl *)(int32_t)', axes[1].address)
        local fy = ffi.cast('void (__cdecl *)(int32_t)', axes[2].address)
        -- Thiscall WORD getter follows the matched chat-Y writer's CALL.
        -- Receiver is recovered from two agreeing MOV ECX operands nearby.
        -- Phoenix getter/receiver RVAs: 0x15F9C0 / 0x621838. It reads native
        -- UI layout through a selector/state-query call; it is not patched.
        local get = ffi.cast('int16_t (__thiscall *)(void*, int32_t)', native.getter)
        call = function(axis, v)
            if axis == 'x' then
                fx(v)
            else
                fy(v)
            end
        end
        native_y = function()
            return tonumber(get(ffi.cast('void*', native.receiver), 0))
        end
    end

    function state:release(restore_layout)
        local errors = {}
        -- Attempt both axes even if one has been changed by another owner.
        for i, a in ipairs(axes) do
            if self.owned[i] then
                local original = setter(slot, a.field):sub(
                    layout.setter_patch_offset + 1,
                    layout.setter_patch_offset + layout.setter_patch_size
                )
                -- Exchange only the audited setter +8..+15 region; ownership is checked.
                local changed, err =
                    swap(a.address + layout.setter_patch_offset, self.owned[i], original)
                if changed then
                    self.owned[i] = nil
                end
                if err then
                    errors[#errors + 1] = a.name .. ': ' .. err
                end
            end
        end

        self.active = self.owned[1] ~= nil or self.owned[2] ~= nil
        assert(#errors == 0, table.concat(errors, '; '))
        if self.original then
            validate()
            local object = core.u32(read(slot, 4), 1)
            if object ~= 0 and restore_layout ~= false then
                -- Ask the verified native getter for current chat geometry rather
                -- than restoring a stale Y captured before chat was resized.
                local y = native_y()
                assert(y >= 0 and y <= 32767, 'Native layout getter returned invalid Y')
                call('x', self.original.x)
                call('y', y)
            end
            self.original = nil
        end

        if restore_layout == false then
            return 'Native setter instructions released; waiting for native layout'
        end

        return 'Fixed anchor released; native setter instructions and current chat-relative Y restored'
    end

    function state:start(tx, ty)
        assert(
            not self.active and not self.original,
            'Fixed anchor already installed; release first'
        )
        validate()
        local _, x, y = current()
        assert(type(tx) == 'number' and type(ty) == 'number', 'Anchor coordinates required')
        assert(
            tx == math.floor(tx)
                and ty == math.floor(ty)
                and tx >= 0
                and tx <= 32767
                and ty >= 0
                and ty <= 32767,
            'Fixed target out of signed coordinate range'
        )

        self.original = { x = x, y = y, tx = tx, ty = ty }
        for i, a in ipairs(axes) do
            local original = setter(slot, a.field):sub(
                layout.setter_patch_offset + 1,
                layout.setter_patch_offset + layout.setter_patch_size
            )
            local replacement = patch(i == 1 and tx or ty)

            -- Exchange only the audited setter +8..+15 region; ownership is checked.
            local changed, err = swap(a.address + layout.setter_patch_offset, original, replacement)

            if changed then
                self.owned[i] = replacement
                self.active = true
            end

            if err or not changed then
                local ok, rollback_err = pcall(self.release, self)
                error(
                    'Install refused: '
                        .. (err or 'Code was not replaced')
                        .. (ok and '; rolled back' or '; rollback: ' .. tostring(rollback_err))
                )
            end
        end

        call('x', tx)
        call('y', ty)
        return ('Fixed native anchor enabled: (%d,%d).'):format(tx, ty)
    end

    function state:object()
        return core.u32(read(slot, 4), 1)
    end

    function state:position()
        validate()
        return current()
    end

    function state:apply()
        validate()
        current() -- Refuse calls when the object is absent or being replaced.
        call('x', self.original.tx)
        call('y', self.original.ty)
    end

    function state:move(tx, ty)
        assert(self.active and self.original, 'No active fixed anchor')
        assert(
            tx == math.floor(tx)
                and ty == math.floor(ty)
                and tx >= 0
                and tx <= 32767
                and ty >= 0
                and ty <= 32767,
            'Anchor outside signed coordinate range'
        )
        validate()
        current()
        for i, a in ipairs(axes) do
            local replacement = patch(i == 1 and tx or ty)
            if replacement ~= self.owned[i] then
                -- Exchange only the audited setter +8..+15 region; ownership is checked.
                local changed, err =
                    swap(a.address + layout.setter_patch_offset, self.owned[i], replacement)
                if changed then
                    self.owned[i] = replacement
                end
                if err or not changed then
                    local ok, rollback_err = pcall(self.release, self)
                    error(
                        'Move refused: '
                            .. (err or 'Code was not replaced')
                            .. (ok and '; released' or '; rollback: ' .. tostring(rollback_err))
                    )
                end
            end
        end
        self.original.tx, self.original.ty = tx, ty
        self:apply()
    end
    return state
end
return M
