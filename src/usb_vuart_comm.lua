--[[
@module  usb_vuart_comm
@summary Air8000 与 Hi3516cv610 USB虚拟串口通信模块 (V1.0协议)
@version 1.0
@date    2025.12.13
@description
实现V1.0帧协议通信：
- 帧格式: [0xAA][0x55][VER][TYPE][SEQ][CMD_H][CMD_L][LEN_H][LEN_L][DATA...][CRC_H][CRC_L]
- 支持REQUEST/RESPONSE/ACK/NACK/NOTIFY帧类型
- CRC-16/MODBUS校验

@usage
    local usb_vuart = require "usb_vuart_comm"

    -- 注册命令处理器
    usb_vuart.on_cmd(0x3001, function(seq, data)
        -- 处理电机旋转命令
        return usb_vuart.CMD_RESULT.ACK
    end)
]]

local usb_vuart = {}

-- ==================== 协议常量 ====================
local SYNC1 = 0xAA
local SYNC2 = 0x55
local VERSION = 0x10  -- V1.0

local HEADER_SIZE = 9
local CRC_SIZE = 2
local MIN_FRAME_SIZE = HEADER_SIZE + CRC_SIZE

-- 帧类型
usb_vuart.FRAME_TYPE = {
    REQUEST   = 0x00,
    RESPONSE  = 0x01,
    NOTIFY    = 0x02,
    ACK       = 0x03,
    NACK      = 0x04,
}

-- 命令码定义 (16位)
usb_vuart.CMD = {
    -- 系统命令 (0x00xx)
    SYS_PING      = 0x0001,
    SYS_VERSION   = 0x0002,
    SYS_RESET     = 0x0003,

    -- 查询命令 (0x01xx)
    QUERY_POWER   = 0x0101,
    QUERY_STATUS  = 0x0102,
    QUERY_NETWORK = 0x0103,

    -- 电机命令 (0x30xx)
    MOTOR_ROTATE     = 0x3001,
    MOTOR_ENABLE     = 0x3002,
    MOTOR_DISABLE    = 0x3003,
    MOTOR_STOP       = 0x3004,
    MOTOR_SET_ORIGIN = 0x3005,
    MOTOR_GET_POS    = 0x3006,
    MOTOR_SET_VEL    = 0x3007,
    MOTOR_ROTATE_REL = 0x3008,
    MOTOR_GET_ALL    = 0x3010,

    -- 电机参数命令 (0x31xx)
    MOTOR_READ_REG     = 0x3101,  -- 读取电机寄存器
    MOTOR_WRITE_REG    = 0x3102,  -- 写入电机寄存器
    MOTOR_SAVE_FLASH   = 0x3103,  -- 保存参数到Flash
    MOTOR_REFRESH      = 0x3104,  -- 刷新电机状态
    MOTOR_CLEAR_ERROR  = 0x3105,  -- 清除电机错误

    -- 传感器命令 (0x40xx)
    SENSOR_READ_TEMP = 0x4001,
    SENSOR_READ_ALL  = 0x4002,

    -- 设备控制命令 (0x50xx)
    DEV_HEATER      = 0x5001,
    DEV_FAN         = 0x5002,
    DEV_LED         = 0x5003,
    DEV_LASER       = 0x5004,
    DEV_PWM_LIGHT   = 0x5005,
    DEV_MOTOR_POWER = 0x5006,  -- 电机供电控制
    DEV_GET_STATE   = 0x5010,

    -- OTA升级命令 (0x60xx)
    OTA_START       = 0x6001,  -- 启动OTA升级 (数据: URL字符串)
    OTA_STATUS      = 0x6002,  -- 查询OTA状态
    OTA_VERSION     = 0x6003,  -- 查询版本信息

    -- 串口FOTA升级命令 (0x601x)
    OTA_UART_START  = 0x6010,  -- 开始串口升级 (数据: [firmware_size u32 大端序])
    OTA_UART_DATA   = 0x6011,  -- 固件数据包 (数据: [seq u16 大端序][data...])
    OTA_UART_FINISH = 0x6012,  -- 升级完成
    OTA_UART_ABORT  = 0x6013,  -- 取消升级
    OTA_UART_STATUS = 0x6014,  -- 串口升级状态通知
}

-- 命令处理结果
usb_vuart.CMD_RESULT = {
    ACK = 1,       -- 发送ACK
    NACK = 2,      -- 发送NACK
    RESPONSE = 3,  -- 发送RESPONSE (需要data)
    NONE = 4,      -- 不发送响应
}

