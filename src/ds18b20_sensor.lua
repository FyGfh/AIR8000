--[[
@module  ds18b20_sensor
@summary Air8000 DS18B20温度传感器模块 (基于官方onewire示例)
@version 1.0
@date    2025.12.18
@author  VDM
@description
单个DS18B20设备,使用SKIP ROM命令,简化实现
]]

local ds18b20 = {}

-- ==================== 配置参数 ====================
local ONEWIRE_ID = 0  -- OneWire总线ID (默认GPIO2)

-- ==================== 初始化 ====================
function ds18b20.init()
    if not onewire then
        log.error("ds18b20", "onewire库不可用")
        return false
    end

    -- 初始化OneWire (参考官方示例)
    onewire.init(ONEWIRE_ID)
    onewire.timing(ONEWIRE_ID, false, 0, 500, 500, 15, 240, 70, 1, 15, 10, 2)

    log.info("ds18b20", "OneWire初始化完成 (单设备模式)")
    return true
end

-- ==================== 设备扫描 ====================
function ds18b20.scan_devices()
    -- 单设备模式,总是返回1
    return 1
end

-- ==================== 温度读取 (参考官方示例) ====================
function ds18b20.read_single(device_index)
    if not onewire then
        return nil
    end

    local tbuff = zbuff.create(10)
    local rbuff = zbuff.create(9)
    local succ, rx_data, crc8c, range, t

    -- 单设备模式: 使用SKIP ROM (参考官方示例)
    tbuff:write(0xcc, 0xb8)  -- SKIP ROM + 0xb8

    -- 发送温度转换命令
    tbuff[tbuff:used() - 1] = 0x44  -- CONVERT T
    succ = onewire.tx(ONEWIRE_ID, tbuff, false, true, true)
    if not succ then
        return nil
    end

    -- 等待转换完成 (参考官方示例)
    while true do
        succ = onewire.reset(ONEWIRE_ID, true)
        if not succ then
            return nil
        end
        if onewire.bit(ONEWIRE_ID) > 0 then
            break
        end
        sys.wait(10)
    end

    -- 读取温度数据
    tbuff[tbuff:used() - 1] = 0xbe  -- READ SCRATCHPAD
    succ = onewire.tx(ONEWIRE_ID, tbuff, false, true, true)
    if not succ then
        return nil
    end

    succ, rx_data = onewire.rx(ONEWIRE_ID, 9, nil, rbuff, false, false, false)
    if not succ then
        return nil
    end

    -- 验证CRC (参考官方示例)
    crc8c = crypto.crc8(rbuff:toStr(0, 8), 0x31, 0, true)
    if crc8c ~= rbuff[8] then
        log.warn("ds18b20", "数据CRC校验失败")
        return nil
    end

    -- 解析温度数据 (参考官方示例)
    range = (rbuff[4] >> 5) & 0x03
    t = rbuff:query(0, 2, false, true)
    t = t * (5000 >> range)
    t = t / 10  -- 转换为毫度

    log.info("ds18b20", string.format("温度: %.2f°C", t / 1000.0))
    return math.floor(t)  -- 返回毫度
end

-- 读取所有DS18B20温度
function ds18b20.read_all()
    local temps = {}
    local count = 0

    local temp = ds18b20.read_single(0)
    if temp then
        temps[0] = temp
        count = 1
    end

    return temps, count
end

-- 将温度数据打包成二进制格式
function ds18b20.read_temperature_data()
    local temps, count = ds18b20.read_all()

    if count == 0 then
        return string.char(0x00)
    end

    local data = string.char(count)

    for i = 0, count - 1 do
        local temp = temps[i]
        local temp_int = math.floor(temp / 100)
        local temp_h = math.floor(temp_int / 256)
        local temp_l = temp_int % 256
        data = data .. string.char(temp_h, temp_l)
    end

    return data
end

-- 测试函数
function ds18b20.test()
    log.info("ds18b20", "======== DS18B20测试 ========")

    if not ds18b20.init() then
        log.error("ds18b20", "初始化失败")
        return false
    end

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
