package reader

import "core:strings"

// The standard include files (``.. include:: <isonum.txt>``), embedded from
// the shim's copy of docutils' ``parsers/rst/include``.  The native tools
// then need no docutils data directory at run time: a path below any
// ``parsers/rst/include`` directory (``<docutils>/parsers/rst/include`` by
// default) that is not on disk is read from here.

STD_INCLUDE_DIR :: "parsers/rst/include"

@(private = "file")
STD_INCLUDE_FILES := #load_directory("../../python/docodin/shim/docutils/parsers/rst/include")

// The default directory of the standard include files.
DEFAULT_STD_INCLUDE_PATH :: "<docutils>/" + STD_INCLUDE_DIR

// The embedded standard include file at ``path``, if ``path`` names one.
standard_include :: proc(path: string) -> ([]u8, bool) {
	slash := strings.last_index_byte(path, '/')
	if slash < 0 || !strings.has_suffix(path[:slash], STD_INCLUDE_DIR) do return nil, false
	name := path[slash + 1:]
	for f in STD_INCLUDE_FILES {
		if f.name == name do return f.data, true
	}
	return nil, false
}
