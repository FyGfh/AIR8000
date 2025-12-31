--[[
@module  ota_update
@summary OTA远程升级功能模块
@version 1.0
@date    2025.12.30
@description
实现Air8000的OTA远程升级功能，支持:
1. 自建服务器升级 - 通过USB虚拟串口命令下发升级URL
2. 定时检查升级 - 可配置定时检查（默认关闭）
3. 升级状态通知 - 通过NOTIFY帧向Hi3516cv610报告升级状态

@usage
    local ota = require "ota_update"

    -- 启动升级（由外部命令触发）
    ota.start_update("http://your-server.com/firmware.bin")

    -- 查询升级状态
    local status = ota.get_status()
]]

local ota_update = {}

-- ==================== 依赖模块 ====================
local libfota2 = require "libfota2"

-- ==================== 状态常量 ====================
ota_update.STATUS = {
    IDLE = 0,           -- 空闲
    CHECKING = 1,       -- 检查中
    DOWNLOADING = 2,    -- 下载中
    READY = 3,          -- 下载完成，等待重启
    FAILED = 4,         -- 失败
}

-- 错误码
ota_update.ERROR_CODE = {
    NONE = 0,           -- 无错误
    CONNECT_FAILED = 1, -- 连接失败
    URL_ERROR = 2,      -- URL错误
    SERVER_CLOSED = 3,  -- 服务器断开
    RECV_ERROR = 4,     -- 接收报文错误
    VERSION_ERROR = 5,  -- 版本号格式错误
    NO_NETWORK = 6,     -- 无网络
    ALREADY_RUNNING = 7,-- 升级已在进行中
}

-- ==================== 内部变量 ====================
local current_status = ota_update.STATUS.IDLE
local last_error = ota_update.ERROR_CODE.NONE
local fota_running = false
local notify_callbacks = {}  -- 支持多个通知回调函数

-- OTA配置
local ota_config = {
    auto_check_enabled = false,     -- 是否启用自动检查
    auto_check_interval = 4 * 3600, -- 自动检查间隔（秒）
    default_url = "",               -- 默认升级URL（留空则需要命令指定）
    auto_reboot = true,             -- 下载成功后自动重启
}

-- ==================== 状态管理 ====================
local function set_status(status, error_code)
    current_status = status
    last_error = error_code or ota_update.ERROR_CODE.NONE

    log.info("ota", string.format("状态变更: %d, 错误码: %d", current_status, last_error))

    -- 发送状态通知到所有注册的回调
    for _, callback in ipairs(notify_callbacks) do
        callback(current_status, last_error)
    end
end

-- ==================== FOTA回调 ====================
local function fota_callback(ret)
    log.info("ota", "FOTA回调", ret)
    fota_running = false

    if ret == 0 then
        log.info("ota", "升级包下载成功")
        set_status(ota_update.STATUS.READY, ota_update.ERROR_CODE.NONE)

        if ota_config.auto_reboot then
            log.info("ota", "3秒后自动重启...")
            sys.timerStart(function()
                log.info("ota", "执行重启")
                rtos.reboot()
            end, 3000)
        end
    elseif ret == 1 then
        log.error("ota", "连接失败 - 请检查URL或服务器配置")
        set_status(ota_update.STATUS.FAILED, ota_update.ERROR_CODE.CONNECT_FAILED)
    elseif ret == 2 then
        log.error("ota", "URL错误")
        set_status(ota_update.STATUS.FAILED, ota_update.ERROR_CODE.URL_ERROR)
    elseif ret == 3 then
        log.error("ota", "服务器断开")
        set_status(ota_update.STATUS.FAILED, ota_update.ERROR_CODE.SERVER_CLOSED)
    elseif ret == 4 then
        log.error("ota", "接收报文错误 - 可能升级包缺失或已是最新版本")
        set_status(ota_update.STATUS.FAILED, ota_update.ERROR_CODE.RECV_ERROR)
    elseif ret == 5 then
        log.error("ota", "版本号格式错误")
        set_status(ota_update.STATUS.FAILED, ota_update.ERROR_CODE.VERSION_ERROR)
    else
        log.error("ota", "未知错误", ret)
        set_status(ota_update.STATUS.FAILED, ret)
    end
