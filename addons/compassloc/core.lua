--[[
    CompassLoc | core.lua
    Author: Mage

    Overview: Parses loaded PE metadata and supplies signature matching and compass layout
              fields.
    Scope: Read-only discovery primitives; no diagnostic exports or process-memory writes.
]]

local M = {}
-- Memory-write summary: README.md. Verified native setters/render origin on Phoenix/Horizon.
-- These are fields relative to the discovered compass object, not DLL RVAs.
-- The X/Y stores were decoded in the native setters and confirmed by live
-- movement tests. The renderer loads them as signed 16-bit coordinates.
M.layout = {
    x = 0x28, -- WORD: native compass/clock origin X.
    y = 0x2A, -- WORD: native origin Y, normally chat-relative.
    draw_offset_y = 0x2C, -- WORD: subtracted from origin Y by the renderer; read-only.
    expected_draw_offset_y = 42, -- Observed initializer value; compatibility guard only.
    origin_size = 6, -- Read only the three WORDs at object +0x28/+0x2A/+0x2C.
    setter_size = 19, -- Complete guarded MOV/global/null/load/store/RET routine.
    setter_patch_offset = 8, -- Setter +8: unchanged JE displacement, source load, store prefix.
    setter_patch_size = 8, -- Only +9..+13 change; aligned exchange also covers unchanged bytes.
}

-- Read-only entry fingerprint from Ashita's mapdot addon. The A1 instruction's
-- operand at site +1 is the ADDRESS of the global compass-object pointer slot.
-- Phoenix example: site RVA 0x21EE70 -> slot RVA 0x666E84. Neither RVA is used
-- as a runtime address. The float/radar instructions in this function are not patched.
M.signature = 'A1????????85C074??D9442404D80D????????8B4C2404'

function M.u16(s, p)
    assert(p >= 1 and p + 1 <= #s, 'Truncated uint16')
    local a, b = s:byte(p, p + 1)
    return a + b * 256
end

function M.u32(s, p)
    assert(p >= 1 and p + 3 <= #s, 'Truncated uint32')
    local a, b, c, d = s:byte(p, p + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

function M.hex(s)
    return (s:gsub('.', function(c)
        return ('%02X'):format(c:byte())
    end))
end

function M.matches(s, pattern)
    pattern = pattern or M.signature
    local fixed = {}
    for p = 1, #pattern, 2 do
        local pair = pattern:sub(p, p + 1)
        if pair == '??' then
            fixed[#fixed + 1] = false
        else
            fixed[#fixed + 1] = tonumber(pair, 16)
        end
    end
    local results, start = {}, 1
    while true do
        local p = s:find(string.char(fixed[1]), start, true)
        if not p then
            break
        end
        if p + #fixed - 1 > #s then
            break
        end
        local ok = true
        for i, value in ipairs(fixed) do
            if value and s:byte(p + i - 1) ~= value then
                ok = false
                break
            end
        end
        if ok then
            results[#results + 1] = p - 1
        end -- zero-based offsets
        start = p + 1
    end
    return results
end

-- Reader must return a copied byte string or raise an error, never a raw pointer.
function M.image(read, base)
    local dos = read(base, 64)
    assert(dos:sub(1, 2) == 'MZ', 'Not an MZ image')
    -- PE format: DOS +0x3C is e_lfanew; copied Lua strings are 1-based.
    local pe = M.u32(dos, 61)
    assert(pe >= 64 and pe <= 0x100000, 'Invalid PE header offset')

    -- PE signature + 20-byte COFF header, used only to validate the loaded image.
    local header = read(base + pe, 24)
    assert(header:sub(1, 4) == 'PE\0\0', 'Not a PE image')

    -- COFF +0: Machine; +2: NumberOfSections; +16: SizeOfOptionalHeader.
    assert(M.u16(header, 5) == 0x14C, 'Expected x86 image')
    local count, opt_size = M.u16(header, 7), M.u16(header, 21)
    assert(count > 0 and count <= 96 and opt_size >= 96 and opt_size <= 4096, 'Invalid PE headers')

    local opt = read(base + pe + 24, opt_size)
    assert(M.u16(opt, 1) == 0x10B, 'Expected PE32 image')

    -- PE32 optional header +0x38: SizeOfImage; +0x1C: preferred ImageBase.
    local size = M.u32(opt, 57)
    assert(size > 0 and size <= 0x10000000, 'Invalid image size')
    local sections = read(base + pe + 24 + opt_size, count * 40)
    local found, total, executable_sections = {}, 0, {}
    for n = 0, count - 1 do
        local p = n * 40 + 1
        -- IMAGE_SECTION_HEADER +0x24: Characteristics (0x20000000 = executable).
        local flags = M.u32(sections, p + 36)
        if math.floor(flags / 0x20000000) % 2 == 1 then
            -- Section +8/+12: VirtualSize/VirtualAddress, not compass fields.
            local length, rva = M.u32(sections, p + 8), M.u32(sections, p + 12)
            assert(length <= 0x2000000 and rva + length <= size, 'Invalid executable section')
            total = total + length
            assert(total <= 0x8000000, 'Executable scan limit exceeded')
            if length > 0 then
                executable_sections[#executable_sections + 1] = { rva = rva, size = length }
                local bytes = read(base + rva, length)
                for _, offset in ipairs(M.matches(bytes)) do
                    found[#found + 1] = base + rva + offset
                end
            end
        end
    end

    assert(#found == 1, ('Expected one executable signature match, got %d'):format(#found))

    return {
        base = base,
        size = size,
        timestamp = M.u32(header, 9), -- COFF +4: TimeDateStamp, reported, not a build lock.
        preferred_base = M.u32(opt, 29),
        site = found[1],
        executable_sections = executable_sections,
    }
end

return M
