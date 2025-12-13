--[[
@module  dm_can_motor
@summary DM CAN电机多电机控制驱动（重构版）
@version 2.0
@date    2025.12.13
@description
支持动态控制多个不同CAN ID的DM电机：
- 面向对象设计，每个电机独立管理
- 支持电机注册/移除
- 支持MIT模式、位置速度模式、速度模式
- 支持寄存器读写和状态反馈
- 统一的CAN总线管理

@usage
    local dm_motor = require "dm_can_motor"

    -- 初始化CAN总线
    dm_motor.can_init()

    -- 注册电机（CAN ID: 0x02）
    dm_motor.register_motor(0x02)

    -- 注册第二个电机（CAN ID: 0x03）
    dm_motor.register_motor(0x03)

    -- 控制电机0x02
    dm_motor.mit_control(0x02, 0, 5, 10, 0.5, 0)

    -- 控制电机0x03
    dm_motor.vel_control(0x03, 10)
]]

local dm_motor = {}

--------------
-- CAN相关配置
local CAN_ID = 0              -- CAN端口号
local br = 1000000            -- 1Mbps
local PTS = 6
local PBS1 = 6
local PBS2 = 4
local SJW = 2
--------------

-- 电机实例表（按CAN ID索引）
local motors = {}

-- 控制模式定义
local MODE_DEFINITIONS = {
    [1] = {name = "MIT模式", can_base = 0x0000},
    [2] = {name = "位置速度模式", can_base = 0x0100},
    [3] = {name = "速度模式", can_base = 0x0200},
}

-- 寄存器定义（简化版，完整定义见原文件）
local REGISTER_TYPES = {
    [0x07] = {name = "MST_ID", type = "uint32", desc = "反馈ID"},
    [0x0A] = {name = "CTRL_MODE", type = "uint32", desc = "控制模式"},
    [0x15] = {name = "PMAX", type = "float", desc = "位置映射范围", unit = "rad"},
    [0x16] = {name = "VMAX", type = "float", desc = "速度映射范围", unit = "rad/s"},
    [0x17] = {name = "TMAX", type = "float", desc = "扭矩映射范围", unit = "Nm"},
    [0x50] = {name = "p_m", type = "float", desc = "电机当前位置", unit = "rad"},
}

local KP_MAX = 50
local KD_MAX = 5

-------------------------------------------------------------------------
-------------------------------- 电机实例管理 --------------------------------
-------------------------------------------------------------------------

-- 创建电机实例
local function create_motor(can_id)
    return {
        can_id = can_id,           -- 电机CAN ID（8位）
        can_id_l = can_id % 256,   -- 低字节
        can_id_h = math.floor(can_id / 256), -- 高字节

        -- 电机参数（从寄存器读取）
        pmax = 12.5,               -- 位置映射范围 (rad)
        vmax = 280,                -- 速度映射范围 (rad/s)
        tmax = 1,                  -- 扭矩映射范围 (Nm)
        mst_id = 0x11,             -- 反馈ID

        -- 电机状态
        position = 0,              -- 当前位置 (rad)
        velocity = 0,              -- 当前速度 (rad/s)
        torque = 0,                -- 当前扭矩 (Nm)
        temperature_mos = 0,       -- MOS温度 (°C)
        temperature_rotor = 0,     -- 转子温度 (°C)
        error_code = 0,            -- 错误码
        mode = 0,                  -- 当前模式
        enabled = false,           -- 使能状态
    }
end

-- 注册电机
function dm_motor.register_motor(can_id)
    if motors[can_id] then
        log.warn("dm_motor", string.format("电机0x%02X已注册", can_id))
        return false
    end

    motors[can_id] = create_motor(can_id)
    log.info("dm_motor", string.format("注册电机 CAN ID: 0x%02X", can_id))

    -- 读取电机初始参数
    sys.taskInit(function()
        sys.wait(100)
        dm_motor.read_register(can_id, 0x07)  -- MST_ID
        sys.wait(100)
        dm_motor.read_register(can_id, 0x0A)  -- 控制模式
        sys.wait(100)
        dm_motor.read_register(can_id, 0x15)  -- PMAX
        sys.wait(100)
        dm_motor.read_register(can_id, 0x16)  -- VMAX
        sys.wait(100)
        dm_motor.read_register(can_id, 0x17)  -- TMAX
    end)

    return true
