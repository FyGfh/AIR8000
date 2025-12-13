--[[
@module  main
@summary VDM Air8000 双通道通信系统 (V1.0协议)
@version 3.0
@date    2025.12.13
@description
本项目实现Air8000与Hi3516cv610的双通道通信：
1. USB RNDIS - 网络透传，共享4G网络给Hi3516cv610
2. USB 虚拟串口 - V1.0帧协议命令控制和状态查询
]]

PROJECT = "VDM_AIR8000_V1"
VERSION = "003.000.000"

sys = require "sys"

log.info("main", PROJECT, VERSION)

-- ==================== 1. 硬件初始化 ====================
local MOTOR_PWR_EN_PIN = 33
local WIFI_PWR_EN_PIN = 36
gpio.setup(WIFI_PWR_EN_PIN, 1)
gpio.setup(MOTOR_PWR_EN_PIN, 1)

-- ==================== 2. 启用USB RNDIS网络透传 ====================
require "open_ecm"

-- ==================== 3. 启用USB虚拟串口通信 (V1.0协议) ====================
local usb_vuart = require "usb_vuart_comm"
local CMD = usb_vuart.CMD
local RESULT = usb_vuart.CMD_RESULT
local ERROR = usb_vuart.ERROR

-- ==================== 4. 业务数据状态 ====================
local sensor_data = {
    temperature = 25,
    humidity = 60,
    battery = 80,
    light = 128,
}

-- 根据实际需求配置电机数量
local motor_status = {}
for i = 1, 4 do  -- 默认支持4个电机
    motor_status[i] = {
        action = 0,   -- 0=停止, 1=正转, 2=反转
        speed = 0,    -- 速度 0-1000
        position = 0, -- 位置 (度)
        enabled = false,
    }
end

-- ==================== 5. 状态数据提供者 ====================
-- 传感器状态
usb_vuart.register_status("sensor", function()
    local temp = math.floor(sensor_data.temperature * 10)
    local temp_h = math.floor(temp / 256)
    local temp_l = temp % 256
    return string.char(temp_h, temp_l, sensor_data.humidity, sensor_data.light, sensor_data.battery)
end)

