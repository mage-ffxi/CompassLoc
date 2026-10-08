--[[
    CompassLoc | discovery.lua
    Author: Mage

    Overview: Finds compatible compass setters and layout functions from linked fingerprints.
    Scope: Read-only discovery; refuses ambiguous or inconsistent native implementations.
]]

local core = require('core')
local layout = core.layout
local M = {}
-- Phoenix RVA 0x15F9C0: reads WORD through selector + table helper, RET 4.
M.getter_pattern = '8B44240456508BF1' .. 'E8????????83C4048BCE50' .. 'E8????????668B005EC20400'

-- Phoenix RVA 0x15F9E0: LEA [receiver + selector*2 + 0xA0]; no store.
M.helper_pattern = '8B44240456508BF1E8????????83C404' .. '8D8446A00000005EC20400'

-- Phoenix RVA 0x15F980: native UI-state selection of layout entry 0 or 4.
-- The 0xB4 state query and global UI-state pointer are read/called, not patched.
M.selector_pattern = '568B74240885F67530'
    .. '68B4000000E8????????83C40483F802750433C05EC3'
    .. 'A1????????85C074118B500885D20F95C084C0'
    .. 'B80400000075028BC65EC3'

-- Phoenix RVA 0x15FCCC: getter result is PUSHed directly into compass Y setter.
-- Following A1 accesses a separate, unclassified UI object; matched context only.
M.writer_pattern = '85FF7541578BCDE8????????50E8????????A1????????83C40485C07447'

-- Phoenix RVA 0x15FD31: two MOV ECX loads of the same layout-manager instance.
-- This contextual identification is conservative, not a formal receiver type proof.
M.receiver_pattern = 'B9????????E8????????85C08944241074578D542410'
    .. 'B9????????52E8????????8BF085F6743A'

local function le(v, n)
    local s = ''
    for _ = 1, n do
        s = s .. string.char(v % 256)
        v = math.floor(v / 256)
    end
    return s
end

-- Exact 19-byte setter: MOV EAX,[slot]; TEST EAX,EAX; JE RET;
-- MOV CX,[ESP+4]; MOV [EAX+field],CX; RET. The final field byte is
-- restricted to the compass X/Y WORD offsets, not an arbitrary write target.
function M.setter(slot, field)
    assert(field == layout.x or field == layout.y, 'Not a compass coordinate field')
    return string.char(0xA1)
        .. le(slot, 4) -- MOV EAX,[compass pointer slot]
        .. string.char(0x85, 0xC0) -- TEST EAX,EAX
        .. string.char(0x74, 0x09) -- JE the RET instruction if object is null
        .. string.char(0x66, 0x8B, 0x4C, 0x24, 0x04) -- MOV CX,[ESP+4]
        .. string.char(0x66, 0x89, 0x48, field) -- MOV WORD [EAX+X/Y field],CX
        .. string.char(0xC3) -- RET; caller cleans argument
end

