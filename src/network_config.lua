--[[
@module  network_config
@summary 网络配置管理模块
@version 1.0
@date    2025.12.31
@description
统一管理Air8000的网络配置：
1. APN配置 - 使用fskv持久化存储，启动时自动加载
2. ECM/RNDIS模式 - USB以太网卡模式配置
3. 网络状态查询 - 详细网络状态信息
4. 网络重置 - 通过飞行模式重置网络连接

注意: APN必须在入网前设置，所以需要在模块加载时立即应用

@usage
    local network = require "network_config"

    -- 设置APN (保存后重启生效)
    network.set_apn("cmiot", "user", "password", 1)

    -- 查询APN配置
    local apn, user, pwd, auth = network.get_apn()

    -- 查询网络状态
    local status = network.get_status()

    -- 重置网络
    network.reset(5)  -- 飞行模式5秒
]]

local network_config = {}

-- ==================== 配置常量 ====================
-- USB以太网模式配置
-- bit0: 开关 (1开0关)
-- bit1: 模式 (1=NAT, 0=独立IP)
-- bit2: 协议 (1=ECM, 0=RNDIS)
local USB_ETH_MODE = {
    RNDIS_NAT = 3,      -- 0011: RNDIS + NAT模式 (Windows兼容)
    RNDIS_DIRECT = 1,   -- 0001: RNDIS + 独立IP
    ECM_NAT = 7,        -- 0111: ECM + NAT模式 (Linux/Mac)
    ECM_DIRECT = 5,     -- 0101: ECM + 独立IP
}

-- 默认使用ECM + NAT模式
local DEFAULT_USB_MODE = USB_ETH_MODE.ECM_NAT

-- ==================== fskv存储键名 ====================
local FSKV_KEYS = {
    APN_NAME = "apn_name",
    APN_USER = "apn_user",
    APN_PWD = "apn_pwd",
    APN_AUTH = "apn_auth",
    USB_MODE = "usb_eth_mode",
}

-- ==================== 内部变量 ====================
local is_initialized = false

-- ==================== 内部函数 ====================

-- 初始化fskv
local function init_fskv()
    if fskv then
        fskv.init()
        return true
    end
    return false
end

-- 从fskv加载APN配置
local function load_apn_from_fskv()
    if not fskv then
        return "", "", "", 0
    end

    local apn = fskv.get(FSKV_KEYS.APN_NAME) or ""
    local user = fskv.get(FSKV_KEYS.APN_USER) or ""
    local password = fskv.get(FSKV_KEYS.APN_PWD) or ""
    local auth_type = fskv.get(FSKV_KEYS.APN_AUTH) or 0

    return apn, user, password, auth_type
end

-- 保存APN配置到fskv
local function save_apn_to_fskv(apn, user, password, auth_type)
    if not fskv then
        log.error("network", "fskv不可用，无法保存APN配置")
        return false
    end

    fskv.set(FSKV_KEYS.APN_NAME, apn or "")
    fskv.set(FSKV_KEYS.APN_USER, user or "")
    fskv.set(FSKV_KEYS.APN_PWD, password or "")
    fskv.set(FSKV_KEYS.APN_AUTH, auth_type or 0)

    log.info("network", "APN配置已保存到fskv")
    return true
end

-- 启用USB以太网卡并配置APN (ECM/RNDIS)
-- 注意: APN和USB以太网都需要在飞行模式下配置
local function enable_network(usb_mode, apn, user, password, auth_type)
    usb_mode = usb_mode or DEFAULT_USB_MODE

    log.info("network", string.format("配置网络: USB模式=0x%02X, APN=%s", usb_mode, apn or "默认"))

    -- 进入飞行模式
    local fly_sign = mobile.flymode(0, true)
    if fly_sign then
        log.info("network", "进入飞行模式成功")

        -- 1. 配置APN (必须在飞行模式下，入网前设置)
        if apn and apn ~= "" then
            -- mobile.apn(index, cid, apn, user, password, authType)
            mobile.apn(0, 1, apn, user or "", password or "", auth_type or 0)
            log.info("network", string.format("APN配置已应用: apn=%s, user=%s, auth=%d",
                apn, user or "", auth_type or 0))
        end

        -- 2. 配置USB以太网模式
        local result = mobile.config(mobile.CONF_USB_ETHERNET, usb_mode)
        log.info("network", "USB以太网配置结果:", result)

        -- 退出飞行模式
        mobile.flymode(0, false)
        log.info("network", "退出飞行模式，网络开始连接...")

        return true
    else
        log.error("network", "进入飞行模式失败")
        return false
    end
end

-- ==================== 公开接口 ====================

