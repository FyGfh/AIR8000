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

PROJECT = "VDM_AIR8000"
VERSION = "000.400.003"

sys = require "sys"

log.info("Application<========>", PROJECT, VERSION)

-- ==================== 1. 硬件初始化 ====================
local MOTOR_PWR_EN_PIN = 33
local WIFI_PWR_EN_PIN = 36
local HOST_PWR_EN_PIN = 34   -- Hi3516cv610 供电控制引脚

gpio.setup(WIFI_PWR_EN_PIN, 1)
gpio.setup(MOTOR_PWR_EN_PIN, 1)
gpio.setup(HOST_PWR_EN_PIN, 1)  -- 默认供电开启

-- ==================== 2. 网络配置 (APN + USB以太网) ====================
-- 必须在入网前初始化，会自动加载fskv中的APN配置并启用ECM/RNDIS
local network = require "network_config"
network.init()

-- ==================== 3. 启用USB虚拟串口通信 (V1.0协议) ====================
local usb_vuart = require "usb_vuart_comm"
local CMD = usb_vuart.CMD
local RESULT = usb_vuart.CMD_RESULT
local ERROR = usb_vuart.ERROR

-- ==================== 3.1 初始化 DS18B20 温度传感器 ====================
local ds18b20 = require "ds18b20_sensor"
ds18b20.init()

-- ==================== 3.2 初始化 OTA 升级模块 ====================
local ota_update = require "ota_update"

-- ==================== 3.3 初始化 MQTT OTA 模块 (暂时禁用) ====================
-- local mqtt_ota = require "mqtt_ota"
-- 配置MQTT服务器 (可选，使用默认配置则不需要调用)
-- mqtt_ota.configure({
--     server = "your-mqtt-server.com",  -- 替换为您的MQTT服务器
--     port = 1883,
--     username = "",
--     password = "",
-- })
-- 启动MQTT OTA服务
-- mqtt_ota.start()

-- ==================== 3.4 初始化 串口FOTA 模块 ====================
local uart_fota = require "uart_fota"

-- ==================== 3.5 初始化 DM CAN 电机驱动 ====================
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

        -- 初始化完成后，读取所有电机的初始位置，确保缓存有效
        sys.wait(500)  -- 等待电机注册完成并读取参数
        log.info("motor", "开始读取所有电机初始位置...")
        for i, can_id in ipairs(MOTOR_CAN_IDS) do
            dm_motor.read_register(can_id, 0x50)  -- 读取位置
            sys.wait(100)  -- 等待CAN响应
        end
        log.info("motor", "所有电机初始位置已读取")
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

-- ==================== 6. 电机命令处理 (异步RESPONSE模式) ====================
-- 电机命令不返回同步响应，后台执行完成后发送异步RESPONSE/NACK

