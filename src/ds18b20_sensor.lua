--[[
@module  ds18b20_sensor
@summary Air8000 OneWire DS18B20温度传感器模块
@version 1.0
@date    2025.12.13
@author  VDM
@usage
在main.lua中引用：
    local ds18b20 = require "ds18b20_sensor"

    -- 注册DS18B20状态提供者
    usb_vuart.register_status("ds18b20", function()
        return ds18b20.read_temperature_data()
    end)

    -- 或者注册自定义命令
    usb_vuart.on_cmd(0x15, function(data)
        local temp_data = ds18b20.read_temperature_data()
        return pack_response(0x06, temp_data)
    end)
]]

local ds18b20 = {}

-- ==================== 配置参数 ====================
local ONEWIRE_PIN = 7  -- OneWire数据引脚，根据实际硬件修改
local ds18b20_devices = {}  -- 发现的DS18B20设备列表

-- ==================== OneWire初始化 ====================
local sensor = require "sensor"
local w1Id = 0  -- OneWire总线ID

function ds18b20.init()
    -- 初始化OneWire
    if sensor.w1_setup then
        sensor.w1_setup(w1Id, ONEWIRE_PIN)
        log.info("ds18b20", "OneWire初始化成功，引脚:", ONEWIRE_PIN)

        -- 搜索总线上的DS18B20设备
        ds18b20.scan_devices()
        return true
    else
        log.error("ds18b20", "OneWire功能不可用")
        return false
    end
end

-- ==================== 设备扫描 ====================
function ds18b20.scan_devices()
    -- 扫描OneWire总线上的所有DS18B20设备
    if sensor.ds18b20 then
        local count = 0
        -- 遍历所有可能的设备地址
        for i = 0, 7 do
            local temp = sensor.ds18b20(w1Id, i)
            if temp then
                ds18b20_devices[count] = i
                count = count + 1
                log.info("ds18b20", string.format("发现设备 #%d，地址: %d", count, i))
            end
        end

        log.info("ds18b20", "扫描完成，发现", count, "个DS18B20设备")
        return count
    else
        log.error("ds18b20", "DS18B20传感器不支持")
        return 0
    end
end

-- ==================== 温度读取 ====================
-- 读取单个DS18B20温度
function ds18b20.read_single(device_index)
    if sensor.ds18b20 then
        local temp = sensor.ds18b20(w1Id, device_index or 0)
        if temp then
            log.info("ds18b20", string.format("设备%d温度: %.2f°C", device_index or 0, temp / 1000.0))
            return temp  -- 返回温度值（单位：毫度）
        else
            log.warn("ds18b20", "读取设备", device_index or 0, "失败")
            return nil
        end
    end
    return nil
end

-- 读取所有DS18B20温度
function ds18b20.read_all()
    local temps = {}
    local count = 0

    for i = 0, #ds18b20_devices do
        local temp = ds18b20.read_single(i)
        if temp then
            temps[count] = temp
            count = count + 1
        end
    end

    return temps, count
end

-- ==================== 数据打包 ====================
-- 将温度数据打包成二进制格式，供USB虚拟串口发送
-- 格式：[设备数量(1B)] [温度1(2B)] [温度2(2B)] ...
function ds18b20.read_temperature_data()
    local temps, count = ds18b20.read_all()

    if count == 0 then
        -- 没有检测到设备或读取失败
        return string.char(0x00)
    end

    local data = string.char(count)  -- 第一个字节是设备数量

    for i = 0, count - 1 do
        local temp = temps[i]
        -- 温度值转换为0.1°C单位的整数（例如25.6°C = 256）
        local temp_int = math.floor(temp / 100)  -- temp是毫度，除以100得到0.1度
        local temp_h = math.floor(temp_int / 256)
        local temp_l = temp_int % 256
        data = data .. string.char(temp_h, temp_l)
    end

    return data
end

-- ==================== 定期采集（可选）====================
-- 启动定时采集任务
function ds18b20.start_periodic_read(interval_ms)
    interval_ms = interval_ms or 5000  -- 默认5秒

    sys.timerLoopStart(function()
        ds18b20.read_all()
    end, interval_ms)

    log.info("ds18b20", "启动定期采集，间隔:", interval_ms, "ms")
end

-- ==================== 测试函数 ====================
function ds18b20.test()
    log.info("ds18b20", "======== DS18B20测试 ========")

    if not ds18b20.init() then
        log.error("ds18b20", "初始化失败")
        return false
    end

    -- 读取温度
    local data = ds18b20.read_temperature_data()
    local count = data:byte(1)

    log.info("ds18b20", "检测到", count, "个设备")

    if count > 0 then
        for i = 0, count - 1 do
            local temp_h = data:byte(2 + i * 2)
            local temp_l = data:byte(3 + i * 2)
            local temp_int = temp_h * 256 + temp_l
            log.info("ds18b20", string.format("设备%d: %.1f°C", i, temp_int / 10.0))
        end
    end

    log.info("ds18b20", "=============================")
    return true
end

return ds18b20
