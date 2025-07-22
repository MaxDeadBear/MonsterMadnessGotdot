extends CharacterBody3D

@export var speed = 5.0
@export var run_speed = 8.0
@export var jump_velocity = 10.0
@export var mouse_sensitivity = 0.003
@export var rotation_speed = 3.0
@export var dodge_speed = 12.0
@export var dodge_duration = 0.525
@export var dodge_jump_height = 4.5

# Attack system variables
@export var attack_damage = 20.0
@export var attack_range = 2.5
@export var attack_duration = 0.6
@export var attack_cooldown = 0.2
@export var combo_window = 1.2

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity") * 3.0
var is_jumping = false
var is_dodging = false
var dodge_direction = Vector3.ZERO
var dodge_timer = 0.0
var shift_held = false
var space_pressed_time = 0.0
var space_held = false
var is_running = false
var run_delay = 0.25
var dodge_to_run_timer = 0.0
var can_run = true

# Attack system state
var is_attacking = false
var attack_timer = 0.0
var attack_cooldown_timer = 0.0
var combo_count = 0
var combo_timer = 0.0
var can_attack = true
var queued_attack = false
@export var player_physics_material: PhysicsMaterial

@onready var model = $Model
@onready var camera = $Camera3D
@onready var animation_player: AnimationPlayer
@onready var collision_shape = $CollisionShape3D

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	# Find animation player in the Jennifer model
	print("Looking for animation player in model...")
	animation_player = find_animation_player_in_children(model)
	if animation_player:
		print("AnimationPlayer found!")
		print("Available animations:")
		for anim_name in animation_player.get_animation_list():
			print("  - ", anim_name)
		
		# Connect to animation finished signal for combo chaining
		animation_player.animation_finished.connect(_on_animation_finished)
	else:
		print("No AnimationPlayer found in model!")
		print("Model children:")
		for child in model.get_children():
			print("  - ", child.name, " (", child.get_class(), ")")
			if child.get_children().size() > 0:
				for grandchild in child.get_children():
					print("    - ", grandchild.name, " (", grandchild.get_class(), ")")
	
	# Set up proper character collision shape
	setup_character_collision()

func _input(event):
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotation.y -= event.relative.x * mouse_sensitivity
	
	if Input.is_action_just_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	# Space for dodge and run
	if event is InputEventKey and event.keycode == KEY_SPACE:
		if event.pressed and not space_held:
			space_held = true
			space_pressed_time = 0.0
			
			# Immediate dodge if moving and on ground
			if not is_dodging and is_on_floor() and not is_running:
				var dodge_input = Vector2.ZERO
				if Input.is_key_pressed(KEY_W):
					dodge_input.y += 1
				if Input.is_key_pressed(KEY_S):
					dodge_input.y -= 1
				if Input.is_key_pressed(KEY_A):
					dodge_input.x -= 1
				if Input.is_key_pressed(KEY_D):
					dodge_input.x += 1
				
				if dodge_input != Vector2.ZERO:
					start_dodge(dodge_input)
		elif not event.pressed:
			space_held = false
			is_running = false
			space_pressed_time = 0.0
			dodge_to_run_timer = 0.0
			can_run = true
	
	# Shift for jump only
	if event is InputEventKey and event.keycode == KEY_SHIFT:
		if event.pressed and not shift_held:
			if is_on_floor() and not is_dodging:
				velocity.y = jump_velocity
				is_jumping = true
				play_jump_animation()
			shift_held = true
		elif not event.pressed:
			shift_held = false
	
	# Mouse clicks for attacks
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if can_attack and not is_dodging and not is_running and attack_cooldown_timer <= 0:
				start_attack()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if can_attack and not is_dodging and not is_running and attack_cooldown_timer <= 0:
				start_heavy_attack()

