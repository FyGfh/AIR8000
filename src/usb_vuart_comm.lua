--[[
@module  usb_vuart_comm
@summary Air8000 与 Hi3516cv610 USB虚拟串口通信模块
@version 2.0
@date    2025.12.13
@description
实现USB虚拟串口协议通信：
- 协议格式: [CMD(1B)][LEN_H(1B)][LEN_L(1B)][DATA(N)]
- 支持查询命令、控制命令、状态推送
- 自动过滤日志，仅处理协议数据

@usage
    local usb_vuart = require "usb_vuart_comm"

    -- 注册状态提供者
    usb_vuart.register_status("sensor", function()
        return string.char(0x01, 0x02, 0x03)
    end)

    -- 注册自定义命令处理
    usb_vuart.on_cmd(0x30, function(data)
        return pack_response(0x31, "response_data")
    end)

    -- 主动发送通知
    usb_vuart.notify(0x10, "notification_data")
]]

local usb_vuart = {}

-- ==================== 配置参数 ====================
local UART_ID = uart.VUART_0  -- USB虚拟串口
local BAUDRATE = 115200

-- ==================== 命令定义 ====================
usb_vuart.CMD = {
    -- 查询命令 (Hi3516cv610 -> Air8000)
    QUERY_SENSOR    = 0x11,   -- 查询传感器状态
    QUERY_MOTOR     = 0x12,   -- 查询电机状态
    QUERY_ALL       = 0x13,   -- 查询所有状态
    QUERY_NETWORK   = 0x14,   -- 查询网络状态

    -- 控制命令
    MOTOR_CTRL      = 0x20,   -- 电机控制指令
    SET_PARAM       = 0x21,   -- 设置参数

    -- 响应命令 (Air8000 -> Hi3516cv610)
    RESP_SENSOR     = 0x01,   -- 传感器状态响应
    RESP_MOTOR      = 0x02,   -- 电机状态响应
    RESP_ALL        = 0x03,   -- 所有状态响应
    RESP_NETWORK    = 0x04,   -- 网络状态响应
    RESP_ACK        = 0x05,   -- ACK响应
    RESP_ERROR      = 0xFF,   -- 错误响应
}

-- ==================== 内部变量 ====================
local is_initialized = false
local rx_buff = nil
local status_providers = {}   -- 状态数据提供者
local cmd_handlers = {}       -- 命令处理器

-- ==================== 工具函数 ====================
-- 打包响应数据
-- 格式: [命令(1B)] [数据长度(2B)] [数据(NB)]
local function pack_response(cmd, data)
    data = data or ""
    local len = #data
    local len_h = math.floor(len / 256)
    local len_l = len % 256
    return string.char(cmd, len_h, len_l) .. data
end

-- 解析请求数据
local function parse_request(data)
    if not data or #data < 1 then
        return nil, "数据为空"
    end

    local cmd = data:byte(1)
    local payload = data:sub(2)

    return {
        cmd = cmd,
        data = payload
    }
end

