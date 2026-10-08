--[[
    CompassLoc | safe_memory.lua
    Author: Mage

    Overview: Copies bounded memory ranges from the current Windows x86 process.
    Scope: Uses ReadProcessMemory rather than unchecked Lua pointer dereferences; no write
              API.
]]

local ffi = require('ffi')
assert(ffi.os == 'Windows' and ffi.sizeof('void*') == 4, 'Requires Windows x86 LuaJIT')
ffi.cdef([[
void* __stdcall GetCurrentProcess(void);
int __stdcall ReadProcessMemory(void* hProcess, const void* lpBaseAddress,
    void* lpBuffer, size_t nSize, size_t* lpNumberOfBytesRead);
]])
local kernel = ffi.load('kernel32')
-- All reads target this game process only. Addresses come from module
-- headers/signatures or guarded native compass object pointers.
local process = kernel.GetCurrentProcess()
local M = {}
function M.read(address, length)
    assert(
        type(address) == 'number'
            and address == math.floor(address)
            and address > 0
            and address < 0x100000000,
        'Invalid x86 address'
    )
    assert(
        length == math.floor(length)
            and length > 0
            and length <= 0x2000000
            and address + length <= 0x100000000,
        'Invalid read length'
    )
    local buffer = ffi.new('uint8_t[?]', length)
    local got = ffi.new('size_t[1]')
    if
        kernel.ReadProcessMemory(process, ffi.cast('const void*', address), buffer, length, got)
            == 0
        or tonumber(got[0]) ~= length
    then
        error(('Memory unavailable at %08X (%d bytes); read refused'):format(address, length))
    end
    return ffi.string(buffer, length)
end
return M