func _physics_process(delta):
	if not is_on_floor():
		velocity.y -= gravity * delta
		if not is_jumping:
			is_jumping = true
			play_jump_animation()
	else:
		if is_jumping:
			is_jumping = false

	# Handle dodge timer
	if is_dodging:
		dodge_timer -= delta
		if dodge_timer <= 0:
			is_dodging = false
			dodge_direction = Vector3.ZERO
			# Start delay timer for dodge to run transition if space is still held
			if space_held:
				dodge_to_run_timer = run_delay
				can_run = false
	
	# Handle dodge to run delay timer
	if dodge_to_run_timer > 0:
		dodge_to_run_timer -= delta
		if dodge_to_run_timer <= 0:
			can_run = true
	
	# Attack system now uses animation finished signals instead of timers
	
	# Handle attack cooldown timer
	if attack_cooldown_timer > 0:
		attack_cooldown_timer -= delta
	
	# Handle combo timer
	if combo_timer > 0:
		combo_timer -= delta
		if combo_timer <= 0:
			combo_count = 0
	
	# Handle space press timing for run
	if space_held:
		space_pressed_time += delta
		# Start running after delay if not dodging and allowed to run
		if space_pressed_time >= run_delay and not is_dodging and is_on_floor() and can_run:
			is_running = true

	# Get WASD input (always allow input, even while jumping)
	var input_dir = Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		input_dir.y += 1
	if Input.is_key_pressed(KEY_S):
		input_dir.y -= 1
	if Input.is_key_pressed(KEY_A):
		input_dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1
	
	# Handle movement based on state
	if is_dodging:
		# Apply dodge movement
		velocity.x = dodge_direction.x * dodge_speed
		velocity.z = dodge_direction.z * dodge_speed
	elif is_attacking:
		# Slow movement during attacks
		velocity.x = move_toward(velocity.x, 0, speed * 2.0)
		velocity.z = move_toward(velocity.z, 0, speed * 2.0)
	else:
		# Normal movement (works while jumping too)
		var current_speed = run_speed if is_running else speed
		
		if is_running:
			# Running mode - always go forward, A/D steers
			velocity.x = transform.basis.z.x * -current_speed
			velocity.z = transform.basis.z.z * -current_speed
			
			# A/D keys turn the player while running
			if Input.is_key_pressed(KEY_A):
				rotation.y += rotation_speed * delta
			elif Input.is_key_pressed(KEY_D):
				rotation.y -= rotation_speed * delta
		elif input_dir != Vector2.ZERO:
			# Normal movement mode
			var camera_basis = camera.global_transform.basis
			var forward = -camera_basis.z
			var right = camera_basis.x
			# Project onto horizontal plane
			forward.y = 0
			right.y = 0
			forward = forward.normalized()
			right = right.normalized()
			# Calculate movement direction relative to camera
			var direction = (forward * input_dir.y + right * input_dir.x).normalized()
			velocity.x = direction.x * current_speed
			velocity.z = direction.z * current_speed
		else:
			velocity.x = move_toward(velocity.x, 0, speed)
			velocity.z = move_toward(velocity.z, 0, speed)
		
		# Play movement animations (but not while jumping or attacking)
		if not is_jumping and not is_attacking:
			if is_running:
				play_movement_animation(Vector2(0, 1), true)  # Always forward animation when running
			elif input_dir != Vector2.ZERO:
				play_movement_animation(input_dir, false)
			else:
				play_idle_animation()
	
	move_and_slide()
	
	# Apply physics forces to objects we're touching
	for i in get_slide_collision_count():
		var collision = get_slide_collision(i)
		var collider = collision.get_collider()
		
		if collider is RigidBody3D:
			# Calculate push force based on player's movement direction and speed
			var push_direction = velocity.normalized()
			var push_force = velocity.length() * 0.5 # Adjust multiplier as needed
			
			# Apply force at the collision point for more realistic interaction
			collider.apply_impulse(push_direction * push_force, collision.get_position() - collider.global_transform.origin)

func play_movement_animation(input_dir: Vector2, is_running: bool = false):
	if not animation_player:
		return
	
	var anim_name = ""
	if is_running:
		# Use run animations for all directions
		anim_name = "Jennifer_animset_run_fast"
	else:
		# Use directional melee animations
		if input_dir.y > 0:  # Forward (W)
			anim_name = "Jennifer_animset_noweapon_melee_forward"
		elif input_dir.y < 0:  # Backward (S)
			anim_name = "Jennifer_animset_noweapon_melee_backward"
		elif input_dir.x < 0:  # Left (A)
			anim_name = "Jennifer_animset_noweapon_melee_left"
		elif input_dir.x > 0:  # Right (D)
			anim_name = "Jennifer_animset_noweapon_melee_right"
	
	if anim_name != "" and animation_player.has_animation(anim_name):
		if animation_player.current_animation != anim_name:
			animation_player.speed_scale = 1.0  # Normal speed for movement
			animation_player.play(anim_name, 0.2)

