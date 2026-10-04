-- RE4 Tank Controls
-- Tank controls for Resident Evil 4 (2023), with an optional classic controller layout.
-- Up moves Leon the way he's facing and left/right turn him. Back walks backwards,
-- and back + run does a quick turn. F6 toggles the mod. Settings are in the REFramework menu.
--
-- Once PlayerHeadUpdater.updateMoveDirection has run, we read the raw stick, turn our own
-- heading with it and write that heading over the game's move and watch directions.

if reframework:get_game_name() ~= "re4" then return end

local VERSION = "1.2.10"
local CONFIG_FILE = "re4_tank_controls.json"
local RECORD_FILE = "re4_tank_controls_record.json"

-- Config

local cfg = {
    enabled = true,
    toggle_key = 0x75, -- F6
    turn_speed = 150.0, -- degrees per second
    deadzone = 0.25,
    camera_snap_back = false, -- also return behind Leon while standing still
    pitch_k = 0.0, -- learned pitch value -> angle ratio, 0 = unknown
    camera_input_pause = 1.5, -- seconds before the camera follows again after manual look
    aim_lock = true, -- no walking while aiming
    aim_from_facing = true, -- aiming starts from Leon's facing
    camera_pitch_band = 12.0, -- degrees of tilt kept when the camera height resets
    classic = false, -- classic controller layout
    show_debug = false,
}

do
    local loaded = json.load_file(CONFIG_FILE)
    if type(loaded) == "table" then
        for k, v in pairs(loaded) do
            if cfg[k] ~= nil and type(v) == type(cfg[k]) then cfg[k] = v end
        end
        -- old "Always behind Leon" camera mode
        if loaded.camera_mode == 2 and loaded.camera_snap_back == nil then cfg.camera_snap_back = true end
    end
end

local function save_cfg() json.dump_file(CONFIG_FILE, cfg) end

-- Math (yaw = atan2(x, z), forward is +Z)
local PI, TAU = math.pi, math.pi * 2
local function wrap(a) return (a + PI) % TAU - PI end
local function yaw_of(v) return math.atan(v.x, v.z) end
local function dir_of(h) return Vector3f.new(math.sin(h), 0.0, math.cos(h)) end
local function flat(v)
    local f = Vector3f.new(v.x, 0.0, v.z)
    if f:length() < 1e-4 then return nil end
    return f:normalized()
end
-- right of a flat forward vector
local function right_of(f) return Vector3f.new(-f.z, 0.0, f.x) end
local function vtab(v) return v and { v.x, v.y, v.z } or nil end

-- State
local S = {
    ctx = nil, body_addr = nil, body_tf = nil, updater_is_player = {},
    now = 0, dt = 1 / 60, frame = 0, step_frame = -1,
    body_yaw = nil, heading = nil,
    suspended = true, suspend_reason = "no player",
    stick_x = 0, stick_y = 0, game_dir = nil, game_inten = 0, head_is_player = {}, head_go_addr = nil,
    out_dir = nil, out_inten = nil, wrote = false, moving = false,
    quick_turn_left = 0, prev_back = false,
    cam_ctrl = nil, out_watch = nil, backpedal = false,
    cam_Y = nil, cam_last_set_Y = nil, cam_pause_until = 0, cam_active = false,
    hits = { head_update = 0, body_update = 0, cam_update = 0 },
    hooks = {},
    last_error = nil,
    toggle_down = false,
    record = nil, record_until = 0, record_status = "", auto_recorded = false,
}
if cfg.pitch_k ~= 0.0 then S.pitch_k = cfg.pitch_k end