-- 错误码
usb_vuart.ERROR = {
    UNKNOWN_CMD = 0x01,
    INVALID_PARAM = 0x02,
    DEVICE_BUSY = 0x03,
    NOT_READY = 0x04,
    EXEC_FAILED = 0x05,
    TIMEOUT = 0x06,
    CRC_ERROR = 0x07,
    VERSION_UNSUPPORTED = 0x08,
}

-- ==================== 配置参数 ====================
local UART_ID = uart.VUART_0
local BAUDRATE = 115200

-- ==================== 内部变量 ====================
local is_initialized = false
local rx_buff = nil
local parse_buffer = ""
local cmd_handlers = {}
local status_providers = {}

-- ==================== CRC-16/MODBUS ====================
local function crc16_modbus(data)
    local crc = 0xFFFF
    for i = 1, #data do
        crc = bit.bxor(crc, data:byte(i))
        for _ = 1, 8 do
            if bit.band(crc, 0x0001) ~= 0 then
                crc = bit.bxor(bit.rshift(crc, 1), 0xA001)
            else
                crc = bit.rshift(crc, 1)
            end
        end
    end
    return crc
end

-- ==================== 帧构造 ====================
-- 构造完整帧
local function build_frame(frame_type, seq, cmd, data)
    data = data or ""
    local data_len = #data

    -- 构造帧头 (不含SYNC)
    local header = string.char(
        VERSION,
        frame_type,
        seq,
        bit.rshift(cmd, 8),       -- CMD_H
        bit.band(cmd, 0xFF),      -- CMD_L
        bit.rshift(data_len, 8),  -- LEN_H
        bit.band(data_len, 0xFF)  -- LEN_L
    )

    -- 计算CRC (从VER开始)
    local crc_data = header .. data
    local crc = crc16_modbus(crc_data)

    -- 组装完整帧
    return string.char(SYNC1, SYNC2) .. header .. data ..
           string.char(bit.rshift(crc, 8), bit.band(crc, 0xFF))
end

-- 构造ACK帧
local function build_ack(seq, cmd)
    return build_frame(usb_vuart.FRAME_TYPE.ACK, seq, cmd, "")
end

-- 构造NACK帧
local function build_nack(seq, cmd, error_code)
    return build_frame(usb_vuart.FRAME_TYPE.NACK, seq, cmd, string.char(error_code))
end

-- 构造RESPONSE帧
local function build_response(seq, cmd, data)
    return build_frame(usb_vuart.FRAME_TYPE.RESPONSE, seq, cmd, data)
end

-- 构造NOTIFY帧
local function build_notify(cmd, data)
    return build_frame(usb_vuart.FRAME_TYPE.NOTIFY, 0, cmd, data)
end

-- ==================== 帧解析 ====================
-- 解析一帧数据
local function parse_frame(buffer)
    -- 查找帧头
    local header_pos = nil
    for i = 1, #buffer - 1 do
        if buffer:byte(i) == SYNC1 and buffer:byte(i + 1) == SYNC2 then
            header_pos = i
            break
        end
    end

    if not header_pos then
        return nil, nil, "未找到帧头"
    end

    -- 移除帧头之前的数据
    if header_pos > 1 then
        buffer = buffer:sub(header_pos)
    end

    -- 检查最小长度
    if #buffer < MIN_FRAME_SIZE then
        return nil, buffer, "数据不完整"
    end

    -- 读取长度
    local len_h = buffer:byte(8)
    local len_l = buffer:byte(9)
    local data_len = len_h * 256 + len_l

    local total_len = HEADER_SIZE + data_len + CRC_SIZE

    -- 检查数据是否完整
    if #buffer < total_len then
        return nil, buffer, "数据不完整"
    end

    -- 提取帧
    local frame_data = buffer:sub(1, total_len)
    local remaining = buffer:sub(total_len + 1)

    -- 解析帧字段
    local frame = {
        version = frame_data:byte(3),
        frame_type = frame_data:byte(4),
        seq = frame_data:byte(5),
        cmd = frame_data:byte(6) * 256 + frame_data:byte(7),
        data_len = data_len,
        data = data_len > 0 and frame_data:sub(10, 9 + data_len) or "",
        crc = frame_data:byte(-2) * 256 + frame_data:byte(-1),
    }

    return frame, remaining, nil
end

