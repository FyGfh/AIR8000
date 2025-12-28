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

-- 寄存器定义（完整版 - 参考达妙MATLAB库）
-- RW: 可读写, RO: 只读
local REGISTER_TYPES = {
    -- 保护参数 (0x00-0x03)
    [0x00] = {name = "UV_Value", type = "float", desc = "低压保护值", rw = true},
    [0x01] = {name = "KT_Value", type = "float", desc = "扭矩系数", rw = true},
    [0x02] = {name = "OT_Value", type = "float", desc = "过温保护值", rw = true},
    [0x03] = {name = "OC_Value", type = "float", desc = "过流保护值", rw = true},
    -- 运动参数 (0x04-0x06)
    [0x04] = {name = "ACC", type = "float", desc = "加速度", rw = true},
    [0x05] = {name = "DEC", type = "float", desc = "减速度", rw = true},
    [0x06] = {name = "MAX_SPD", type = "float", desc = "最大速度", rw = true},
    -- ID配置 (0x07-0x08)
    [0x07] = {name = "MST_ID", type = "uint32", desc = "反馈ID (Master ID)", rw = true},
    [0x08] = {name = "ESC_ID", type = "uint32", desc = "接收ID (Slave ID)", rw = true},
    -- 控制参数 (0x09-0x0A)
    [0x09] = {name = "TIMEOUT", type = "uint32", desc = "超时警报时间", rw = true},
    [0x0A] = {name = "CTRL_MODE", type = "uint32", desc = "控制模式", rw = true},
    -- 电机物理参数 (0x0B-0x14) - 只读
    [0x0B] = {name = "Damp", type = "float", desc = "电机粘滞系数", rw = false},
    [0x0C] = {name = "Inertia", type = "float", desc = "电机转动惯量", rw = false},
    [0x0D] = {name = "hw_ver", type = "uint32", desc = "硬件版本号", rw = false},
    [0x0E] = {name = "sw_ver", type = "uint32", desc = "软件版本号", rw = false},
    [0x0F] = {name = "SN", type = "uint32", desc = "序列号", rw = false},
    [0x10] = {name = "NPP", type = "uint32", desc = "电机极对数", rw = false},
    [0x11] = {name = "Rs", type = "float", desc = "电机相电阻", rw = false},
    [0x12] = {name = "Ls", type = "float", desc = "电机相电感", rw = false},
    [0x13] = {name = "Flux", type = "float", desc = "电机磁链值", rw = false},
    [0x14] = {name = "Gr", type = "float", desc = "齿轮减速比", rw = false},
    -- 映射范围 (0x15-0x17)
    [0x15] = {name = "PMAX", type = "float", desc = "位置映射范围", unit = "rad", rw = true},
    [0x16] = {name = "VMAX", type = "float", desc = "速度映射范围", unit = "rad/s", rw = true},
    [0x17] = {name = "TMAX", type = "float", desc = "扭矩映射范围", unit = "Nm", rw = true},
    -- 控制环参数 (0x18-0x22)
    [0x18] = {name = "I_BW", type = "float", desc = "电流环控制带宽", rw = true},
    [0x19] = {name = "KP_ASR", type = "float", desc = "速度环Kp", rw = true},
    [0x1A] = {name = "KI_ASR", type = "float", desc = "速度环Ki", rw = true},
    [0x1B] = {name = "KP_APR", type = "float", desc = "位置环Kp", rw = true},
    [0x1C] = {name = "KI_APR", type = "float", desc = "位置环Ki", rw = true},
    [0x1D] = {name = "OV_Value", type = "float", desc = "过压保护值", rw = true},
    [0x1E] = {name = "GREF", type = "float", desc = "齿轮力矩效率", rw = true},
    [0x1F] = {name = "Deta", type = "float", desc = "速度环阻尼系数", rw = true},
    [0x20] = {name = "V_BW", type = "float", desc = "速度环滤波带宽", rw = true},
    [0x21] = {name = "IQ_c1", type = "float", desc = "电流环增强系数", rw = true},
    [0x22] = {name = "VL_c1", type = "float", desc = "速度环增强系数", rw = true},
    -- CAN配置 (0x23)
    [0x23] = {name = "can_br", type = "uint32", desc = "CAN波特率代码", rw = true},
    -- 子版本 (0x24)
    [0x24] = {name = "sub_ver", type = "uint32", desc = "子版本号", rw = false},
    -- 校准参数 (0x32-0x37) - 只读
    [0x32] = {name = "u_off", type = "float", desc = "u相偏置", rw = false},
    [0x33] = {name = "v_off", type = "float", desc = "v相偏置", rw = false},
    [0x34] = {name = "k1", type = "float", desc = "补偿因子1", rw = false},
    [0x35] = {name = "k2", type = "float", desc = "补偿因子2", rw = false},
    [0x36] = {name = "m_off", type = "float", desc = "角度偏移", rw = false},
    [0x37] = {name = "dir", type = "float", desc = "方向", rw = false},
    -- 实时状态 (0x50-0x52) - 只读
    [0x50] = {name = "p_m", type = "float", desc = "电机当前位置", unit = "rad", rw = false},
    [0x51] = {name = "xout", type = "float", desc = "输出轴位置", unit = "rad", rw = false},
    [0x52] = {name = "t_m", type = "float", desc = "电机当前扭矩", unit = "Nm", rw = false},
}

