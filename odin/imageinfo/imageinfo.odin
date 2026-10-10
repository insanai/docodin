package imageinfo

import "core:hash"
import "core:os"

// Image dimensions only: no pixels are decoded or allocated. A bounded
// prefix covers common raster headers; unfamiliar, invalid or longer
// headers remain a Python need in the publisher.
Size :: struct {
	width, height: int,
}

MAX_HEADER :: 64 * 1024

read_size :: proc(path: string) -> (Size, bool, os.Error) {
	f, err := os.open(path)
	if err != nil do return {}, false, err
	defer os.close(f)
	header: [MAX_HEADER]u8
	n, _ := os.read_at(f, header[:], 0)
	size, ok := from_bytes(header[:n])
	return size, ok, nil
}

from_bytes :: proc(data: []u8) -> (Size, bool) {
	size: Size
	switch {
	case len(data) >= 33 && string(data[:8]) == "\x89PNG\r\n\x1a\n":
		size = png_size(data)
	case len(data) >= 13 && (string(data[:6]) == "GIF87a" || string(data[:6]) == "GIF89a"):
		size = {int(uint_le(data[6:8])), int(uint_le(data[8:10]))}
	case len(data) >= 26 && string(data[:2]) == "BM":
		size = bmp_size(data)
	case len(data) >= 2 && data[0] == 0xff && data[1] == 0xd8:
		size = jpeg_size(data)
	case len(data) >= 30 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP":
		size = webp_size(data)
	case len(data) >= 8 && (string(data[:4]) == "II*\x00" || string(data[:4]) == "MM\x00*"):
		size = tiff_size(data)
	}
	// Large images can trigger Pillow's configurable decompression-bomb
	// policy. Leave them to the fallback rather than silently bypass it.
	ok := size.width > 0 && size.height > 0 &&
		u64(size.width) * u64(size.height) <= 89_478_485
	return size, ok
}

// Verify metadata chunks before the first IDAT, as Pillow's lazy open
// does. Do not read or decompress the IDAT payload.
@(private = "file")
png_size :: proc(data: []u8) -> Size {
	if uint_be(data[8:12]) != 13 || string(data[12:16]) != "IHDR" do return {}
	depth, color := data[24], data[25]
	valid_depth := false
	switch color {
	case 0: valid_depth = depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16
	case 2, 4, 6: valid_depth = depth == 8 || depth == 16
	case 3: valid_depth = depth == 1 || depth == 2 || depth == 4 || depth == 8
	}
	if !valid_depth || data[26] != 0 || data[27] != 0 || data[28] > 1 do return {}
	for i := 8; i + 8 <= len(data); {
		length := int(uint_be(data[i:i + 4]))
		kind := string(data[i + 4:i + 8])
		if kind == "IDAT" {
			return {int(uint_be(data[16:20])), int(uint_be(data[20:24]))}
		}
		if length > len(data) - i - 12 || i + 12 > len(data) do return {}
		end := i + 8 + length
		if hash.crc32(data[i + 4:end]) != uint_be(data[end:end + 4]) do return {}
		if kind == "IEND" do return {}
		i = end + 4
	}
	return {}
}

@(private = "file")
uint_be :: proc(data: []u8) -> u32 {
	x: u32
	for b in data do x = x << 8 | u32(b)
	return x
}

@(private = "file")
uint_le :: proc(data: []u8) -> u32 {
	x: u32
	for b, i in data do x |= u32(b) << uint(8 * i)
	return x
}

@(private = "file")
bmp_size :: proc(data: []u8) -> Size {
	header := uint_le(data[14:18])
	if header == 12 do return {int(uint_le(data[18:20])), int(uint_le(data[20:22]))}
	if header < 40 || len(data) < 54 do return {}
	w := i32(uint_le(data[18:22]))
	h := i64(i32(uint_le(data[22:26])))
	return {int(w), int(abs(h))}
}

// JPEG markers carry their own lengths; stop before compressed pixels.
@(private = "file")
jpeg_size :: proc(data: []u8) -> Size {
	i := 2
	for i + 4 <= len(data) {
		if data[i] != 0xff do return {}
		for i < len(data) && data[i] == 0xff do i += 1
		if i >= len(data) do return {}
		marker := data[i]
		i += 1
		if marker == 0xd9 || marker == 0xda do return {}
		if marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7) do continue
		if i + 2 > len(data) do return {}
		length := int(uint_be(data[i:i + 2]))
		if length < 2 || length > len(data) - i do return {}
		if marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc {
			if length < 8 do return {}
			components := int(data[i + 7])
			if components < 1 || components > 4 || length != 8 + 3 * components do return {}
			return {int(uint_be(data[i + 5:i + 7])), int(uint_be(data[i + 3:i + 5]))}
		}
		i += length
	}
	return {}
}

@(private = "file")
webp_size :: proc(data: []u8) -> Size {
	switch string(data[12:16]) {
	case "VP8X":
		return {1 + int(uint_le(data[24:27])), 1 + int(uint_le(data[27:30]))}
	case "VP8L":
		if data[20] != 0x2f do return {}
		bits := uint_le(data[21:25])
		return {1 + int(bits & 0x3fff), 1 + int((bits >> 14) & 0x3fff)}
	case "VP8 ":
		if string(data[23:26]) != "\x9d\x01\x2a" do return {}
		return {int(uint_le(data[26:28]) & 0x3fff), int(uint_le(data[28:30]) & 0x3fff)}
	}
	return {}
}

@(private = "file")
tiff_size :: proc(data: []u8) -> Size {
	read := uint_le if data[0] == 'I' else uint_be
	offset := int(read(data[4:8]))
	if offset > len(data) - 2 do return {}
	count := int(read(data[offset:offset + 2]))
	offset += 2
	if count > (len(data) - offset) / 12 do return {}
	size: Size
	for i in 0 ..< count {
		entry := data[offset + i * 12:offset + (i + 1) * 12]
		tag, kind := read(entry[:2]), read(entry[2:4])
		if (tag != 256 && tag != 257) || read(entry[4:8]) != 1 do continue
		value: int
		switch kind {
		case 3: value = int(read(entry[8:10]))
		case 4: value = int(read(entry[8:12]))
		case: continue
		}
		if tag == 256 do size.width = value
		if tag == 257 do size.height = value
	}
	return size
}
