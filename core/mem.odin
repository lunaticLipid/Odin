#import "fmt.odin"
#import "os.odin"

set :: proc(data: rawptr, value: i32, len: int) -> rawptr #link_name "__mem_set" {
	llvm_memset_64bit :: proc(dst: rawptr, val: byte, len: int, align: i32, is_volatile: bool) #foreign "llvm.memset.p0i8.i64"
	llvm_memset_64bit(data, value as byte, len, 1, false)
	return data
}

zero :: proc(data: rawptr, len: int) -> rawptr {
	return set(data, 0, len)
}

copy :: proc(dst, src: rawptr, len: int) -> rawptr #link_name "__mem_copy" {
	// NOTE(bill): This _must_ implemented like C's memmove
	llvm_memmove_64bit :: proc(dst, src: rawptr, len: int, align: i32, is_volatile: bool) #foreign "llvm.memmove.p0i8.p0i8.i64"
	llvm_memmove_64bit(dst, src, len, 1, false)
	return dst
}

copy_non_overlapping :: proc(dst, src: rawptr, len: int) -> rawptr #link_name "__mem_copy_non_overlapping" {
	// NOTE(bill): This _must_ implemented like C's memcpy
	llvm_memcpy_64bit :: proc(dst, src: rawptr, len: int, align: i32, is_volatile: bool) #foreign "llvm.memcpy.p0i8.p0i8.i64"
	llvm_memcpy_64bit(dst, src, len, 1, false)
	return dst
}


compare :: proc(dst, src: rawptr, n: int) -> int #link_name "__mem_compare" {
	// Translation of http://mgronhol.github.io/fast-strcmp/
	a := slice_ptr(dst as ^byte, n)
	b := slice_ptr(src as ^byte, n)

	fast := n/size_of(int) + 1
	offset := (fast-1)*size_of(int)
	curr_block := 0
	if n <= size_of(int) {
		fast = 0
	}

	la := slice_ptr(^a[0] as ^int, fast)
	lb := slice_ptr(^b[0] as ^int, fast)

	for ; curr_block < fast; curr_block++ {
		if (la[curr_block] ~ lb[curr_block]) != 0 {
			for pos := curr_block*size_of(int); pos < n; pos++ {
				if (a[pos] ~ b[pos]) != 0 {
					return a[pos] as int - b[pos] as int
				}
			}
		}

	}

	for ; offset < n; offset++ {
		if (a[offset] ~ b[offset]) != 0 {
			return a[offset] as int - b[offset] as int
		}
	}

	return 0
}



kilobytes :: proc(x: int) -> int #inline { return          (x) * 1024; }
megabytes :: proc(x: int) -> int #inline { return kilobytes(x) * 1024; }
gigabytes :: proc(x: int) -> int #inline { return gigabytes(x) * 1024; }
terabytes :: proc(x: int) -> int #inline { return terabytes(x) * 1024; }

is_power_of_two :: proc(x: int) -> bool {
	if x <= 0 {
		return false
	}
	return (x & (x-1)) == 0
}

align_forward :: proc(ptr: rawptr, align: int) -> rawptr {
	assert(is_power_of_two(align))

	a := align as uint
	p := ptr as uint
	modulo := p & (a-1)
	if modulo != 0 {
		p += a - modulo
	}
	return p as rawptr
}



AllocationHeader :: struct {
	size: int
}
allocation_header_fill :: proc(header: ^AllocationHeader, data: rawptr, size: int) {
	header.size = size
	ptr := (header+1) as ^int

	for i := 0; ptr as rawptr < data; i++ {
		(ptr+i)^ = -1
	}
}
allocation_header :: proc(data: rawptr) -> ^AllocationHeader {
	p := data as ^int
	for (p-1)^ == -1 {
		p = (p-1)
	}
	return (p as ^AllocationHeader)-1
}





// Custom allocators

Arena :: struct {
	backing:    Allocator
	memory:     []byte
	temp_count: int

	Temp_Memory :: struct {
		arena:          ^Arena
		original_count: int
	}
}





init_arena_from_memory :: proc(using a: ^Arena, data: []byte) {
	backing    = Allocator{}
	memory     = data[:0]
	temp_count = 0
}

init_arena_from_context :: proc(using a: ^Arena, size: int) {
	backing = context.allocator
	memory = new_slice(byte, 0, size)
	temp_count = 0
}