func play_idle_animation():
	if not animation_player:
		return
	
	var idle_anim = "Jennifer_animset_noweapon_stand"
	if animation_player.has_animation(idle_anim):
		if animation_player.current_animation != idle_anim:
			animation_player.speed_scale = 1.0  # Normal speed for idle
			animation_player.play(idle_anim, 0.3)

func play_jump_animation():
	if not animation_player:
		return
	
	var jump_anim = "Jennifer_animset_noweapon_melee_jump"
	if animation_player.has_animation(jump_anim):
		animation_player.speed_scale = 1.5  # Speed up the animation
		animation_player.play(jump_anim, 0.1)

func start_dodge(dodge_input: Vector2):
	is_dodging = true
	dodge_timer = dodge_duration
	
	# Get camera direction for dodge
	var camera_basis = camera.global_transform.basis
	var forward = -camera_basis.z
	var right = camera_basis.x
	# Project onto horizontal plane
	forward.y = 0
	right.y = 0
	forward = forward.normalized()
	right = right.normalized()
	# Calculate dodge direction relative to camera
	dodge_direction = (forward * dodge_input.y + right * dodge_input.x).normalized()
	
	# Add vertical arc to dodge
	velocity.y = dodge_jump_height
	
	play_dodge_animation(dodge_input)

func play_dodge_animation(dodge_input: Vector2):
	if not animation_player:
		return
	
	var dodge_anim = ""
	if dodge_input.y > 0:  # Forward (W)
		dodge_anim = "Jennifer_animset_dodgefront"
	elif dodge_input.y < 0:  # Backward (S)
		dodge_anim = "Jennifer_animset_dodgeback"
	elif dodge_input.x < 0:  # Left (A)
		dodge_anim = "Jennifer_animset_dodgeleft"
	elif dodge_input.x > 0:  # Right (D)
		dodge_anim = "Jennifer_animset_dodgeright"
	
	if dodge_anim != "" and animation_player.has_animation(dodge_anim):
		animation_player.speed_scale = 1.8  # Much faster dodge animation
		animation_player.play(dodge_anim, 0.05)

func setup_character_collision():
	# Create a properly sized capsule for character movement
	var capsule = CapsuleShape3D.new()
	capsule.height = 1.8  # Character height
	capsule.radius = 0.4  # Character width
	
	collision_shape.shape = capsule
	
	print("Set up character capsule collision: height=", capsule.height, " radius=", capsule.radius)