-- ==================== 请求处理 ====================
-- 处理客户端请求
local function handle_request(request)
    local cmd = request.cmd
    local data = request.data

    log.info("vuart", "处理请求", string.format("0x%02X", cmd))

    -- 先检查自定义处理器
    local handler = cmd_handlers[cmd]
    if handler then
        local resp_data = handler(data)
        if resp_data then
            return resp_data
        end
    end

    -- 内置查询命令处理
    if cmd == usb_vuart.CMD.QUERY_SENSOR then
        -- 查询传感器状态
        local provider = status_providers["sensor"]
        if provider then
            local sensor_data = provider()
            return pack_response(usb_vuart.CMD.RESP_SENSOR, sensor_data)
        else
            return pack_response(usb_vuart.CMD.RESP_ERROR, string.char(0x01)) -- 无数据
        end

    elseif cmd == usb_vuart.CMD.QUERY_MOTOR then
        -- 查询电机状态
        local provider = status_providers["motor"]
        if provider then
            local motor_data = provider()
            return pack_response(usb_vuart.CMD.RESP_MOTOR, motor_data)
        else
            return pack_response(usb_vuart.CMD.RESP_ERROR, string.char(0x02))
        end

    elseif cmd == usb_vuart.CMD.QUERY_NETWORK then
        -- 查询网络状态
        local network_data = ""

        -- 蜂窝网络状态
        local csq = mobile.csq()
        local rssi = mobile.rssi()
        local rsrp = mobile.rsrp()
        local status = mobile.status()

        -- 打包网络信息 (格式: csq, rssi, rsrp, status)
        network_data = string.char(csq, rssi & 0xFF, rsrp & 0xFF, status)

        -- 添加IP地址
        local ip = socket.localIP(socket.LWIP_GP)
        if ip then
            network_data = network_data .. ip
        end

        return pack_response(usb_vuart.CMD.RESP_NETWORK, network_data)

    elseif cmd == usb_vuart.CMD.QUERY_ALL then
        -- 查询所有状态
        local all_data = ""
        for name, provider in pairs(status_providers) do
            local d = provider()
            if d then
                all_data = all_data .. d
            end
        end
        return pack_response(usb_vuart.CMD.RESP_ALL, all_data)

    elseif cmd == usb_vuart.CMD.MOTOR_CTRL then
        -- 电机控制 - 发布消息让业务层处理
        sys.publish("USB_MOTOR_CTRL", data)
        return pack_response(usb_vuart.CMD.RESP_ACK, string.char(cmd))

    elseif cmd == usb_vuart.CMD.SET_PARAM then
        -- 设置参数
        sys.publish("USB_SET_PARAM", data)
        return pack_response(usb_vuart.CMD.RESP_ACK, string.char(cmd))
    end

    -- 未知命令
    log.warn("vuart", "未知命令", string.format("0x%02X", cmd))
    return pack_response(usb_vuart.CMD.RESP_ERROR, string.char(0xFF))
end

-- ==================== 串口接收处理 ====================
-- 串口接收回调
local function uart_receive_callback(id, len)
    while true do
        local len = uart.rx(id, rx_buff)
        if len <= 0 then
            break
        end

        -- 获取接收到的数据
        local recv_data = rx_buff:query()
        rx_buff:del()

        if #recv_data > 0 then
            -- 解析请求
            local request, parse_err = parse_request(recv_data)

            if request then
                -- 处理请求并生成响应
                local response = handle_request(request)

                -- 发送响应（使用uart.write符合官方规范）
                uart.write(UART_ID, response)
                log.info("vuart", "响应已发送", #response .. "字节")
            else
                log.error("vuart", "解析请求失败", parse_err)
                -- 发送错误响应
                local err_resp = pack_response(usb_vuart.CMD.RESP_ERROR, string.char(0xFE))
                uart.write(UART_ID, err_resp)
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

    log.info("vuart", "初始化USB虚拟串口通信")

    -- 创建接收缓冲区
    rx_buff = zbuff.create(1024)

    -- 配置串口
    uart.setup(UART_ID, BAUDRATE, 8, 1)

    -- 注册接收回调
    uart.on(UART_ID, "receive", uart_receive_callback)

    is_initialized = true

    log.info("vuart", "USB虚拟串口通信已就绪")
    log.info("vuart", "波特率:", BAUDRATE)
    log.info("vuart", "等待Hi3516cv610连接...")

    return true
end

-- 关闭USB虚拟串口通信
function usb_vuart.close()
    if is_initialized then
        is_initialized = false

        if rx_buff then
            rx_buff:del()
            rx_buff = nil
        end

        uart.close(UART_ID)
        log.info("vuart", "已关闭")
    end
end

-- ==================== 状态提供者注册 ====================
-- 注册状态数据提供者，用于查询时自动返回数据
-- name: "sensor", "motor" 等
-- provider: 返回状态数据的函数
function usb_vuart.register_status(name, provider)
    status_providers[name] = provider
    log.info("vuart", "注册状态提供者", name)
end

-- ==================== 命令处理注册 ====================
-- 注册自定义命令处理器
-- cmd: 命令字节
-- handler: 处理函数，返回完整的响应数据（包含响应头）
function usb_vuart.on_cmd(cmd, handler)
    cmd_handlers[cmd] = handler
    log.info("vuart", "注册命令处理", string.format("0x%02X", cmd))
end

-- ==================== 主动发送 ====================
-- 主动向Hi3516cv610发送通知
function usb_vuart.notify(cmd, data)
    if not is_initialized then
        log.warn("vuart", "串口未初始化")
        return false
    end

    local notification = pack_response(cmd, data)
    uart.write(UART_ID, notification)
    log.info("vuart", "发送通知", string.format("0x%02X", cmd), #notification .. "字节")
    return true
end

-- ==================== 自动初始化 ====================
usb_vuart.init()

return usb_vuart
