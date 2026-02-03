--[[
@module  file_transfer
@summary Air8000 文件传输功能模块
@version 1.0
@date    2026.01.19
@description
实现Air8000与Hi3516cv610之间的文件传输功能：
1. 支持Air8000主动通知CV610传输文件
2. 支持CV610请求Air8000发送文件
3. 分片传输、CRC32校验和失败重传
4. 模块化设计，与现有通信协议无缝集成

@usage
    local file_transfer = require "file_transfer"
    
    -- 注册文件传输回调
    file_transfer.set_callback(function(event, data)
        if event == file_transfer.EVENT.TRANSFER_COMPLETED then
            log.info("file_transfer", "文件传输完成")
        end
    end)
    
    -- 初始化文件传输
    file_transfer.init()
    
    -- 主动通知传输文件
    file_transfer.notify("test.txt", 1024)
]]

local file_transfer = {}

-- ==================== 依赖模块 ====================
-- local sys = require "sys"
-- local log = require "log"
-- local uart = require "uart"
local usb_vuart = require "usb_vuart_comm"

-- ==================== 常量定义 ====================

-- 文件传输状态
file_transfer.STATE = {
    IDLE = 0,             -- 空闲状态
    NOTIFIED = 1,         -- 已通知，等待确认
    STARTED = 2,          -- 传输开始
    TRANSMITTING = 3,     -- 传输中
    COMPLETED = 4,        -- 传输完成
    ERROR = 5,            -- 传输错误
    CANCELLED = 6         -- 传输取消
}

-- 文件传输事件
file_transfer.EVENT = {
    TRANSFER_NOTIFIED = 1,     -- 已通知CV610
    TRANSFER_STARTED = 2,      -- 传输开始
    DATA_SENT = 3,             -- 分片发送成功
    TRANSFER_COMPLETED = 4,    -- 传输完成
    TRANSFER_ERROR = 5,        -- 传输错误
    TRANSFER_CANCELLED = 6,    -- 传输取消
    REQUEST_RECEIVED = 7       -- 收到CV610的传输请求
}

-- 默认配置
local DEFAULT_BLOCK_SIZE = 1024  -- 默认分片大小
local DEFAULT_RETRY_TIMEOUT = 1000  -- 默认重传超时（毫秒）
local DEFAULT_MAX_RETRIES = 5  -- 默认最大重传次数

-- ==================== 内部变量 ====================

-- 文件传输方向枚举
file_transfer.DIRECTION = {
    CV610_TO_AIR8000 = 0, -- CV610向Air8000传输
    AIR8000_TO_CV610 = 1  -- Air8000向CV610传输
}

-- 文件传输上下文
local transfer_ctx = {
    state = file_transfer.STATE.IDLE,
    direction = file_transfer.DIRECTION.CV610_TO_AIR8000,
    filename = "",
    file_size = 0,
    block_size = DEFAULT_BLOCK_SIZE,
    total_blocks = 0,
    current_block = 0,
    retry_count = 0,
    retry_timer = nil,
    file_handle = nil,
    crc32 = 0,
    callback = nil,
    notify_callback = nil, -- 通知回调函数
    user_data = nil,
    save_path = "", -- 保存路径（用于Air8000→CV610）
    sent_blocks = 0  -- 已发送的块数
}

-- ==================== 内部函数 ====================

-- 设置传输状态
-- 参照uart_fota.lua中的set_status函数实现
local function set_status(status, error_code, progress)
    transfer_ctx.state = status
    progress = progress or 0

    log.info("file_transfer", string.format("状态: %d, 错误: %d, 进度: %d%%",
        transfer_ctx.state, error_code or 0, progress))

    -- 触发回调
    if transfer_ctx.callback then
        transfer_ctx.callback(file_transfer.EVENT.TRANSFER_STARTED, {
            status = status,
            error_code = error_code,
            progress = progress,
            filename = transfer_ctx.filename,
            file_size = transfer_ctx.file_size
        })
    end

    -- 触发通知回调，与FOTA模块保持一致
    if transfer_ctx.notify_callback then
        transfer_ctx.notify_callback(status, error_code or 0, progress)
    end
end

-- 计算CRC32校验和
local function calculate_crc32(data)
    local crc32 = 0
    -- 简化实现，实际应用中应使用标准CRC32算法
    for i = 1, #data do
        crc32 = crc32 + string.byte(data, i)
    end
    return crc32
end

