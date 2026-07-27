package analysis

Source_Position :: struct {
	line:   int,
	column: int,
	offset: int,
}

Source_Range :: struct {
	start: Source_Position,
	end:   Source_Position,
}

Resolution_Kind :: enum {
	Exact,
	Ambiguous,
	Unresolved,
}

Symbol_Kind :: enum {
	Unknown,
	Package,
	Import,
	Constant,
	Variable,
	Procedure,
	Procedure_Group,
	Struct,
	Union,
	Enum,
	Field,
	Parameter,
}

Symbol_ID :: distinct int
File_ID   :: distinct int

Symbol :: struct {
	id:        Symbol_ID,
	name:      string,
	kind:      Symbol_Kind,
	path:      string,
	package_name: string,
	package_directory: string,
	owner_type: string,
	range:     Source_Range,
	extent:    Source_Range,
	detail:    string,
	is_global: bool,
}

Occurrence :: struct {
	name:       string,
	path:       string,
	package_name: string,
	package_directory: string,
	range:      Source_Range,
	symbol:     Symbol_ID,
	is_call:    bool,
	is_selector: bool,
	selector_base: string,
}

Import :: struct {
	path:         string,
	package_name: string,
	alias:        string,
	import_path:  string,
	resolved_path: string,
	is_using:     bool,
	range:        Source_Range,
}

Diagnostic_Severity :: enum {
	Error,
	Warning,
	Information,
}

Diagnostic :: struct {
	path:     string,
	range:    Source_Range,
	severity: Diagnostic_Severity,
	message:  string,
	source:   string,
}

Text_Edit :: struct {
	path:     string,
	range:    Source_Range,
	new_text: string,
}

Location_Result :: struct {
	resolution: Resolution_Kind,
	locations:  []Symbol,
}

Inspect_Result :: struct {
	resolution:      Resolution_Kind,
	symbols:         []Symbol,
	type_definitions: []Symbol,
	reference_count: int,
}

Status :: struct {
	root:             string,
	file_count:       int,
	symbol_count:     int,
	occurrence_count: int,
	generation:       u64,
	pid:              int,
	persistent:       bool,
}
