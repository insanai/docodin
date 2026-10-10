package imageinfo_tests

import "core:math/rand"
import "core:testing"

import info ".."

// Exercise every truncation and arbitrary headers with bounds checking
// enabled. None should panic or manufacture zero-sized images.
@(test)
malformed_headers :: proc(t: ^testing.T) {
	buffer: [256]u8
	signatures := []string{"\x89PNG\r\n\x1a\n", "GIF89a", "BM", "\xff\xd8",
		"RIFF\x00\x00\x00\x00WEBP", "II*\x00", "MM\x00*"}
	for signature in signatures {
		for _ in 0 ..< 1000 {
			for &b in buffer do b = u8(rand.int_max(256))
			copy(buffer[:], transmute([]u8)signature)
			for n in 0 ..< len(buffer) {
				size, ok := info.from_bytes(buffer[:n])
				if ok do testing.expect(t, size.width > 0 && size.height > 0)
			}
		}
	}
}

@(test)
rejects_missing_files :: proc(t: ^testing.T) {
	_, ok, err := info.read_size("/no-such-docodin-image-info-file")
	testing.expect(t, !ok && err != nil)
}
