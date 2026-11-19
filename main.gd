extends Node2D
# OUTBREAK - a "Where's My Water?"-style puzzle about a virus taking over cells.
# Everything is drawn in code, so there are no assets to import.
# Requires Godot 4.2+ (uses AStarGrid2D.region).

const COLS := 18
const ROWS := 10
const CS := 56.0                    # cell size in pixels
const OFFSET := Vector2(72, 64)     # where the grid sits on screen
const VIEW := Vector2(1152, 648)

# --- Tuning knobs -----------------------------------------------------------
const TICK := 0.35                  # seconds between infection spread rolls
const GROW_RATE := 0.8              # infection progress per second (1.0 = mature)
const KILL_TIME := 1.2              # seconds an antibody needs to destroy a cell
const SEED_RANGE := 3.3             # how far (in cells) from infection you can plant a spore
const BURST_COOLDOWN := 3.0
const MED_WARN := 2.2               # medicine warning time before it activates
const MED_ACTIVE := 5.0             # how long medicine stays active
const MED_POWER := 0.9              # infection progress removed per second inside medicine

enum Mode { TITLE, PLAYING, WON, LOST }

var LEVELS: Array = [
	{
		"name": "Common Cold",
		"hint": "Left-click a healthy cell near the infection to plant a spore. Infect every GOLD-nucleus cell!",
		"seeds": 3, "ab": 0, "ab_speed": 0.0, "ab_delay": 0.0,
		"med_interval": 0.0, "med_r": 0.0, "spread": 0.5,
		"map": [
			"##################",
			"#................#",
			"#................#",
			"#................#",
			"#E.............TT#",
			"#..............TT#",
			"#................#",
			"#................#",
			"#................#",
			"##################",
		],
	},
	{
		"name": "Seasonal Flu",
		"hint": "White Y-shaped antibodies destroy infected cells. Keep spreading faster than they can kill!",
		"seeds": 3, "ab": 1, "ab_speed": 38.0, "ab_delay": 12.0,
		"med_interval": 0.0, "med_r": 0.0, "spread": 0.45,
		"map": [
			"##################",
			"#......#.........#",
			"#E.....#.........#",
			"#......#......TT.#",
			"#................#",
			"#................#",
			"#......#......TT.#",
			"#......#.........#",
			"#......#.........#",
			"##################",
		],
	},
	{
		"name": "Bacterial Infection",
		"hint": "Walls block the spread, but spores can be planted across them (range ~3 cells).",
		"seeds": 4, "ab": 2, "ab_speed": 46.0, "ab_delay": 8.0,
		"med_interval": 0.0, "med_r": 0.0, "spread": 0.45,
		"map": [
			"##################",
			"#E.....#.....#..T#",
			"#......#.....#...#",
			"#......#..#..#...#",
			"#.........#......#",
			"#.........#...#..#",
			"#......#..#...#..#",
			"#......#......#..#",
			"#T.....#.....#..T#",
			"##################",
		],
	},
	{
		"name": "Pneumonia",
		"hint": "Blue rings are medicine drops. RIGHT-click a mature infected cell to burst it and spray spores (even over walls) before it's cured!",
		"seeds": 4, "ab": 3, "ab_speed": 52.0, "ab_delay": 6.0,
		"med_interval": 16.0, "med_r": 2.0, "spread": 0.42,
		"map": [
			"##################",
			"#E..............T#",
			"#.....##...##....#",
			"#.....#.....#....#",
			"#..###....###....#",
			"#................#",
			"#.....#.....#....#",
			"#.....##...##....#",
			"#T..............T#",
			"##################",
		],
	},
	{
		"name": "Sepsis",
		"hint": "The corridors are narrow and the body is fighting back hard. Use bursts to leap past the chokepoints.",
		"seeds": 5, "ab": 5, "ab_speed": 60.0, "ab_delay": 5.0,
		"med_interval": 11.0, "med_r": 2.4, "spread": 0.42,
		"map": [
			"##################",
			"#E....#......#..T#",
			"#.....#..##..#...#",
			"#.........##.....#",
			"####.####..####.##",
			"#................#",
			"#..##.......##...#",
			"#..#....##....#..#",
			"#T.....#..#.....T#",
			"##################",
		],
	},
	{
		"name": "Immune Storm",
		"hint": "Full immune response! Antibodies everywhere and medicine raining down. Good luck.",
		"seeds": 6, "ab": 8, "ab_speed": 68.0, "ab_delay": 4.0,
		"med_interval": 8.0, "med_r": 2.6, "spread": 0.4,
		"map": [
			"##################",
			"#E..............T#",
			"#................#",
			"#..##........##..#",
			"#..#..........#..#",
			"#T..............T#",
			"#..#..........#..#",
			"#..##........##..#",
			"#................#",
			"##################",
		],
	},
]