-- 寄存器名称到地址的映射表
dm_motor.REG = {
    UV_Value = 0x00, KT_Value = 0x01, OT_Value = 0x02, OC_Value = 0x03,
    ACC = 0x04, DEC = 0x05, MAX_SPD = 0x06,
    MST_ID = 0x07, ESC_ID = 0x08, TIMEOUT = 0x09, CTRL_MODE = 0x0A,
    Damp = 0x0B, Inertia = 0x0C, hw_ver = 0x0D, sw_ver = 0x0E,
    SN = 0x0F, NPP = 0x10, Rs = 0x11, Ls = 0x12, Flux = 0x13, Gr = 0x14,
    PMAX = 0x15, VMAX = 0x16, TMAX = 0x17,
    I_BW = 0x18, KP_ASR = 0x19, KI_ASR = 0x1A, KP_APR = 0x1B, KI_APR = 0x1C,
    OV_Value = 0x1D, GREF = 0x1E, Deta = 0x1F, V_BW = 0x20,
    IQ_c1 = 0x21, VL_c1 = 0x22, can_br = 0x23, sub_ver = 0x24,
    p_m = 0x50, v_m = 0x51, t_m = 0x52,
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
        online = false,            -- 在线状态（是否有CAN响应）
        response_counter = 0,      -- 响应计数器（每次收到CAN响应时递增）
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
        log.info("can.tx", string.format("✓ 发送成功 CAN_ID:0x%03X DLC:%d Data:[%s]",
            msg_id, #data, data:toHex()))
    else
        log.error("can.tx", string.format("✗ 发送失败 CAN_ID:0x%03X result:%d", msg_id, result))
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

    -- 标记电机在线
    motor.online = true
    motor.response_counter = motor.response_counter + 1  -- 响应计数器递增

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

    -- 标记电机在线
    motor.online = true
    motor.response_counter = motor.response_counter + 1  -- 响应计数器递增

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
    elseif rid == 0x50 then
        -- 位置寄存器反馈
        motor.position = value
        log.debug("dm_motor", string.format("电机0x%02X 位置寄存器反馈: %.2f rad", motor.can_id, value))
    elseif rid == 0x51 then
        -- 速度寄存器反馈
        motor.velocity = value
        log.debug("dm_motor", string.format("电机0x%02X 速度寄存器反馈: %.2f rad/s", motor.can_id, value))
    elseif rid == 0x52 then
        -- 扭矩寄存器反馈
        motor.torque = value
        log.debug("dm_motor", string.format("电机0x%02X 扭矩寄存器反馈: %.2f Nm", motor.can_id, value))
    end

    if rid ~= 0x50 and rid ~= 0x51 and rid ~= 0x52 then
        log.info("dm_motor", string.format("电机0x%02X 寄存器0x%02X=%s",
            motor.can_id, rid, tostring(value)))
    end

    return true
end

-- CAN接收回调
local function can_callback(can_id, type, param)
    if type == can.CB_MSG then
        while true do
            local succ, msg_id, msg_type, rtr, data = can.rx(can_id)
            if not succ then break end

            log.debug("can_rx", string.format("收到CAN帧: msg_id=0x%03X, len=%d, data=%s",
                msg_id, #data, data:toHex()))

            if #data == 8 then
                local motor_can_id = nil
                local is_register_frame = false

                -- 先检查数据格式判断是否为寄存器帧
                local flag = string.byte(data, 3)
                if flag == 0x33 or flag == 0x55 then
                    -- 寄存器读写反馈帧 (CAN ID固定为0x7FF)
                    -- 数据格式：[电机ID_L][电机ID_H][flag][寄存器ID][数据4字节]
                    local can_id_l = string.byte(data, 1)
                    local can_id_h = string.byte(data, 2)
                    motor_can_id = bit.bor(can_id_l, bit.lshift(can_id_h, 8))
                    is_register_frame = true
                    log.debug("can_rx", string.format("寄存器帧: motor_id=0x%02X, flag=0x%02X, rid=0x%02X",
                        motor_can_id, flag, string.byte(data, 4)))
                else
                    -- 控制反馈帧
                    -- 达妙电机协议：
                    -- msg_id = MST_ID（Master ID，默认为0，可通过调试助手设置）
                    -- D[0] = ID | (ERR << 4)，其中ID是CAN_ID的低8位
                    -- 从D[0]低4位提取电机ID（注意：只支持ID 0-15）
                    local d0 = string.byte(data, 1)
                    motor_can_id = bit.band(d0, 0x0F)  -- 低4位是电机ID
                    local err = bit.rshift(d0, 4)       -- 高4位是错误/状态码
                    is_register_frame = false
                    log.debug("can_rx", string.format("控制反馈帧: msg_id=0x%03X(MST_ID), D[0]=0x%02X, motor_id=0x%02X, err=0x%X",
                        msg_id, d0, motor_can_id, err))
                end

                local motor = motors[motor_can_id]

                if motor then
                    if is_register_frame then
                        -- 寄存器读写反馈
                        if flag == 0x33 then  -- 寄存器读取
                            local rid = string.byte(data, 4)
                            parse_register_data(motor, rid,
                                string.byte(data, 5), string.byte(data, 6),
                                string.byte(data, 7), string.byte(data, 8))
                        elseif flag == 0x55 then  -- 寄存器写入确认
                            log.debug("dm_motor", string.format("电机0x%02X 写入成功", motor_can_id))
                            motor.response_counter = motor.response_counter + 1  -- 写入确认也算响应
                        end
                    else
                        -- 控制反馈帧：解析位置、速度、扭矩等状态
                        parse_feedback_frame(motor, data)
                    end
                else
                    log.debug("dm_motor", string.format("收到未注册电机的反馈: CAN ID=0x%02X, msg_id=0x%03X", motor_can_id or 0, msg_id))
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

    -- 配置CAN接收过滤器 - 接收所有标准帧
    -- 达妙电机反馈帧: 0x7FF(寄存器), 0x001-0x00F(MIT), 0x101-0x10F(位置速度), 0x201-0x20F(速度)
    can.filter(CAN_ID, 0, can.STD, 0x000, 0x000)  -- 接收所有标准帧 (掩码为0表示不过滤)
    can.mode(CAN_ID, can.MODE_NORMAL)
    can.on(CAN_ID, can_callback)

    log.info("dm_motor", "CAN初始化完成 波特率:1Mbps, 接收过滤器:接收所有标准帧")
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

    -- 速度模式协议: D[0]-D[3]=v_des(float,小端序), D[4]-D[7]=保留(填充0x00)
    local data = pack.pack("<f", v_des) .. string.char(0x00, 0x00, 0x00, 0x00)
    local can_id = 0x0200 + motor.can_id_l

    return can_send(can_id, can.STD, false, true, data)
end

-- 电机使能/失能/保存零点/清除错误
function dm_motor.send_mode_command(motor_can_id, mode, command_type)
    mode = mode or 2  -- 默认位置速度模式（不覆盖传入的mode参数）
    local motor = get_motor(motor_can_id)
    if not motor then return false end

    -- 使用传入的mode参数选择模式
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

    -- 使用选定模式对应的CAN ID
    local can_id = mode_info.can_base + motor.can_id_l

    log.info("dm_motor", string.format("发送%s命令: 电机0x%02X, 模式=%s, CAN_ID=0x%03X",
        command_type, motor_can_id, mode_info.name, can_id))

    return can_send(can_id, can.STD, false, true, cmd_data)
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

-- 保存参数到Flash（掉电保存）
-- 注意：必须在失能状态下执行
function dm_motor.save_param_to_flash(motor_can_id)
    local motor = get_motor(motor_can_id)
    if not motor then return false end

    -- 参考MATLAB代码：data_buf = uint8([can_id_l,can_id_h, 0xAA, 1, 0, 0, 0, 0])
    local can_data = string.char(
        motor.can_id_l, motor.can_id_h,
        0xAA, 0x01,  -- 0xAA = 保存参数命令标志
        0x00, 0x00, 0x00, 0x00
    )

    log.info("dm_motor", string.format("电机0x%02X 保存参数到Flash", motor_can_id))
    return can_send(0x7FF, can.STD, false, true, can_data)
end

-- 刷新电机状态（主动请求电机返回当前状态）
-- 用于在不发送控制命令时获取电机实时状态
function dm_motor.refresh_status(motor_can_id)
    local motor = get_motor(motor_can_id)
    if not motor then return false end

    -- 参考MATLAB代码：data_buf = uint8([can_id_l,can_id_h, 0xCC, 0, 0, 0, 0, 0])
    local can_data = string.char(
        motor.can_id_l, motor.can_id_h,
        0xCC, 0x00,  -- 0xCC = 刷新状态命令标志
        0x00, 0x00, 0x00, 0x00
    )

    log.debug("dm_motor", string.format("电机0x%02X 刷新状态", motor_can_id))
    return can_send(0x7FF, can.STD, false, false, can_data)
end

-- 刷新电机状态（带确认）
function dm_motor.refresh_status_confirmed(motor_can_id, timeout_ms)
    return dm_motor.send_and_wait(motor_can_id, function()
        return dm_motor.refresh_status(motor_can_id)
    end, timeout_ms or 200)
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
        enabled = motor.enabled,
        online = motor.online,
        response_counter = motor.response_counter
    }
end

-- 等待电机响应（通过监测response_counter变化）
-- motor_can_id: 电机CAN ID
-- timeout_ms: 超时时间（毫秒）
-- 返回: true=收到响应, false=超时
function dm_motor.wait_response(motor_can_id, timeout_ms)
    local motor = get_motor(motor_can_id)
    if not motor then return false end

    timeout_ms = timeout_ms or 200  -- 默认200ms超时

    local start_counter = motor.response_counter
    local wait_interval = 10  -- 每10ms检查一次
    local elapsed = 0

    while elapsed < timeout_ms do
        sys.wait(wait_interval)
        elapsed = elapsed + wait_interval

        if motor.response_counter > start_counter then
            log.debug("dm_motor", string.format("电机0x%02X 收到响应，耗时%dms", motor_can_id, elapsed))
            return true
        end
    end

    log.warn("dm_motor", string.format("电机0x%02X 等待响应超时 (%dms)", motor_can_id, timeout_ms))
    return false
end

-- 检查电机是否在线（基于最近是否有响应）
function dm_motor.is_online(motor_can_id)
    local motor = get_motor(motor_can_id)
    if not motor then return false end
    return motor.online
end

-- 发送命令并等待反馈帧
-- 返回: true=发送成功且收到反馈, false=发送失败或超时无反馈
function dm_motor.send_and_wait(motor_can_id, send_func, timeout_ms)
    local motor = get_motor(motor_can_id)
    if not motor then
        log.warn("dm_motor", string.format("电机0x%02X 未注册", motor_can_id))
        return false
    end

    timeout_ms = timeout_ms or 200

    -- 记录发送前的响应计数
    local start_counter = motor.response_counter

    -- 执行发送函数
    local send_ok = send_func()
    if not send_ok then
        log.warn("dm_motor", string.format("电机0x%02X CAN发送失败", motor_can_id))
        return false
    end

    -- 等待反馈帧（检测response_counter增加）
    local wait_interval = 10
    local elapsed = 0

    while elapsed < timeout_ms do
        sys.wait(wait_interval)
        elapsed = elapsed + wait_interval

        -- 检查是否收到新的反馈帧
        if motor.response_counter > start_counter then
            log.debug("dm_motor", string.format("电机0x%02X 收到反馈帧，耗时%dms", motor_can_id, elapsed))
            return true
        end
    end

    log.warn("dm_motor", string.format("电机0x%02X 等待反馈超时 (%dms)", motor_can_id, timeout_ms))
    return false
end

return dm_motor