func find_animation_player_in_children(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	
	for child in node.get_children():
		var result = find_animation_player_in_children(child)
		if result:
			return result
	
	return null

func _on_animation_finished(anim_name: String):
	# Check if it was an attack animation
	if anim_name.contains("attack") or anim_name.contains("noweapon"):
		is_attacking = false
		
		# Check if we have a queued attack for combo chaining
		if queued_attack:
			queued_attack = false
			# NOW increment the combo count when starting the next attack
			combo_count += 1
			# Start the next combo attack immediately
			is_attacking = true
			combo_timer = combo_window
			play_attack_animation()
			perform_attack_damage()
		else:
			# No queued attack, start cooldown and reset combo
			attack_cooldown_timer = attack_cooldown

func start_attack():
	if is_attacking:
		# Combo system - queue next attack (but don't increment count until animation finishes)
		if combo_count < 4 and not queued_attack:  # Only queue if not already queued
			queued_attack = true
		return
	
	is_attacking = true
	combo_count = max(combo_count, 1)
	combo_timer = combo_window
	queued_attack = false
	
	play_attack_animation()
	perform_attack_damage()

func start_heavy_attack():
	if is_attacking:
		return  # No combos for heavy attacks
	
	is_attacking = true
	attack_timer = attack_duration * 1.5  # Heavy attacks take longer
	combo_count = 0  # Reset combo
	combo_timer = 0.0
	
	play_heavy_attack_animation()
	perform_heavy_attack_damage()

func play_attack_animation():
	if not animation_player:
		return
	
	var attack_anim = ""
	# Use no-weapon attacks since player is fighting with fists - 4 hit combo
	match combo_count:
		1:
			attack_anim = "Jennifer_animset_melee_noweaponA"
		2:
			attack_anim = "Jennifer_animset_melee_noweaponB"
		3:
			attack_anim = "Jennifer_animset_melee_noweaponC"
		4:
			attack_anim = "Jennifer_animset_melee_noweaponD"
		_:
			attack_anim = "Jennifer_animset_melee_noweaponA"
	
	# Fallback animations if specific combo animations don't exist
	if not animation_player.has_animation(attack_anim):
		var fallback_anims = [
			"Jennifer_animset_melee_noweaponD",  # Try the 4th no-weapon attack
			"Jennifer_animset_melee_lightattackA",  # Fall back to light attacks if needed
			"Jennifer_animset_melee_lightattackB", 
			"Jennifer_animset_melee_lightattackC",
			"Jennifer_animset_noweapon_melee_forward"  # Last resort
		]
		for anim in fallback_anims:
			if animation_player.has_animation(anim):
				attack_anim = anim
				break
	
	if animation_player.has_animation(attack_anim):
		animation_player.speed_scale = 1.3  # Speed up attack animation
		animation_player.play(attack_anim, 0.1)

func play_heavy_attack_animation():
	if not animation_player:
		return
	
	# Use special attacks for heavy attacks since noweaponD is now part of light combo
	var heavy_attack_anim = "Jennifer_animset_specialmeleeattack_A"
	
	# Fallback animations if heavy attack doesn't exist
	if not animation_player.has_animation(heavy_attack_anim):
		var fallback_anims = [
			"Jennifer_animset_specialmeleeattack_B",  # Other special attacks
			"Jennifer_animset_specialmeleeattack_C",
			"Jennifer_animset_specialmeleeattack_D",
			"Jennifer_animset_melee_heavyattackA",  # Fall back to weapon heavy attacks
			"Jennifer_animset_melee_heavyattackB",
			"Jennifer_animset_melee_heavyattackC",
			"Jennifer_animset_melee_noweaponD"  # Last resort - use the 4th combo as heavy
		]
		for anim in fallback_anims:
			if animation_player.has_animation(anim):
				heavy_attack_anim = anim
				break
	
	if animation_player.has_animation(heavy_attack_anim):
		animation_player.speed_scale = 0.8  # Slower heavy attack animation
		animation_player.play(heavy_attack_anim, 0.1)

func perform_attack_damage():
	# Get all bodies in attack range
	var space_state = get_world_3d().direct_space_state
	var forward_direction = -transform.basis.z
	var attack_position = global_position + forward_direction * (attack_range / 2)
	
	# Create a sphere query for attack detection
	var query = PhysicsShapeQueryParameters3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = attack_range / 2
	query.shape = sphere
	query.transform.origin = attack_position
	query.collision_mask = 1  # Adjust collision mask as needed
	query.exclude = [self]  # Don't hit self
	
	var results = space_state.intersect_shape(query)
	
	for result in results:
		var hit_body = result.collider
		if hit_body.has_method("take_damage"):
			hit_body.take_damage(attack_damage, global_position)
		elif hit_body is RigidBody3D:
			# Apply force to physics objects
			var force_direction = (hit_body.global_position - global_position).normalized()
			hit_body.apply_central_impulse(force_direction * attack_damage * 10)
		

func perform_heavy_attack_damage():
	# Similar to regular attack but with more damage and range
	var heavy_damage = attack_damage * 2.0
	var heavy_range = attack_range * 1.5
	
	var space_state = get_world_3d().direct_space_state
	var forward_direction = -transform.basis.z
	var attack_position = global_position + forward_direction * (heavy_range / 2)
	
	var query = PhysicsShapeQueryParameters3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = heavy_range / 2
	query.shape = sphere
	query.transform.origin = attack_position
	query.collision_mask = 1
	query.exclude = [self]
	
	var results = space_state.intersect_shape(query)
	
	for result in results:
		var hit_body = result.collider
		if hit_body.has_method("take_damage"):
			hit_body.take_damage(heavy_damage, global_position)
		elif hit_body is RigidBody3D:
			# Apply much stronger force for heavy attacks
			var force_direction = (hit_body.global_position - global_position).normalized()
			hit_body.apply_central_impulse(force_direction * heavy_damage * 20)
		