var mode: Mode = Mode.TITLE
var level_i := 0
var L: Dictionary = {}

# Per-cell data (flat arrays, index = y * COLS + x)
var solid := PackedByteArray()
var is_target := PackedByteArray()
var state := PackedInt32Array()      # 0 healthy, 1 infected, 2 debris (can't be infected for a while)
var prog := PackedFloat32Array()     # infection progress 0..1
var dead_t := PackedFloat32Array()
var phase := PackedFloat32Array()

var seeds := 0
var tick_t := 0.0
var time := 0.0
var level_t := 0.0
var burst_cd := 0.0
var targets_total := 0
var targets_done := 0

var antibodies: Array = []
var ab_to_spawn := 0
var ab_spawn_t := 0.0
var meds: Array = []
var med_t := 0.0
var fx: Array = []

var flash := 0.0
var flash_pos := Vector2.ZERO

var astar := AStarGrid2D.new()
var rng := RandomNumberGenerator.new()
var font: Font
var DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


func _ready() -> void:
	rng.randomize()
	font = ThemeDB.fallback_font


# ----------------------------------------------------------------------------
# Level loading / generation
# ----------------------------------------------------------------------------
func get_level(i: int) -> Dictionary:
	if i < LEVELS.size():
		return LEVELS[i]
	return gen_level(i)


func gen_level(i: int) -> Dictionary:
	var gr := RandomNumberGenerator.new()
	gr.seed = 7000 + i
	var rows: Array = []
	for y in range(ROWS):
		var s := ""
		for x in range(COLS):
			var ch := "."
			if x == 0 or y == 0 or x == COLS - 1 or y == ROWS - 1:
				ch = "#"
			elif x > 2 and x < COLS - 3 and gr.randf() < 0.15:
				ch = "#"
			s += ch
		rows.append(s)
	_set_char(rows, 1, gr.randi_range(1, ROWS - 2), "E")
	for k in range(3):
		_set_char(rows, COLS - 2, gr.randi_range(1, ROWS - 2), "T")
	var n := i - LEVELS.size() + 1
	return {
		"name": "Mutation %d" % n,
		"hint": "The immune system adapts. Endless mode: each stage is harder than the last.",
		"seeds": 6 + n / 2,
		"ab": 8 + n,
		"ab_speed": minf(120.0, 68.0 + 4.0 * n),
		"ab_delay": 3.0,
		"med_interval": maxf(4.0, 8.0 - 0.4 * n),
		"med_r": minf(3.2, 2.6 + 0.1 * n),
		"spread": 0.4,
		"map": rows,
	}


func _set_char(rows: Array, x: int, y: int, c: String) -> void:
	var s: String = rows[y]
	rows[y] = s.substr(0, x) + c + s.substr(x + 1)


func load_level(i: int) -> void:
	level_i = i
	L = get_level(i)
	var n := COLS * ROWS
	solid.resize(n)
	is_target.resize(n)
	state.resize(n)
	prog.resize(n)
	dead_t.resize(n)
	phase.resize(n)

	var rows: Array = L["map"]
	for y in range(ROWS):
		var line: String = rows[y] if y < rows.size() else ""
		for x in range(COLS):
			var ch: String = line[x] if x < line.length() else "#"
			var k := y * COLS + x
			solid[k] = 1 if ch == "#" else 0
			is_target[k] = 1 if ch == "T" else 0
			state[k] = 0
			prog[k] = 0.0
			dead_t[k] = 0.0
			phase[k] = rng.randf() * TAU
			if ch == "E":
				state[k] = 1
				prog[k] = 1.0

	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, COLS, ROWS)
	astar.cell_size = Vector2(CS, CS)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar.update()
	for y in range(ROWS):
		for x in range(COLS):
			if solid[y * COLS + x] == 1:
				astar.set_point_solid(Vector2i(x, y), true)

	seeds = L["seeds"]
	ab_to_spawn = L["ab"]
	ab_spawn_t = L["ab_delay"]
	med_t = L["med_interval"]
	antibodies.clear()
	meds.clear()
	fx.clear()
	burst_cd = 0.0
	level_t = 0.0
	tick_t = 0.0
	mode = Mode.PLAYING


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
func cell_center(c: Vector2i) -> Vector2:
	return (Vector2(c) + Vector2(0.5, 0.5)) * CS


