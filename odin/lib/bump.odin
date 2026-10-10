package docodin

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:sync"

// Lock-free bump allocator for per-thread parse arenas.
//
// Every parse allocates many small, same-lifetime objects (nodes, line
// slices, strings) that are released together.  ``core:mem/virtual.Arena``
// takes a mutex on every allocation; this arena is owned by one thread, so
// it needs none.  Blocks are mapped from the OS directly (not from the C
// heap, which may keep freed memory), so a released block returns its
// memory at once.  ``bump_reset`` keeps the largest block of at most
// ``BUMP_RETAIN_MAX``: steady-state parsing maps no memory, and a large parse
// does not leave a large block resident.
//
// Between calls an arena holds no memory: ``bump_park`` moves the kept block
// to a small process-wide cache (``BUMP_CACHE_MAX`` blocks) and
// ``bump_unpark`` takes one back.  A thread that exits therefore owns
// nothing, and hosts that create and retire threads keep at most
// ``BUMP_CACHE_MAX * BUMP_RETAIN_MAX`` bytes cached.

BUMP_MIN_BLOCK  :: 1 * mem.Megabyte
BUMP_MAX_GROWTH :: 64 * mem.Megabyte // blocks double up to this size
BUMP_RETAIN_MAX :: 4 * mem.Megabyte
BUMP_CACHE_MAX  :: 8 // cached blocks shared by all threads

Bump_Block :: struct {
	prev: ^Bump_Block,
	size: int, // usable bytes after the header
	used: int,
}

// A block takes `size_of(Bump_Block) + size` bytes of its mapping.
@(private = "file")
free_block :: proc "contextless" (b: ^Bump_Block) {
	virtual.release(b, uint(size_of(Bump_Block) + b.size))
}

Bump_Arena :: struct {
	block:      ^Bump_Block,
	last_alloc: rawptr, // start of the most recent allocation (for in-place resize)
}

@(private = "file")
block_data :: #force_inline proc "contextless" (b: ^Bump_Block) -> [^]byte {
	return ([^]byte)(uintptr(b) + size_of(Bump_Block))
}

@(private = "file")
new_block :: proc "contextless" (a: ^Bump_Arena, min_size: int) -> bool {
	total := max(min_size + size_of(Bump_Block), BUMP_MIN_BLOCK)
	if a.block != nil {
		total = max(total, min((size_of(Bump_Block) + a.block.size) * 2, BUMP_MAX_GROWTH))
	}
	raw, err := virtual.reserve_and_commit(uint(total))
	if err != nil do return false
	b := (^Bump_Block)(raw_data(raw))
	b^ = Bump_Block{prev = a.block, size = total - size_of(Bump_Block)}
	a.block = b
	return true
}

bump_alloc :: proc "contextless" (
	a: ^Bump_Arena,
	size, alignment: int,
	zero: bool,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	if size == 0 do return nil, nil
	align := max(alignment, 1)
	for {
		if b := a.block; b != nil {
			base := uintptr(block_data(b))
			a_mask := uintptr(align - 1)
			start := (base + uintptr(b.used) + a_mask) &~ a_mask
			offset := int(start - base)
			if offset + size <= b.size {
				b.used = offset + size
				ptr := rawptr(start)
				if zero do runtime.mem_zero(ptr, size)
				a.last_alloc = ptr
				return ([^]byte)(ptr)[:size], nil
			}
		}
		if !new_block(a, size + align) do return nil, .Out_Of_Memory
	}
}

bump_resize :: proc "contextless" (
	a: ^Bump_Arena,
	old: rawptr,
	old_size, size, alignment: int,
	zero: bool,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	if old == nil do return bump_alloc(a, size, alignment, zero)
	if size <= old_size do return ([^]byte)(old)[:size], nil
	// grow the most recent allocation in place
	if b := a.block; b != nil && old == a.last_alloc {
		base := uintptr(block_data(b))
		offset := int(uintptr(old) - base)
		if offset + size <= b.size {
			b.used = offset + size
			if zero {
				runtime.mem_zero(rawptr(uintptr(old) + uintptr(old_size)), size - old_size)
			}
			return ([^]byte)(old)[:size], nil
		}
	}
	data, err := bump_alloc(a, size, alignment, false)
	if err != nil do return nil, err
	runtime.mem_copy_non_overlapping(raw_data(data), old, old_size)
	if zero {
		runtime.mem_zero(rawptr(uintptr(raw_data(data)) + uintptr(old_size)), size - old_size)
	}
	return data, nil
}

// Release everything; keep one block for reuse: the newest one of at most
// ``BUMP_RETAIN_MAX`` bytes (blocks grow, so the largest such block).
bump_reset :: proc "contextless" (a: ^Bump_Arena) {
	keep: ^Bump_Block
	for b := a.block; b != nil; {
		prev := b.prev
		if keep == nil && size_of(Bump_Block) + b.size <= BUMP_RETAIN_MAX {
			keep = b
		} else {
			free_block(b)
		}
		b = prev
	}
	a.block = keep
	if keep != nil {
		keep.prev = nil
		keep.used = 0
	}
	a.last_alloc = nil
}

@(private = "file")
Block_Cache :: struct {
	lock:   sync.Atomic_Mutex,
	blocks: [BUMP_CACHE_MAX]^Bump_Block,
	count:  int,
}

@(private = "file")
block_cache: Block_Cache

// Reset the arena and move its kept block to the shared cache (or unmap it
// when the cache is full): the arena holds no memory afterwards.
bump_park :: proc "contextless" (a: ^Bump_Arena) {
	bump_reset(a)
	b := a.block
	if b == nil do return
	a.block = nil
	c := &block_cache
	sync.atomic_mutex_lock(&c.lock)
	cached := c.count < BUMP_CACHE_MAX
	if cached {
		c.blocks[c.count] = b
		c.count += 1
	}
	sync.atomic_mutex_unlock(&c.lock)
	if !cached do free_block(b)
}

// Give an empty arena a cached block, if any.
bump_unpark :: proc "contextless" (a: ^Bump_Arena) {
	if a.block != nil do return
	c := &block_cache
	sync.atomic_mutex_lock(&c.lock)
	if c.count > 0 {
		c.count -= 1
		a.block = c.blocks[c.count]
		c.blocks[c.count] = nil
	}
	sync.atomic_mutex_unlock(&c.lock)
}

// Blocks in the shared cache (for tests).
bump_cached_blocks :: proc "contextless" () -> int {
	c := &block_cache
	sync.atomic_mutex_lock(&c.lock)
	defer sync.atomic_mutex_unlock(&c.lock)
	return c.count
}

bump_destroy :: proc "contextless" (a: ^Bump_Arena) {
	for b := a.block; b != nil; {
		prev := b.prev
		free_block(b)
		b = prev
	}
	a^ = {}
}

bump_allocator :: proc "contextless" (a: ^Bump_Arena) -> runtime.Allocator {
	return runtime.Allocator{procedure = bump_allocator_proc, data = a}
}

bump_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	a := (^Bump_Arena)(allocator_data)
	switch mode {
	case .Alloc:              return bump_alloc(a, size, alignment, true)
	case .Alloc_Non_Zeroed:   return bump_alloc(a, size, alignment, false)
	case .Resize:             return bump_resize(a, old_memory, old_size, size, alignment, true)
	case .Resize_Non_Zeroed:  return bump_resize(a, old_memory, old_size, size, alignment, false)
	case .Free:               return nil, nil // freed in bulk
	case .Free_All:           bump_reset(a); return nil, nil
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {
				.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed,
				.Free, .Free_All, .Query_Features,
			}
		}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}
