package nested

value := 1

first :: proc() {
	value := 2
	{
		value := 3
		_ = value
	}
	_ = value
}

second :: proc() {
	_ = value
}

Alpha :: struct { shared: int }
Beta :: struct { shared: string }

fields :: proc(alpha: Alpha, beta: Beta) {
	_ = alpha.shared
	_ = beta.shared
}