func cell_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / CS), floori(p.y / CS))


func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < COLS and c.y < ROWS


func idx(c: Vector2i) -> int:
	return c.y * COLS + c.x


func mouse_cell() -> Vector2i:
	return cell_of(get_local_mouse_position() - OFFSET)


func infect(c: Vector2i) -> void:
	var k := idx(c)
	state[k] = 1
	prog[k] = 0.0


func add_ring(pos: Vector2, col: Color, radius: float, dur: float) -> void:
	fx.append({"pos": pos, "t": 0.0, "max": dur, "color": col, "r": radius})


func can_seed(c: Vector2i) -> bool:
	if not in_bounds(c):
		return false
	var k := idx(c)
	if solid[k] == 1 or state[k] != 0:
		return false
	var p := cell_center(c)
	for y in range(ROWS):
		for x in range(COLS):
			if state[y * COLS + x] == 1:
				if cell_center(Vector2i(x, y)).distance_to(p) <= SEED_RANGE * CS:
					return true
	return false


func infected_dist(c: Vector2i) -> int:
	var best := 999
	for y in range(ROWS):
		for x in range(COLS):
			if state[y * COLS + x] == 1:
				best = mini(best, absi(x - c.x) + absi(y - c.y))
	return best


func pick_target(from: Vector2i) -> Vector2i:
	var list: Array = []
	for y in range(ROWS):
		for x in range(COLS):
			if state[y * COLS + x] == 1:
				list.append([absi(x - from.x) + absi(y - from.y), Vector2i(x, y)])
	if list.is_empty():
		return Vector2i(-1, -1)
	list.sort_custom(func(a, b): return a[0] < b[0])
	var n := mini(3, list.size())
	return list[rng.randi_range(0, n - 1)][1]


# ----------------------------------------------------------------------------
# Input
# ----------------------------------------------------------------------------
func _unhandled_input(e: InputEvent) -> void:
	var key := e as InputEventKey
	if key and key.pressed and not key.echo:
		if key.keycode == KEY_R and mode != Mode.TITLE:
			load_level(level_i)
		return
	var mb := e as InputEventMouseButton
	if mb and mb.pressed:
		match mode:
			Mode.TITLE:
				load_level(0)
			Mode.WON:
				load_level(level_i + 1)
			Mode.LOST:
				load_level(level_i)
			Mode.PLAYING:
				var c := mouse_cell()
				if mb.button_index == MOUSE_BUTTON_LEFT:
					try_seed(c)
				elif mb.button_index == MOUSE_BUTTON_RIGHT:
					try_burst(c)


func try_seed(c: Vector2i) -> void:
	if seeds <= 0 or not can_seed(c):
		flash = 0.35
		flash_pos = cell_center(c)
		return
	seeds -= 1
	infect(c)
	add_ring(cell_center(c), Color(0.6, 1.0, 0.3), 40.0, 0.5)


func try_burst(c: Vector2i) -> void:
	if burst_cd > 0.0 or not in_bounds(c):
		return
	var k := idx(c)
	if state[k] != 1 or prog[k] < 0.5:
		return
	state[k] = 2
	dead_t[k] = 5.0
	burst_cd = BURST_COOLDOWN
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			if absi(dx) + absi(dy) > 2 or (dx == 0 and dy == 0):
				continue
			var n := Vector2i(c.x + dx, c.y + dy)
			if in_bounds(n) and solid[idx(n)] == 0 and state[idx(n)] == 0:
				infect(n)
	add_ring(cell_center(c), Color(1.0, 0.9, 0.3), CS * 2.5, 0.6)