end

-- 移除电机
function dm_motor.unregister_motor(can_id)
    if not motors[can_id] then
        log.warn("dm_motor", string.format("电机0x%02X未注册", can_id))
        return false
    end

    motors[can_id] = nil
    log.info("dm_motor", string.format("移除电机 CAN ID: 0x%02X", can_id))
    return true
end

-- 获取电机实例
local function get_motor(can_id)
    local motor = motors[can_id]
    if not motor then
        log.error("dm_motor", string.format("电机0x%02X未注册", can_id))
    end
    return motor
end

-- 获取所有注册的电机
function dm_motor.get_motors()
    local motor_list = {}
    for can_id, motor in pairs(motors) do
        table.insert(motor_list, can_id)
    end
    return motor_list
end

-------------------------------------------------------------------------
-------------------------------- 辅助函数 --------------------------------
-------------------------------------------------------------------------

local function float_to_uint(x_float, x_min, x_max, bits)
    local span = x_max - x_min
    local offset = x_min
    local raw_value = (x_float - offset) * ((1 << bits) - 1) / span
    return math.floor(raw_value)
end

local function uint_to_float(x_int, x_min, x_max, bits)
    local span = x_max - x_min
    local offset = x_min
    return (x_int * span / (bit.lshift(1, bits) - 1)) + offset
end

local function uint16_to_int16(uint16)
    if bit.band(uint16, 0x8000) ~= 0 then
        return uint16 - 0x10000
    else
        return uint16
    end
end

local function uint12_to_int12(uint12)
    if bit.band(uint12, 0x800) ~= 0 then
        return uint12 - 0x1000
    else
        return uint12
    end
end

-------------------------------------------------------------------------
-------------------------------- CAN通信 --------------------------------
-------------------------------------------------------------------------

-- CAN发送函数
local function can_send(msg_id, id_type, RTR, need_ack, data)
    local result = can.tx(CAN_ID, msg_id, id_type, RTR, need_ack, data)
    if result == 0 then
        log.debug("can.tx", string.format("发送成功 ID:0x%X Data:%s", msg_id, data:toHex()))
    else
        log.error("can.tx", string.format("发送失败 ID:0x%X result:%d", msg_id, result))
    end
    return result == 0
end

-- 解析状态反馈帧
local function parse_feedback_frame(motor, frame)
    if #frame ~= 8 then return false end

    local d0 = string.byte(frame, 1)
    local d1 = string.byte(frame, 2)
    local d2 = string.byte(frame, 3)
    local d3 = string.byte(frame, 4)
    local d4 = string.byte(frame, 5)
    local d5 = string.byte(frame, 6)
    local d6 = string.byte(frame, 7)
    local d7 = string.byte(frame, 8)

    -- 解析错误状态
    local err = bit.rshift(bit.band(d0, 0xF0), 4)
    motor.error_code = err
    motor.enabled = (err == 1)

    -- 解析位置（16位）
    local pos_raw = bit.bor(bit.lshift(d1, 8), d2)
    if motor.pmax ~= 0 then
        motor.position = uint_to_float(pos_raw, -motor.pmax, motor.pmax, 16)
    end

    -- 解析速度（12位）
    local vel_high = bit.band(d3, 0xFF)
    local vel_low = bit.rshift(d4, 4)
    local vel_raw = bit.bor(bit.lshift(vel_high, 4), vel_low)
    if motor.vmax ~= 0 then
        motor.velocity = uint_to_float(vel_raw, -motor.vmax, motor.vmax, 12)
    end

    -- 解析扭矩（12位）
    local torque_high = bit.band(d4, 0x0F)
    local torque_low = bit.band(d5, 0xFF)
    local torque_raw = bit.bor(bit.lshift(torque_high, 8), torque_low)
    if motor.tmax ~= 0 then
        motor.torque = uint_to_float(torque_raw, -motor.tmax, motor.tmax, 12)
    end

    -- 解析温度
    motor.temperature_mos = d6
    motor.temperature_rotor = d7

    log.debug("motor_state", string.format("电机0x%02X: pos=%.2f vel=%.2f torque=%.2f err=0x%X",
        motor.can_id, motor.position, motor.velocity, motor.torque, err))

    return true
