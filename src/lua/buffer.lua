-- buffer.lua (internal file)

local ffi = require('ffi')
local READAHEAD = 16320

ffi.cdef[[
struct slab_cache;
struct slab_cache *
tarantool_lua_slab_cache();

struct ibuf *
cord_ibuf_take(void);

void
cord_ibuf_put(struct ibuf *ibuf);

void
cord_ibuf_drop(struct ibuf *ibuf);

struct ibuf
{
    struct slab_cache *slabc;
    char *buf;
    /** Start of input. */
    char *rpos;
    /** End of useful input */
    char *wpos;
    /** End of ibuf. */
    char *epos;
    size_t start_capacity;
};

void
ibuf_create(struct ibuf *ibuf, struct slab_cache *slabc, size_t start_capacity);

void
ibuf_destroy(struct ibuf *ibuf);

void
ibuf_reinit(struct ibuf *ibuf);

void *
ibuf_reserve_slow(struct ibuf *ibuf, size_t size);

void *
lua_static_aligned_alloc(size_t size, size_t alignment);

/**
 * Register is a buffer to use with FFI functions, which usually
 * operate with pointers to scalar values like int, char, size_t,
 * void *. To avoid doing 'ffi.new(<type>[1])' on each such FFI
 * function invocation, a module can use one of attributes of the
 * register union.
 *
 * Naming policy of the attributes is easy to remember:
 * 'a' for array type + type name first letters + 'p' for pointer.
 *
 * For example:
 * - int[1] - <a>rray of <i>nt - ai;
 * - const unsigned char *[1] -
 *       <a>rray of <c>onst <u>nsigned <c>har <p> pointer - acucp.
 */
union c_register {
    size_t as[1];
    void *ap[1];
    int ai[1];
    char ac[1];
    const unsigned char *acucp[1];
    unsigned long aul[1];
    uint16_t u16;
    uint32_t u32;
    uint64_t u64;
    int64_t i64;
    int64_t ai64[1];
};
]]

local builtin = ffi.C
local ibuf_t = ffi.typeof('struct ibuf')

local function errorf(s, ...)
    error(string.format(s, ...))
end

local function checkibuf(buf, method)
    if not ffi.istype(ibuf_t, buf) then
        errorf('Attempt to call method without object, use ibuf:%s()', method)
    end
end

local function ibuf_capacity(buf)
    checkibuf(buf, 'capacity')
    return tonumber(buf.epos - buf.buf)
end

local function ibuf_pos(buf)
    checkibuf(buf, 'pos')
    return tonumber(buf.rpos - buf.buf)
end

local function ibuf_used(buf)
    checkibuf(buf, 'size')
    return tonumber(buf.wpos - buf.rpos)
end

local function ibuf_unused(buf)
    checkibuf(buf, 'unused')
    return tonumber(buf.epos - buf.wpos)
end

local function ibuf_recycle(buf)
    checkibuf(buf, 'recycle')
    builtin.ibuf_reinit(buf)
end

local function ibuf_reset(buf)
    checkibuf(buf, 'reset')
    buf.rpos = buf.buf
    buf.wpos = buf.buf
end

local function ibuf_reserve_slow(buf, size)
    local ptr = builtin.ibuf_reserve_slow(buf, size)
    if ptr == nil then
        errorf("Failed to allocate %d bytes in ibuf", size)
    end
    return ffi.cast('char *', ptr)
end

local function ibuf_reserve(buf, size)
    checkibuf(buf, 'reserve')
    if buf.wpos + size <= buf.epos then
        return buf.wpos
    end
    return ibuf_reserve_slow(buf, size)
end

local function ibuf_alloc(buf, size)
    checkibuf(buf, 'alloc')
    local wpos
    if buf.wpos + size <= buf.epos then
        wpos = buf.wpos
    else
        wpos = ibuf_reserve_slow(buf, size)
    end
    buf.wpos = buf.wpos + size
    return wpos
end

local function checksize(buf, size)
    if buf.rpos + size > buf.wpos then
        errorf("Attempt to read out of range bytes: needed=%d size=%d",
            tonumber(size), ibuf_used(buf))
    end
end

local function ibuf_checksize(buf, size)
    checkibuf(buf, 'checksize')
    checksize(buf, size)
    return buf.rpos
end

local function ibuf_read(buf, size)
    checkibuf(buf, 'read')
    checksize(buf, size)
    local rpos = buf.rpos
    buf.rpos = rpos + size
    return rpos
end

local function ibuf_serialize(buf)
    local properties = { rpos = buf.rpos, wpos = buf.wpos }
    return { ibuf = properties }
end

local ibuf_methods = {
    recycle = ibuf_recycle;
    reset = ibuf_reset;

    reserve = ibuf_reserve;
    alloc = ibuf_alloc;

    checksize = ibuf_checksize;
    read = ibuf_read;
    __serialize = ibuf_serialize;

    size = ibuf_used;
    capacity = ibuf_capacity;
    pos = ibuf_pos;
    unused = ibuf_unused;
}

local function ibuf_tostring(self)
    return '<ibuf>'
end
local ibuf_mt = {
    __gc = ibuf_recycle;
    __index = ibuf_methods;
    __tostring = ibuf_tostring;
};

