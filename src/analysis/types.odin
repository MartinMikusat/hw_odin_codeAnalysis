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
	documentation: string,
	is_global: bool,
}

Document_Record :: struct {
	path:              string,
	package_directory: string,
	text:              string,
}

Capability_Primitive :: struct {
	id:           string,
	need:         string,
	search_terms: []string,
	kind:         string,
	parameter_types: []string,
	result_types: []string,
	generic_requirement: string,
	target_platform: string,
	allocation_behavior: string,
	ownership_requirement: string,
	allowed_sources: []string,
}

Capability_Audit_Input :: struct {
	target_project: string,
	primitives:     []Capability_Primitive,
}

Capability_Match :: struct {
	name:      string,
	kind:      string,
	signature: string,
	docs:      string,
	package_name: string `json:"package"`,
	import_path: string,
	qualified_symbol: string,
	file:      string,
	line:      int,
	source:    string,
	excerpt:   string,
	generic_constraints: string,
	platform: string,
	allocation_behavior: string,
	ownership: string,
	unknown_properties: []string,
	rank:      int,
	reasons:   []string,
}

Capability_Primitive_Result :: struct {
	id:      string,
	need:    string,
	status:  string,
	matches: []Capability_Match,
}

Capability_Audit_Result :: struct {
	target_project: string,
	compiler_root:  string,
	compiler_release: string,
	config_digest: string,
	generation:     u64,
	indexed_roots: []string,
	excluded_paths: []string,
	fsevents_flushed: bool,
	query_scope: string,
	result_limit: int,
	truncated: bool,
	last_rebuild_nanoseconds: i64,
	results:        []Capability_Primitive_Result,
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
	reason: string,
	next_action: string,
	active_package: string,
	visible_imports: []Import,
	scope_chain: []string,
	shadowing_declarations: []Symbol,
	rejected_candidates: []Symbol,
	analyzer_boundary: string,
}

Inspect_Result :: struct {
	resolution:      Resolution_Kind,
	symbols:         []Symbol,
	type_definitions: []Symbol,
	reference_count: int,
	explanation: Location_Result,
}

Status :: struct {
	root:             string,
	file_count:       int,
	symbol_count:     int,
	occurrence_count: int,
	generation:       u64,
	pid:              int,
	persistent:       bool,
	config_digest:    string,
}