end

-- 解析寄存器数据
local function parse_register_data(motor, rid, d4, d5, d6, d7)
    local reg_info = REGISTER_TYPES[rid] or {name = "未知寄存器", type = "uint32"}
    local raw_value = d4 + d5*256 + d6*(256^2) + d7*(256^3)

    local value
    if reg_info.type == "float" then
        local float_bytes = string.char(d4, d5, d6, d7)
        value = string.unpack("<f", float_bytes)
    else
        value = raw_value
    end

    -- 更新电机参数
    if rid == 0x07 then
        motor.mst_id = value
    elseif rid == 0x0A then
        motor.mode = value
    elseif rid == 0x15 then
        motor.pmax = value
    elseif rid == 0x16 then
        motor.vmax = value
    elseif rid == 0x17 then
        motor.tmax = value
    end

    log.info("dm_motor", string.format("电机0x%02X 寄存器0x%02X=%s",
        motor.can_id, rid, tostring(value)))

    return true
end

-- CAN接收回调
local function can_callback(can_id, type, param)
    if type == can.CB_MSG then
        while true do
            local succ, msg_id, msg_type, rtr, data = can.rx(can_id)
            if not succ then break end

            if #data == 8 then
                local can_id_l = string.byte(data, 1)
                local can_id_h = string.byte(data, 2)
                local flag = string.byte(data, 3)

                -- 查找对应的电机
                local motor_can_id = bit.band(can_id_l, 0x0F)  -- 提取低4位作为电机ID
                local motor = motors[motor_can_id]

                if motor then
                    if flag == 0x33 then  -- 寄存器读取
                        local rid = string.byte(data, 4)
                        parse_register_data(motor, rid,
                            string.byte(data, 5), string.byte(data, 6),
                            string.byte(data, 7), string.byte(data, 8))
                    elseif flag == 0x55 then  -- 寄存器写入
                        log.debug("dm_motor", string.format("电机0x%02X 写入成功", motor_can_id))
                    else  -- 状态反馈
                        parse_feedback_frame(motor, data)
                    end
                end
            end
        end
    elseif type == can.CB_ERR then
        local direction = (param >> 16) & 0xFF
        local error_type = (param >> 8) & 0xFF
        log.error("CAN错误", "方向:", direction, "类型:", error_type)
    end
end

-- CAN初始化
function dm_motor.can_init()
    gpio.setup(27, 0)  -- CAN_STB
    gpio.setup(20, 1)  -- CAN_EN

    can.debug(false)

    local can_ret = can.init(CAN_ID, 128)
    if not can_ret then
        log.error("dm_motor", "CAN初始化失败")
        return false
    end

    can_ret = can.timing(CAN_ID, br, PTS, PBS1, PBS2, SJW)
    if not can_ret then
        log.error("dm_motor", "CAN波特率设置失败")
        return false
    end

    can.node(0, 0x011, can.STD)
    can.mode(0, can.MODE_NORMAL)
    can.on(CAN_ID, can_callback)

    log.info("dm_motor", "CAN初始化完成 波特率:1Mbps")
    return true
end

-------------------------------------------------------------------------
-------------------------------- 控制函数 --------------------------------
-------------------------------------------------------------------------