ffi.metatype(ibuf_t, ibuf_mt);

local function ibuf_new(arg)
    local buf = ffi.new(ibuf_t)
    local slabc = builtin.tarantool_lua_slab_cache()
    builtin.ibuf_create(buf, slabc, READAHEAD)
    if arg == nil then
        return buf
    elseif type(arg) == 'number' then
        ibuf_reserve(buf, arg)
        return buf
    end
    errorf('Usage: ibuf([size])')
end

--
-- Stash keeps an FFI object for re-usage and helps to ensure the proper
-- ownership. Is supposed to be used in yield-free code when almost always it is
-- possible to put the taken object back.
-- Then cost of the stash is almost the same as ffi.new() for small objects like
-- 'int[1]' even when jitted. Examples:
--
-- * ffi.new('int[1]') is about ~0.4ns, while the stash take() + put() is about
--   ~0.8ns;
--
-- * Much better on objects > 128 bytes in size. ffi.new('struct uri[1]') is
--   ~300ns, while the stash is still ~0.8ns;
--
-- * For structs not allocated as an array is also much better than ffi.new().
--   For instance, ffi.new('struct tt_uuid') is ~300ns, the stash is ~0.8ns.
--   Even though 'struct tt_uuid' is 16 bytes;
--
local function ffi_stash_new(c_type)
    local item = nil

    local function take()
        local res
        -- This line is guaranteed to be GC-safe. GC is not invoked. Because
        -- there are no allocation. So it can be considered 'atomic'.
        res, item = item, nil
        -- The next lines don't need to be atomic and can survive GC. The only
        -- important part was to take the global item and set it to nil.
        if res then
            return res
        end
        return ffi.new(c_type)
    end

    local function put(i)
        -- It is ok to rewrite the existing global item if it was set. Does
        -- not matter. They are all the same.
        item = i
    end

    -- Due to some random reason if the stash returns a table with methods it
    -- works faster than returning them as multiple values. Regardless of how
    -- the methods are used later. Even if the caller will cache take and put
    -- methods anyway.
    return {
        take = take,
        put = put,
    }
end

--
-- NOTE: ffi.new() with inlined size <= 128 works even faster
--       than this allocator. If your size is a constant <= 128 -
--       use ffi.new(). This function is faster than malloc,
--       ffi.new(> 128), and ffi.new() with any size not known in
--       advance like this:
--
--           local size = <any expression>
--           ffi.new('char[?]', size)
--
-- Allocate a chunk of static BSS memory, or use ordinal ffi.new,
-- when too big size.
-- @param type C type - a struct, a basic type, etc. Should be a
--        string: 'int', 'char *', 'struct tuple', etc.
-- @param size Optional argument, number of elements of @a type to
--        allocate. 1 by default.
-- @return Cdata pointer to @a type.
--
local function static_alloc(type, size)
    size = size or 1
    local bsize = size * ffi.sizeof(type)
    local ptr = builtin.lua_static_aligned_alloc(bsize, ffi.alignof(type))
    if ptr ~= nil then
        return ffi.cast(type..' *', ptr)
    end
    return ffi.new(type..'[?]', size)
end

--
-- Sometimes it is wanted to use several temporary registers at
-- once. For example, when a C function takes 2 C pointers. Then
-- one register is not enough - its attributes share memory. Note,
-- registers are not allocated with separate ffi.new calls
-- deliberately. With a single allocation they fit into 1 cache
-- line, and reduce the heap fragmentation.
--
local reg_array = ffi.new('union c_register[?]', 2)

--
-- Cord buffer is useful for the places, where
--
-- * Want to reuse the already allocated memory which might be stored in the
--   cord buf. Although sometimes the buffer is recycled, so should not rely on
--   being able to reuse it always. When reused, the win is the biggest -
--   becomes about x20 times faster than a new buffer creation (~5ns vs ~100ns);
--
-- * Want to avoid allocation of a new ibuf because it produces a new GC object
--   which is additional load for Lua GC. Although according to benches it is
--   not super expensive;
--
-- * Almost always can put the buffer back manually. Not rely on it being
--   recycled automatically. It is recycled, but still should not rely on that;
--
-- It is important to wrap the C functions, not expose them directly. Because
-- JIT works a bit better when C functions are called as 'ffi.C.func()' than
-- 'func()' with func being cached. The only pros is to cache 'ffi.C' itself.
-- It is quite strange though how having them wrapped into a Lua function is
-- faster than cached directly as C functions.
--
local function cord_ibuf_take()
    return builtin.cord_ibuf_take()
end

local function cord_ibuf_put(buf)
    return builtin.cord_ibuf_put(buf)
end

local function cord_ibuf_drop(buf)
    return builtin.cord_ibuf_drop(buf)
end

local internal = {
    cord_ibuf_take = cord_ibuf_take,
    cord_ibuf_put = cord_ibuf_put,
    cord_ibuf_drop = cord_ibuf_drop,
}

return {
    internal = internal,
    ibuf = ibuf_new;
    READAHEAD = READAHEAD;
    static_alloc = static_alloc,
    -- Keep reference.
    reg_array = reg_array,
    reg1 = reg_array[0],
    reg2 = reg_array[1],
    ffi_stash_new = ffi_stash_new,
}
