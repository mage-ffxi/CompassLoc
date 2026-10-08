--[[
    CompassLoc | atomic_patch.lua
    Author: Mage

    Overview: Publishes a guarded eight-byte instruction replacement through Windows atomic
              APIs.
    Scope: Caller selects only compass setter regions; restores page protection and flushes
              cache.
]]

local ffi = require('ffi')
assert(ffi.os == 'Windows' and ffi.sizeof('void*') == 4, 'Requires Windows x86')
ffi.cdef([[
    void* __stdcall GetCurrentProcess(void);
    int __stdcall VirtualProtect(void*, size_t, uint32_t, uint32_t*);
    int64_t __stdcall InterlockedCompareExchange64(volatile int64_t*, int64_t, int64_t);
    int __stdcall FlushInstructionCache(void*, const void*, size_t);
]])

local kernel = ffi.load('kernel32')
-- Resolve before any mutation; do not fall back to non-atomic writes.
local exchange = kernel.InterlockedCompareExchange64
local protect = kernel.VirtualProtect
local flush = kernel.FlushInstructionCache
local process = kernel.GetCurrentProcess()
local M = {}

function M.swap(address, expected, replacement)
    assert(
        address % 8 == 0 and #expected == 8 and #replacement == 8,
        'Patch must be aligned and eight bytes'
    )
    -- Caller native.lua supplies only discovered X/Y setter +8 addresses.
    -- This helper does not discover or select game memory by itself.
    -- These buffers and outputs are allocated before changing page protection.
    local old_word, new_word = ffi.new('int64_t[1]'), ffi.new('int64_t[1]')
    ffi.copy(old_word, expected, 8)
    ffi.copy(new_word, replacement, 8)
    local old_protection, ignored = ffi.new('uint32_t[1]'), ffi.new('uint32_t[1]')
    local destination = ffi.cast('volatile int64_t*', address)
    -- 0x40 = PAGE_EXECUTE_READWRITE. Windows adjusts the containing page
    -- protection; the exchange itself writes exactly eight bytes, then restores
    -- the prior protection and flushes instruction cache. No code allocation.
    if protect(ffi.cast('void*', address), 8, 0x40, old_protection) == 0 then
        return false, 'VirtualProtect refused writable code access'
    end
    local previous = exchange(destination, new_word[0], old_word[0])
    local changed = previous == old_word[0]
    local coherent = flush(process, ffi.cast('const void*', address), 8) ~= 0
    local restored = protect(ffi.cast('void*', address), 8, old_protection[0], ignored) ~= 0
    if not restored then
        return changed, 'Failed to restore code-page protection'
    end
    if not coherent then
        return changed, 'FlushInstructionCache failed'
    end
    if not changed then
        return false, 'Code ownership mismatch; expected bytes were not overwritten'
    end
    return true
end
return M