local function try(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    S.last_error = tostring(r)
    return nil
end

-- Game access
local app_t = sdk.find_type_definition("via.Application")
local gp_t = sdk.find_type_definition("via.hid.GamePad")

local function game_time()
    local app = sdk.get_native_singleton("via.Application")
    if app == nil then return nil end
    local ok, t = pcall(sdk.call_native_func, app, app_t, "get_UpTimeSecond")
    if ok and type(t) == "number" then return t end
    return nil
end

-- Pad buttons (via.hid.GamePadButton bits) and trigger values.
local function pad_state()
    local gp = sdk.get_native_singleton("via.hid.GamePad")
    if gp == nil then return nil end
    local ok, pad = pcall(sdk.call_native_func, gp, gp_t, "get_LastInputDevice")
    if not ok or pad == nil then return nil end
    local okb, b = pcall(pad.call, pad, "get_Button")
    local okl, lt = pcall(pad.call, pad, "get_AnalogL")
    local okr, rt = pcall(pad.call, pad, "get_AnalogR")
    return { buttons = okb and b or nil, lt = okl and lt or nil, rt = okr and rt or nil }
end

local function pad_right_stick()
    local gp = sdk.get_native_singleton("via.hid.GamePad")
    if gp == nil then return nil end
    local ok, pad = pcall(sdk.call_native_func, gp, gp_t, "get_LastInputDevice")
    if not ok or pad == nil then return nil end
    local okr, r = pcall(pad.call, pad, "get_AxisR")
    return okr and r or nil
end

local function camera_forward()
    local cam = sdk.get_primary_camera()
    if cam == nil then return nil end
    local go = cam:call("get_GameObject")
    local tf = go and go:call("get_Transform")
    if tf == nil then return nil end
    local f = flat(tf:call("get_Rotation") * Vector3f.new(0.0, 0.0, -1.0))
    if f == nil then return nil end
    -- point it towards the player
    if S.body_tf ~= nil then
        local p = S.body_tf:call("get_Position") - tf:call("get_Position")
        if p.x * f.x + p.z * f.z < 0 then f = Vector3f.new(-f.x, 0.0, -f.z) end
    end
    return f
end

-- Yaw of the camera that's actually rendering.
local function rendered_camera_yaw()
    local cam = sdk.get_primary_camera()
    local go = cam and cam:call("get_GameObject")
    local tf = go and go:call("get_Transform")
    if tf == nil then return nil end
    local f = flat(tf:call("get_Rotation") * Vector3f.new(0.0, 0.0, -1.0))
    return f and yaw_of(f) or nil
end

-- Camera tilt in radians, positive is up.
local function camera_world_pitch()
    local cam = sdk.get_primary_camera()
    local go = cam and cam:call("get_GameObject")
    local tf = go and go:call("get_Transform")
    if tf == nil then return nil end
    local f = tf:call("get_Rotation") * Vector3f.new(0.0, 0.0, -1.0)
    return math.asin(math.max(-1.0, math.min(1.0, f.y)))
end

local function body_yaw()
    if S.body_tf == nil then return nil end
    local f = flat(S.body_tf:call("get_Rotation") * Vector3f.new(0.0, 0.0, 1.0))
    return f and yaw_of(f) or nil
end

-- The mod steps aside while any of these is set.
local SUSPEND_FLAGS = {
    "get_IsHolding", "get_IsHoldStart", "get_IsAiming", "get_IsLadder", "get_IsEventLocked",
    "get_IsTerrainAction", "get_IsMoveGimmickRide",
    "get_IsBoat",                 -- the lake boat
    "get_IsWheel",                -- turning a wheel / crank
    "get_IsLiftActing",           -- operating lifts
    "get_IsHookShot",             -- grapple
    "get_IsTerrainUpWithPartner", -- boosting Ashley up a ledge
    "get_IsTalkActing",
}

-- While aiming, the mod only stops Leon from walking.
local AIM_REASONS = { IsHolding = true, IsHoldStart = true, IsAiming = true }

local function check_suspended(ctx)
    for _, m in ipairs(SUSPEND_FLAGS) do
        local ok, v = pcall(ctx.call, ctx, m)
        if ok and v == true then return true, m:sub(5) end
    end
    return false, ""
end

local function run_pressed(ctx)
    for _, m in ipairs({ "get_IsButtonRun", "get_RequestButtonRun", "get_RequestRun" }) do
        local ok, v = pcall(ctx.call, ctx, m)
        if ok and v == true then return true end
    end
    return false
end

local function tank_active()
    return cfg.enabled and not S.suspended and S.heading ~= nil
end

-- True until the quick turn and its camera swing have finished. Weapons can't come up before then.
local function quick_turn_busy()
    return cfg.enabled and ((S.quick_turn_left or 0) > 0
        or (S.qt_cam_goal ~= nil and S.now <= (S.qt_cam_until or 0)))
end

-- Steering
local MOVE_DIR_FIELD = "<MoveDirection>k__BackingField"
local MOVE_INTEN_FIELD = "<MoveIntensity>k__BackingField"
local WATCH_DIR_FIELD = "<WatchDirection>k__BackingField"
local MAX_LEAD = math.rad(75) -- max heading lead over Leon's body
local QUICK_TURN_TIMEOUT = 1.0
local QUICK_TURN_GRACE = 0.15 -- before moving can cancel a quick turn
local QUICK_TURN_STALL = 0.2  -- no progress for this long ends a quick turn

-- share.hid.Command input hashes
local MOVE_POWER_HASH = 0x343fe603   -- move stick: vec2 (x right, y forward), float amount
local CAMERA_INPUT_HASH = 0xb1331f3d -- mouse delta
local AIM_BUTTON_HASH = 0x52965bd9   -- aim, float
local CAMERA_FOLLOW_RATE = 10.0
local CAMERA_HOLD_TIME = 2.0 -- no height adjustments this long after the game had control
local AIM_SNAP_TIME = 0.35
local AIM_SNAP_MIN_ANGLE = math.rad(15)
local AIM_SNAP_RATE = 18.0
local AIM_LEVEL_MIN_ANGLE = math.rad(3)
local COMMAND_FIELD = "<Command>k__BackingField"

local function player_command()
    if S.head == nil then return nil end
    local ok, cmd = pcall(S.head.get_field, S.head, COMMAND_FIELD)
    return ok and cmd or nil
end

local function command_float(hash)
    local cmd = player_command()
    if cmd == nil then return nil end
    local ok, v = pcall(cmd.call, cmd, "getFloat(System.UInt32)", hash)
    return ok and type(v) == "number" and v or nil
end

local function command_vec2(hash)
    local cmd = player_command()
    if cmd == nil then return nil end
    local ok, v = pcall(cmd.call, cmd, "getVec2(System.UInt32)", hash)
    if ok and v ~= nil and type(v.x) == "number" then return v end
    return nil
end

local function camera_yaw()
    if S.cam_ctrl ~= nil then
        local ok, y = pcall(S.cam_ctrl.call, S.cam_ctrl, "get_Yaw")
        if ok and type(y) == "number" then return y end
    end
    local f = camera_forward()
    return f and yaw_of(f) or nil
end

-- Raw move stick. Falls back to working it out from the game's move direction.
local function read_virtual_stick(head)
    local d = head:get_field(MOVE_DIR_FIELD)
    local i = head:get_field(MOVE_INTEN_FIELD) or 0
    S.game_dir, S.game_inten = d, i

    local raw = command_vec2(MOVE_POWER_HASH)
    S.raw_stick = raw ~= nil
    if raw ~= nil then
        S.stick_x, S.stick_y = raw.x, raw.y
        return
    end

    local c = camera_yaw()
    local md = d and flat(d)
    if c == nil or md == nil or i < 0.01 then
        S.stick_x, S.stick_y = 0, 0
        return
    end
    local f = dir_of(c)
    local r = right_of(f)
    local mag = math.min(i, 1.0)
    S.stick_x = (md.x * r.x + md.z * r.z) * mag
    S.stick_y = (md.x * f.x + md.z * f.z) * mag
end

local function steer()
    local x = S.stick_x
    local y = S.stick_y

    -- quick turn: back + run (classic: hold back, then press A)
    local back
    if cfg.classic then
        local a = S.pad_buttons ~= nil and (S.pad_buttons & 32) ~= 0
        back = y < -0.6 and a and not S.prev_a
        S.prev_a = a
    else
        back = y < -0.6 and run_pressed(S.ctx)
    end
    if back and not S.prev_back and S.quick_turn_left == 0 then
        S.quick_turn_left = 1
        S.qt_goal = wrap(S.body_yaw + PI)
        S.qt_start = S.now
        S.qt_until = S.now + QUICK_TURN_TIMEOUT
        S.qt_best, S.qt_best_time = PI, S.now
        S.qt_cam_goal, S.qt_cam_until = S.qt_goal, S.now + 0.9
    end
    S.prev_back = back

    if S.quick_turn_left > 0 then
        -- Leon's turn animation only keeps going while the target is within reach, so we
        -- keep it a fixed angle ahead of him. Clockwise, like the original.
        local remaining = (S.body_yaw - S.qt_goal) % TAU
        if remaining < S.qt_best - math.rad(1) then S.qt_best, S.qt_best_time = remaining, S.now end
        local moving_on = S.now - S.qt_start > QUICK_TURN_GRACE
            and (y > cfg.deadzone or math.abs(x) > 0.6)
        if moving_on then
            -- go the new way and finish turning on the move
            S.quick_turn_left = 0
            S.heading = S.qt_goal
        elseif remaining < math.rad(5) or remaining > TAU - math.rad(10) or S.now > S.qt_until
            or (S.now - S.qt_start > 0.3 and S.now - S.qt_best_time > QUICK_TURN_STALL) then
            -- done, or stuck against something
            S.quick_turn_left = 0
            S.heading = S.body_yaw
        else
            S.heading = wrap(S.body_yaw - math.min(remaining, MAX_LEAD))
        end
    elseif math.abs(x) > cfg.deadzone then
        -- turning right decreases yaw
        S.heading = wrap(S.heading - x * math.rad(cfg.turn_speed) * S.dt)
        local diff = wrap(S.heading - S.body_yaw)
        if math.abs(diff) > MAX_LEAD then
            S.heading = wrap(S.body_yaw + (diff > 0 and MAX_LEAD or -MAX_LEAD))
        end
    elseif math.abs(y) < cfg.deadzone then
        S.heading = S.body_yaw
    end
end

local RUN_REQUEST_FIELDS = {
    "<RequestRun>k__BackingField", "<RequestButtonRun>k__BackingField", "<RequestDash>k__BackingField",
}

local function is_running()
    for _, m in ipairs({ "get_IsRun", "get_IsRunStart", "get_IsRunLoop", "get_IsRunTurn" }) do
        local ok, v = pcall(S.ctx.call, S.ctx, m)
        if ok and v == true then return true end
    end
    return false
end

local function apply_fields(obj)
    obj:set_field(MOVE_DIR_FIELD, S.out_dir)
    obj:set_field(MOVE_INTEN_FIELD, S.out_inten)
    obj:set_field(WATCH_DIR_FIELD, S.out_watch or S.out_dir)
    if (S.backpedal or S.quick_turn_left > 0) and obj == S.ctx then
        -- stop the game's own run-turn from kicking in
        for _, f in ipairs(RUN_REQUEST_FIELDS) do obj:set_field(f, false) end
    end
end

local function write_output(head)
    local idle = math.abs(S.stick_x) < cfg.deadzone and math.abs(S.stick_y) < cfg.deadzone
    S.moving = not idle or S.quick_turn_left > 0
    if not S.moving then
        S.wrote = false
        return
    end
    -- The game plays its walk-back when Leon moves away from the way he's watching.
    S.backpedal = S.quick_turn_left == 0
        and S.stick_y < -cfg.deadzone
    S.out_watch = nil
    S.backpedal_waiting = false
    if S.backpedal and is_running() then
        -- stop first
        S.backpedal_waiting = true
        S.out_dir = dir_of(S.heading)
        S.out_inten = 0.0
    elseif S.backpedal then
        S.out_dir = dir_of(wrap(S.heading + PI))
        S.out_watch = dir_of(S.heading)
        S.out_inten = S.game_inten
    else
        S.out_dir = dir_of(S.heading)
        S.out_inten = 0.0
        if S.quick_turn_left == 0 and S.stick_y > cfg.deadzone then
            S.out_inten = S.game_inten
        end
    end
    apply_fields(head)
    apply_fields(S.ctx)
    S.wrote = true
end

local function tank_step(head)
    if S.ctx == nil or S.step_frame == S.frame then return end
    S.step_frame = S.frame

    read_virtual_stick(head)
    if not tank_active() then
        S.wrote, S.moving, S.quick_turn_left = false, false, 0
        if S.aim_locked then
            head:set_field(MOVE_INTEN_FIELD, 0.0)
            S.ctx:set_field(MOVE_INTEN_FIELD, 0.0)
        end
        return
    end
    steer()
    write_output(head)
end

-- Per frame
local function refresh_player()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    local ctx = cm and cm:call("getPlayerContextRef")
    local body = ctx and ctx:call("get_BodyGameObject")
    if ctx == nil or body == nil then
        S.ctx, S.body_addr, S.body_tf = nil, nil, nil
        return false
    end
    local addr = body:get_address()
    if addr ~= S.body_addr then
        S.updater_is_player, S.body_updater, S.hw_hub, S.hw_var, S.hw_saved = {}, nil, nil, nil, nil
    end
    S.ctx, S.body_addr = ctx, addr
    S.body_tf = body:call("get_Transform")
    -- Ashley's head is the same class as Leon's. Remember which one belongs to the player
    local hgo = ctx:call("get_HeadGameObject")
    local haddr = hgo and hgo:get_address() or nil
    if haddr ~= S.head_go_addr then
        S.head_go_addr, S.head_is_player, S.head = haddr, {}, nil
    end
    return true
end

local function update_toggle_key()
    local down = reframework:is_key_down(cfg.toggle_key)
    if down and not S.toggle_down then
        cfg.enabled = not cfg.enabled
        save_cfg()
    end
    S.toggle_down = down
end

-- For debug recordings.
local function head_snapshot()
    local out = {}
    local h = S.head
    local ok = pcall(function()
        local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
        local ctx = cm and cm:call("getPlayerContextRef")
        local hgo = ctx and ctx:call("get_HeadGameObject")
        out.head_go = hgo and string.format("%x", hgo:get_address()) or nil
        if h ~= nil then
            out.hooked_head = string.format("%x", h:get_address())
            out.hooked_head_go = string.format("%x", h:call("get_GameObject"):get_address())
            out.type = h:get_type_definition():get_full_name()
            local unit = h:get_field("_CurrentUnit")
            out.unit = unit and unit:get_type_definition():get_full_name() or nil
            out.dir = vtab(h:get_field(MOVE_DIR_FIELD))
            out.inten = h:get_field(MOVE_INTEN_FIELD)
            out.enabled = h:call("get_Enabled")
        end
    end)
    if not ok then out.err = true end
    return out
end

local function start_record(seconds, label)
    S.record = { version = VERSION, label = label, hooks = S.hooks, cfg = cfg, samples = {} }
    S.record_until = S.now + seconds
    S.record_status = "Recording (" .. label .. ")..."
end

local function record_sample()
    if S.record == nil then return end
    if S.now > S.record_until then
        json.dump_file(RECORD_FILE, S.record)
        S.record_status = "Saved reframework/data/" .. RECORD_FILE .. " (" .. #S.record.samples .. " samples)"
        S.record = nil
        return
    end
    table.insert(S.record.samples, {
        t = S.now, frame = S.frame, enabled = cfg.enabled,
        suspended = S.suspended, reason = S.suspend_reason, aim_locked = S.aim_locked,
        classic_ctx = S.classic_ctx, binding_refreshes = S.binding_refreshes,
        head = head_snapshot(),
        aim_prev = S.aim_prev, facing_yaw = S.facing_yaw, aim_snap = S.now <= (S.aim_snap_until or 0),
        aim_level = S.now <= (S.aim_level_until or 0), pitch_k = S.pitch_k,
        cam_pitch = S.cam_ctrl and S.cam_ctrl:call("get_Pitch") or nil, cam_world_pitch = camera_world_pitch(),
        hold_walk_var = S.hw_var ~= nil, hold_walk_saved = S.hw_saved,
        pad = pad_state(),
        cmd = S.cmd_frame, blocked_reads = S.blocked_reads, raw_stick = S.raw_stick,
        stick = { S.stick_x, S.stick_y }, backpedal = S.backpedal, bp_wait = S.backpedal_waiting,
        running = S.ctx and is_running() or nil,
        game_dir = vtab(S.game_dir), game_inten = S.game_inten,
        field_dir = vtab(S.ctx and S.ctx:get_field(MOVE_DIR_FIELD) or nil),
        field_inten = S.ctx and S.ctx:get_field(MOVE_INTEN_FIELD) or nil,
        field_watch = vtab(S.ctx and S.ctx:get_field(WATCH_DIR_FIELD) or nil),
        heading = S.heading, body_yaw = S.body_yaw, quick_turn_left = S.quick_turn_left,
        wrote = S.wrote, out_inten = S.out_inten, moving = S.moving,
        cam_Y = S.cam_Y, cam_active = S.cam_active, cam_paused = S.now < S.cam_pause_until,
        run = S.ctx and run_pressed(S.ctx) or nil,
        hits = { S.hits.head_update, S.hits.body_update, S.hits.cam_update },
        last_error = S.last_error,
    })
end

local function update()
    S.cmd_frame = {}
    S.frame = S.frame + 1
    local t = game_time()
    if t ~= nil and S.now > 0 then
        S.dt = math.max(0.0, math.min(t - S.now, 0.1))
    else
        S.dt = 1 / 60
    end
    S.now = t or (S.now + S.dt)

    update_toggle_key()

    if not refresh_player() then
        S.suspended, S.suspend_reason, S.heading = true, "no player", nil
        return
    end

    S.body_yaw = body_yaw()
    S.suspended, S.suspend_reason = check_suspended(S.ctx)
    -- no camera height adjustments while (and just after) the game is in charge
    local no_input = S.last_head_time ~= nil and S.now - S.last_head_time > 0.25
    if no_input or (S.suspended and AIM_REASONS[S.suspend_reason] ~= true) then
        S.pitch_hold_until = S.now + CAMERA_HOLD_TIME
    end

    -- log state changes
    local state = S.suspended and ("paused: " .. S.suspend_reason) or "steering"
    if state ~= S.logged_state then
        S.logged_state = state
        log.info("[RE4 Tank Controls] " .. state)
    end
    local head_quiet = S.last_head_time ~= nil and S.now - S.last_head_time > 1.0
    if head_quiet ~= S.logged_head_quiet then
        S.logged_head_quiet = head_quiet
        log.info("[RE4 Tank Controls] movement input hook " .. (head_quiet and "not running" or "running"))
    end
    local okb, boat = pcall(S.ctx.call, S.ctx, "get_IsBoat")
    S.in_boat = okb and boat == true
    -- in the boat the left stick steers, so aiming can't block it
    S.aim_locked = cfg.enabled and cfg.aim_lock and S.suspended and AIM_REASONS[S.suspend_reason] == true
        and not S.in_boat

    -- Remember which way Leon faces, so aiming starts from there rather than from the camera.
    local aim_now = (command_float(AIM_BUTTON_HASH) or 0) > 0.5
        or (S.suspended and AIM_REASONS[S.suspend_reason] == true)
    if aim_now and not S.aim_prev then
        S.aim_level_until = S.now + AIM_SNAP_TIME
        if quick_turn_busy() and S.qt_goal ~= nil then
            -- weapon came up mid quick turn
            S.facing_yaw, S.qt_cam_goal = S.qt_goal, nil
        end
    end
    if not aim_now then
        S.facing_yaw = S.body_yaw
    elseif not S.aim_prev and S.facing_yaw ~= nil and S.cam_Y ~= nil
        and math.abs(wrap(S.facing_yaw - S.cam_Y)) > AIM_SNAP_MIN_ANGLE then
        S.aim_snap_until = S.now + AIM_SNAP_TIME
    end
    if S.aim_prev and not aim_now then
        S.unaim_until = S.now + 0.6 -- reset camera height
    end
    -- turning also resets camera height
    if cfg.enabled and not S.suspended and not aim_now and math.abs(S.stick_x) > cfg.deadzone then
        S.unaim_until = S.now + 0.3
    end
    S.aim_prev = aim_now
    if not cfg.enabled or S.suspended or S.heading == nil then S.heading = S.body_yaw end

    -- debug: record the first movement
    if cfg.show_debug and not S.auto_recorded and (math.abs(S.stick_x) > 0.5 or math.abs(S.stick_y) > 0.5) then
        S.auto_recorded = true
        start_record(20, "auto")
    end
    record_sample()
end

re.on_pre_application_entry("UpdateBehavior", function()
    local ok, err = pcall(update)
    if not ok then S.last_error = tostring(err) end
end)

-- Hooks
local function install_hook(type_name, method_name, pre, post)
    local td = sdk.find_type_definition(type_name)
    local m = td and td:get_method(method_name)
    if m == nil then
        S.hooks[type_name .. "." .. method_name] = "MISSING"
        return
    end
    sdk.hook(m, pre, post)
    S.hooks[type_name .. "." .. method_name] = "ok"
end

local function decode_f32(retval)
    local bits = sdk.to_int64(retval) & 0xFFFFFFFF
    return (string.unpack("<f", string.pack("<I4", bits)))
end

-- Classic controls
-- Sits on top of the game's classic preset. Buttons are moved by rewriting the targets in
-- the player's KeyAssign table, and aim and fire come through Command.getFloat.
local PAD = { A = 32, X = 64, B = 128, Y = 16, LB = 256, LT = 512, RB = 1024, RT = 2048, LS = 4096, RS = 8192,
    NONE = 268435456 } -- a Joy-Con button, i.e. unbound
local HOLD_HASH = 0x52965bd9
local SHOT_HASH = 0x6a6af607

-- Action hashes. A binding fires if any button in its target mask is pressed.
local ACT = {
    RELOAD = 0x9491ed2d, INTERACT = 0x70b04bb9, PARRY = 0xe6dd2225,
    ESCAPE_KNIFE = 0x38324405, RT_FATAL = 0x1f266d80,
}

-- function(context, original target) -> classic target
local CLASSIC_ACTIONS = {
    -- reload only with the gun up
    [ACT.RELOAD] = function(ctx, orig)
        if ctx == "gun" then return orig | PAD.A end
        if ctx == "gun_wait" then return orig end
        return PAD.NONE
    end,
    -- prompts stay on their preset button
    [ACT.ESCAPE_KNIFE] = function(_, orig) return orig end,
    [ACT.RT_FATAL] = function(_, orig) return orig end,
}

-- LB actions (knife, parry) also go on LT
local function classic_target(rec, ctx)
    local rule = CLASSIC_ACTIONS[rec.hash]
    if rule ~= nil then return rule(ctx, rec.orig) end
    if rec.orig == PAD.LB then
        if ctx == "quickturn" then return PAD.NONE end
        return PAD.LB | PAD.LT
    end
    return rec.orig
end

local TARGET_FIELD = "<Target>k__BackingField"

-- Dictionary entries as { key, value } pairs.
local function dict_entries(d)
    local out = {}
    local entries = d:get_field("_entries") or d:get_field("entries")
    if entries == nil then return out end
    local n = entries:get_size()
    for i = 0, n - 1 do
        local e = entries:get_element(i)
        if e ~= nil then
            local hc = e:get_field("hashCode")
            local v = e:get_field("value")
            if v ~= nil and (hc == nil or hc >= 0) then table.insert(out, { key = e:get_field("key"), value = v }) end
        end
    end
    return out
end

-- known holds every binding we've changed, keyed by address, with its original button.
-- list is the player's current binding table.
local KB = { known = {}, list = nil, ka_addr = nil, dict_addr = nil, applied = nil, check_frame = 0 }

local function current_key_assign()
    local ka = S.head and S.head:get_field("_KeyAssign")
    local d = ka and ka:get_field("<BoolElementDictionary>k__BackingField")
    return ka, d
end

local function element_addresses(d)
    local addrs = {}
    for _, e in ipairs(dict_entries(d)) do
        local n = e.value:call("get_Count") or 0
        for i = 0, n - 1 do
            local el = e.value:call("get_Item", i)
            if el ~= nil then addrs[el:get_address()] = true end
        end
    end
    return addrs
end

local function collect_bindings(d)
    KB.list = {}
    for _, e in ipairs(dict_entries(d)) do
        local n = e.value:call("get_Count") or 0
        for i = 0, n - 1 do
            local el = e.value:call("get_Item", i)
            if el ~= nil and el:get_type_definition():get_full_name() == "share.hid.KeyAssign.GamePadButtonElement" then
                local addr = el:get_address()
                local rec = KB.known[addr]
                if rec == nil then
                    rec = { el = el, hash = e.key & 0xFFFFFFFF, orig = el:get_field(TARGET_FIELD) }
                    KB.known[addr] = rec
                end
                rec.el = el
                table.insert(KB.list, rec)
            end
        end
    end
    KB.applied = nil
end

-- nil restores the original bindings
local function apply_bindings(context)
    if context == nil then
        for _, rec in pairs(KB.known) do
            if rec.cur ~= nil and rec.cur ~= rec.orig then pcall(rec.el.set_field, rec.el, TARGET_FIELD, rec.orig) end
            rec.cur = rec.orig
        end
        KB.applied = nil
        return
    end
    if KB.list == nil or KB.applied == context then return end
    for _, rec in ipairs(KB.list) do
        local target = classic_target(rec, context)
        pcall(rec.el.set_field, rec.el, TARGET_FIELD, target)
        rec.cur = target
    end
    KB.applied = context
end

-- The game sometimes replaces or rebuilds the binding table, so check it every few frames.
local function maintain_bindings()
    local ka, d = current_key_assign()
    if d == nil then return end
    local ka_addr, d_addr = ka:get_address(), d:get_address()
    if ka_addr ~= KB.ka_addr or d_addr ~= KB.dict_addr then
        KB.ka_addr, KB.dict_addr = ka_addr, d_addr
        collect_bindings(d)
        S.binding_refreshes = (S.binding_refreshes or 0) + 1
        return
    end
    if KB.applied == nil or S.frame < KB.check_frame then return end
    KB.check_frame = S.frame + 5

    -- rebuilt in place with new binding objects?
    local addrs = element_addresses(d)
    local stale = false
    for _, rec in ipairs(KB.list) do
        if not addrs[rec.el:get_address()] then stale = true break end
    end
    if stale then
        collect_bindings(d)
        S.binding_refreshes = (S.binding_refreshes or 0) + 1
        return
    end

    for _, rec in ipairs(KB.list) do
        local ok, now = pcall(rec.el.get_field, rec.el, TARGET_FIELD)
        if ok and now ~= rec.cur then
            -- changed by the game or the player: treat as the new original
            rec.orig, rec.cur = now, nil
            KB.applied = nil
            S.binding_refreshes = (S.binding_refreshes or 0) + 1
        end
    end
end

local function pad_down(bit) return S.pad_buttons ~= nil and (S.pad_buttons & bit) ~= 0 end

-- Knife prompts are triggered with "Shot" (RT). When one is up, RT shouldn't raise the gun.
local KNIFE_PROMPT_MASK = 32 | 64 | 1024 -- Fatal_Knife | StealthKill | Knife_Rush

local function knife_prompt_available()
    local head = S.head
    if head == nil then return false end
    local ok, sel = pcall(head.call, head, "get_TargetSelectorDriver")
    if not ok or sel == nil then
        ok, sel = pcall(head.get_field, head, "<TargetSelectorDriver>k__BackingField")
    end
    if not ok or sel == nil then return false end
    local ok2, t = pcall(sel.call, sel, "get_CurrentTargetType")
    if not ok2 or type(t) ~= "number" then return false end
    S.target_type = t
    return (t & KNIFE_PROMPT_MASK) ~= 0
end

-- Left-stick aiming. Copies the left stick onto the right stick on the engine's gamepad
-- devices before the game reads them.
local function swap_sticks_for_aim()
    local gp = sdk.get_native_singleton("via.hid.GamePad")
    if gp == nil then return end
    local seen = {}
    local swapped = false
    for _, getter in ipairs({ "get_MergedDevice", "get_LastInputDevice" }) do
        local ok, dev = pcall(sdk.call_native_func, gp, gp_t, getter)
        if ok and dev ~= nil then
            local addr = dev:get_address()
            if not seen[addr] then
                seen[addr] = true
                for _, pair in ipairs({ { "AxisL", "AxisR" }, { "RawAxisL", "RawAxisR" } }) do
                    local okl, l = pcall(dev.call, dev, "get_" .. pair[1])
                    local okr, r = pcall(dev.call, dev, "get_" .. pair[2])
                    if okl and okr and l ~= nil and r ~= nil and (math.abs(l.x) > 0.0 or math.abs(l.y) > 0.0) then
                        local x, y = l.x + r.x, l.y + r.y
                        local m = math.sqrt(x * x + y * y)
                        if m > 1.0 then x, y = x / m, y / m end
                        pcall(dev.call, dev, "set_" .. pair[2], Vector2f.new(x, y))
                        pcall(dev.call, dev, "set_" .. pair[1], Vector2f.new(0.0, 0.0))
                        swapped = true
                    end
                end
            end
        end
    end
    if swapped then S.stick_swaps = (S.stick_swaps or 0) + 1 end
end

-- Del Lago fight remaps
local function remap_boat_buttons()
    local gp = sdk.get_native_singleton("via.hid.GamePad")
    if gp == nil then return end
    S.boat_prev = S.boat_prev or {}
    local seen = {}
    for _, getter in ipairs({ "get_MergedDevice", "get_LastInputDevice" }) do
        local ok, dev = pcall(sdk.call_native_func, gp, gp_t, getter)
        if ok and dev ~= nil and not seen[dev:get_address()] then
            local addr = dev:get_address()
            seen[addr] = true
            local okb, b = pcall(dev.call, dev, "get_Button")
            local oka, ar = pcall(dev.call, dev, "get_AnalogR")
            if okb and type(b) == "number" then
                ar = oka and type(ar) == "number" and ar or 0.0
                local rt = (b & PAD.RT) ~= 0 or ar > 0.3
                local x = (b & PAD.X) ~= 0
                local nb, nar
                if (b & PAD.LB) ~= 0 then
                    -- game layout: RT throws as normal, X throws too
                    nb, nar = b & ~PAD.X, ar
                    if x then nb, nar = nb | PAD.RT, 1.0 end
                else
                    nb = b & ~(PAD.RT | PAD.X)
                    if rt then nb = nb | PAD.LB end
                    if x then nb = nb | PAD.RT end
                    nar = x and 1.0 or 0.0
                end
                local prev = S.boat_prev[addr] or nb
                pcall(dev.call, dev, "set_Button", nb)
                pcall(dev.call, dev, "set_ButtonDown", nb & ~prev)
                pcall(dev.call, dev, "set_ButtonUp", prev & ~nb)
                pcall(dev.call, dev, "set_AnalogR", nar)
                S.boat_prev[addr] = nb
            end
        end
    end
end

local function update_classic()
    local pad = pad_state()
    S.pad_buttons = pad and pad.buttons or 0
    S.pad_rt = pad and pad.rt or 0
    -- stands down while the game is in charge (boat, ladders, events), but not while aiming
    local game_in_charge = (S.suspended and AIM_REASONS[S.suspend_reason] ~= true) or S.in_boat
    local on = cfg.enabled and cfg.classic and S.head ~= nil and not game_in_charge
    if on then
        local ok, err = pcall(maintain_bindings)
        if not ok then S.last_error = "bindings: " .. tostring(err) end
    end
    -- boat: the game's own controls, except RT readies the harpoon, X throws it
    -- and the left stick aims while it's up
    if cfg.enabled and cfg.classic and S.in_boat then
        S.classic_ctx = nil
        if KB.applied ~= nil then apply_bindings(nil) end
        if S.pad_rt > 0.3 or pad_down(PAD.LB) then swap_sticks_for_aim() end
        remap_boat_buttons()
        return
    end
    S.boat_prev = nil
    if not on then
        S.classic_ctx = nil
        if KB.applied ~= nil then apply_bindings(nil) end
        return
    end
    local was_gun = S.classic_ctx == "gun" or S.classic_ctx == "gun_wait"
    if quick_turn_busy() then
        S.classic_ctx = "quickturn"
    elseif S.pad_rt > 0.3 and (S.classic_ctx == "prompt" or (not was_gun and knife_prompt_available())) then
        S.classic_ctx = "prompt"
    elseif S.pad_rt > 0.3 then
        if S.classic_ctx ~= "gun" and S.classic_ctx ~= "gun_wait" and pad_down(PAD.A) then
            S.classic_ctx = "gun_wait"
        elseif S.classic_ctx == "gun_wait" and pad_down(PAD.A) then
            S.classic_ctx = "gun_wait"
        else
            S.classic_ctx = "gun"
        end
    elseif pad_down(PAD.LT) or pad_down(PAD.LB) then
        S.classic_ctx = "knife"
    else
        S.classic_ctx = "normal"
    end
    apply_bindings(S.classic_ctx)

    local weapon_up = S.classic_ctx == "gun" or S.classic_ctx == "gun_wait" or S.classic_ctx == "knife"
    if weapon_up then swap_sticks_for_aim() end
end

-- Override for an analog input, or nil to leave it.
local function classic_float(hash, orig)
    -- Leon stops turning on the spot once the stick is released, so keep it held for the whole quick turn
    if hash == MOVE_POWER_HASH and S.quick_turn_left > 0 and tank_active() then return 1.0 end
    if hash == HOLD_HASH and quick_turn_busy() then return 0.0 end
    if S.classic_ctx == nil then return nil end
    if hash == HOLD_HASH then return (S.classic_ctx ~= "prompt" and S.pad_rt > 0.3) and 1.0 or 0.0 end
    if hash == SHOT_HASH then
        if S.classic_ctx == "prompt" then return S.pad_rt end
        local up = S.classic_ctx == "gun" or S.classic_ctx == "gun_wait" or S.classic_ctx == "knife"
        return (up and pad_down(PAD.X)) and 1.0 or 0.0
    end
    return nil
end

re.on_pre_application_entry("UpdateBehavior", function()
    local ok, err = pcall(update_classic)
    if not ok then S.last_error = tostring(err) end
end)

local block_call = false
local override_hash = nil
install_hook("share.hid.Command", "getFloat(System.UInt32)",
    function(args)
        local hash = sdk.to_int64(args[3]) & 0xFFFFFFFF
        block_call = S.aim_locked == true and hash == MOVE_POWER_HASH
        override_hash = hash
        if S.record ~= nil then
            S.probe_key = string.format("getFloat|%08x|%x", hash, sdk.to_int64(args[2]))
        else
            S.probe_key = nil
        end
    end,
    function(retval)
        if S.probe_key ~= nil and S.cmd_frame ~= nil then
            local ok, v = pcall(decode_f32, retval)
            if ok then S.cmd_frame[S.probe_key] = v end
            S.probe_key = nil
        end
        local hash = override_hash
        override_hash = nil
        if block_call then
            block_call = false
            S.blocked_reads = (S.blocked_reads or 0) + 1
            return sdk.float_to_ptr(0.0)
        end
        if hash ~= nil then
            local ok, orig = pcall(decode_f32, retval)
            local v = classic_float(hash, ok and orig or nil)
            if v ~= nil then return sdk.float_to_ptr(v) end
        end
        return retval
    end)

-- Debug: log button reads while recording.
local function probe_bool(sig, label)
    local key = nil
    install_hook("share.hid.Command", sig,
        function(args)
            key = nil
            if S.record == nil then return end
            key = string.format("%s|%08x|%x", label, sdk.to_int64(args[3]) & 0xFFFFFFFF, sdk.to_int64(args[2]))
        end,
        function(retval)
            if key ~= nil and S.cmd_frame ~= nil and (sdk.to_int64(retval) & 0xFF) ~= 0 then
                S.cmd_frame[key] = true
            end
            key = nil
            return retval
        end)
end
probe_bool("isDown(System.UInt32)", "isDown")
probe_bool("isTrigger(System.UInt32)", "isTrigger")
probe_bool("isRelease(System.UInt32)", "isRelease")

-- Debug: log vec2 reads while recording (returned via a buffer, so args shift by one).
local vec2_key = nil
install_hook("share.hid.Command", "getVec2(System.UInt32)",
    function(args)
        vec2_key = nil
        if S.record == nil then return end
        vec2_key = string.format("getVec2|%08x|%x", sdk.to_int64(args[4]) & 0xFFFFFFFF, sdk.to_int64(args[3]))
    end,
    function(retval)
        if vec2_key ~= nil and S.cmd_frame ~= nil then
            local ok, vt = pcall(sdk.to_valuetype, sdk.to_int64(retval), "via.vec2")
            if ok and vt ~= nil then
                local okx, x = pcall(vt.read_float, vt, 0)
                local oky, y = pcall(vt.read_float, vt, 4)
                if okx and oky then S.cmd_frame[vec2_key] = { x, y } end
            end
            vec2_key = nil
        end
        return retval
    end)

-- Debug: dump the player's key bindings once.
local function describe_element(el)
    local info = { type = el:get_type_definition():get_full_name() }
    for _, f in ipairs({ "<ElementName>k__BackingField", "<Target>k__BackingField", "<Scope>k__BackingField",
        "<ComparisonType>k__BackingField" }) do
        local ok, v = pcall(el.get_field, el, f)
        if ok and v ~= nil then info[f:match("<(.-)>")] = type(v) == "userdata" and tostring(v) or v end
    end
    return info
end

local function dump_key_assign(head)
    local ka = head:get_field("_KeyAssign")
    if ka == nil then return "no KeyAssign" end
    local out = {}
    for _, kind in ipairs({ "Bool", "Float", "Vec2" }) do
        local d = ka:get_field("<" .. kind .. "ElementDictionary>k__BackingField")
        local list = {}
        if d ~= nil then
            for _, e in ipairs(dict_entries(d)) do
                local els = {}
                local n = e.value:call("get_Count") or 0
                for i = 0, n - 1 do
                    local el = e.value:call("get_Item", i)
                    if el ~= nil then table.insert(els, describe_element(el)) end
                end
                table.insert(list, { hash = string.format("%08x", e.key & 0xFFFFFFFF), elements = els })
            end
        end
        out[kind] = list
    end
    json.dump_file("re4_tank_keyassign.json", out)
    return "ok"
end

-- Ashley's head also uses PlayerHeadUpdater. Skip anything that isn't the player's.
local function is_player_head(arg)
    if S.head_go_addr == nil then return nil end
    local addr = sdk.to_int64(arg)
    local known = S.head_is_player[addr]
    if known == nil then
        local obj = sdk.to_managed_object(arg)
        local go = obj and obj:call("get_GameObject")
        known = go ~= nil and go:get_address() == S.head_go_addr
        S.head_is_player[addr] = known
    end
    return known
end

local player_head_call = false
install_hook("chainsaw.PlayerHeadUpdater", "updateMoveDirection",
    function(args)
        player_head_call = try(is_player_head, args[2]) == true
        if not player_head_call then return end
        S.hits.head_update = S.hits.head_update + 1
        S.last_head_time = S.now
        local head = sdk.to_managed_object(args[2])
        S.head = head
        if head ~= nil and cfg.show_debug and not S.keyassign_dumped then
            S.keyassign_dumped = true
            local ok, r = pcall(dump_key_assign, head)
            S.keyassign_status = ok and tostring(r) or ("error: " .. tostring(r))
            log.info("[RE4 Tank Controls] key binding dump: " .. S.keyassign_status)
        end
    end,
    function(retval)
        if player_head_call and S.head ~= nil then try(tank_step, S.head) end
        player_head_call = false
        return retval
    end)

-- Same for the body updater.
local function is_player_updater(arg)
    if S.body_addr == nil then return false end
    local addr = sdk.to_int64(arg)
    local known = S.updater_is_player[addr]
    if known == nil then
        local u = sdk.to_managed_object(arg)
        local go = u and u:call("get_GameObject")
        known = go ~= nil and go:get_address() == S.body_addr
        S.updater_is_player[addr] = known
    end
    return known
end

-- The game's own "no walking with a weapon raised" variable.
local function hold_walk_var()
    local u = S.body_updater
    if u == nil then return nil end
    local acc = u:get_field("<ActionVariablesHub>k__BackingField")
    if acc == nil then return nil end
    if S.hw_hub ~= acc:get_address() then
        S.hw_hub = acc:get_address()
        S.hw_var = acc:get_field("_DisableHoldWalk")
    end
    return S.hw_var
end

local function update_hold_walk_lock()
    local v = hold_walk_var()
    if v == nil then return end
    if S.aim_locked then
        if S.hw_saved == nil then S.hw_saved = v:call("get_Bool") end
        v:call("set_Bool", true)
    elseif S.hw_saved ~= nil then
        v:call("set_Bool", S.hw_saved)
        S.hw_saved = nil
    end
end

install_hook("chainsaw.PlayerBodyUpdater", "update",
    function(args)
        S.hits.body_update = S.hits.body_update + 1
        if S.ctx == nil or not try(is_player_updater, args[2]) then return end
        if S.body_updater == nil then S.body_updater = sdk.to_managed_object(args[2]) end
        try(update_hold_walk_lock)
        -- re-apply in case something changed them since
        if S.step_frame == S.frame then
            if S.wrote then
                try(apply_fields, S.ctx)
            elseif S.aim_locked then
                try(S.ctx.set_field, S.ctx, MOVE_INTEN_FIELD, 0.0)
            end
        end
    end,
    function(retval) return retval end)

-- Camera (controller yaw is world radians)
local PITCH_K_CANDIDATES = { 1.0, -1.0, math.pi / 180, -math.pi / 180 }
S.pitch_votes = { 0, 0, 0, 0 }

local function on_camera_update(ctrl)
    S.cam_ctrl = ctrl
    local Y = ctrl:call("get_Yaw")
    S.cam_Y = Y
    S.cam_active = false

    -- A cutscene camera is in charge if the rendered camera doesn't point where this
    -- controller does. Hands off entirely while it is, and off the height for a bit after.
    local W = rendered_camera_yaw()
    if type(Y) ~= "number" or W == nil or math.abs(wrap(Y - W)) > math.rad(10) then
        S.pitch_hold_until = S.now + CAMERA_HOLD_TIME
        S.pitch_last_P, S.cam_last_set_Y = nil, nil
        return
    end
    -- The blend back from a cutscene can still have the old tilt, so height
    -- adjustments wait until it's done.
    local pitch_hold = S.now < (S.pitch_hold_until or 0)
    if pitch_hold then S.pitch_last_P, S.unaim_until, S.aim_level_until = nil, 0, 0 end

    -- Work out the pitch value -> angle ratio from how both change each frame. Some areas
    -- add a pitch offset, which breaks comparing the absolute values.
    local P = ctrl:call("get_Pitch")
    local wp = camera_world_pitch()
    if not pitch_hold and type(P) == "number" and wp ~= nil and S.pitch_last_P ~= nil then
        local dP, dW = P - S.pitch_last_P, wp - S.pitch_last_wp
        if math.abs(dP) > 1e-5 and math.abs(dW) > 0.002 and math.abs(dW) < 0.3 then
            local ratio = dW / dP
            for i, k in ipairs(PITCH_K_CANDIDATES) do
                if math.abs(ratio / k - 1.0) < 0.25 then
                    S.pitch_votes[i] = S.pitch_votes[i] + 1
                    if S.pitch_votes[i] >= 10 and S.pitch_k ~= k then
                        S.pitch_k, cfg.pitch_k = k, k
                        save_cfg()
                    end
                end
            end
        end
    end
    if not pitch_hold then S.pitch_last_P, S.pitch_last_wp = P, wp end

    -- aim comes up level
    if cfg.enabled and cfg.aim_from_facing and S.pitch_k ~= nil and wp ~= nil and type(P) == "number"
        and S.now <= (S.aim_level_until or 0) then
        if math.abs(wp) < math.rad(1) then
            S.aim_level_until = 0
        elseif S.aim_level_started or math.abs(wp) > AIM_LEVEL_MIN_ANGLE then
            S.aim_level_started = true
            ctrl:call("setPitch", P - wp / S.pitch_k * math.min(1.0, AIM_SNAP_RATE * S.dt))
        else
            S.aim_level_until = 0
        end
    else
        S.aim_level_started = false
    end

    if cfg.enabled and cfg.aim_from_facing and S.facing_yaw ~= nil and S.now <= (S.aim_snap_until or 0)
        and type(Y) == "number" then
        local err = wrap(S.facing_yaw - Y)
        if math.abs(err) < math.rad(1) then
            S.aim_snap_until = 0
        else
            ctrl:call("setYaw", Y + err * math.min(1.0, AIM_SNAP_RATE * S.dt))
            S.cam_last_set_Y = nil
            return
        end
    end

    -- quick turn: swing the camera 180 clockwise, without waiting for Leon
    if cfg.enabled and S.qt_cam_goal ~= nil and type(Y) == "number" then
        local err = -((Y - S.qt_cam_goal) % TAU)
        if err < -(TAU - math.rad(10)) then err = err + TAU end -- overshot
        if math.abs(err) < math.rad(1) or S.now > (S.qt_cam_until or 0) then
            S.qt_cam_goal = nil
        else
            ctrl:call("setYaw", Y + err * math.min(1.0, 9.0 * S.dt))
            S.cam_last_set_Y = nil
            return
        end
    end

    -- Height reset: ease the tilt back into the band around level. Stops on manual look.
    if cfg.enabled and cfg.aim_from_facing and S.now <= (S.unaim_until or 0) then
        local r = pad_right_stick()
        local m = command_vec2(CAMERA_INPUT_HASH)
        local user = (r ~= nil and (math.abs(r.x) > 0.2 or math.abs(r.y) > 0.2))
            or (m ~= nil and (math.abs(m.x) > 0.01 or math.abs(m.y) > 0.01))
        local P = ctrl:call("get_Pitch")
        local D
        if S.pitch_k ~= nil and wp ~= nil and type(P) == "number" then
            local band = math.rad(cfg.camera_pitch_band)
            local target = math.max(-band, math.min(band, wp))
            D = P + (target - wp) / S.pitch_k
        else
            D = ctrl:call("get_DefaultPitch") -- ratio not learned yet
        end
        if user or type(P) ~= "number" or type(D) ~= "number" or math.abs(D - P) < 0.002 then
            S.unaim_until = 0
        else
            ctrl:call("setPitch", P + (D - P) * math.min(1.0, 10.0 * S.dt))
        end
    end

    -- classic: leave the camera alone while aiming
    if cfg.enabled and cfg.classic and S.aim_prev then
        S.cam_last_set_Y = nil
        return
    end

    if type(Y) ~= "number" or not tank_active() or S.body_yaw == nil then
        S.cam_last_set_Y = nil
        return
    end

    -- manual look pauses the follow
    local r = pad_right_stick()
    local user_moved = r ~= nil and (math.abs(r.x) > 0.2 or math.abs(r.y) > 0.2)
    local m = command_vec2(CAMERA_INPUT_HASH)
    if m ~= nil and (math.abs(m.x) > 0.01 or math.abs(m.y) > 0.01) then user_moved = true end

    -- without snap back, looking around while standing still doesn't delay the follow
    local follow_while_moving = not cfg.camera_snap_back
    if follow_while_moving and S.moving and not S.cam_was_moving and not user_moved then
        S.cam_pause_until = 0
    end
    S.cam_was_moving = S.moving
    if user_moved and (S.moving or not follow_while_moving) then
        S.cam_pause_until = S.now + cfg.camera_input_pause
    end

    local want = S.now >= S.cam_pause_until and (cfg.camera_snap_back or S.moving)
    if not want then
        S.cam_last_set_Y = nil
        return
    end

    -- follow the heading, not the body, so they don't chase each other
    local target = S.moving and S.heading or S.body_yaw
    local newY = Y + wrap(target - Y) * math.min(1.0, CAMERA_FOLLOW_RATE * S.dt)
    ctrl:call("setYaw", newY)
    S.cam_last_set_Y = newY
    S.cam_active = true
    -- also reset the height
    S.unaim_until = S.now + 0.3
end

install_hook("chainsaw.PlayerCameraController", "onCameraUpdate",
    function(args)
        S.hits.cam_update = S.hits.cam_update + 1
        local ctrl = sdk.to_managed_object(args[2])
        if ctrl ~= nil and S.ctx ~= nil then try(on_camera_update, ctrl) end
    end,
    function(retval) return retval end)

-- UI
local function fmt_deg(v) return v and string.format("%.1f", math.deg(v)) or "-" end

local function draw_debug()
    imgui.text(string.format("Suspended: %s %s", tostring(S.suspended), S.suspend_reason))
    imgui.text(string.format("Stick: x=%.2f y=%.2f (raw input=%s)  game intensity=%.2f  moving=%s",
        S.stick_x, S.stick_y, tostring(S.raw_stick), S.game_inten or 0, tostring(S.moving)))
    imgui.text(string.format("Heading: %s  Body yaw: %s  Camera yaw: %s  following=%s",
        fmt_deg(S.heading), fmt_deg(S.body_yaw), fmt_deg(S.cam_Y), tostring(S.cam_active)))
    imgui.text(string.format("Aim lock: %s  DisableHoldWalk var found: %s  blocked input reads: %d",
        tostring(S.aim_locked), tostring(S.hw_var ~= nil), S.blocked_reads or 0))
    imgui.text(string.format("Camera pitch mapping learned: %s", tostring(S.pitch_k)))
    imgui.text(string.format("Left-stick aim swaps: %d", S.stick_swaps or 0))
    imgui.text(string.format("Classic: context=%s  pad bindings=%d  applied=%s  refreshes=%d  target type=%s",
        tostring(S.classic_ctx), KB.list and #KB.list or 0, tostring(KB.applied), S.binding_refreshes or 0,
        tostring(S.target_type)))
    imgui.text(string.format("Hook hits: headUpdate=%d bodyUpdate=%d camUpdate=%d",
        S.hits.head_update, S.hits.body_update, S.hits.cam_update))
    for k, v in pairs(S.hooks) do imgui.text("  " .. k .. ": " .. v) end
    if S.last_error then imgui.text_colored("Last error: " .. S.last_error, 0xFF5555FF) end

    if S.record == nil then
        if imgui.button("Record 10 seconds") then start_record(10, "manual") end
        imgui.same_line()
        if imgui.button("Record 30 seconds") then start_record(30, "manual") end
        imgui.same_line()
    end
    imgui.text(S.record_status)
end

re.on_draw_ui(function()
    if not imgui.tree_node("RE4 Tank Controls v" .. VERSION) then return end
    local changed, v
    local any = false

    changed, v = imgui.checkbox("Enabled (F6)", cfg.enabled); if changed then cfg.enabled = v; any = true end
    changed, v = imgui.slider_float("Turn speed (deg/s)", cfg.turn_speed, 45.0, 360.0, "%.0f"); if changed then cfg.turn_speed = v; any = true end
    changed, v = imgui.slider_float("Stick deadzone", cfg.deadzone, 0.05, 0.6, "%.2f"); if changed then cfg.deadzone = v; any = true end

    imgui.text("")
    imgui.text("Camera swings behind Leon while he moves or turns.")
    changed, v = imgui.checkbox("Camera snaps back when standing still", cfg.camera_snap_back); if changed then cfg.camera_snap_back = v; any = true end
    changed, v = imgui.slider_float("Snap back delay (s)", cfg.camera_input_pause, 0.0, 5.0, "%.1f"); if changed then cfg.camera_input_pause = v; any = true end
    changed, v = imgui.slider_float("Camera height range (deg)", cfg.camera_pitch_band, 0.0, 45.0, "%.0f"); if changed then cfg.camera_pitch_band = v; any = true end

    imgui.text("")
    changed, v = imgui.checkbox("No walking while aiming", cfg.aim_lock); if changed then cfg.aim_lock = v; any = true end
    changed, v = imgui.checkbox("Aim where Leon is facing", cfg.aim_from_facing); if changed then cfg.aim_from_facing = v; any = true end

    imgui.text("")
    changed, v = imgui.checkbox("Classic controls (controller)", cfg.classic); if changed then cfg.classic = v; any = true end
    if cfg.classic then
        imgui.text_colored("  Set the game's controller preset to its classic layout first", 0xFF00FFFF)
        imgui.text_colored("  (LT weapon, LB knife, RT shoot, RB reload, X interact, A run).", 0xFF00FFFF)
        imgui.text("  A run, hold back then A: quick turn, X interact, B crouch")
        imgui.text("  RT ready gun, LT or LB ready knife")
        imgui.text("  Weapon up: X fire/slash, A or RB reload, left stick aims")
    end

    imgui.text("")
    changed, v = imgui.checkbox("Show debug info", cfg.show_debug); if changed then cfg.show_debug = v; any = true end
    if cfg.show_debug then draw_debug() end

    if any then save_cfg() end
    imgui.tree_pop()
end)

re.on_script_reset(function()
    pcall(apply_bindings, nil)
    if S.record ~= nil then json.dump_file(RECORD_FILE, S.record) end
end)

log.info("[RE4 Tank Controls] v" .. VERSION .. " loaded")