free_arena :: proc(using a: ^Arena) {
	if backing.procedure != nil {
		push_allocator backing {
			free(memory.data)
			memory = memory[0:0:0]
		}
	}
}

arena_allocator :: proc(arena: ^Arena) -> Allocator {
	return Allocator{
		procedure = arena_allocator_proc,
		data = arena,
	}
}

arena_allocator_proc :: proc(allocator_data: rawptr, mode: Allocator.Mode,
                             size, alignment: int,
                             old_memory: rawptr, old_size: int, flags: u64) -> rawptr {
	arena := allocator_data as ^Arena

	using Allocator.Mode
	match mode {
	case ALLOC:
		total_size := size + alignment

		if arena.memory.count + total_size > arena.memory.capacity {
			fmt.fprintln(os.stderr, "Arena out of memory")
			return nil
		}

		#no_bounds_check end := ^arena.memory[arena.memory.count]

		ptr := align_forward(end, alignment)
		arena.memory.count += total_size
		return zero(ptr, size)

	case FREE:
		// NOTE(bill): Free all at once
		// Use Arena.Temp_Memory if you want to free a block

	case FREE_ALL:
		arena.memory.count = 0

	case RESIZE:
		return default_resize_align(old_memory, old_size, size, alignment)
	}

	return nil
}

begin_arena_temp_memory :: proc(a: ^Arena) -> Arena.Temp_Memory {
	tmp: Arena.Temp_Memory
	tmp.arena = a
	tmp.original_count = a.memory.count
	a.temp_count++
	return tmp
}

end_arena_temp_memory :: proc(using tmp: Arena.Temp_Memory) {
	assert(arena.memory.count >= original_count)
	assert(arena.temp_count > 0)
	arena.memory.count = original_count
	arena.temp_count--
}







align_of_type_info :: proc(type_info: ^Type_Info) -> int {
	WORD_SIZE :: size_of(int)
	using Type_Info

	match type info : type_info {
	case Named:
		return align_of_type_info(info.base)
	case Integer:
		return info.size
	case Float:
		return info.size
	case String:
		return WORD_SIZE
	case Boolean:
		return 1
	case Pointer:
		return WORD_SIZE
	case Maybe:
		return max(align_of_type_info(info.elem), 1)
	case Procedure:
		return WORD_SIZE
	case Array:
		return align_of_type_info(info.elem)
	case Slice:
		return WORD_SIZE
	case Vector:
		return align_of_type_info(info.elem)
	case Struct:
		return info.align
	case Union:
		return info.align
	case Raw_Union:
		return info.align
	case Enum:
		return align_of_type_info(info.base)
	}

	return 0
}

align_formula :: proc(size, align: int) -> int {
	result := size + align-1
	return result - result%align
}

size_of_type_info :: proc(type_info: ^Type_Info) -> int {
	WORD_SIZE :: size_of(int)
	using Type_Info

	match type info : type_info {
	case Named:
		return size_of_type_info(info.base)
	case Integer:
		return info.size
	case Float:
		return info.size
	case Any:
		return 2*WORD_SIZE
	case String:
		return 2*WORD_SIZE
	case Boolean:
		return 1
	case Pointer:
		return WORD_SIZE
	case Maybe:
		return size_of_type_info(info.elem) + 1
	case Procedure:
		return WORD_SIZE
	case Array:
		count := info.count
		if count == 0 {
			return 0
		}
		size      := size_of_type_info(info.elem)
		align     := align_of_type_info(info.elem)
		alignment := align_formula(size, align)
		return alignment*(count-1) + size
	case Slice:
		return 3*WORD_SIZE
	case Vector:
		is_bool :: proc(type_info: ^Type_Info) -> bool {
			match type info : type_info {
			case Named:
				return is_bool(info.base)
			case Boolean:
				return true
			}
			return false
		}

		count := info.count
		if count == 0 {
			return 0
		}
		bit_size := 8*size_of_type_info(info.elem)
		if is_bool(info.elem) {
			// NOTE(bill): LLVM can store booleans as 1 bit because a boolean _is_ an `i1`
			// Silly LLVM spec
			bit_size = 1
		}
		total_size_in_bits := bit_size * count
		total_size := (total_size_in_bits+7)/8
		return total_size

	case Struct:
		return info.size
	case Union:
		return info.size
	case Raw_Union:
		return info.size
	case Enum:
		return size_of_type_info(info.base)
	}

	return 0
}