-- ==================== 请求处理 ====================
local function handle_request(frame)
    local seq = frame.seq
    local cmd = frame.cmd
    local data = frame.data

    log.info("vuart", string.format("处理请求 CMD=0x%04X SEQ=%d LEN=%d", cmd, seq, #data))

    -- 检查版本
    if frame.version ~= VERSION then
        log.warn("vuart", "版本不支持", string.format("0x%02X", frame.version))
        return build_nack(seq, cmd, usb_vuart.ERROR.VERSION_UNSUPPORTED)
    end

    -- 先检查自定义处理器
    local handler = cmd_handlers[cmd]
    if handler then
        local result, resp_data, error_code = handler(seq, data)
        if result == usb_vuart.CMD_RESULT.ACK then
            return build_ack(seq, cmd)
        elseif result == usb_vuart.CMD_RESULT.NACK then
            return build_nack(seq, cmd, error_code or usb_vuart.ERROR.EXEC_FAILED)
        elseif result == usb_vuart.CMD_RESULT.RESPONSE then
            return build_response(seq, cmd, resp_data or "")
        else
            return nil  -- 不发送响应
        end
    end

    -- 内置命令处理
    if cmd == usb_vuart.CMD.SYS_PING then
        return build_ack(seq, cmd)

    elseif cmd == usb_vuart.CMD.SYS_VERSION then
        -- 返回版本: major, minor, patch + build string
        local version_data = string.char(0, 0, 3) .. "AIR8000"
        return build_response(seq, cmd, version_data)

    elseif cmd == usb_vuart.CMD.QUERY_NETWORK then
        -- 查询网络状态
        local csq = mobile.csq() or 0
        local rssi = mobile.rssi() or 0
        local rsrp = mobile.rsrp() or 0
        local status = mobile.status() or 0

        -- 获取SIM卡ICCID（SIM卡号，通常是20位数字）
        local iccid = mobile.iccid() or ""

        -- 获取IMSI（国际移动用户识别码，用于识别运营商）
        local imsi = mobile.imsi() or ""

        -- 从IMSI解析运营商代码 (MCC+MNC)
        -- IMSI格式: MCCMNC + 用户ID
        -- 中国移动: 46000, 46002, 46007, 46008
        -- 中国联通: 46001, 46006, 46009
        -- 中国电信: 46003, 46005, 46011
        local operator = 0  -- 0=未知, 1=中国移动, 2=中国联通, 3=中国电信
        if #imsi >= 5 then
            local mccmnc = imsi:sub(1, 5)
            if mccmnc == "46000" or mccmnc == "46002" or mccmnc == "46007" or mccmnc == "46008" then
                operator = 1  -- 中国移动
            elseif mccmnc == "46001" or mccmnc == "46006" or mccmnc == "46009" then
                operator = 2  -- 中国联通
            elseif mccmnc == "46003" or mccmnc == "46005" or mccmnc == "46011" then
                operator = 3  -- 中国电信
            end
        end

        -- 限制ICCID长度为20字节（标准ICCID长度）
        if #iccid > 20 then
            iccid = iccid:sub(1, 20)
        elseif #iccid < 20 then
            iccid = iccid .. string.rep("\0", 20 - #iccid)  -- 填充0
        end

        -- 网络数据格式: [csq][rssi][rsrp][status][operator][iccid(20字节)]
        local network_data = string.char(
            csq,
            bit.band(rssi, 0xFF),
            bit.band(rsrp, 0xFF),
            status,
            operator
        ) .. iccid

        -- 添加IP地址
        local ip = socket.localIP(socket.LWIP_GP)
        if ip then
            network_data = network_data .. ip
        end

        return build_response(seq, cmd, network_data)

    elseif cmd == usb_vuart.CMD.SENSOR_READ_ALL then
        -- 读取所有传感器
        local provider = status_providers["sensor"]
        if provider then
            local sensor_data = provider()
            return build_response(seq, cmd, sensor_data)
        else
            return build_nack(seq, cmd, usb_vuart.ERROR.NOT_READY)
        end

    elseif cmd == usb_vuart.CMD.MOTOR_GET_ALL then
        -- 查询所有电机状态
        local provider = status_providers["motor"]
        if provider then
            local motor_data = provider()
            return build_response(seq, cmd, motor_data)
        else
            return build_nack(seq, cmd, usb_vuart.ERROR.NOT_READY)
        end
    end

    -- 未知命令
    log.warn("vuart", "未知命令", string.format("0x%04X", cmd))
    return build_nack(seq, cmd, usb_vuart.ERROR.UNKNOWN_CMD)
end

-- ==================== 串口接收处理 ====================
local function uart_receive_callback(id, len)
    while true do
        local recv_len = uart.rx(id, rx_buff)
        if recv_len <= 0 then
            break
        end

        -- 获取接收到的数据并追加到解析缓冲区
        local recv_data = rx_buff:query()
        rx_buff:del()
        parse_buffer = parse_buffer .. recv_data

        -- 尝试解析帧
        while #parse_buffer >= MIN_FRAME_SIZE do
            local frame, remaining, err = parse_frame(parse_buffer)

            if frame then
                parse_buffer = remaining or ""

                -- 只处理REQUEST帧
                if frame.frame_type == usb_vuart.FRAME_TYPE.REQUEST then
                    local response = handle_request(frame)
                    if response then
                        uart.write(UART_ID, response)
                        log.info("vuart", "响应已发送", #response .. "字节")
                    end
                else
                    log.info("vuart", "忽略非REQUEST帧", string.format("TYPE=0x%02X", frame.frame_type))
                end
            else
                -- 数据不完整，等待更多数据
                if err == "未找到帧头" and #parse_buffer > 256 then
                    -- 缓冲区太大但找不到帧头，清理
                    parse_buffer = ""
                    log.warn("vuart", "清理无效数据")
                end
                break
            end
        end
    end
end

-- ==================== 初始化 ====================
function usb_vuart.init()
    if is_initialized then
        log.warn("vuart", "已经初始化过了")
        return true
    end

    log.info("vuart", "初始化USB虚拟串口通信 V1.0")

    -- 创建接收缓冲区
    rx_buff = zbuff.create(1024)
    parse_buffer = ""

    -- 配置串口
    uart.setup(UART_ID, BAUDRATE, 8, 1)

    -- 注册接收回调
    uart.on(UART_ID, "receive", uart_receive_callback)

    is_initialized = true

    log.info("vuart", "USB虚拟串口通信已就绪")
    log.info("vuart", "协议版本: V1.0")
    log.info("vuart", "帧格式: AA 55 [VER][TYPE][SEQ][CMD][LEN][DATA][CRC]")

    return true
end

-- 关闭
function usb_vuart.close()
    if is_initialized then
        is_initialized = false
        parse_buffer = ""

        if rx_buff then
            rx_buff:del()
            rx_buff = nil
        end

        uart.close(UART_ID)
        log.info("vuart", "已关闭")
    end
end

-- ==================== 状态提供者注册 ====================
function usb_vuart.register_status(name, provider)
    status_providers[name] = provider
    log.info("vuart", "注册状态提供者", name)
end

-- ==================== 命令处理注册 ====================
-- handler(seq, data) -> result, resp_data, error_code
function usb_vuart.on_cmd(cmd, handler)
    cmd_handlers[cmd] = handler
    log.info("vuart", "注册命令处理", string.format("0x%04X", cmd))
end

-- ==================== 主动发送 ====================
function usb_vuart.notify(cmd, data)
    if not is_initialized then
        log.warn("vuart", "串口未初始化")
        return false
    end

    local notification = build_notify(cmd, data)
    uart.write(UART_ID, notification)
    log.info("vuart", "发送通知", string.format("0x%04X", cmd), #notification .. "字节")
    return true
end

-- 发送响应 (用于异步响应)
function usb_vuart.send_response(seq, cmd, data)
    if not is_initialized then
        return false
    end
    local response = build_response(seq, cmd, data)
    uart.write(UART_ID, response)
    return true
end

-- 发送ACK
function usb_vuart.send_ack(seq, cmd)
    if not is_initialized then
        return false
    end
    local ack = build_ack(seq, cmd)
    uart.write(UART_ID, ack)
    return true
end

-- 发送NACK (用于异步响应失败)
function usb_vuart.send_nack(seq, cmd, error_code)
    if not is_initialized then
        return false
    end
    local nack = build_nack(seq, cmd, error_code or 0x05)
    uart.write(UART_ID, nack)
    return true
end

-- ==================== 导出构造函数 ====================
usb_vuart.build_frame = build_frame
usb_vuart.build_response = build_response
usb_vuart.build_notify = build_notify

-- ==================== 自动初始化 ====================
usb_vuart.init()

return usb_vuart