--- 初始化网络配置模块
-- 在main.lua开头调用，会自动加载APN配置并启用USB以太网
-- APN和USB以太网配置都在飞行模式下完成，然后退出飞行模式开始入网
-- @param usb_mode number USB以太网模式(可选)
-- @return boolean 是否成功
function network_config.init(usb_mode)
    if is_initialized then
        log.warn("network", "网络配置模块已初始化")
        return true
    end

    log.info("network", "初始化网络配置模块")

    -- 初始化fskv
    if not init_fskv() then
        log.warn("network", "fskv初始化失败，APN配置功能受限")
    end

    -- 从fskv加载APN配置
    local apn, user, password, auth_type = load_apn_from_fskv()
    local has_apn = apn and apn ~= ""
    if has_apn then
        log.info("network", string.format("从fskv加载APN: apn=%s, user=%s, auth=%d",
            apn, user or "", auth_type or 0))
    else
        log.info("network", "未配置自定义APN，使用默认配置")
    end

    -- 启用网络配置（APN + USB以太网，在同一次飞行模式中完成）
    sys.taskInit(function()
        if has_apn then
            enable_network(usb_mode, apn, user, password, auth_type)
        else
            enable_network(usb_mode, nil, nil, nil, nil)
        end
    end)

    is_initialized = true
    log.info("network", "网络配置模块初始化完成")

    return true
end

--- 设置APN配置
-- 配置保存到fskv，重启后自动生效
-- @param apn string APN名称
-- @param user string 用户名(可选)
-- @param password string 密码(可选)
-- @param auth_type number 认证类型 0=无 1=PAP 2=CHAP(可选)
-- @return boolean 是否保存成功
function network_config.set_apn(apn, user, password, auth_type)
    return save_apn_to_fskv(apn, user, password, auth_type)
end

--- 获取APN配置
-- @return string apn APN名称
-- @return string user 用户名
-- @return string password 密码
-- @return number auth_type 认证类型
function network_config.get_apn()
    return load_apn_from_fskv()
end

--- 获取详细网络状态
-- @return table 网络状态表
function network_config.get_status()
    local status = {
        -- 基本状态
        registered = mobile.status() or 0,
        csq = mobile.csq() or 0,
        rssi = mobile.rssi() or 0,
        rsrp = mobile.rsrp() or 0,
        rsrq = mobile.rsrq() or 0,
        snr = mobile.snr() or 0,

        -- SIM卡信息
        imei = mobile.imei() or "",
        imsi = mobile.imsi() or "",
        iccid = mobile.iccid() or "",

        -- 运营商
        operator = 0,  -- 0=未知, 1=移动, 2=联通, 3=电信
        operator_name = "未知",

        -- IP地址
        ip = "",
    }

    -- 解析运营商
    local imsi = status.imsi
    if #imsi >= 5 then
        local mccmnc = imsi:sub(1, 5)
        if mccmnc == "46000" or mccmnc == "46002" or mccmnc == "46007" or mccmnc == "46008" then
            status.operator = 1
            status.operator_name = "中国移动"
        elseif mccmnc == "46001" or mccmnc == "46006" or mccmnc == "46009" then
            status.operator = 2
            status.operator_name = "中国联通"
        elseif mccmnc == "46003" or mccmnc == "46005" or mccmnc == "46011" then
            status.operator = 3
            status.operator_name = "中国电信"
        end
    end

    -- 获取IP地址
    if socket and socket.localIP then
        status.ip = socket.localIP(socket.LWIP_GP) or ""
    end

    return status
end

--- 获取网络状态字节数据 (用于协议响应)
-- @return string 二进制数据
function network_config.get_status_bytes()
    local s = network_config.get_status()

    -- 构造响应数据
    -- [status u8][csq u8][rssi i8][rsrp i16 大端][snr i8][operator u8][ip_len u8][ip string]
    local resp_data = string.char(
        s.registered,
        s.csq,
        bit.band(s.rssi, 0xFF)
    )
    -- rsrp 为 i16 大端序
    resp_data = resp_data .. string.char(
        bit.band(bit.rshift(s.rsrp, 8), 0xFF),
        bit.band(s.rsrp, 0xFF)
    )
    resp_data = resp_data .. string.char(
        bit.band(s.snr, 0xFF),
        s.operator,
        #s.ip
    ) .. s.ip

    return resp_data
end

--- 重置网络连接
-- 通过进入/退出飞行模式重置网络
-- @param duration number 飞行模式持续时间(秒)，默认3秒
function network_config.reset(duration)
    duration = duration or 3
    if duration < 1 then duration = 1 end
    if duration > 30 then duration = 30 end

    log.info("network", string.format("重置网络连接，飞行模式持续 %d 秒", duration))

    sys.taskInit(function()
        if mobile and mobile.flymode then
            mobile.flymode(0, true)
            log.info("network", "已进入飞行模式")

            sys.wait(duration * 1000)

            mobile.flymode(0, false)
            log.info("network", "已退出飞行模式，网络重新连接中...")
        else
            log.error("network", "mobile.flymode不可用")
        end
    end)
end

--- 设置USB以太网模式
-- @param mode number 模式值 (参考USB_ETH_MODE)
-- @return boolean 是否成功
function network_config.set_usb_mode(mode)
    if fskv then
        fskv.set(FSKV_KEYS.USB_MODE, mode)
    end
    log.info("network", string.format("USB以太网模式已设置为 0x%02X，重启后生效", mode))
    return true
end

--- 获取USB以太网模式常量
-- @return table 模式常量表
function network_config.get_usb_modes()
    return USB_ETH_MODE
end

-- ==================== 导出常量 ====================
network_config.USB_MODE = USB_ETH_MODE

-- ==================== 初始化日志 ====================
log.info("network", "网络配置模块已加载")

return network_config
