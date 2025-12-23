--[[
@module  main
@summary VDM Air8000 双通道通信系统 (V1.0协议)
@version 1.0
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

-- ==================== 3.1 初始化 DS18B20 温度传感器 ====================
local ds18b20 = require "ds18b20_sensor"
ds18b20.init()

-- ==================== 3.2 初始化 DM CAN 电机驱动 ====================
local dm_motor = require "dm_motor_bridge"

-- 电机CAN ID配置 (根据实际硬件配置修改)
local MOTOR_CAN_IDS = {
    0x01,  -- 电机1的CAN ID
    0x02,  -- 电机2的CAN ID
    0x03,  -- 电机3的CAN ID
    0x04,  -- 电机4的CAN ID
}

-- 初始化DM电机驱动
sys.taskInit(function()
    sys.wait(1000)  -- 等待CAN总线稳定

    if dm_motor.init() then
        log.info("motor", "DM电机驱动初始化成功")

        -- 注册所有电机
        for i, can_id in ipairs(MOTOR_CAN_IDS) do
            if dm_motor.register(can_id) then
                log.info("motor", string.format("电机%d (CAN ID: 0x%02X) 注册成功", i, can_id))
            else
                log.warn("motor", string.format("电机%d (CAN ID: 0x%02X) 注册失败", i, can_id))
            end
        end
    else
        log.error("motor", "DM电机驱动初始化失败")
    end
end)

-- ==================== 4. 业务数据状态 ====================
local sensor_data = {
    temperature = -99,   -- 将由 DS18B20 更新
    humidity = 60,
    battery = 80,
    light = 128,
}

-- ==================== 4.1 ADC 配置 ====================
-- ADC 通道配置 (Air8000: 0=ADC0, 1=ADC1)
local ADC_CHANNEL_V12 = 0       -- 12V 电压 ADC 通道 (ADC0)
local ADC_CHANNEL_VBATT = 1     -- 电池电压(4.2V) ADC 通道 (ADC1)
local ADC_VREF = 3600           -- ADC 参考电压 (mV) - Air8000 内部量程 0-3.6V
local ADC_RESOLUTION = 4096     -- 12位 ADC (12 bits)
-- 分压比根据多点实测数据校准:
-- 数据点1: 实际10.04V, ADC引脚426.3mV → 分压比 = 23.55
-- 数据点2: 实际8.05V, ADC引脚333.7mV → 分压比 = 24.12
-- 数据点3: 实际12.00V, ADC引脚522mV → 分压比 = 23.0
-- 最新校准分压比: 23.0 (基于12V实测)
local V12_DIVIDER_RATIO = 23.0    -- 12V 电压分压比 (12.00V实测校准)
local VBATT_DIVIDER_RATIO = 5.0  -- 电池电压分压比 (4.2V实测，非常准确)

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
    -- 读取 DS18B20 温度 (实时)
    local temp_raw = ds18b20.read_single(0)
    local temperature = sensor_data.temperature  -- 默认值
    if temp_raw then
        temperature = temp_raw / 1000.0  -- 毫度转换为度
    end

    local temp = math.floor(temperature * 10)
    local temp_h = math.floor(temp / 256)
    local temp_l = temp % 256
    return string.char(temp_h, temp_l, sensor_data.humidity, sensor_data.light, sensor_data.battery)
end)

-- 电机状态
-- 返回格式: [电机数量 u8][电机1状态][电机2状态]...
-- 每个电机状态: [电机ID u8][action u8][speed u16][position f32][enabled u8]
usb_vuart.register_status("motor", function()
    local data = string.char(#MOTOR_CAN_IDS)  -- 电机数量
    for i = 1, #MOTOR_CAN_IDS do
        local can_id = MOTOR_CAN_IDS[i]
        local state = dm_motor.get_state(can_id)

        if state then
            -- 从实际DM电机状态更新motor_status
            motor_status[i].position = state.position
            motor_status[i].speed = math.floor(math.abs(state.velocity) * 100)  -- 转换为0-1000范围
            motor_status[i].enabled = state.enabled

            -- 根据速度方向判断动作
            if math.abs(state.velocity) < 0.01 then
                motor_status[i].action = 0  -- 停止
            elseif state.velocity > 0 then
                motor_status[i].action = 1  -- 正转
            else
                motor_status[i].action = 2  -- 反转
            end
        end

        local m = motor_status[i]
        local speed_h = math.floor(m.speed / 256)
        local speed_l = m.speed % 256
        local pos_bytes = string.pack(">f", m.position)  -- 位置以大端f32格式

        data = data .. string.char(i, m.action, speed_h, speed_l) .. pos_bytes .. string.char(m.enabled and 1 or 0)
    end
    return data
end)

-- DS18B20 温度状态
usb_vuart.register_status("ds18b20", function()
    return ds18b20.read_temperature_data()
end)

-- ==================== 6. 电机命令处理 ====================

-- 电机使能 (0x3002)
-- 数据格式: [motor_id u8][mode u8] (mode: 1=MIT, 2=位置速度, 3=速度)
usb_vuart.on_cmd(CMD.MOTOR_ENABLE, function(seq, data)
    if #data >= 2 then
        local motor_id = data:byte(1)
        local mode = data:byte(2) or 2  -- 默认位置速度模式

        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]
            if dm_motor.enable(can_id, true, mode) then
                motor_status[motor_id].enabled = true
                log.info("motor", string.format("电机%d (CAN:0x%02X) 已使能, 模式=%d", motor_id, can_id, mode))
                return RESULT.ACK
            else
                log.error("motor", string.format("电机%d (CAN:0x%02X) 使能失败", motor_id, can_id))
                return RESULT.NACK, nil, ERROR.DEVICE_ERROR
            end
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机禁用 (0x3003)
usb_vuart.on_cmd(CMD.MOTOR_DISABLE, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)
        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]
            if dm_motor.enable(can_id, false, 1) then
                motor_status[motor_id].enabled = false
                motor_status[motor_id].action = 0
                motor_status[motor_id].speed = 0
                log.info("motor", string.format("电机%d (CAN:0x%02X) 已禁用", motor_id, can_id))
                return RESULT.ACK
            else
                log.error("motor", string.format("电机%d (CAN:0x%02X) 禁用失败", motor_id, can_id))
                return RESULT.NACK, nil, ERROR.DEVICE_ERROR
            end
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
            local success_count = 0
            for i = 1, #MOTOR_CAN_IDS do
                local can_id = MOTOR_CAN_IDS[i]
                -- 发送速度为0的速度控制命令
                if dm_motor.vel_control(can_id, 0) then
                    motor_status[i].action = 0
                    motor_status[i].speed = 0
                    success_count = success_count + 1
                end
            end
            log.info("motor", string.format("所有电机已急停 (%d/%d 成功)", success_count, #MOTOR_CAN_IDS))
            return RESULT.ACK
        elseif motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]
            if dm_motor.vel_control(can_id, 0) then
                motor_status[motor_id].action = 0
                motor_status[motor_id].speed = 0
                log.info("motor", string.format("电机%d (CAN:0x%02X) 已急停", motor_id, can_id))
                return RESULT.ACK
            else
                log.error("motor", string.format("电机%d (CAN:0x%02X) 急停失败", motor_id, can_id))
                return RESULT.NACK, nil, ERROR.DEVICE_ERROR
            end
        else
            return RESULT.NACK, nil, ERROR.INVALID_PARAM
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机旋转 (0x3001)
-- 数据格式: [motor_id u8][angle f32 大端][velocity f32 大端]
-- angle: 目标位置 (弧度)
-- velocity: 目标速度 (弧度/秒)
usb_vuart.on_cmd(CMD.MOTOR_ROTATE, function(seq, data)
    if #data >= 9 then
        local motor_id = data:byte(1)

        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            -- 大端序解析 f32
            local angle = string.unpack(">f", data:sub(2, 5))
            local velocity = string.unpack(">f", data:sub(6, 9))

            local can_id = MOTOR_CAN_IDS[motor_id]

            -- 使用位置速度模式控制电机
            if dm_motor.pos_control(can_id, angle, velocity) then
                log.info("motor", string.format("电机%d (CAN:0x%02X) 旋转至 %.2f rad, 速度 %.2f rad/s",
                    motor_id, can_id, angle, velocity))
                return RESULT.ACK
            else
                log.error("motor", string.format("电机%d (CAN:0x%02X) 旋转控制失败", motor_id, can_id))
                return RESULT.NACK, nil, ERROR.DEVICE_ERROR
            end
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机查询位置 (0x3006)
-- 响应格式: [motor_id u8][position f32 大端序]
usb_vuart.on_cmd(CMD.MOTOR_GET_POS, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)
        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]

            -- 主动读取电机位置寄存器 (0x50)
            dm_motor.read_register(can_id, 0x50)

            -- 等待 CAN 响应 (100ms)
            sys.wait(100)

            local state = dm_motor.get_state(can_id)

            if state then
                -- 构造响应: [motor_id u8][position f32 大端序]
                local pos_bytes = string.pack(">f", state.position)
                local resp_data = string.char(motor_id) .. pos_bytes
                log.info("motor", string.format("电机%d (CAN:0x%02X) 位置: %.4f rad (%.2f°)", motor_id, can_id, state.position, math.deg(state.position)))
                return RESULT.RESPONSE, resp_data
            else
                log.error("motor", string.format("电机%d (CAN:0x%02X) 状态查询失败", motor_id, can_id))
                return RESULT.NACK, nil, ERROR.DEVICE_ERROR
            end
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机设置原点 (0x3005)
usb_vuart.on_cmd(CMD.MOTOR_SET_ORIGIN, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)
        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]
            -- 调用DM电机的保存零点命令
            if dm_motor.save_zero(can_id) then
                motor_status[motor_id].position = 0
                log.info("motor", string.format("电机%d (CAN:0x%02X) 已设置原点", motor_id, can_id))
                return RESULT.ACK
            else
                log.error("motor", string.format("电机%d (CAN:0x%02X) 设置原点失败", motor_id, can_id))
                return RESULT.NACK, nil, ERROR.DEVICE_ERROR
            end
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机设置速度 (0x3007)
-- 数据格式: [motor_id u8][velocity f32 大端]
usb_vuart.on_cmd(CMD.MOTOR_SET_VEL, function(seq, data)
    if #data >= 5 then
        local motor_id = data:byte(1)

        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            -- 大端序解析 f32
            local velocity = string.unpack(">f", data:sub(2, 5))

            local can_id = MOTOR_CAN_IDS[motor_id]

            -- 使用速度模式控制电机
            if dm_motor.vel_control(can_id, velocity) then
                log.info("motor", string.format("电机%d (CAN:0x%02X) 设置速度 %.2f rad/s",
                    motor_id, can_id, velocity))
                return RESULT.ACK
            else
                log.error("motor", string.format("电机%d (CAN:0x%02X) 速度控制失败", motor_id, can_id))
                return RESULT.NACK, nil, ERROR.DEVICE_ERROR
            end
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机相对旋转 (0x3008)
-- 数据格式: [motor_id u8][angle_delta f32 大端][velocity f32 大端]
usb_vuart.on_cmd(CMD.MOTOR_ROTATE_REL, function(seq, data)
    if #data >= 9 then
        local motor_id = data:byte(1)

        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            -- 大端序解析 f32
            local angle_delta = string.unpack(">f", data:sub(2, 5))
            local velocity = string.unpack(">f", data:sub(6, 9))

            local can_id = MOTOR_CAN_IDS[motor_id]

            -- 获取当前位置
            local state = dm_motor.get_state(can_id)
            if state then
                -- 计算目标位置 = 当前位置 + 相对位置
                local target_pos = state.position + angle_delta

                -- 使用位置速度模式控制电机
                if dm_motor.pos_control(can_id, target_pos, velocity) then
                    log.info("motor", string.format("电机%d (CAN:0x%02X) 相对旋转 %.2f rad (从 %.2f -> %.2f), 速度 %.2f rad/s",
                        motor_id, can_id, angle_delta, state.position, target_pos, velocity))
                    return RESULT.ACK
                else
                    log.error("motor", string.format("电机%d (CAN:0x%02X) 相对旋转失败", motor_id, can_id))
                    return RESULT.NACK, nil, ERROR.DEVICE_ERROR
                end
            else
                log.error("motor", string.format("电机%d (CAN:0x%02X) 无法获取当前位置", motor_id, can_id))
                return RESULT.NACK, nil, ERROR.DEVICE_ERROR
            end
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

-- 电机供电控制 (0x5006)
-- 数据格式: [power_state u8] (0=断电, 1=供电)
usb_vuart.on_cmd(CMD.DEV_MOTOR_POWER, function(seq, data)
    if #data >= 1 then
        local power_state = data:byte(1)

        if power_state == 0 then
            -- 断开电机供电
            gpio.set(MOTOR_PWR_EN_PIN, 0)
            log.info("motor_power", "电机供电已关闭")
            return RESULT.ACK
        elseif power_state == 1 then
            -- 开启电机供电
            gpio.set(MOTOR_PWR_EN_PIN, 1)
            log.info("motor_power", "电机供电已开启")
            return RESULT.ACK
        else
            log.warn("motor_power", string.format("无效的供电状态值: %d", power_state))
            return RESULT.NACK, nil, ERROR.INVALID_PARAM
        end
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

-- 读取温度 (0x4001) - 使用 DS18B20 传感器
usb_vuart.on_cmd(CMD.SENSOR_READ_TEMP, function(seq, data)
    if #data >= 1 then
        local sensor_id = data:byte(1)
        -- 读取 DS18B20 温度 (只有一个传感器，忽略 sensor_id)
        local temp_raw = ds18b20.read_single(0)
        local temp = 25.0  -- 默认值
        if temp_raw then
            temp = temp_raw / 1000.0  -- 毫度转换为度
        end
        -- 响应格式: [sensor_id u8][temperature f32 大端序]
        local temp_bytes = string.pack(">f", temp)
        log.info("sensor", string.format("DS18B20 温度: %.2f°C", temp))
        return RESULT.RESPONSE, string.char(sensor_id) .. temp_bytes
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- ==================== 9. ADC 电压查询命令 ====================

-- 读取 ADC 电压 (0x0101 QUERY_POWER)
usb_vuart.on_cmd(CMD.QUERY_POWER, function(seq, data)
    if not adc then
        log.warn("adc", "ADC功能不可用")
        -- 使用模拟值
        local mock_vbatt = 0  -- 12.5V
        local mock_v12 = 0    -- 12.0V
        local resp_data = string.char(
            bit.rshift(mock_vbatt, 8), bit.band(mock_vbatt, 0xFF),
            bit.rshift(mock_v12, 8), bit.band(mock_v12, 0xFF)
        )
        return RESULT.RESPONSE, resp_data
    end

    -- ADC采样函数 (参考官方示例)
    local function read_adc_samples(channel, num_samples)
        adc.setRange(adc.ADC_RANGE_MAX)  -- Air8000 ADC 量程 0-3.6V (内部分压开启)
        adc.open(channel)

        local samples = {}
        for i = 1, num_samples do
            table.insert(samples, adc.get(channel))
        end

        adc.close(channel)

        -- 排序并去掉极值
        if #samples > 2 then
            table.sort(samples)
            local sum = 0
            for i = 2, #samples - 1 do
                sum = sum + samples[i]
            end
            return sum / (#samples - 2)  -- 返回平均值
        else
            return samples[1] or 0
        end
    end

    -- 读取12V电压ADC原始值 (ADC0)
    local v12_adc_raw = read_adc_samples(ADC_CHANNEL_V12, 5)

    -- 读取电池电压ADC原始值 (ADC1)
    local vbatt_adc_raw = read_adc_samples(ADC_CHANNEL_VBATT, 5)

    -- 确保原始值是整数
    v12_adc_raw = math.floor(v12_adc_raw or 0)
    vbatt_adc_raw = math.floor(vbatt_adc_raw or 0)

    -- ADC原始值转换为实际电压
    -- adc.get()返回的是ADC原始值(0-4095), 需要转换为mV
    -- 转换公式: voltage_mv = (adc_raw / ADC_RESOLUTION) * ADC_VREF * 分压比
    local v12_adc_mv = (v12_adc_raw / ADC_RESOLUTION) * ADC_VREF      -- ADC引脚电压
    local vbatt_adc_mv = (vbatt_adc_raw / ADC_RESOLUTION) * ADC_VREF  -- ADC引脚电压

    local v12_mv = math.floor(v12_adc_mv * V12_DIVIDER_RATIO)        -- 实际12V电压
    local vbatt_mv = math.floor(vbatt_adc_mv * VBATT_DIVIDER_RATIO)  -- 实际电池电压

    -- 响应格式: [voltage_mv u16 大端][current_ma u16 大端]
    -- 第一个字段：12V主电压, 第二个字段：电池电压
    local resp_data = string.char(
        bit.rshift(v12_mv, 8), bit.band(v12_mv, 0xFF),      -- 12V电压高低字节
        bit.rshift(vbatt_mv, 8), bit.band(vbatt_mv, 0xFF)   -- 电池电压高低字节
    )

    log.info("adc", string.format("ADC原始值: V12=%d VBATT=%d | ADC电压: V12=%.1fmV VBATT=%.1fmV | 实际电压: V12=%dmV VBATT=%dmV",
        v12_adc_raw, vbatt_adc_raw, v12_adc_mv, vbatt_adc_mv, v12_mv, vbatt_mv))

    return RESULT.RESPONSE, resp_data
end)

-- ==================== 10. 定期任务 ====================
-- DS18B20 温度定期采集
sys.timerLoopStart(function()
    -- 读取 DS18B20 温度
    local temp_raw = ds18b20.read_single(0)
    if temp_raw then
        sensor_data.temperature = temp_raw / 1000.0  -- 毫度转换为度
        log.debug("sensor", string.format("DS18B20 温度更新: %.2f°C", sensor_data.temperature))
    end
    -- 其他传感器数据（如有）
    sensor_data.humidity = 50 + math.random(0, 20)
    sensor_data.light = math.random(50, 200)
end, 5000)

-- ADC电压定期采集（调试用）
sys.timerLoopStart(function()
    if not adc then
        return
    end

    -- ADC采样函数
    local function read_adc_samples(channel, num_samples)
        adc.setRange(adc.ADC_RANGE_MAX)  -- Air8000 ADC 量程 0-3.6V (内部分压开启)
        adc.open(channel)

        local samples = {}
        for i = 1, num_samples do
            table.insert(samples, adc.get(channel))
        end

        adc.close(channel)

        -- 排序并去掉极值
        if #samples > 2 then
            table.sort(samples)
            local sum = 0
            for i = 2, #samples - 1 do
                sum = sum + samples[i]
            end
            return sum / (#samples - 2)
        else
            return samples[1] or 0
        end
    end

    -- 读取ADC原始值
    local v12_adc_raw = read_adc_samples(ADC_CHANNEL_V12, 5)
    local vbatt_adc_raw = read_adc_samples(ADC_CHANNEL_VBATT, 5)

    -- 确保原始值是整数
    v12_adc_raw = math.floor(v12_adc_raw or 0)
    vbatt_adc_raw = math.floor(vbatt_adc_raw or 0)

    -- 转换为ADC引脚电压
    local v12_adc_mv = (v12_adc_raw / ADC_RESOLUTION) * ADC_VREF
    local vbatt_adc_mv = (vbatt_adc_raw / ADC_RESOLUTION) * ADC_VREF

    -- 计算实际电压
    local v12_mv = math.floor(v12_adc_mv * V12_DIVIDER_RATIO)
    local vbatt_mv = math.floor(vbatt_adc_mv * VBATT_DIVIDER_RATIO)

    log.info("adc_debug", string.format("ADC原始值: V12=%d VBATT=%d | ADC电压: V12=%.1fmV VBATT=%.1fmV | 实际电压: V12=%dmV(%.2fV) VBATT=%dmV(%.2fV)",
        v12_adc_raw, vbatt_adc_raw, v12_adc_mv, vbatt_adc_mv, v12_mv, v12_mv/1000.0, vbatt_mv, vbatt_mv/1000.0))
end, 3000)

-- 定期状态推送到Hi3516cv610（使用NOTIFY帧）
sys.timerLoopStart(function()
    local csq = mobile.csq() or 0
    local status = mobile.status() or 0
    local notify_data = string.char(csq, status, sensor_data.battery)
    usb_vuart.notify(0x0002, notify_data)  -- 使用16位命令码
end, 10000)

-- ==================== 11. 看门狗 ====================
if wdt then
    wdt.init(9000)
    sys.timerLoopStart(wdt.feed, 3000)
end

-- ==================== 12. 启动系统 ====================
log.info("main", "VDM Air8000 V1.0协议 系统已启动")
log.info("main", "帧格式: AA 55 [VER][TYPE][SEQ][CMD][LEN][DATA][CRC]")
sys.run()
