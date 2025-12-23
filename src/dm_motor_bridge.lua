--[[
@module  dm_motor_bridge
@summary DM CAN电机 USB虚拟串口桥接模块（多电机版）
@version 1.0
@date    2025.12.13
@description
将DM CAN电机功能通过USB虚拟串口暴露给Hi3516cv610：
- 支持多个不同CAN ID的电机
- 支持MIT模式、位置速度模式、速度模式控制
- 支持电机使能/失能
- 支持读取电机状态（位置、速度、扭矩、温度）
- 支持读写电机寄存器

@usage
    -- 在main.lua中引用
    local dm_motor = require "dm_motor_bridge"
    dm_motor.init()  -- 初始化CAN和电机

    -- 注册电机
    dm_motor.register(0x02)  -- 注册CAN ID为0x02的电机
    dm_motor.register(0x03)  -- 注册CAN ID为0x03的电机
]]

local dm_motor_bridge = {}

-- 引入多电机控制模块
local dm_can = require "dm_can_motor"

-- ==================== 电机管理 ====================

-- 初始化CAN总线
function dm_motor_bridge.init()
    local success = dm_can.can_init()
    if not success then
        log.error("dm_motor_bridge", "CAN初始化失败")
        return false
    end
    log.info("dm_motor_bridge", "CAN初始化成功")
    return true
end

-- 注册电机
function dm_motor_bridge.register(motor_can_id)
    return dm_can.register_motor(motor_can_id)
end

-- 移除电机
function dm_motor_bridge.unregister(motor_can_id)
    return dm_can.unregister_motor(motor_can_id)
end

-- 获取已注册的电机列表
function dm_motor_bridge.get_motors()
    return dm_can.get_motors()
end

-- ==================== 电机控制API ====================

-- MIT模式控制
-- motor_can_id: 电机CAN ID
-- p_des: 目标位置 (rad)
-- v_des: 目标速度 (rad/s)
-- kp: 位置刚度
-- kd: 阻尼系数
-- t_ff: 前馈扭矩 (Nm)
function dm_motor_bridge.mit_control(motor_can_id, p_des, v_des, kp, kd, t_ff)
    return dm_can.mit_control(motor_can_id, p_des, v_des, kp, kd, t_ff)
end

-- 位置速度模式控制
function dm_motor_bridge.pos_control(motor_can_id, p_des, v_des)
    return dm_can.pos_control(motor_can_id, p_des, v_des)
end

-- 速度模式控制
function dm_motor_bridge.vel_control(motor_can_id, v_des)
    return dm_can.vel_control(motor_can_id, v_des)
end

-- 切换控制模式
function dm_motor_bridge.switch_mode(motor_can_id, mode)
    return dm_can.switch_mode(motor_can_id, mode)
end

-- 电机使能/失能
-- enabled: true=使能, false=失能
-- mode: 控制模式 (1=MIT, 2=位置速度, 3=速度)
function dm_motor_bridge.enable(motor_can_id, enabled, mode)
    mode = mode or 1  -- 默认MIT模式
    local cmd_type = enabled and "enable" or "disable"
    return dm_can.send_mode_command(motor_can_id, mode, cmd_type)
end

-- 保存零点（使用MIT模式）
function dm_motor_bridge.save_zero(motor_can_id)
    return dm_can.send_mode_command(motor_can_id, 1, "save_zero")  -- 使用MIT模式
end

-- 清除错误（使用MIT模式）
function dm_motor_bridge.clear_error(motor_can_id)
    return dm_can.send_mode_command(motor_can_id, 1, "clear_error")  -- 使用MIT模式
end

-- 读取寄存器
function dm_motor_bridge.read_register(motor_can_id, rid)
    return dm_can.read_register(motor_can_id, rid)
end

-- 写入寄存器
function dm_motor_bridge.write_register(motor_can_id, rid, value, is_float)
    return dm_can.write_register(motor_can_id, rid, value, is_float)
end

-- 获取电机状态
function dm_motor_bridge.get_state(motor_can_id)
    return dm_can.get_state(motor_can_id)
end

-- ==================== 打包电机状态数据 ====================
-- 格式: [位置(4B float)][速度(4B float)][扭矩(4B float)][MOS温度(1B)][转子温度(1B)][错误码(1B)][模式(1B)][使能(1B)]
function dm_motor_bridge.pack_state(motor_can_id)
    local state = dm_can.get_state(motor_can_id)
    if not state then
        return string.char(0xFF):rep(17)  -- 返回无效数据
    end

    local data = pack.pack("<fff",
        state.position,
        state.velocity,
        state.torque
    )
    data = data .. string.char(
        state.temperature_mos,
        state.temperature_rotor,
        state.error_code,
        state.mode,
        state.enabled and 1 or 0
    )
    return data
end

return dm_motor_bridge