-- 电机使能 (0x3002)
-- 数据格式: [motor_id u8][mode u8] (mode: 1=MIT, 2=位置速度, 3=速度)
-- 响应格式: [motor_id u8]
usb_vuart.on_cmd(CMD.MOTOR_ENABLE, function(seq, data)
    if #data >= 2 then
        local motor_id = data:byte(1)
        local mode = data:byte(2) or 2  -- 默认位置速度模式

        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]
            -- 后台执行，完成后发送异步响应
            sys.taskInit(function()
                if dm_motor.enable_confirmed(can_id, true, mode, 300) then
                    motor_status[motor_id].enabled = true
                    log.info("motor", string.format("电机%d (CAN:0x%02X) 已使能, 模式=%d", motor_id, can_id, mode))
                    usb_vuart.send_response(seq, CMD.MOTOR_ENABLE, string.char(motor_id))
                else
                    log.error("motor", string.format("电机%d (CAN:0x%02X) 使能失败(无响应)", motor_id, can_id))
                    usb_vuart.send_nack(seq, CMD.MOTOR_ENABLE, ERROR.TIMEOUT)
                end
            end)
            return RESULT.NONE  -- 不发送同步响应
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机禁用 (0x3003)
-- 响应格式: [motor_id u8]
usb_vuart.on_cmd(CMD.MOTOR_DISABLE, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)
        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]
            -- 后台执行，完成后发送异步响应
            sys.taskInit(function()
                if dm_motor.enable_confirmed(can_id, false, 2, 300) then
                    motor_status[motor_id].enabled = false
                    motor_status[motor_id].action = 0
                    motor_status[motor_id].speed = 0
                    log.info("motor", string.format("电机%d (CAN:0x%02X) 已禁用", motor_id, can_id))
                    usb_vuart.send_response(seq, CMD.MOTOR_DISABLE, string.char(motor_id))
                else
                    log.error("motor", string.format("电机%d (CAN:0x%02X) 禁用失败(无响应)", motor_id, can_id))
                    usb_vuart.send_nack(seq, CMD.MOTOR_DISABLE, ERROR.TIMEOUT)
                end
            end)
            return RESULT.NONE
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机急停 (0x3004)
-- 响应格式: [motor_id u8][success_count u8] (当motor_id=0xFF时)
usb_vuart.on_cmd(CMD.MOTOR_STOP, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)
        if motor_id == 0xFF then
            -- 所有电机急停 - 后台执行
            sys.taskInit(function()
                local success_count = 0
                for i = 1, #MOTOR_CAN_IDS do
                    local can_id = MOTOR_CAN_IDS[i]
                    if dm_motor.vel_control_confirmed(can_id, 0, 200) then
                        motor_status[i].action = 0
                        motor_status[i].speed = 0
                        success_count = success_count + 1
                    end
                end
                log.info("motor", string.format("所有电机已急停 (%d/%d)", success_count, #MOTOR_CAN_IDS))
                if success_count > 0 then
                    usb_vuart.send_response(seq, CMD.MOTOR_STOP, string.char(0xFF, success_count))
                else
                    usb_vuart.send_nack(seq, CMD.MOTOR_STOP, ERROR.TIMEOUT)
                end
            end)
            return RESULT.NONE
        elseif motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]
            -- 后台执行
            sys.taskInit(function()
                if dm_motor.vel_control_confirmed(can_id, 0, 200) then
                    motor_status[motor_id].action = 0
                    motor_status[motor_id].speed = 0
                    log.info("motor", string.format("电机%d (CAN:0x%02X) 已急停", motor_id, can_id))
                    usb_vuart.send_response(seq, CMD.MOTOR_STOP, string.char(motor_id))
                else
                    log.error("motor", string.format("电机%d (CAN:0x%02X) 急停失败(无响应)", motor_id, can_id))
                    usb_vuart.send_nack(seq, CMD.MOTOR_STOP, ERROR.TIMEOUT)
                end
            end)
            return RESULT.NONE
        else
            return RESULT.NACK, nil, ERROR.INVALID_PARAM
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机旋转 (0x3001)
-- 数据格式: [motor_id u8][angle f32 大端][velocity f32 大端]
-- 响应格式: [motor_id u8]
usb_vuart.on_cmd(CMD.MOTOR_ROTATE, function(seq, data)
    if #data >= 9 then
        local motor_id = data:byte(1)

        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            -- 大端序解析 f32
            local angle = string.unpack(">f", data:sub(2, 5))
            local velocity = string.unpack(">f", data:sub(6, 9))

            local can_id = MOTOR_CAN_IDS[motor_id]

            -- 后台执行，完成后发送异步响应
            sys.taskInit(function()
                if dm_motor.pos_control_confirmed(can_id, angle, velocity, 200) then
                    log.info("motor", string.format("电机%d (CAN:0x%02X) 旋转至 %.2f rad, 速度 %.2f rad/s",
                        motor_id, can_id, angle, velocity))
                    usb_vuart.send_response(seq, CMD.MOTOR_ROTATE, string.char(motor_id))
                else
                    log.error("motor", string.format("电机%d (CAN:0x%02X) 旋转控制失败(无响应)", motor_id, can_id))
                    usb_vuart.send_nack(seq, CMD.MOTOR_ROTATE, ERROR.TIMEOUT)
                end
            end)
            return RESULT.NONE
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机查询位置 (0x3006) - 从寄存器 0x50 实时读取
-- 响应格式: [motor_id u8][position f32 大端序]
usb_vuart.on_cmd(CMD.MOTOR_GET_POS, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)

        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]

            -- 使用异步方式：读取寄存器 0x50 (p_m 电机当前位置)
            sys.taskInit(function()
                -- 发送读取位置寄存器命令
                dm_motor.read_register(can_id, 0x50)

                -- 等待电机响应
                local success = dm_motor.wait_response(can_id, 200)

                if success then
                    local state = dm_motor.get_state(can_id)
                    if state then
                        local pos_bytes = string.pack(">f", state.position)
                        local resp_data = string.char(motor_id) .. pos_bytes
                        log.info("motor", string.format("电机%d (CAN:0x%02X) 位置查询(寄存器): %.4f rad (%.2f°)",
                            motor_id, can_id, state.position, math.deg(state.position)))
                        usb_vuart.send_response(seq, CMD.MOTOR_GET_POS, resp_data)
                        return
                    end
                end

                -- 读取失败，返回错误
                log.error("motor", string.format("电机%d (CAN:0x%02X) 位置查询失败(无响应)", motor_id, can_id))
                usb_vuart.send_nack(seq, CMD.MOTOR_GET_POS, ERROR.TIMEOUT)
            end)
            return RESULT.NONE  -- 异步响应
        else
            log.error("motor", string.format("无效的电机ID: %d (范围: 1-%d)", motor_id, #MOTOR_CAN_IDS))
            return RESULT.NACK, nil, ERROR.INVALID_PARAM
        end
    end
    log.error("motor", "缺少电机ID参数")
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机设置原点 (0x3005)
-- 响应格式: [motor_id u8]
usb_vuart.on_cmd(CMD.MOTOR_SET_ORIGIN, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)
        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]

            -- 保存零点：需要先失能电机，保存后重新使能并控制到0位置
            -- 根据达妙电机协议：所有保存参数、修改参数请在失能模式下修改
            sys.taskInit(function()
                -- 1. 先失能电机
                dm_motor.enable(can_id, false, 2)
                sys.wait(50)

                -- 2. 发送保存零点命令（带确认）
                local success = dm_motor.save_zero_confirmed(can_id, 2, 300)
                sys.wait(100)

                -- 3. 重新使能电机
                dm_motor.enable(can_id, true, 2)
                sys.wait(50)

                -- 4. 发送位置控制命令到0位置，防止电机回到之前的目标位置
                dm_motor.pos_control(can_id, 0, 1.0)

                if success then
                    log.info("motor", string.format("电机%d (CAN:0x%02X) 保存零点完成", motor_id, can_id))
                    usb_vuart.send_response(seq, CMD.MOTOR_SET_ORIGIN, string.char(motor_id))
                else
                    log.error("motor", string.format("电机%d (CAN:0x%02X) 保存零点命令发送失败", motor_id, can_id))
                    usb_vuart.send_nack(seq, CMD.MOTOR_SET_ORIGIN, ERROR.EXEC_FAILED)
                end
            end)
            return RESULT.NONE
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机设置速度 (0x3007)
-- 数据格式: [motor_id u8][velocity f32 大端]
-- 响应格式: [motor_id u8]
usb_vuart.on_cmd(CMD.MOTOR_SET_VEL, function(seq, data)
    if #data >= 5 then
        local motor_id = data:byte(1)

        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            -- 大端序解析 f32
            local velocity = string.unpack(">f", data:sub(2, 5))

            local can_id = MOTOR_CAN_IDS[motor_id]

            -- 后台执行，完成后发送异步响应
            sys.taskInit(function()
                if dm_motor.vel_control_confirmed(can_id, velocity, 200) then
                    log.info("motor", string.format("电机%d (CAN:0x%02X) 设置速度 %.2f rad/s",
                        motor_id, can_id, velocity))
                    usb_vuart.send_response(seq, CMD.MOTOR_SET_VEL, string.char(motor_id))
                else
                    log.error("motor", string.format("电机%d (CAN:0x%02X) 速度控制失败(无响应)", motor_id, can_id))
                    usb_vuart.send_nack(seq, CMD.MOTOR_SET_VEL, ERROR.TIMEOUT)
                end
            end)
            return RESULT.NONE
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 电机相对旋转 (0x3008)
-- 数据格式: [motor_id u8][angle_delta f32 大端][velocity f32 大端]
-- 响应格式: [motor_id u8]
usb_vuart.on_cmd(CMD.MOTOR_ROTATE_REL, function(seq, data)
    if #data >= 9 then
        local motor_id = data:byte(1)

        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            -- 大端序解析 f32
            local angle_delta = string.unpack(">f", data:sub(2, 5))
            local velocity = string.unpack(">f", data:sub(6, 9))

            local can_id = MOTOR_CAN_IDS[motor_id]

            -- 后台执行：先读取实时位置，再计算目标位置
            sys.taskInit(function()
                -- 1. 先读取最新位置（从寄存器0x50实时读取）
                dm_motor.read_register(can_id, 0x50)
                if not dm_motor.wait_response(can_id, 200) then
                    log.error("motor", string.format("电机%d (CAN:0x%02X) 无法读取当前位置", motor_id, can_id))
                    usb_vuart.send_nack(seq, CMD.MOTOR_ROTATE_REL, ERROR.TIMEOUT)
                    return
                end

                -- 2. 获取刚读取的位置
                local state = dm_motor.get_state(can_id)
                if not state then
                    log.error("motor", string.format("电机%d (CAN:0x%02X) 状态获取失败", motor_id, can_id))
                    usb_vuart.send_nack(seq, CMD.MOTOR_ROTATE_REL, ERROR.NOT_READY)
                    return
                end

                -- 3. 计算目标位置 = 当前位置 + 相对位置
                local current_pos = state.position
                local target_pos = current_pos + angle_delta

                -- 4. 发送位置控制命令
                if dm_motor.pos_control_confirmed(can_id, target_pos, velocity, 200) then
                    log.info("motor", string.format("电机%d (CAN:0x%02X) 相对旋转 %.2f rad (从 %.2f -> %.2f), 速度 %.2f rad/s",
                        motor_id, can_id, angle_delta, current_pos, target_pos, velocity))
                    usb_vuart.send_response(seq, CMD.MOTOR_ROTATE_REL, string.char(motor_id))
                else
                    log.error("motor", string.format("电机%d (CAN:0x%02X) 相对旋转失败(无响应)", motor_id, can_id))
                    usb_vuart.send_nack(seq, CMD.MOTOR_ROTATE_REL, ERROR.TIMEOUT)
                end
            end)
            return RESULT.NONE
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- ==================== 6.1 电机参数命令 (0x31xx) ====================

-- 读取电机寄存器 (0x3101)
-- 数据格式: [motor_id u8][reg_id u8]
-- 响应格式: [motor_id u8][reg_id u8][value f32/u32 大端序]
usb_vuart.on_cmd(CMD.MOTOR_READ_REG, function(seq, data)
    if #data >= 2 then
        local motor_id = data:byte(1)
        local reg_id = data:byte(2)

        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]

            sys.taskInit(function()
                -- 发送读取寄存器命令
                dm_motor.read_register(can_id, reg_id)

                -- 等待电机响应
                local success = dm_motor.wait_response(can_id, 300)

                if success then
                    local state = dm_motor.get_state(can_id)
                    if state and state.last_reg_id == reg_id and state.last_reg_value ~= nil then
                        -- 使用最近读取的寄存器值
                        local value = state.last_reg_value

                        -- 响应格式: [motor_id][reg_id][value f32 大端序]
                        local value_bytes = string.pack(">f", value)
                        local resp_data = string.char(motor_id, reg_id) .. value_bytes
                        log.info("motor", string.format("电机%d (CAN:0x%02X) 读取寄存器0x%02X = %.4f",
                            motor_id, can_id, reg_id, value))
                        usb_vuart.send_response(seq, CMD.MOTOR_READ_REG, resp_data)
                        return
                    end
                end

                log.error("motor", string.format("电机%d (CAN:0x%02X) 读取寄存器0x%02X失败", motor_id, can_id, reg_id))
                usb_vuart.send_nack(seq, CMD.MOTOR_READ_REG, ERROR.TIMEOUT)
            end)
            return RESULT.NONE
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 写入电机寄存器 (0x3102)
-- 数据格式: [motor_id u8][reg_id u8][value f32/u32 大端序]
-- 响应格式: [motor_id u8][reg_id u8]
-- 注意: 写入寄存器需要电机处于失能状态
usb_vuart.on_cmd(CMD.MOTOR_WRITE_REG, function(seq, data)
    if #data >= 6 then
        local motor_id = data:byte(1)
        local reg_id = data:byte(2)
        local value = string.unpack(">f", data:sub(3, 6))

        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]

            sys.taskInit(function()
                -- 写入寄存器（使用float类型）
                local success = dm_motor.write_register(can_id, reg_id, value, true)

                if success then
                    -- 等待写入确认
                    local confirmed = dm_motor.wait_response(can_id, 300)
                    if confirmed then
                        log.info("motor", string.format("电机%d (CAN:0x%02X) 写入寄存器0x%02X = %.4f",
                            motor_id, can_id, reg_id, value))
                        usb_vuart.send_response(seq, CMD.MOTOR_WRITE_REG, string.char(motor_id, reg_id))
                        return
                    end
                end

                log.error("motor", string.format("电机%d (CAN:0x%02X) 写入寄存器0x%02X失败", motor_id, can_id, reg_id))
                usb_vuart.send_nack(seq, CMD.MOTOR_WRITE_REG, ERROR.TIMEOUT)
            end)
            return RESULT.NONE
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 保存参数到Flash (0x3103)
-- 数据格式: [motor_id u8]
-- 响应格式: [motor_id u8]
-- 注意: 必须在失能状态下执行
usb_vuart.on_cmd(CMD.MOTOR_SAVE_FLASH, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)

        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]

            sys.taskInit(function()
                -- 保存参数到Flash
                local success = dm_motor.save_param_to_flash(can_id)

                if success then
                    sys.wait(200)  -- 等待Flash写入完成
                    log.info("motor", string.format("电机%d (CAN:0x%02X) 参数已保存到Flash", motor_id, can_id))
                    usb_vuart.send_response(seq, CMD.MOTOR_SAVE_FLASH, string.char(motor_id))
                else
                    log.error("motor", string.format("电机%d (CAN:0x%02X) 保存Flash失败", motor_id, can_id))
                    usb_vuart.send_nack(seq, CMD.MOTOR_SAVE_FLASH, ERROR.EXEC_FAILED)
                end
            end)
            return RESULT.NONE
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 刷新电机状态 (0x3104)
-- 数据格式: [motor_id u8]
-- 响应格式: [motor_id u8][position f32][velocity f32][torque f32][temp_mos u8][temp_rotor u8][error u8][enabled u8]
usb_vuart.on_cmd(CMD.MOTOR_REFRESH, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)

        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]

            sys.taskInit(function()
                -- 刷新电机状态
                local success = dm_motor.refresh_status_confirmed(can_id, 300)

                if success then
                    local state = dm_motor.get_state(can_id)
                    if state then
                        -- 打包完整状态数据
                        local resp_data = string.char(motor_id) ..
                            string.pack(">f", state.position) ..
                            string.pack(">f", state.velocity) ..
                            string.pack(">f", state.torque) ..
                            string.char(
                                state.temperature_mos,
                                state.temperature_rotor,
                                state.error_code,
                                state.enabled and 1 or 0
                            )
                        log.info("motor", string.format("电机%d (CAN:0x%02X) 状态刷新: pos=%.2f vel=%.2f err=0x%X",
                            motor_id, can_id, state.position, state.velocity, state.error_code))
                        usb_vuart.send_response(seq, CMD.MOTOR_REFRESH, resp_data)
                        return
                    end
                end

                log.error("motor", string.format("电机%d (CAN:0x%02X) 状态刷新失败", motor_id, can_id))
                usb_vuart.send_nack(seq, CMD.MOTOR_REFRESH, ERROR.TIMEOUT)
            end)
            return RESULT.NONE
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 清除电机错误 (0x3105)
-- 数据格式: [motor_id u8]
-- 响应格式: [motor_id u8]
usb_vuart.on_cmd(CMD.MOTOR_CLEAR_ERROR, function(seq, data)
    if #data >= 1 then
        local motor_id = data:byte(1)

        if motor_id >= 1 and motor_id <= #MOTOR_CAN_IDS then
            local can_id = MOTOR_CAN_IDS[motor_id]

            sys.taskInit(function()
                -- 清除错误（使用MIT模式）
                local success = dm_motor.clear_error(can_id)

                if success then
                    local confirmed = dm_motor.wait_response(can_id, 300)
                    if confirmed then
                        log.info("motor", string.format("电机%d (CAN:0x%02X) 错误已清除", motor_id, can_id))
                        usb_vuart.send_response(seq, CMD.MOTOR_CLEAR_ERROR, string.char(motor_id))
                        return
                    end
                end

                log.error("motor", string.format("电机%d (CAN:0x%02X) 清除错误失败", motor_id, can_id))
                usb_vuart.send_nack(seq, CMD.MOTOR_CLEAR_ERROR, ERROR.EXEC_FAILED)
            end)
            return RESULT.NONE
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

-- ==================== 7.1 OTA升级命令 ====================

-- 启动OTA升级 (0x6001)
-- 数据格式: [URL字符串]
-- 响应格式: ACK表示升级已启动，NACK表示失败
usb_vuart.on_cmd(CMD.OTA_START, function(seq, data)
    if #data >= 1 then
        local url = data
        log.info("ota_cmd", "收到升级请求", url)

        if ota_update.start(url) then
            log.info("ota_cmd", "升级已启动")
            return RESULT.ACK
        else
            log.error("ota_cmd", "升级启动失败")
            return RESULT.NACK, nil, ERROR.DEVICE_BUSY
        end
    end
    return RESULT.NACK, nil, ERROR.INVALID_PARAM
end)

-- 查询OTA状态 (0x6002)
-- 响应格式: [status u8][error_code u8]
usb_vuart.on_cmd(CMD.OTA_STATUS, function(seq, data)
    local status, error_code = ota_update.get_status()
    local resp_data = string.char(status, error_code)
    log.info("ota_cmd", string.format("状态查询: status=%d, error=%d", status, error_code))
    return RESULT.RESPONSE, resp_data
end)

-- 查询版本信息 (0x6003)
-- 响应格式: [project_len u8][project string][version string(12字节)]
usb_vuart.on_cmd(CMD.OTA_VERSION, function(seq, data)
    local project, version, core_ver = ota_update.get_version()

    -- 限制project长度
    if #project > 32 then
        project = project:sub(1, 32)
    end

    -- version格式: XXX.YYY.ZZZ (12字节，不足补0)
    if #version < 12 then
        version = version .. string.rep("\0", 12 - #version)
    elseif #version > 12 then
        version = version:sub(1, 12)
    end

    local resp_data = string.char(#project) .. project .. version
    log.info("ota_cmd", "版本查询", project, version)
    return RESULT.RESPONSE, resp_data
end)

-- 设置OTA状态变更通知回调
ota_update.set_notify_callback(function(status, error_code)
    -- 发送NOTIFY帧通知Hi3516cv610 OTA状态变更
    local notify_data = string.char(status, error_code)
    usb_vuart.notify(0x6002, notify_data)  -- 使用OTA_STATUS命令码
    log.info("ota_notify", string.format("状态通知: status=%d, error=%d", status, error_code))
end)

-- ==================== 7.2 串口FOTA升级命令 ====================

-- 开始串口升级 (0x6010)
-- 数据格式: [firmware_size u32 大端序]
-- 响应格式: ACK表示准备就绪，NACK表示失败
usb_vuart.on_cmd(CMD.OTA_UART_START, function(seq, data)
    log.info("uart_fota_cmd", "收到串口升级开始命令")
    local success, err = uart_fota.handle_start(data)
    if success then
        return RESULT.ACK
    else
        return RESULT.NACK, nil, err or ERROR.EXEC_FAILED
    end
end)

-- 固件数据包 (0x6011)
-- 数据格式: [seq u16 大端序][firmware_data...]
-- 响应格式: ACK表示收到，NACK表示失败
usb_vuart.on_cmd(CMD.OTA_UART_DATA, function(seq, data)
    local success, err = uart_fota.handle_data(data)
    if success then
        return RESULT.ACK
    else
        return RESULT.NACK, nil, err or ERROR.EXEC_FAILED
    end
end)

-- 升级完成 (0x6012)
-- 响应格式: ACK表示开始校验，NACK表示失败
usb_vuart.on_cmd(CMD.OTA_UART_FINISH, function(seq, data)
    log.info("uart_fota_cmd", "收到串口升级完成命令")
    local success, err = uart_fota.handle_finish()
    if success then
        return RESULT.ACK
    else
        return RESULT.NACK, nil, err or ERROR.EXEC_FAILED
    end
end)

-- 取消升级 (0x6013)
-- 响应格式: ACK
usb_vuart.on_cmd(CMD.OTA_UART_ABORT, function(seq, data)
    log.info("uart_fota_cmd", "收到取消升级命令")
    uart_fota.handle_abort()
    return RESULT.ACK
end)

-- 设置串口FOTA状态变更通知回调
uart_fota.set_notify_callback(function(status, error_code, progress)
    -- 发送NOTIFY帧通知Hi3516cv610 串口FOTA状态变更
    local notify_data = string.char(status, error_code, progress)
    usb_vuart.notify(CMD.OTA_UART_STATUS, notify_data)
    log.info("uart_fota_notify", string.format("状态通知: status=%d, error=%d, progress=%d%%",
        status, error_code, progress))
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

-- ==================== 10.1 网络配置命令 ====================
-- 使用 network_config 模块处理网络配置

-- 设置APN (0x7001)
-- 数据格式: [apn_len u8][apn string][user_len u8][user string][pwd_len u8][pwd string][auth_type u8]
-- 注意: 设置后需要重启才能生效，因为APN必须在入网前配置
usb_vuart.on_cmd(CMD.NET_SET_APN, function(_, data)
    if #data < 3 then
        return RESULT.NACK, nil, ERROR.INVALID_PARAM
    end

    local offset = 1

    -- 解析APN
    local apn_len = data:byte(offset)
    offset = offset + 1
    if #data < offset + apn_len then
        return RESULT.NACK, nil, ERROR.INVALID_PARAM
    end
    local apn = apn_len > 0 and data:sub(offset, offset + apn_len - 1) or ""
    offset = offset + apn_len

    -- 解析用户名
    if #data < offset then
        return RESULT.NACK, nil, ERROR.INVALID_PARAM
    end
    local user_len = data:byte(offset)
    offset = offset + 1
    if #data < offset + user_len then
        return RESULT.NACK, nil, ERROR.INVALID_PARAM
    end
    local user = user_len > 0 and data:sub(offset, offset + user_len - 1) or ""
    offset = offset + user_len

    -- 解析密码
    if #data < offset then
        return RESULT.NACK, nil, ERROR.INVALID_PARAM
    end
    local pwd_len = data:byte(offset)
    offset = offset + 1
    if #data < offset + pwd_len then
        return RESULT.NACK, nil, ERROR.INVALID_PARAM
    end
    local password = pwd_len > 0 and data:sub(offset, offset + pwd_len - 1) or ""
    offset = offset + pwd_len

    -- 解析认证类型 (可选)
    local auth_type = 0
    if #data >= offset then
        auth_type = data:byte(offset) or 0
    end

    log.info("net", string.format("设置APN: apn=%s, user=%s, auth=%d", apn, user, auth_type))

    -- 使用network模块保存配置 (重启后自动加载)
    if network.set_apn(apn, user, password, auth_type) then
        log.info("net", "APN配置已保存，重启后生效")
        return RESULT.ACK
    else
        return RESULT.NACK, nil, ERROR.EXEC_FAILED
    end
end)

-- 查询APN配置 (0x7002)
-- 响应格式: [apn_len u8][apn string][user_len u8][user string][auth_type u8]
usb_vuart.on_cmd(CMD.NET_GET_APN, function()
    local apn, user, _, auth_type = network.get_apn()

    local resp_data = string.char(#apn) .. apn ..
                      string.char(#user) .. user ..
                      string.char(auth_type)

    log.info("net", string.format("查询APN: apn=%s, user=%s, auth=%d", apn, user, auth_type))
    return RESULT.RESPONSE, resp_data
end)

-- 查询详细网络状态 (0x7003)
-- 响应格式: [status u8][csq u8][rssi i8][rsrp i16 大端][snr i8][operator u8][ip_len u8][ip string]
usb_vuart.on_cmd(CMD.NET_GET_STATUS, function()
    local resp_data = network.get_status_bytes()
    local s = network.get_status()
    log.info("net", string.format("网络状态: status=%d, csq=%d, rssi=%d, rsrp=%d, ip=%s",
        s.registered, s.csq, s.rssi, s.rsrp, s.ip))
    return RESULT.RESPONSE, resp_data
end)

-- 重置网络连接 (0x7004)
-- 数据格式: 无 或 [飞行模式持续时间 u8 秒]
usb_vuart.on_cmd(CMD.NET_RESET, function(_, data)
    local duration = 3  -- 默认飞行模式持续3秒
    if #data >= 1 then
        duration = data:byte(1)
        if duration < 1 then duration = 1 end
        if duration > 30 then duration = 30 end
    end

    log.info("net", string.format("重置网络连接，飞行模式持续 %d 秒", duration))
    network.reset(duration)
    return RESULT.ACK
end)

-- ==================== 10.2 系统命令 ====================

-- 系统重启 (0x0003)
-- 数据格式: 无 或 [delay u8 秒] (延迟重启时间，默认3秒)
usb_vuart.on_cmd(CMD.SYS_RESET, function(_, data)
    local delay = 3  -- 默认3秒后重启
    if #data >= 1 then
        delay = data:byte(1)
        if delay < 1 then delay = 1 end
        if delay > 30 then delay = 30 end
    end

    log.info("system", string.format("收到重启命令，%d秒后重启", delay))

    -- 先发送ACK确认，然后延迟重启
    sys.taskInit(function()
        sys.wait(delay * 1000)
        log.info("system", "执行重启...")
        rtos.reboot()
    end)

    return RESULT.ACK
end)

-- 主机(Hi3516cv610)重启 (0x0004) - 通过断电重启
-- 数据格式: 无 或 [off_time u8 秒] (断电持续时间，默认2秒)
usb_vuart.on_cmd(CMD.SYS_RESET_HOST, function(_, data)
    local off_time = 2  -- 默认断电2秒
    if #data >= 1 then
        off_time = data:byte(1)
        if off_time < 1 then off_time = 1 end
        if off_time > 10 then off_time = 10 end
    end

    log.info("system", string.format("收到主机重启命令，断电 %d 秒", off_time))

    -- 后台执行断电重启
    sys.taskInit(function()
        -- 关闭Hi3516cv610供电
        gpio.set(HOST_PWR_EN_PIN, 0)
        log.info("system", "Hi3516cv610 供电已关闭")

        sys.wait(off_time * 1000)

        -- 恢复供电
        gpio.set(HOST_PWR_EN_PIN, 1)
        log.info("system", "Hi3516cv610 供电已恢复")
    end)

    return RESULT.ACK
end)

-- ==================== 11. 看门狗 ====================
if wdt then
    wdt.init(9000)
    sys.timerLoopStart(wdt.feed, 3000)
end



-- ==================== 13. 启动系统 ====================
log.info("main", "VDM Air8000 V1.0协议 系统已启动")
log.info("main", "帧格式: AA 55 [VER][TYPE][SEQ][CMD][LEN][DATA][CRC]")

sys.run()