# ----------------------------------------------------------------------------
# Simulation
# ----------------------------------------------------------------------------
func _process(dt: float) -> void:
	time += dt
	flash = maxf(0.0, flash - dt)
	if mode == Mode.PLAYING:
		step(dt)
	for f in fx:
		f["t"] += dt
	fx = fx.filter(func(f): return f["t"] < f["max"])
	queue_redraw()


func step(dt: float) -> void:
	level_t += dt
	burst_cd = maxf(0.0, burst_cd - dt)

	for k in range(COLS * ROWS):
		if state[k] == 1:
			prog[k] = minf(1.0, prog[k] + GROW_RATE * dt)
		elif state[k] == 2:
			dead_t[k] -= dt
			if dead_t[k] <= 0.0:
				state[k] = 0

	tick_t += dt
	if tick_t >= TICK:
		tick_t = 0.0
		spread()

	update_meds(dt)
	spawn_antibodies(dt)
	update_antibodies(dt)
	check_end()


func spread() -> void:
	var chance: float = L["spread"]
	var newly: Array[int] = []
	for y in range(ROWS):
		for x in range(COLS):
			var k := y * COLS + x
			if state[k] != 1 or prog[k] < 0.5:
				continue
			for d in DIRS:
				var nx: int = x + d.x
				var ny: int = y + d.y
				if nx < 0 or ny < 0 or nx >= COLS or ny >= ROWS:
					continue
				var nk: int = ny * COLS + nx
				if solid[nk] == 1 or state[nk] != 0:
					continue
				if rng.randf() < chance:
					newly.append(nk)
	for nk in newly:
		state[nk] = 1
		prog[nk] = 0.0


func spawn_antibodies(dt: float) -> void:
	if ab_to_spawn <= 0:
		return
	ab_spawn_t -= dt
	if ab_spawn_t > 0.0:
		return
	ab_spawn_t = 3.0
	var best := Vector2i(-1, -1)
	for attempt in range(40):
		var c := Vector2i(rng.randi_range(0, COLS - 1), rng.randi_range(0, ROWS - 1))
		if solid[idx(c)] == 1:
			continue
		best = c
		if infected_dist(c) >= 6:
			break
	if best.x < 0:
		return
	ab_to_spawn -= 1
	antibodies.append({"pos": cell_center(best), "path": [], "repath": 0.0, "kill": 0.0, "spawn": 1.0})


func update_antibodies(dt: float) -> void:
	var speed: float = L["ab_speed"]
	for ab in antibodies:
		if ab["spawn"] > 0.0:
			ab["spawn"] = maxf(0.0, ab["spawn"] - dt)
			continue
		var pos: Vector2 = ab["pos"]
		var c := cell_of(pos)
		if not in_bounds(c):
			continue
		# Standing on an infected cell: destroy it.
		if state[idx(c)] == 1:
			ab["kill"] += dt
			if ab["kill"] >= KILL_TIME:
				kill_cell(c)
				ab["kill"] = 0.0
				ab["repath"] = 0.0
			continue
		ab["kill"] = 0.0
		ab["repath"] -= dt
		if ab["repath"] <= 0.0:
			ab["repath"] = 0.5
			var tgt := pick_target(c)
			if tgt.x < 0:
				ab["path"] = []
			else:
				ab["path"] = astar.get_id_path(c, tgt)
		var path: Array = ab["path"]
		var i := path.find(c)
		if i == -1:
			ab["repath"] = 0.0
			continue
		if i + 1 >= path.size():
			ab["repath"] = 0.0
			continue
		var goal := cell_center(path[i + 1])
		var to_goal := goal - pos
		var stepd := speed * dt
		if to_goal.length() <= stepd:
			ab["pos"] = goal
		else:
			ab["pos"] = pos + to_goal.normalized() * stepd


func kill_cell(c: Vector2i) -> void:
	var k := idx(c)
	state[k] = 2
	dead_t[k] = 6.0
	add_ring(cell_center(c), Color(1.0, 0.3, 0.3), 36.0, 0.5)