function M.resolve(image, read)
    local sections = image.executable_sections
    assert(sections and #sections > 0, 'Executable section inventory missing; rescan required')
    local copied = {}
    for _, s in ipairs(sections) do
        assert(
            s.rva >= 0 and s.size > 0 and s.size <= 0x2000000 and s.rva + s.size <= image.size,
            'Invalid discovery section'
        )
        local data = read(image.base + s.rva, s.size)
        assert(#data == s.size, 'Incomplete discovery read')
        copied[#copied + 1] = { address = image.base + s.rva, bytes = data }
    end

    local function inside(address, length)
        return address >= image.base and address + length <= image.base + image.size
    end

    local function executable(address, length)
        for _, s in ipairs(copied) do
            if address >= s.address and address + length <= s.address + #s.bytes then
                return true
            end
        end
        return false
    end

    local function unique(pattern, label)
        local found = {}
        for _, s in ipairs(copied) do
            for _, offset in ipairs(core.matches(s.bytes, pattern)) do
                found[#found + 1] = s.address + offset
            end
        end
        assert(#found == 1, ('Discovery %s: expected one match, got %d'):format(label, #found))
        return found[1]
    end

    local guards = {}
    local function guard(address, pattern, label)
        assert(executable(address, #pattern / 2), label .. ' outside executable sections')
        local bytes = read(address, #pattern / 2)
        local found = core.matches(bytes, pattern)
        assert(#found == 1 and found[1] == 0, label .. ' fingerprint differs')
        guards[#guards + 1] = { address = address, bytes = bytes }
        return bytes
    end

    local function call(address)
        assert(
            executable(address, 5) and read(address, 1) == string.char(0xE8),
            'Expected direct CALL'
        )
        -- E8 +1 holds a signed rel32 displacement; next instruction is +5.
        local d = core.u32(read(address + 1, 4), 1)
        if d >= 0x80000000 then
            d = d - 0x100000000
        end
        local target = address + 5 + d
        assert(executable(target, 1), 'CALL target outside executable sections')
        return target
    end

    guard(image.site, core.signature, 'Compass discovery site')

    -- A1 immediate at discovery site +1: pointer-slot ADDRESS, not object data.
    local slot = core.u32(read(image.site + 1, 4), 1)
    assert(inside(slot, 4), 'Compass global outside module')

    local x = unique(core.hex(M.setter(slot, layout.x)), 'X setter')
    local y = unique(core.hex(M.setter(slot, layout.y)), 'Y setter')

    -- The existing atomic publication strategy needs this instruction alignment.
    assert(
        (x + layout.setter_patch_offset) % 8 == 0 and (y + layout.setter_patch_offset) % 8 == 0,
        'Setter patch alignment unsupported'
    )

    local writer = unique(M.writer_pattern, 'chat Y writer')
    guard(writer, M.writer_pattern, 'Chat Y writer')

    -- Writer +7 CALLs getter; +12 PUSH EAX; +13 CALLs the Y setter.
    assert(call(writer + 13) == y, 'Chat writer does not call discovered Y setter')
    local getter = call(writer + 7)
    guard(getter, M.getter_pattern, 'Native Y getter')

    -- Getter +8/+19 are CALL opcodes, not data fields or patch offsets.
    local selector, helper = call(getter + 8), call(getter + 19)
    guard(helper, M.helper_pattern, 'Native table helper')

    -- Helper +8 must call the same selector as the getter.
    assert(call(helper + 8) == selector, 'Getter/helper selector targets differ')
    guard(selector, M.selector_pattern, 'Native layout selector')

    -- Selector +14: CALL to the native UI-state query (argument 0xB4).
    -- Validate its target; this native call is used only through the layout getter.
    call(selector + 14)

    -- Selector +31 A1: +32 is its global UI-state pointer operand (read-only).
    local selector_slot = core.u32(read(selector + 32, 4), 1)
    assert(inside(selector_slot, 4), 'Layout selector global outside module')
    local receiver_site = unique(M.receiver_pattern, 'layout receiver')
    local receiver_bytes = guard(receiver_site, M.receiver_pattern, 'Layout receiver')

    -- Require the receiver-load path to belong to the discovered writer's
    -- nearby continuation, not merely a lookalike elsewhere in the module.
    assert(
        receiver_site > writer and receiver_site - writer <= 256,
        'Layout receiver disconnected from chat writer'
    )

    -- MOV ECX,imm32 operands at receiver-site +1 and +23. Lua indices: 2/24.
    local receiver = core.u32(receiver_bytes, 2)
    assert(receiver == core.u32(receiver_bytes, 24), 'Layout receiver operands disagree')

    -- 0xAA covers WORD layout entries +0xA0 through selector 4 (+0xA8).
    assert(inside(receiver, 0xAA), 'Layout receiver outside module')

    -- Context CALL opcodes after each receiver load; targets must be executable.
    call(receiver_site + 5)
    call(receiver_site + 28)
    local result = {
        slot = slot,
        x_setter = x,
        y_setter = y,
        getter = getter,
        receiver = receiver,
        guards = guards,
    }

    function result:validate()
        for _, g in ipairs(self.guards) do
            assert(read(g.address, #g.bytes) == g.bytes, 'Discovered code changed; rescan required')
        end
    end

    result:validate()
    assert(
        read(x, layout.setter_size) == M.setter(slot, layout.x)
            and read(y, layout.setter_size) == M.setter(slot, layout.y),
        'Setter changed during discovery'
    )
    return result
end
return M