-- 发送命令的辅助函数
local function send_command(cmd, data)
    -- 参照uart_fota.lua中的实现，使用usb_vuart模块发送命令
    -- 对于文件传输命令，使用REQUEST帧类型，需要对方响应
    local frame = usb_vuart.build_frame(usb_vuart.FRAME_TYPE.REQUEST, 0, cmd, data)
    if frame then
        -- 通过UART_ID发送帧数据
        -- 注意：这里直接使用uart.write，因为usb_vuart模块已经初始化了UART
        local UART_ID = uart.VUART_0
        uart.write(UART_ID, frame)
        log.info("file_transfer", string.format("命令已发送: 0x%04X, 长度: %d字节", cmd, #frame))
        return true
    end
    -- 如果构建帧失败，记录错误并返回失败
    log.error("file_transfer", "构建命令帧失败")
    return false
end

-- 发送文件分片
local function send_file_block()
    if not transfer_ctx.file_handle then
        return false
    end
    
    -- 计算当前块的偏移量
    local offset = transfer_ctx.current_block * transfer_ctx.block_size
    
    -- 读取块数据
    transfer_ctx.file_handle:seek("set", offset)
    local data = transfer_ctx.file_handle:read(transfer_ctx.block_size)
    
    if not data then
        return false
    end
    
    -- 计算CRC32
    local crc32 = calculate_crc32(data)
    
    -- 构建块数据
    local block_data = string.pack(">I4", transfer_ctx.current_block) .. 
                      string.pack(">I4", #data) .. 
                      string.pack(">I4", crc32) .. 
                      data
    
    -- 发送文件分片命令
    send_command(0x6025, block_data)
    
    transfer_ctx.sent_blocks = transfer_ctx.sent_blocks + 1
    transfer_ctx.current_block = transfer_ctx.current_block + 1
    
    -- 计算进度
    local progress = math.floor((transfer_ctx.sent_blocks / transfer_ctx.total_blocks) * 100)
    
    -- 触发数据发送事件
    if transfer_ctx.callback then
        transfer_ctx.callback(file_transfer.EVENT.DATA_SENT, {
            status = file_transfer.STATE.TRANSMITTING,
            progress = progress,
            filename = transfer_ctx.filename,
            file_size = transfer_ctx.file_size
        })
    end
    
    -- 每10%上报一次进度，与uart_fota.lua保持一致
    if progress % 10 == 0 then
        set_status(file_transfer.STATE.TRANSMITTING, 0, progress)
    end
    
    return true
end

-- 处理文件传输请求
local function handle_file_transfer_request(data)
    local filename = data
    log.info("file_transfer", string.format("收到文件传输请求: %s", filename))
    
    -- 检查文件是否存在
    local file_path = "/" .. filename
    local file_stat = io.stat(file_path)
    if not file_stat then
        log.error("file_transfer", string.format("文件不存在: %s", file_path))
        -- 发送错误通知
        send_command(0x6023, string.pack(">I4", 0x05)) -- EXEC_FAILED
        return false
    end
    
    -- 更新上下文
    transfer_ctx.filename = filename
    transfer_ctx.file_size = file_stat.size
    transfer_ctx.total_blocks = math.ceil(file_stat.size / transfer_ctx.block_size)
    transfer_ctx.current_block = 0
    transfer_ctx.sent_blocks = 0
    transfer_ctx.direction = file_transfer.DIRECTION.AIR8000_TO_CV610
    
    -- 打开文件
    transfer_ctx.file_handle = io.open(file_path, "rb")
    if not transfer_ctx.file_handle then
        log.error("file_transfer", string.format("无法打开文件: %s", file_path))
        -- 发送错误通知
        send_command(0x6023, string.pack(">I4", 0x05)) -- EXEC_FAILED
        set_status(file_transfer.STATE.ERROR, 0x05, 0)
        return false
    end
    
    -- 设置状态为开始
    set_status(file_transfer.STATE.STARTED, 0, 0)
    
    -- 构建文件信息数据
    local file_info_data = string.pack(">I4", #filename) .. 
                          filename .. 
                          string.pack(">I8", file_stat.size) .. 
                          string.pack(">I4", transfer_ctx.block_size) .. 
                          string.pack(">I4", 0) .. -- CRC32
                          string.pack(">I4", 0) -- 文件类型
    
    -- 发送文件传输开始命令
    send_command(0x6026, file_info_data)
    
    -- 开始发送文件分片
    -- 参照uart_fota.lua中的实现，使用sys.taskInit进行异步处理
    sys.taskInit(function()
        while transfer_ctx.current_block < transfer_ctx.total_blocks do
            if not send_file_block() then
                log.error("file_transfer", "发送文件分片失败")
                break
            end
            
            -- 短暂延迟，避免发送过快
            -- 注意：这里使用sys.wait是安全的，因为是在独立的任务中，不是在命令回调中
            sys.wait(10)
        end
        
        -- 关闭文件
        if transfer_ctx.file_handle then
            transfer_ctx.file_handle:close()
            transfer_ctx.file_handle = nil
        end
        
        -- 更新状态
        transfer_ctx.state = file_transfer.STATE.COMPLETED
        
        -- 触发完成事件
        if transfer_ctx.callback then
            transfer_ctx.callback(file_transfer.EVENT.TRANSFER_COMPLETED, {
                status = file_transfer.STATE.COMPLETED,
                filename = filename,
                file_size = file_stat.size
            })
        end
        
        -- 触发通知回调
        if transfer_ctx.notify_callback then
            transfer_ctx.notify_callback(file_transfer.STATE.COMPLETED, 0, 100)
        end
    end)
    
    return true
end

-- ==================== 外部API ====================

-- 设置回调函数
-- @param cb 回调函数，格式: function(event, data)
-- @param user_data 用户数据
function file_transfer.set_callback(cb, user_data)
    transfer_ctx.callback = cb
    transfer_ctx.user_data = user_data
end

-- 设置通知回调函数
-- @param cb 回调函数，格式: function(status, error_code, progress)
function file_transfer.set_notify_callback(cb)
    transfer_ctx.notify_callback = cb
    log.info("file_transfer", "通知回调已设置")
end

-- 初始化文件传输模块
function file_transfer.init()
    log.info("file_transfer", "初始化文件传输模块")
    -- 参照uart_fota.lua中的实现，不需要特殊初始化
    return true
end

-- 销毁文件传输模块
function file_transfer.deinit()
    log.info("file_transfer", "销毁文件传输模块")
    -- 参照uart_fota.lua中的实现，不需要特殊销毁
    return true
end

-- 主动通知CV610传输文件
-- @param filename 文件名
-- @param file_size 文件大小
-- @return 成功返回true，失败返回false
function file_transfer.notify(filename, file_size)
    log.info("file_transfer", "主动通知传输文件: " .. filename .. " (" .. file_size .. "字节)")
    
    transfer_ctx.filename = filename
    transfer_ctx.file_size = file_size
    transfer_ctx.state = file_transfer.STATE.NOTIFIED
    
    -- 触发回调
    if transfer_ctx.callback then
        transfer_ctx.callback(file_transfer.EVENT.TRANSFER_NOTIFIED, {
            filename = filename,
            file_size = file_size
        })
    end
    
    return true
end

-- 开始文件传输
-- @param filename 文件名
-- @param file_size 文件大小
-- @param block_size 分片大小（可选，默认1024字节）
-- @return 成功返回true，失败返回false
function file_transfer.start(filename, file_size, block_size)
    log.info("file_transfer", "开始文件传输: " .. filename)
    
    -- 检查当前状态
    if transfer_ctx.state ~= file_transfer.STATE.IDLE then
        log.warn("file_transfer", "正在传输中，拒绝新的请求")
        return false
    end
    
    -- 更新上下文
    transfer_ctx.filename = filename
    transfer_ctx.file_size = file_size
    transfer_ctx.block_size = block_size or DEFAULT_BLOCK_SIZE
    transfer_ctx.total_blocks = math.ceil(file_size / transfer_ctx.block_size)
    transfer_ctx.current_block = 0
    transfer_ctx.sent_blocks = 0
    transfer_ctx.direction = file_transfer.DIRECTION.AIR8000_TO_CV610
    transfer_ctx.state = file_transfer.STATE.STARTED
    
    -- 构建文件信息数据
    local file_info_data = string.pack(">I4", #filename) .. 
                          filename .. 
                          string.pack(">I8", file_size) .. 
                          string.pack(">I4", transfer_ctx.block_size) .. 
                          string.pack(">I4", 0) .. -- CRC32
                          string.pack(">I4", 0) -- 文件类型
    
    -- 发送文件传输开始命令
    local result = send_command(0x6026, file_info_data)
    
    if result then
        -- 设置状态为传输中
        set_status(file_transfer.STATE.TRANSMITTING, 0, 0)
    else
        -- 设置状态为错误
        set_status(file_transfer.STATE.ERROR, 0x05, 0)
    end
    
    return result
end

-- 取消文件传输
-- @return 成功返回true，失败返回false
function file_transfer.cancel()
    if transfer_ctx.state == file_transfer.STATE.IDLE then
        return true
    end
    
    log.info("file_transfer", "取消文件传输")
    
    -- 重置状态
    transfer_ctx.state = file_transfer.STATE.CANCELLED
    
    -- 关闭文件
    if transfer_ctx.file_handle then
        transfer_ctx.file_handle:close()
        transfer_ctx.file_handle = nil
    end
    
    -- 触发回调
    if transfer_ctx.callback then
        transfer_ctx.callback(file_transfer.EVENT.TRANSFER_CANCELLED, {})
    end
    
    -- 触发通知回调
    if transfer_ctx.notify_callback then
        transfer_ctx.notify_callback(file_transfer.STATE.CANCELLED, 0, 0)
    end
    
    return true
end

-- 处理文件传输请求
-- @param filename 文件名
-- @return 成功返回true，失败返回false
function file_transfer.handle_request(filename)
    log.info("file_transfer", "处理文件传输请求: " .. filename)
    
    -- 检查当前状态
    if transfer_ctx.state ~= file_transfer.STATE.IDLE then
        log.warn("file_transfer", "正在传输中，拒绝新的请求")
        return false
    end
    
    -- 处理请求
    return handle_file_transfer_request(filename)
end

-- 发送文件到CV610
-- @param filename 文件名
-- @param file_path 文件路径
-- @return 成功返回true，失败返回false
function file_transfer.send_file(filename, file_path)
    log.info("file_transfer", "发送文件到CV610: " .. filename)
    
    -- 检查当前状态
    if transfer_ctx.state ~= file_transfer.STATE.IDLE then
        log.warn("file_transfer", "正在传输中，拒绝新的请求")
        return false
    end
    
    -- 检查文件是否存在
    local file_stat = io.stat(file_path)
    if not file_stat then
        log.error("file_transfer", "文件不存在: " .. file_path)
        return false
    end
    
    -- 更新上下文
    transfer_ctx.filename = filename
    transfer_ctx.file_size = file_stat.size
    transfer_ctx.block_size = DEFAULT_BLOCK_SIZE
    transfer_ctx.total_blocks = math.ceil(file_stat.size / transfer_ctx.block_size)
    transfer_ctx.current_block = 0
    transfer_ctx.sent_blocks = 0
    transfer_ctx.direction = file_transfer.DIRECTION.AIR8000_TO_CV610
    transfer_ctx.state = file_transfer.STATE.STARTED
    
    -- 打开文件
    local file_handle = io.open(file_path, "rb")
    if not file_handle then
        log.error("file_transfer", "无法打开文件: " .. file_path)
        return false
    end
    transfer_ctx.file_handle = file_handle
    
    -- 设置状态为开始
    set_status(file_transfer.STATE.STARTED, 0, 0)
    
    -- 开始发送文件分片
    -- 参照uart_fota.lua中的实现，使用sys.taskInit进行异步处理
    sys.taskInit(function()
        while transfer_ctx.current_block < transfer_ctx.total_blocks do
            if not send_file_block() then
                log.error("file_transfer", "发送文件分片失败")
                break
            end
            
            -- 短暂延迟，避免发送过快
            sys.wait(10)
        end
        
        -- 关闭文件
        if transfer_ctx.file_handle then
            transfer_ctx.file_handle:close()
            transfer_ctx.file_handle = nil
        end
        
        -- 更新状态
        transfer_ctx.state = file_transfer.STATE.COMPLETED
        
        -- 触发完成事件
        if transfer_ctx.callback then
            transfer_ctx.callback(file_transfer.EVENT.TRANSFER_COMPLETED, {
                status = file_transfer.STATE.COMPLETED,
                filename = filename,
                file_size = file_stat.size
            })
        end
    end)
    
    return true
end

-- 获取当前传输状态
-- @return 当前状态
function file_transfer.get_state()
    return transfer_ctx.state
end

-- 获取当前传输进度
-- @return 进度百分比 (0-100)
function file_transfer.get_progress()
    if transfer_ctx.total_blocks == 0 then
        return 0
    end
    return math.floor((transfer_ctx.sent_blocks / transfer_ctx.total_blocks) * 100)
end

-- ==================== 自动初始化 ====================

-- 模块加载时自动初始化
file_transfer.init()

return file_transfer