func update_meds(dt: float) -> void:
	var interval: float = L["med_interval"]
	if interval > 0.0:
		med_t -= dt
		if med_t <= 0.0:
			med_t = interval
			spawn_med()
	for m in meds:
		m["t"] += dt
		if m["t"] <= MED_WARN:
			continue
		var mp: Vector2 = m["pos"]
		var r: float = m["r"] * CS
		for y in range(ROWS):
			for x in range(COLS):
				var k := y * COLS + x
				if state[k] != 1:
					continue
				if cell_center(Vector2i(x, y)).distance_to(mp) <= r:
					prog[k] -= MED_POWER * dt
					if prog[k] <= 0.0:
						prog[k] = 0.0
						state[k] = 2
						dead_t[k] = 4.0
						add_ring(cell_center(Vector2i(x, y)), Color(0.5, 0.8, 1.0), 30.0, 0.4)
	meds = meds.filter(func(m): return m["t"] < MED_WARN + MED_ACTIVE)


func spawn_med() -> void:
	var list: Array = []
	for y in range(ROWS):
		for x in range(COLS):
			if state[y * COLS + x] == 1:
				list.append(Vector2i(x, y))
	if list.is_empty():
		return
	var c: Vector2i = list[rng.randi_range(0, list.size() - 1)]
	var jitter := Vector2(rng.randf_range(-0.8, 0.8), rng.randf_range(-0.8, 0.8)) * CS
	meds.append({"pos": cell_center(c) + jitter, "t": 0.0, "r": L["med_r"]})


func check_end() -> void:
	var infected := 0
	targets_total = 0
	targets_done = 0
	for k in range(COLS * ROWS):
		if is_target[k] == 1:
			targets_total += 1
			if state[k] == 1 and prog[k] >= 1.0:
				targets_done += 1
		if state[k] == 1:
			infected += 1
	if targets_total > 0 and targets_done == targets_total:
		mode = Mode.WON
	elif infected == 0:
		mode = Mode.LOST