end

-- ==================== 检查网络 ====================
local function wait_network(timeout_ms)
    local start_time = os.time()
    local timeout_sec = (timeout_ms or 30000) / 1000

    while not socket.adapter(socket.LWIP_GP) do
        if os.time() - start_time > timeout_sec then
            log.warn("ota", "等待网络超时")
            return false
        end
        log.info("ota", "等待网络就绪...")
        sys.wait(1000)
    end

    log.info("ota", "网络已就绪")
    return true
end

-- ==================== 公开接口 ====================

--- 启动OTA升级
-- @param url string 升级包URL，如果URL前加"###"表示完整URL不需要追加参数
-- @param version string 可选，版本号
-- @return boolean 是否成功启动升级
function ota_update.start(url, version)
    if fota_running then
        log.warn("ota", "升级正在进行中")
        set_status(ota_update.STATUS.FAILED, ota_update.ERROR_CODE.ALREADY_RUNNING)
        return false
    end

    if not url or url == "" then
        url = ota_config.default_url
    end

    if not url or url == "" then
        log.error("ota", "未指定升级URL")
        set_status(ota_update.STATUS.FAILED, ota_update.ERROR_CODE.URL_ERROR)
        return false
    end

    -- 异步启动升级任务
    sys.taskInit(function()
        set_status(ota_update.STATUS.CHECKING, ota_update.ERROR_CODE.NONE)

        -- 等待网络
        if not wait_network(30000) then
            set_status(ota_update.STATUS.FAILED, ota_update.ERROR_CODE.NO_NETWORK)
            return
        end

        set_status(ota_update.STATUS.DOWNLOADING, ota_update.ERROR_CODE.NONE)

        -- 配置升级参数
        local opts = {
            url = url,
        }

        if version and version ~= "" then
            opts.version = version
        end

        fota_running = true
        log.info("ota", "开始下载升级包", url)
        libfota2.request(fota_callback, opts)
    end)

    return true
end

--- 获取当前状态
-- @return number 状态码
-- @return number 错误码
function ota_update.get_status()
    return current_status, last_error
end

--- 检查是否正在升级
-- @return boolean
function ota_update.is_running()
    return fota_running
end

--- 添加通知回调（支持多个回调）
-- @param callback function 回调函数 callback(status, error_code)
function ota_update.set_notify_callback(callback)
    table.insert(notify_callbacks, callback)
end

--- 配置OTA参数
-- @param config table 配置表
function ota_update.configure(config)
    if config.auto_check_enabled ~= nil then
        ota_config.auto_check_enabled = config.auto_check_enabled
    end
    if config.auto_check_interval then
        ota_config.auto_check_interval = config.auto_check_interval
    end
    if config.default_url then
        ota_config.default_url = config.default_url
    end
    if config.auto_reboot ~= nil then
        ota_config.auto_reboot = config.auto_reboot
    end
    log.info("ota", "配置已更新")
end

--- 获取版本信息
-- @return string PROJECT名称
-- @return string VERSION版本号
-- @return string 固件版本
function ota_update.get_version()
    return _G.PROJECT or "UNKNOWN", _G.VERSION or "000.000.000", rtos.version() or "UNKNOWN"
end

--- 打印版本信息
function ota_update.print_version()
    local project, version, core_ver = ota_update.get_version()
    log.info("ota", "项目:", project)
    log.info("ota", "脚本版本:", version)
    log.info("ota", "固件版本:", core_ver)
end

-- ==================== 自动检查定时器 ====================
if ota_config.auto_check_enabled and ota_config.default_url ~= "" then
    sys.timerLoopStart(function()
        if not fota_running then
            log.info("ota", "定时检查升级...")
            ota_update.start(ota_config.default_url)
        end
    end, ota_config.auto_check_interval * 1000)
end

-- ==================== 初始化日志 ====================
log.info("ota", "OTA升级模块已加载")
ota_update.print_version()

return ota_update
