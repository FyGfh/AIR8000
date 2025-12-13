--[[
@module  main
@summary VDM Air8000 双通道通信系统
@version 2.1
@date    2025.12.13
@description
本项目实现Air8000与Hi3516cv610的双通道通信：
1. USB RNDIS - 网络透传，共享4G网络给Hi3516cv610
2. USB 虚拟串口 - 命令控制和状态查询，支持多电机控制
]]

PROJECT = "VDM_AIR8000_DUAL"
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

-- ==================== 3. 启用USB虚拟串口通信 ====================
local usb_vuart = require "usb_vuart_comm"

-- ==================== 3.5 初始化DM CAN电机（可选）====================
-- 如果使用DM CAN电机，取消下面注释
-- local dm_motor = require "dm_motor_bridge"
-- sys.taskInit(function()
--     sys.wait(2000)  -- 等待系统稳定
--     dm_motor.init()
--     -- 注册电机（根据实际使用的CAN ID修改）
--     dm_motor.register(0x02)  -- 注册第1个电机，CAN ID: 0x02
--     -- dm_motor.register(0x03)  -- 注册第2个电机，CAN ID: 0x03
-- end)

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
    }
end

-- ==================== 5. 状态数据提供者 ====================
-- 传感器状态
usb_vuart.register_status("sensor", function()
    local temp = sensor_data.temperature * 10
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

-- ==================== 6. 命令处理 ====================
-- 电机控制命令
sys.subscribe("USB_MOTOR_CTRL", function(data)
    if data and #data >= 4 then
        local motor_id = data:byte(1)
        local action = data:byte(2)
        local speed = data:byte(3) * 256 + data:byte(4)

        if motor_status[motor_id] then
            motor_status[motor_id].action = action
            motor_status[motor_id].speed = speed
            log.info("motor", string.format("电机%d: 动作=%d, 速度=%d", motor_id, action, speed))
        else
            log.warn("motor", "无效的电机ID:", motor_id)
        end
    end
end)

-- 参数设置命令
sys.subscribe("USB_SET_PARAM", function(data)
    if data and #data >= 2 then
        local param_id = data:byte(1)
        local param_value = data:byte(2)
        log.info("param", string.format("设置参数 ID=%d, Value=%d", param_id, param_value))
        -- TODO: 根据实际需求处理参数
    end
end)

-- GPIO控制命令 (0x40)
usb_vuart.on_cmd(0x40, function(data)
    if #data >= 2 then
        local pin = data:byte(1)
        local value = data:byte(2)

        -- 允许控制的引脚列表
        if pin == MOTOR_PWR_EN_PIN or pin == WIFI_PWR_EN_PIN then
            gpio.set(pin, value)
            log.info("gpio", string.format("引脚%d 设置为 %d", pin, value))
            return pack_response(0x05, string.char(0x40))  -- ACK
        else
            log.warn("gpio", string.format("不允许控制引脚%d", pin))
            return pack_response(0xFF, string.char(0x02))  -- 错误：引脚不允许
        end
    end
    return pack_response(0xFF, string.char(0x01))  -- 错误：数据长度不足
end)

-- GPIO查询命令 (0x41)
usb_vuart.on_cmd(0x41, function(data)
    if #data >= 1 then
        local pin = data:byte(1)

        if pin == MOTOR_PWR_EN_PIN or pin == WIFI_PWR_EN_PIN then
            local value = gpio.get(pin)
            return pack_response(0x06, string.char(pin, value))
        else
            return pack_response(0xFF, string.char(0x02))  -- 错误：引脚不允许
        end
    end
    return pack_response(0xFF, string.char(0x01))  -- 错误：数据长度不足
end)

-- ==================== 6.5 DM CAN电机命令处理（可选）====================
-- 如果使用DM CAN电机，取消下面注释

--[[ DM电机MIT模式控制 (0x30)
数据格式: [电机ID(1B)][位置(4B float)][速度(4B float)][Kp(4B float)][Kd(4B float)][扭矩(4B float)]
usb_vuart.on_cmd(0x30, function(data)
    if #data >= 21 then
        local motor_id = data:byte(1)
        local p_des = string.unpack("<f", data, 2)
        local v_des = string.unpack("<f", data, 6)
        local kp = string.unpack("<f", data, 10)
        local kd = string.unpack("<f", data, 14)
        local t_ff = string.unpack("<f", data, 18)

        dm_motor.mit_control(motor_id, p_des, v_des, kp, kd, t_ff)
        return pack_response(0x05, string.char(0x30))  -- ACK
    end
    return pack_response(0xFF, string.char(0x01))  -- 错误：数据长度不足
end)
]]

--[[ DM电机位置速度模式控制 (0x31)
数据格式: [电机ID(1B)][位置(4B float)][速度(4B float)]
usb_vuart.on_cmd(0x31, function(data)
    if #data >= 9 then
        local motor_id = data:byte(1)
        local p_des = string.unpack("<f", data, 2)
        local v_des = string.unpack("<f", data, 6)

        dm_motor.pos_control(motor_id, p_des, v_des)
        return pack_response(0x05, string.char(0x31))
    end
    return pack_response(0xFF, string.char(0x01))
end)
]]

--[[ DM电机速度模式控制 (0x32)
数据格式: [电机ID(1B)][速度(4B float)]
usb_vuart.on_cmd(0x32, function(data)
    if #data >= 5 then
        local motor_id = data:byte(1)
        local v_des = string.unpack("<f", data, 2)

        dm_motor.vel_control(motor_id, v_des)
        return pack_response(0x05, string.char(0x32))
    end
    return pack_response(0xFF, string.char(0x01))
end)
]]

--[[ DM电机使能控制 (0x33)
数据格式: [电机ID(1B)][使能(1B)][模式(1B)]  模式: 1=MIT, 2=位置速度, 3=速度
usb_vuart.on_cmd(0x33, function(data)
    if #data >= 3 then
        local motor_id = data:byte(1)
        local enabled = data:byte(2) ~= 0
        local mode = data:byte(3)

        dm_motor.enable(motor_id, enabled, mode)
        return pack_response(0x05, string.char(0x33))
    end
    return pack_response(0xFF, string.char(0x01))
end)
]]

--[[ DM电机状态查询 (0x18)
数据格式: [电机ID(1B)]
响应格式: [位置(4B)][速度(4B)][扭矩(4B)][MOS温度(1B)][转子温度(1B)][错误码(1B)][模式(1B)][使能(1B)]
usb_vuart.on_cmd(0x18, function(data)
    if #data >= 1 then
        local motor_id = data:byte(1)
        local state_data = dm_motor.pack_state(motor_id)
        return pack_response(0x09, state_data)
    end
    return pack_response(0xFF, string.char(0x01))
end)
]]

-- ==================== 7. 定期任务（可选）====================
-- 传感器数据模拟（生产环境请删除或替换为真实传感器读取）
sys.timerLoopStart(function()
    sensor_data.temperature = 20 + math.random(0, 100) / 10
    sensor_data.humidity = 50 + math.random(0, 20)
    sensor_data.light = math.random(50, 200)
end, 5000)

-- 定期状态推送到Hi3516cv610（可选）
sys.timerLoopStart(function()
    local status = string.char(mobile.csq(), mobile.status(), sensor_data.battery)
    usb_vuart.notify(0x10, status)
end, 10000)

-- ==================== 8. 看门狗 ====================
if wdt then
    wdt.init(9000)
    sys.timerLoopStart(wdt.feed, 3000)
end

-- ==================== 9. 启动系统 ====================
log.info("main", "VDM Air8000 系统已启动")
sys.run()