-- MIT模式控制
function dm_motor.mit_control(motor_can_id, p_des, v_des, kp, kd, t_ff)
    local motor = get_motor(motor_can_id)
    if not motor then return false end

    local p_int = float_to_uint(p_des, -motor.pmax, motor.pmax, 16)
    local v_int = float_to_uint(v_des, -motor.vmax, motor.vmax, 12)
    local kp_int = float_to_uint(kp, 0, KP_MAX, 12)
    local kd_int = float_to_uint(kd, 0, KD_MAX, 12)
    local t_int = float_to_uint(t_ff, -motor.tmax, motor.tmax, 12)

    local data = string.char(
        bit.rshift(p_int, 8), bit.band(p_int, 0xFF),
        bit.rshift(v_int, 4),
        bit.bor(bit.lshift(bit.band(v_int, 0x0F), 4), bit.rshift(kp_int, 8)),
        bit.band(kp_int, 0xFF),
        bit.rshift(kd_int, 4),
        bit.bor(bit.lshift(bit.band(kd_int, 0x0F), 4), bit.rshift(t_int, 8)),
        bit.band(t_int, 0xFF)
    )

    return can_send(motor.can_id, can.STD, false, true, data)
end

-- 位置速度模式控制
function dm_motor.pos_control(motor_can_id, p_des, v_des)
    local motor = get_motor(motor_can_id)
    if not motor then return false end

    local data = pack.pack("<ff", p_des, v_des)
    local can_id = 0x0100 + motor.can_id_l

    return can_send(can_id, can.STD, false, true, data)
end

-- 速度模式控制
function dm_motor.vel_control(motor_can_id, v_des)
    local motor = get_motor(motor_can_id)
    if not motor then return false end

    local data = pack.pack("<f", v_des)
    local can_id = 0x0200 + motor.can_id_l

    return can_send(can_id, can.STD, false, true, data)
end

-- 电机使能/失能
function dm_motor.send_mode_command(motor_can_id, mode, command_type)
    local motor = get_motor(motor_can_id)
    if not motor then return false end

    local mode_info = MODE_DEFINITIONS[mode]
    if not mode_info then
        log.error("dm_motor", string.format("无效模式: %d", mode))
        return false
    end

    local command_data_map = {
        enable = string.char(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFC),
        disable = string.char(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFD),
        save_zero = string.char(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE),
        clear_error = string.char(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFB)
    }

    local cmd_data = command_data_map[command_type]
    if not cmd_data then
        log.error("dm_motor", string.format("无效命令: %s", command_type))
        return false
    end

    return can_send(motor.can_id, can.STD, false, true, cmd_data)
end

-- 切换控制模式
function dm_motor.switch_mode(motor_can_id, mode)
    local motor = get_motor(motor_can_id)
    if not motor then return false end

    dm_motor.write_register(motor_can_id, 0x0A, mode, false)
    sys.wait(500)
    dm_motor.read_register(motor_can_id, 0x0A)

    return true
end

-- 读取寄存器
function dm_motor.read_register(motor_can_id, rid)
    local motor = get_motor(motor_can_id)
    if not motor then return false end

    local can_data = string.char(
        motor.can_id_l, motor.can_id_h,
        0x33, rid,
        0x00, 0x00, 0x00, 0x00
    )

    return can_send(0x7FF, can.STD, false, false, can_data)
end

-- 写入寄存器
function dm_motor.write_register(motor_can_id, rid, value, is_float)
    local motor = get_motor(motor_can_id)
    if not motor then return false end

    local reg_info = REGISTER_TYPES[rid] or {type = "uint32"}
    local data_bytes
    if is_float or reg_info.type == "float" then
        data_bytes = string.pack("<f", value)
    else
        data_bytes = string.pack("<I4", value)
    end

    local can_data = string.char(
        motor.can_id_l, motor.can_id_h,
        0x55, rid,
        string.byte(data_bytes, 1), string.byte(data_bytes, 2),
        string.byte(data_bytes, 3), string.byte(data_bytes, 4)
    )

    return can_send(0x7FF, can.STD, false, true, can_data)
end

-- 获取电机状态
function dm_motor.get_state(motor_can_id)
    local motor = get_motor(motor_can_id)
    if not motor then return nil end

    return {
        position = motor.position,
        velocity = motor.velocity,
        torque = motor.torque,
        temperature_mos = motor.temperature_mos,
        temperature_rotor = motor.temperature_rotor,
        error_code = motor.error_code,
        mode = motor.mode,
        enabled = motor.enabled
    }
end

return dm_motor
