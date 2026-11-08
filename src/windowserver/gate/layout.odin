package gate

LAYOUT_LIMIT :: 32
Layout_Item :: struct {wid: u32, x, y: i32}
Layout_Plan :: struct {
	items: [LAYOUT_LIMIT]Layout_Item,
	count: u32,
	building: bool,
}

layout_begin :: proc "contextless" (plan: ^Layout_Plan) {
	plan^ = {building = true}
}

layout_add :: proc "contextless" (plan: ^Layout_Plan, wid: u64, x, y: i32) -> bool {
	if !plan.building || plan.count >= LAYOUT_LIMIT || !placement_coordinates_valid(wid, i64(x), i64(y)) {return false}
	for index in 0 ..< plan.count {if plan.items[index].wid == u32(wid) {return false}}
	plan.items[plan.count] = {u32(wid), x, y}
	plan.count += 1
	return true
}

layout_seal :: proc "contextless" (plan: ^Layout_Plan, trigger: u64, budget_us: u64) -> bool {
	if !plan.building || plan.count == 0 || trigger == 0 || trigger > u64(max(u32)) || budget_us == 0 || budget_us > 8_000 {return false}
	// Use a distinct ordering marker so movement of an item cannot recurse
	// into the same trigger's ordered-in callback.
	for index in 0 ..< plan.count {if plan.items[index].wid == u32(trigger) {return false}}
	plan.building = false
	return true
}


placement_coordinates_valid :: proc "contextless" (wid: u64, x, y: i64) -> bool {
	return wid > 0 && wid <= u64(max(u32)) && x >= -1_000_000 && x <= 1_000_000 && y >= -1_000_000 && y <= 1_000_000
}

placement_pack :: proc "contextless" (x, y: i32) -> u64 {
	return u64(transmute(u32)x) | u64(transmute(u32)y) << 32
}

placement_unpack :: proc "contextless" (packed: u64) -> (x, y: i32) {
	return transmute(i32)u32(packed), transmute(i32)u32(packed >> 32)
}
