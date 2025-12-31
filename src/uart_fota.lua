--[[
@module  uart_fota
@summary USB虚拟串口FOTA升级模块 (V1.0协议)
@version 1.0
@date    2025.12.30
@description
通过USB虚拟串口从Hi3516cv610接收固件数据进行OTA升级。
使用V1.0帧协议传输，支持分包接收和校验。

协议流程:
1. Hi3516cv610 发送 OTA_UART_START 命令，携带固件总大小
2. Air8000 回复 ACK，准备接收
3. Hi3516cv610 分包发送 OTA_UART_DATA 命令，每包携带序号和数据
4. Air8000 每包回复 ACK/NACK
5. Hi3516cv610 发送 OTA_UART_FINISH 命令
6. Air8000 校验完成后回复 ACK，然后重启

命令码:
- OTA_UART_START  (0x6010): 开始串口升级，数据=[firmware_size u32 大端序]
- OTA_UART_DATA   (0x6011): 固件数据包，数据=[seq u16 大端序][data...]
- OTA_UART_FINISH (0x6012): 升级完成
- OTA_UART_ABORT  (0x6013): 取消升级

响应状态通过 OTA_UART_STATUS (0x6014) NOTIFY上报:
- status: 0=空闲, 1=接收中, 2=校验中, 3=成功, 4=失败
- progress: 0-100 进度百分比
- error: 错误码

@usage
    local uart_fota = require "uart_fota"

    -- 模块会自动注册命令处理器
    -- Hi3516cv610通过USB虚拟串口发送升级命令即可
]]

local uart_fota = {}

-- ==================== 状态常量 ====================
uart_fota.STATUS = {
    IDLE = 0,           -- 空闲
    RECEIVING = 1,      -- 接收中
    VERIFYING = 2,      -- 校验中
    SUCCESS = 3,        -- 成功
    FAILED = 4,         -- 失败
}

uart_fota.ERROR = {
    NONE = 0,           -- 无错误
    INIT_FAILED = 1,    -- 初始化失败
    SEQ_ERROR = 2,      -- 序号错误
    WRITE_FAILED = 3,   -- 写入失败
    VERIFY_FAILED = 4,  -- 校验失败
    TIMEOUT = 5,        -- 超时
    ABORTED = 6,        -- 已取消
    SIZE_MISMATCH = 7,  -- 大小不匹配
}

-- ==================== 内部变量 ====================
local current_status = uart_fota.STATUS.IDLE
local last_error = uart_fota.ERROR.NONE
local firmware_size = 0         -- 固件总大小
local received_size = 0         -- 已接收大小
local expected_seq = 0          -- 期望的序号
local fota_initialized = false  -- FOTA是否已初始化
local notify_callback = nil     -- 通知回调
local reusable_buff = nil       -- 复用缓冲区，避免频繁分配内存
local BUFF_SIZE = 2048          -- 缓冲区大小，支持最大1024字节数据包

-- ==================== 状态管理 ====================
local function set_status(status, error_code, progress)
    current_status = status
    last_error = error_code or uart_fota.ERROR.NONE
    progress = progress or 0

    log.info("uart_fota", string.format("状态: %d, 错误: %d, 进度: %d%%",
        current_status, last_error, progress))

    -- 发送状态通知
    if notify_callback then
        notify_callback(current_status, last_error, progress)
    end
end

local function get_progress()
    if firmware_size > 0 then
        return math.floor(received_size * 100 / firmware_size)
    end
    return 0
end

local function cleanup()
    if fota_initialized then
        fota.finish(false)
        fota_initialized = false
    end
    -- 释放复用缓冲区
    if reusable_buff then
        reusable_buff:del()
        reusable_buff = nil
    end
    firmware_size = 0
    received_size = 0
    expected_seq = 0
    set_status(uart_fota.STATUS.IDLE, uart_fota.ERROR.NONE, 0)
end

-- ==================== 公开接口 ====================

--- 设置通知回调
-- @param callback function 回调函数 callback(status, error_code, progress)
function uart_fota.set_notify_callback(callback)
    notify_callback = callback
end

--- 获取当前状态
-- @return status, error_code, progress
function uart_fota.get_status()
    return current_status, last_error, get_progress()
end

--- 检查是否正在升级
function uart_fota.is_upgrading()
    return current_status == uart_fota.STATUS.RECEIVING or
           current_status == uart_fota.STATUS.VERIFYING
end

--- 处理开始升级命令
-- @param data 命令数据 [firmware_size u32 大端序]
-- @return success boolean
function uart_fota.handle_start(data)
    if #data < 4 then
        log.error("uart_fota", "START命令数据长度不足")
        return false, uart_fota.ERROR.INIT_FAILED
    end

    -- 如果正在升级，拒绝
    if uart_fota.is_upgrading() then
        log.warn("uart_fota", "正在升级中，拒绝新的升级请求")
        return false, uart_fota.ERROR.INIT_FAILED
    end

    -- 解析固件大小 (大端序 u32)
    firmware_size = string.unpack(">I4", data:sub(1, 4))
    log.info("uart_fota", "开始升级，固件大小:", firmware_size, "字节")

    -- 初始化FOTA
    if not fota.init() then
        log.error("uart_fota", "FOTA初始化失败")
        cleanup()
        return false, uart_fota.ERROR.INIT_FAILED
    end

    -- 创建复用缓冲区 (只创建一次，避免频繁分配内存)
    if not reusable_buff then
        reusable_buff = zbuff.create(BUFF_SIZE)
        log.info("uart_fota", "创建复用缓冲区", BUFF_SIZE, "字节")
    end

    fota_initialized = true
    received_size = 0
    expected_seq = 0
    set_status(uart_fota.STATUS.RECEIVING, uart_fota.ERROR.NONE, 0)

    log.info("uart_fota", "FOTA初始化成功，等待数据...")
    return true, uart_fota.ERROR.NONE