# ----------------------------------------------------------------------------
# Drawing
# ----------------------------------------------------------------------------
func txt(s: String, pos: Vector2, size: int = 20, col: Color = Color.WHITE,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0) -> void:
	draw_string(font, pos, s, align, width, size, col)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, VIEW), Color(0.12, 0.02, 0.05))
	if mode == Mode.TITLE:
		draw_title()
		return

	draw_set_transform(OFFSET, 0.0, Vector2.ONE)
	draw_rect(Rect2(Vector2.ZERO, Vector2(COLS * CS, ROWS * CS)), Color(0.36, 0.08, 0.14))
	for y in range(ROWS):
		for x in range(COLS):
			draw_cell(x, y)
	draw_meds()
	draw_antibodies()
	draw_hover()
	for f in fx:
		var k: float = f["t"] / f["max"]
		var col: Color = f["color"]
		col.a = 1.0 - k
		draw_arc(f["pos"], float(f["r"]) * k, 0.0, TAU, 32, col, 3.0)
	if flash > 0.0:
		draw_arc(flash_pos, 20.0, 0.0, TAU, 24, Color(1, 0.2, 0.2, flash / 0.35), 3.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	draw_hud()
	if mode == Mode.WON:
		draw_overlay("STAGE CLEARED",
			"Next: Stage %d - %s" % [level_i + 2, get_level(level_i + 1)["name"]],
			"Click to continue", Color(0.6, 1.0, 0.3))
	elif mode == Mode.LOST:
		draw_overlay("INFECTION PURGED",
			"The immune system wiped out the virus.",
			"Click to try again", Color(1.0, 0.4, 0.4))


func draw_cell(x: int, y: int) -> void:
	var k := y * COLS + x
	var c := (Vector2(x, y) + Vector2(0.5, 0.5)) * CS
	if solid[k] == 1:
		draw_rect(Rect2(c - Vector2(CS, CS) / 2.0 + Vector2(2, 2), Vector2(CS - 4, CS - 4)), Color(0.22, 0.09, 0.15))
		draw_rect(Rect2(c - Vector2(CS, CS) / 2.0 + Vector2(2, 2), Vector2(CS - 4, CS - 4)), Color(0.4, 0.18, 0.25), false, 2.0)
		return
	var st := state[k]
	if st == 2:
		draw_circle(c, 11.0, Color(0.3, 0.14, 0.18))
		draw_circle(c + Vector2(4, 3), 4.0, Color(0.25, 0.1, 0.14))
		return
	var r := CS * 0.4 + sin(time * 2.0 + phase[k]) * 1.2
	var memb := Color(0.93, 0.55, 0.62)
	var inner := Color(1.0, 0.78, 0.80)
	var nuc := Color(0.78, 0.35, 0.5)
	var p := prog[k]
	if st == 1:
		memb = memb.lerp(Color(0.45, 0.8, 0.25), p)
		inner = inner.lerp(Color(0.75, 1.0, 0.5), p)
		nuc = nuc.lerp(Color(0.2, 0.5, 0.15), p)
	draw_circle(c, r, memb)
	draw_circle(c, r - 3.0, inner)
	draw_circle(c + Vector2(3, -2), 7.0, nuc)
	if is_target[k] == 1:
		draw_arc(c, r + 3.0, 0.0, TAU, 40, Color(1.0, 0.85, 0.25), 3.0)
		draw_circle(c + Vector2(3, -2), 3.0, Color(1.0, 0.9, 0.3))
	if st == 1:
		for i in range(8):
			var d := Vector2.from_angle(TAU * i / 8.0 + time * 0.6)
			var sl := 3.0 + 6.0 * p
			draw_line(c + d * (r - 2.0), c + d * (r + sl), Color(0.7, 1.0, 0.3), 2.0)
			draw_circle(c + d * (r + sl), 2.0 + p, Color(0.85, 1.0, 0.4))
		if p < 1.0:
			draw_arc(c, r + 1.5, -PI / 2.0, -PI / 2.0 + TAU * p, 24, Color(0.9, 1.0, 0.5), 3.0)


func draw_antibodies() -> void:
	for ab in antibodies:
		var p: Vector2 = ab["pos"]
		var a: float = 1.0 - clampf(ab["spawn"], 0.0, 1.0)
		var col := Color(0.88, 0.94, 1.0, a)
		var q := p + Vector2(0, sin(time * 6.0 + p.x) * 1.5)
		draw_circle(q, 17.0, Color(0.3, 0.5, 1.0, 0.25 * a))
		draw_line(q + Vector2(0, 12), q, col, 4.0)
		draw_line(q, q + Vector2(-11, -12), col, 4.0)
		draw_line(q, q + Vector2(11, -12), col, 4.0)
		draw_circle(q + Vector2(-11, -12), 4.0, col)
		draw_circle(q + Vector2(11, -12), 4.0, col)
		draw_circle(q + Vector2(0, 13), 3.0, col)
		if ab["kill"] > 0.0:
			draw_arc(q, 22.0, -PI / 2.0, -PI / 2.0 + TAU * (ab["kill"] / KILL_TIME), 24, Color(1, 0.2, 0.2), 3.0)


func draw_meds() -> void:
	for m in meds:
		var mp: Vector2 = m["pos"]
		var mr: float = float(m["r"]) * CS
		var mt: float = m["t"]
		if mt < MED_WARN:
			var pulse := 0.5 + 0.5 * sin(time * 10.0)
			draw_arc(mp, mr, 0.0, TAU, 48, Color(0.4, 0.7, 1.0, 0.3 + 0.4 * pulse), 3.0)
			draw_arc(mp, mr * (mt / MED_WARN), 0.0, TAU, 48, Color(0.4, 0.7, 1.0, 0.4), 2.0)
		else:
			var left := 1.0 - (mt - MED_WARN) / MED_ACTIVE
			draw_circle(mp, mr, Color(0.3, 0.6, 1.0, 0.22 * clampf(left * 3.0, 0.0, 1.0)))
			draw_arc(mp, mr, 0.0, TAU, 48, Color(0.5, 0.8, 1.0, 0.8), 3.0)
			for i in range(6):
				var ang := time * 0.8 + i * TAU / 6.0
				var pp := mp + Vector2.from_angle(ang) * mr * 0.6
				draw_circle(pp, 5.0, Color(1, 1, 1, 0.85))
				draw_circle(pp + Vector2(5, 0).rotated(ang), 5.0, Color(0.5, 0.8, 1.0, 0.85))


func draw_hover() -> void:
	if mode != Mode.PLAYING:
		return
	var hc := mouse_cell()
	if not in_bounds(hc):
		return
	var c := cell_center(hc)
	if seeds > 0 and can_seed(hc):
		draw_arc(c, CS * 0.45, 0.0, TAU, 32, Color(0.6, 1.0, 0.3, 0.9), 2.0)
	elif state[idx(hc)] == 1 and prog[idx(hc)] >= 0.5 and burst_cd <= 0.0:
		draw_arc(c, CS * 0.45, 0.0, TAU, 32, Color(1.0, 0.9, 0.3, 0.9), 2.0)


func draw_hud() -> void:
	draw_rect(Rect2(0, 0, VIEW.x, 52), Color(0.07, 0.01, 0.03))
	txt("STAGE %d  -  %s" % [level_i + 1, L["name"]], Vector2(20, 33), 22, Color(0.9, 1.0, 0.7))
	txt("Spores:", Vector2(430, 33), 20)
	for i in range(seeds):
		draw_circle(Vector2(510 + i * 22, 26), 7.0, Color(0.6, 1.0, 0.3))
		draw_arc(Vector2(510 + i * 22, 26), 10.0, 0.0, TAU, 12, Color(0.6, 1.0, 0.3, 0.5), 1.5)
	# burst cooldown bar
	txt("Burst", Vector2(720, 33), 20)
	draw_rect(Rect2(780, 20, 90, 12), Color(0.2, 0.05, 0.1))
	draw_rect(Rect2(780, 20, 90 * (1.0 - burst_cd / BURST_COOLDOWN), 12), Color(1.0, 0.9, 0.3))
	txt("Targets %d / %d" % [targets_done, targets_total], Vector2(930, 33), 22, Color(1.0, 0.88, 0.3))
	var bottom := "Left-click: plant spore near infection   |   Right-click: burst a mature infected cell   |   R: restart stage"
	if level_t < 9.0:
		bottom = String(L["hint"])
	txt(bottom, Vector2(0, 644), 16, Color(0.85, 0.75, 0.8), HORIZONTAL_ALIGNMENT_CENTER, VIEW.x)


func draw_overlay(title: String, sub: String, prompt: String, col: Color) -> void:
	draw_rect(Rect2(Vector2.ZERO, VIEW), Color(0, 0, 0, 0.6))
	txt(title, Vector2(0, 270), 56, col, HORIZONTAL_ALIGNMENT_CENTER, VIEW.x)
	txt(sub, Vector2(0, 325), 24, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, VIEW.x)
	txt(prompt, Vector2(0, 390), 22, Color(0.8, 0.8, 0.8), HORIZONTAL_ALIGNMENT_CENTER, VIEW.x)


func draw_title() -> void:
	for i in range(14):
		var p := Vector2(120 + i * 70, 120 + sin(time + i) * 20)
		draw_circle(p, 26, Color(0.93, 0.55, 0.62, 0.35))
	txt("OUTBREAK", Vector2(0, 230), 80, Color(0.7, 1.0, 0.4), HORIZONTAL_ALIGNMENT_CENTER, VIEW.x)
	txt("Spread the infection to every gold-nucleus cell before the body stops you.",
		Vector2(0, 285), 22, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, VIEW.x)
	txt("Left-click: plant a spore near infected cells", Vector2(0, 350), 20, Color(0.85, 0.9, 0.7), HORIZONTAL_ALIGNMENT_CENTER, VIEW.x)
	txt("Right-click: burst a mature cell to spray spores (works over walls)", Vector2(0, 380), 20, Color(0.85, 0.9, 0.7), HORIZONTAL_ALIGNMENT_CENTER, VIEW.x)
	txt("Avoid antibodies (white Y's) and medicine zones (blue rings)", Vector2(0, 410), 20, Color(0.85, 0.9, 0.7), HORIZONTAL_ALIGNMENT_CENTER, VIEW.x)
	txt("Click to begin", Vector2(0, 490), 28, Color(1, 0.9, 0.4), HORIZONTAL_ALIGNMENT_CENTER, VIEW.x)
