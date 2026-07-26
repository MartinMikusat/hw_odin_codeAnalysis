package fixture

import helper "./helper"

Person :: struct {
	name: string,
}

greet :: proc(person: ^Person) -> string {
	return person.name
}

run :: proc() {
	value := Person{name = "Ada"}
	_ = greet(&value)
	helper.ping()
}