end

--- 处理数据包命令
-- @param data 命令数据 [seq u16 大端序][firmware_data...]
-- @return success boolean, error_code
function uart_fota.handle_data(data)
    if current_status ~= uart_fota.STATUS.RECEIVING then
        log.warn("uart_fota", "未在接收状态，忽略数据包")
        return false, uart_fota.ERROR.INIT_FAILED
    end

    if #data < 3 then  -- 至少需要2字节序号 + 1字节数据
        log.error("uart_fota", "DATA命令数据长度不足")
        return false, uart_fota.ERROR.WRITE_FAILED
    end

    -- 解析序号 (大端序 u16)
    local seq = string.unpack(">I2", data:sub(1, 2))
    local payload = data:sub(3)

    -- 检查序号
    if seq ~= expected_seq then
        log.error("uart_fota", string.format("序号错误: 期望 %d, 收到 %d", expected_seq, seq))
        return false, uart_fota.ERROR.SEQ_ERROR
    end

    -- 使用复用缓冲区写入数据
    -- 注意: fota.run 需要 zbuff，且会从位置0开始读取 used() 长度的数据
    reusable_buff:del()        -- 清空缓冲区，重置 used 和位置
    reusable_buff:write(payload)  -- 写入数据，自动更新 used 长度
    reusable_buff:seek(0)      -- 重置读取位置供 fota.run 使用

    -- 写入FOTA
    local result, isDone, cache = fota.run(reusable_buff)

    if not result then
        log.error("uart_fota", "FOTA写入失败")
        set_status(uart_fota.STATUS.FAILED, uart_fota.ERROR.WRITE_FAILED, get_progress())
        cleanup()
        return false, uart_fota.ERROR.WRITE_FAILED
    end

    received_size = received_size + #payload
    expected_seq = expected_seq + 1

    local progress = get_progress()

    -- 每10%上报一次进度
    if progress % 10 == 0 then
        set_status(uart_fota.STATUS.RECEIVING, uart_fota.ERROR.NONE, progress)
        log.info("uart_fota", string.format("进度 %d%%, 收到 %d/%d 字节",
            progress, received_size, firmware_size))
    end

    -- 检查是否完成
    if isDone then
        log.info("uart_fota", "数据接收完成，开始校验...")
        set_status(uart_fota.STATUS.VERIFYING, uart_fota.ERROR.NONE, 100)
    end

    return true, uart_fota.ERROR.NONE
end

--- 处理完成命令
-- @return success boolean, error_code
function uart_fota.handle_finish()
    if current_status ~= uart_fota.STATUS.RECEIVING and
       current_status ~= uart_fota.STATUS.VERIFYING then
        log.warn("uart_fota", "未在升级状态")
        return false, uart_fota.ERROR.INIT_FAILED
    end

    -- 检查大小是否匹配
    if received_size ~= firmware_size then
        log.error("uart_fota", string.format("大小不匹配: 期望 %d, 收到 %d",
            firmware_size, received_size))
        set_status(uart_fota.STATUS.FAILED, uart_fota.ERROR.SIZE_MISMATCH, get_progress())
        cleanup()
        return false, uart_fota.ERROR.SIZE_MISMATCH
    end

    set_status(uart_fota.STATUS.VERIFYING, uart_fota.ERROR.NONE, 100)

    -- 等待底层校验完成
    sys.taskInit(function()
        for i = 1, 50 do  -- 最多等待5秒
            sys.wait(100)
            local succ, fotaDone = fota.isDone()

            if not succ then
                log.error("uart_fota", "校验失败")
                set_status(uart_fota.STATUS.FAILED, uart_fota.ERROR.VERIFY_FAILED, 100)
                cleanup()
                return
            end

            if fotaDone then
                log.info("uart_fota", "校验成功，准备重启")
                fota.finish(true)
                set_status(uart_fota.STATUS.SUCCESS, uart_fota.ERROR.NONE, 100)

                -- 2秒后重启
                sys.wait(2000)
                log.info("uart_fota", "重启中...")
                rtos.reboot()
                return
            end
        end

        -- 超时
        log.error("uart_fota", "校验超时")
        set_status(uart_fota.STATUS.FAILED, uart_fota.ERROR.TIMEOUT, 100)
        cleanup()
    end)

    return true, uart_fota.ERROR.NONE
end

--- 处理取消命令
function uart_fota.handle_abort()
    log.info("uart_fota", "升级已取消")
    set_status(uart_fota.STATUS.FAILED, uart_fota.ERROR.ABORTED, get_progress())
    cleanup()
    return true, uart_fota.ERROR.NONE
end

-- ==================== 初始化日志 ====================
log.info("uart_fota", "串口FOTA模块已加载")

return uart_fota
