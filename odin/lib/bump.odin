package docodin

import "base:runtime"
import "core:mem"

// Lock-free bump allocator for per-thread parse arenas.
//
// Every parse allocates many small, same-lifetime objects (nodes, line
// slices, strings) that are released together.  ``core:mem/virtual.Arena``
// takes a mutex on every allocation; this arena is owned by one thread, so
// it needs none.  Blocks come from the heap; ``bump_reset`` keeps the most
// recent block (up to ``BUMP_RETAIN_MAX``) so steady-state parsing performs no
// heap calls at all.

BUMP_MIN_BLOCK  :: 1 * mem.Megabyte
BUMP_RETAIN_MAX :: 64 * mem.Megabyte

Bump_Block :: struct {
	prev: ^Bump_Block,
	size: int, // usable bytes after the header
	used: int,
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
	size := max(min_size, BUMP_MIN_BLOCK)
	if a.block != nil do size = max(size, min(a.block.size * 2, BUMP_RETAIN_MAX))
	raw := runtime.heap_alloc(size_of(Bump_Block) + size, zero_memory = false)
	if raw == nil do return false
	b := (^Bump_Block)(raw)
	b^ = Bump_Block{prev = a.block, size = size}
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

// Release everything; keep one block for reuse.
bump_reset :: proc "contextless" (a: ^Bump_Arena) {
	keep := a.block
	if keep != nil && keep.size > BUMP_RETAIN_MAX do keep = nil
	for b := a.block; b != nil; {
		prev := b.prev
		if b != keep do runtime.heap_free(b)
		b = prev
	}
	a.block = keep
	if keep != nil {
		keep.prev = nil
		keep.used = 0
	}
	a.last_alloc = nil
}

bump_destroy :: proc "contextless" (a: ^Bump_Arena) {
	for b := a.block; b != nil; {
		prev := b.prev
		runtime.heap_free(b)
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