-- 电机状态
usb_vuart.register_status("motor", function()
    local data = string.char(#motor_status)  -- 电机数量
    for i = 1, #motor_status do
        local m = motor_status[i]
        local speed_h = math.floor(m.speed / 256)
        local speed_l = m.speed % 256
        data = data .. string.char(i, m.action, speed_h, speed_l)
    end
    return data
end)

-- ==================== 6. 电机命令处理 ====================

-- 电机使能 (0x3002)
usb_vuart.on_cmd(CMD.MOTOR_ENABLE, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)
        if motor_status[motor_id] then
            motor_status[motor_id].enabled = true
            log.info("motor", string.format("电机%d 已使能", motor_id))
            return RESULT.ACK
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机禁用 (0x3003)
usb_vuart.on_cmd(CMD.MOTOR_DISABLE, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)
        if motor_status[motor_id] then
            motor_status[motor_id].enabled = false
            motor_status[motor_id].action = 0
            motor_status[motor_id].speed = 0
            log.info("motor", string.format("电机%d 已禁用", motor_id))
            return RESULT.ACK
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机急停 (0x3004)
usb_vuart.on_cmd(CMD.MOTOR_STOP, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)
        if motor_id == 0xFF then
            -- 所有电机急停
            for i = 1, #motor_status do
                motor_status[i].action = 0
                motor_status[i].speed = 0
            end
            log.info("motor", "所有电机已急停")
        elseif motor_status[motor_id] then
            motor_status[motor_id].action = 0
            motor_status[motor_id].speed = 0
            log.info("motor", string.format("电机%d 已急停", motor_id))
        else
            return RESULT.NACK, nil, ERROR.INVALID_PARAM
        end
        return RESULT.ACK
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机旋转 (0x3001)
-- 数据格式: [motor_id u8][angle f32][velocity f32]
usb_vuart.on_cmd(CMD.MOTOR_ROTATE, function(seq, data)
    if #data >= 9 then
        local motor_id = data:byte(1)
        -- 大端序解析 f32
        local angle_bytes = data:sub(2, 5)
        local vel_bytes = data:sub(6, 9)

        if motor_status[motor_id] then
            -- 这里实际项目应该发送到电机控制器
            -- 模拟：设置目标位置
            log.info("motor", string.format("电机%d 旋转命令已接收", motor_id))
            return RESULT.ACK
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机查询位置 (0x3006)
usb_vuart.on_cmd(CMD.MOTOR_GET_POS, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)
        if motor_status[motor_id] then
            local pos = motor_status[motor_id].position
            -- 构造响应: [motor_id u8][position f32 大端序]
            local pos_bytes = string.pack(">f", pos)
            local resp_data = string.char(motor_id) .. pos_bytes
            return RESULT.RESPONSE, resp_data
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机设置原点 (0x3005)
usb_vuart.on_cmd(CMD.MOTOR_SET_ORIGIN, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)
        if motor_status[motor_id] then
            motor_status[motor_id].position = 0
            log.info("motor", string.format("电机%d 已设置原点", motor_id))
            return RESULT.ACK
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- ==================== 7. 设备控制命令 ====================

-- LED控制 (0x5003)
usb_vuart.on_cmd(CMD.DEV_LED, function(seq, data)
    if #data >= 2 then
        local device_id = data:byte(1)
        local state = data:byte(2)
        log.info("device", string.format("LED 设备%d 状态=%d", device_id, state))
        -- TODO: 实际控制LED
        return RESULT.ACK
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 风扇控制 (0x5002)
usb_vuart.on_cmd(CMD.DEV_FAN, function(seq, data)
    if #data >= 2 then
        local device_id = data:byte(1)
        local state = data:byte(2)
        log.info("device", string.format("风扇 设备%d 状态=%d", device_id, state))
        -- TODO: 实际控制风扇
        return RESULT.ACK
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 加热器控制 (0x5001)
usb_vuart.on_cmd(CMD.DEV_HEATER, function(seq, data)
    if #data >= 2 then
        local device_id = data:byte(1)
        local state = data:byte(2)
        log.info("device", string.format("加热器 设备%d 状态=%d", device_id, state))
        -- TODO: 实际控制加热器
        return RESULT.ACK
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 激光控制 (0x5004)
usb_vuart.on_cmd(CMD.DEV_LASER, function(seq, data)
    if #data >= 2 then
        local device_id = data:byte(1)
        local state = data:byte(2)
        log.info("device", string.format("激光 设备%d 状态=%d", device_id, state))
        -- TODO: 实际控制激光
        return RESULT.ACK
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- PWM补光灯控制 (0x5005)
usb_vuart.on_cmd(CMD.DEV_PWM_LIGHT, function(seq, data)
    if #data >= 2 then
        local device_id = data:byte(1)
        local brightness = data:byte(2)
        log.info("device", string.format("PWM补光灯 设备%d 亮度=%d%%", device_id, brightness))
        -- TODO: 实际控制PWM
        return RESULT.ACK
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 设备状态查询 (0x5010)
usb_vuart.on_cmd(CMD.DEV_GET_STATE, function(seq, data)
    if #data >= 1 then
        local device_id = data:byte(1)
        -- 返回设备状态 (模拟)
        local state = 0x01  -- ON
        return RESULT.RESPONSE, string.char(state)
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- ==================== 8. 传感器命令 ====================

-- 读取温度 (0x4001)
usb_vuart.on_cmd(CMD.SENSOR_READ_TEMP, function(seq, data)
    if #data >= 1 then
        local sensor_id = data:byte(1)
        local temp = sensor_data.temperature
        -- 响应格式: [sensor_id u8][temperature f32 大端序]
        local temp_bytes = string.pack(">f", temp)
        return RESULT.RESPONSE, string.char(sensor_id) .. temp_bytes
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- ==================== 9. 定期任务 ====================
-- 传感器数据模拟（生产环境请替换为真实传感器读取）
sys.timerLoopStart(function()
    sensor_data.temperature = 20 + math.random(0, 100) / 10
    sensor_data.humidity = 50 + math.random(0, 20)
    sensor_data.light = math.random(50, 200)
end, 5000)

-- 定期状态推送到Hi3516cv610（使用NOTIFY帧）
sys.timerLoopStart(function()
    local csq = mobile.csq() or 0
    local status = mobile.status() or 0
    local notify_data = string.char(csq, status, sensor_data.battery)
    usb_vuart.notify(0x0002, notify_data)  -- 使用16位命令码
end, 10000)

-- ==================== 10. 看门狗 ====================
if wdt then
    wdt.init(9000)
    sys.timerLoopStart(wdt.feed, 3000)
end

-- ==================== 11. 启动系统 ====================
log.info("main", "VDM Air8000 V1.0协议 系统已启动")
log.info("main", "帧格式: AA 55 [VER][TYPE][SEQ][CMD][LEN][DATA][CRC]")
sys.run()
