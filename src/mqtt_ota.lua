--[[
@module  mqtt_ota
@summary MQTT OTA远程升级触发模块
@version 1.0
@date    2025.12.30
@description
通过MQTT服务器接收OTA升级指令，无需Hi3516cv610触发。
支持:
1. 连接MQTT服务器并订阅升级主题
2. 接收JSON格式的升级指令
3. 上报设备状态和升级进度
4. 自动重连机制

MQTT消息格式:
订阅主题: vdm/{imei}/ota/cmd
发布主题: vdm/{imei}/ota/status

升级指令JSON格式:
{
    "cmd": "upgrade",
    "url": "http://your-server.com/firmware.bin",
    "version": "001.000.001"  -- 可选
}

查询指令:
{
    "cmd": "query_version"
}

状态上报JSON格式:
{
    "imei": "设备IMEI",
    "project": "VDM_AIR8000",
    "version": "000.300.000",
    "core_version": "V2012",
    "ota_status": 0,
    "ota_error": 0,
    "rssi": -70,
    "timestamp": 1234567890
}

@usage
    local mqtt_ota = require "mqtt_ota"

    -- 配置MQTT服务器 (可选，有默认值)
    mqtt_ota.configure({
        server = "your-mqtt-server.com",
        port = 1883,
        username = "",
        password = ""
    })

    -- 启动MQTT OTA服务
    mqtt_ota.start()
]]

local mqtt_ota = {}

-- ==================== 依赖模块 ====================
local ota_update = require "ota_update"

-- ==================== 配置参数 ====================
local config = {
    -- MQTT服务器配置
    server = "lbsmqtt.airm2m.com",  -- 默认使用合宙测试服务器，生产环境请替换
    port = 1884,
    username = "",
    password = "",
    keepalive = 120,

    -- 主题配置 (使用IMEI作为设备标识)
    topic_prefix = "vdm",

    -- 状态上报间隔 (毫秒)
    status_interval = 60000,

    -- 是否启用
    enabled = true,
}

-- ==================== 内部变量 ====================
local mqtt_client = nil
local is_connected = false
local task_name = "mqtt_ota_main"
local imei = nil

-- ==================== 主题生成 ====================
local function get_cmd_topic()
    return string.format("%s/%s/ota/cmd", config.topic_prefix, imei)
end

local function get_status_topic()
    return string.format("%s/%s/ota/status", config.topic_prefix, imei)
end

-- ==================== 状态上报 ====================
local function publish_status()
    if not mqtt_client or not is_connected then
        return false
    end

    local project, version, core_ver = ota_update.get_version()
    local ota_status, ota_error = ota_update.get_status()

    local status_data = {
        imei = imei,
        project = project,
        version = version,
        core_version = core_ver,
        ota_status = ota_status,
        ota_error = ota_error,
        rssi = mobile.rssi() or 0,
        csq = mobile.csq() or 0,
        timestamp = os.time(),
    }

    local json_str = json.encode(status_data)
    if json_str then
        local result = mqtt_client:publish(get_status_topic(), json_str, 1)
        if result then
            log.info("mqtt_ota", "状态上报成功")
            return true
        end
    end

    log.warn("mqtt_ota", "状态上报失败")
    return false
end

-- ==================== 消息处理 ====================
local function handle_message(topic, payload)
    log.info("mqtt_ota", "收到消息", topic, payload)

    -- 解析JSON
    local ok, data = pcall(json.decode, payload)
    if not ok or not data then
        log.error("mqtt_ota", "JSON解析失败", payload)
        return
    end

    local cmd = data.cmd

    -- 升级命令
    if cmd == "upgrade" then
        local url = data.url
        local version = data.version

        if url and url ~= "" then
            log.info("mqtt_ota", "收到升级命令", url, version)

            -- 先上报收到命令的状态
            publish_status()

            -- 启动OTA升级
            if ota_update.start(url, version) then
                log.info("mqtt_ota", "OTA升级已启动")
            else
                log.error("mqtt_ota", "OTA升级启动失败")
            end
        else
            log.error("mqtt_ota", "升级URL为空")
        end

    -- 查询版本命令
    elseif cmd == "query_version" then
        log.info("mqtt_ota", "收到版本查询命令")
        publish_status()

    -- 重启命令
    elseif cmd == "reboot" then
        log.info("mqtt_ota", "收到重启命令，3秒后重启")
        publish_status()
        sys.timerStart(function()
            rtos.reboot()
        end, 3000)

    else
        log.warn("mqtt_ota", "未知命令", cmd)
    end
end

-- ==================== MQTT事件回调 ====================
local function mqtt_event_callback(client, event, data, payload, metas)
    log.info("mqtt_ota", "事件", event, data)

    -- 连接成功
    if event == "conack" then
        is_connected = true
        log.info("mqtt_ota", "MQTT连接成功")

        -- 订阅OTA命令主题
        local cmd_topic = get_cmd_topic()
        if client:subscribe(cmd_topic, 1) then
            log.info("mqtt_ota", "订阅主题", cmd_topic)
        else
            log.error("mqtt_ota", "订阅失败", cmd_topic)
        end

        -- 上报设备状态
        sys.timerStart(publish_status, 1000)

    -- 订阅结果
    elseif event == "suback" then
        if data then
            log.info("mqtt_ota", "订阅成功, QoS:", payload)
        else
            log.error("mqtt_ota", "订阅失败, 错误码:", payload)
        end

    -- 收到消息
    elseif event == "recv" then
        handle_message(data, payload)

    -- 发送成功
    elseif event == "sent" then
        log.debug("mqtt_ota", "消息发送成功, ID:", data)

    -- 断开连接
    elseif event == "disconnect" then
        is_connected = false
        log.warn("mqtt_ota", "MQTT连接断开")
        sys.publish("MQTT_OTA_EVENT", "DISCONNECTED")

    -- 心跳响应
    elseif event == "pong" then
        log.debug("mqtt_ota", "心跳响应")

    -- 错误
    elseif event == "error" then
        is_connected = false
        log.error("mqtt_ota", "MQTT错误", data)
        if data == "connect" or data == "conack" then
            sys.publish("MQTT_OTA_EVENT", "CONNECT_FAILED")
        else
            sys.publish("MQTT_OTA_EVENT", "ERROR")
        end
    end
end

-- ==================== MQTT主任务 ====================
local function mqtt_task_func()
    -- 注册OTA状态变更回调
    ota_update.set_notify_callback(function(status, error_code)
        log.info("mqtt_ota", string.format("OTA状态变更: status=%d, error=%d", status, error_code))
        -- 延迟100ms确保状态已更新
        sys.timerStart(publish_status, 100)
    end)

    -- 获取IMEI
    imei = mobile.imei()
    if not imei or imei == "" then
        imei = "unknown"
    end
    log.info("mqtt_ota", "设备IMEI:", imei)

    while config.enabled do
        -- 在循环开头声明局部变量，避免goto跨越作用域
        local client_id
        local will_topic
        local will_msg

        -- 等待网络就绪
        while not socket.adapter(socket.LWIP_GP) do
            log.info("mqtt_ota", "等待网络...")
            sys.waitUntil("IP_READY", 1000)
        end
        log.info("mqtt_ota", "网络就绪")

        -- 创建MQTT客户端
        mqtt_client = mqtt.create(nil, config.server, config.port)
        if not mqtt_client then
            log.error("mqtt_ota", "创建MQTT客户端失败")
            sys.wait(5000)
            goto continue
        end

        -- 配置认证
        client_id = "vdm_" .. imei
        if not mqtt_client:auth(client_id, config.username, config.password, true) then
            log.error("mqtt_ota", "MQTT认证配置失败")
            mqtt_client:close()
            mqtt_client = nil
            sys.wait(5000)
            goto continue
        end

        -- 设置keepalive
        mqtt_client:keepalive(config.keepalive)

        -- 设置遗嘱消息
        will_topic = get_status_topic()
        will_msg = json.encode({
            imei = imei,
            status = "offline",
            timestamp = os.time()
        })
        mqtt_client:will(will_topic, will_msg, 1, true)

        -- 注册回调
        mqtt_client:on(mqtt_event_callback)

        -- 连接服务器
        if not mqtt_client:connect() then
            log.error("mqtt_ota", "MQTT连接失败")
            mqtt_client:close()
            mqtt_client = nil
            sys.wait(5000)
            goto continue
        end

        -- 等待事件
        while true do
            local result, event = sys.waitUntil("MQTT_OTA_EVENT", 30000)
            if result then
                log.info("mqtt_ota", "收到事件", event)
                if event == "DISCONNECTED" or event == "ERROR" or event == "CONNECT_FAILED" then
                    break
                end
            else
                -- 超时，发送心跳或状态
                if is_connected then
                    -- 定期上报状态
                    publish_status()
                end
            end
        end

        ::continue::

        -- 清理
        is_connected = false

        if mqtt_client then
            mqtt_client:close()
            mqtt_client = nil
        end

        -- 重连延迟
        log.info("mqtt_ota", "5秒后重连...")
        sys.wait(5000)
    end
end

-- ==================== 公开接口 ====================

--- 配置MQTT参数
-- @param cfg table 配置表
--   cfg.server: MQTT服务器地址
--   cfg.port: MQTT端口
--   cfg.username: 用户名
--   cfg.password: 密码
--   cfg.keepalive: 心跳间隔(秒)
--   cfg.topic_prefix: 主题前缀
--   cfg.enabled: 是否启用
function mqtt_ota.configure(cfg)
    if cfg.server then config.server = cfg.server end
    if cfg.port then config.port = cfg.port end
    if cfg.username then config.username = cfg.username end
    if cfg.password then config.password = cfg.password end
    if cfg.keepalive then config.keepalive = cfg.keepalive end
    if cfg.topic_prefix then config.topic_prefix = cfg.topic_prefix end
    if cfg.enabled ~= nil then config.enabled = cfg.enabled end

    log.info("mqtt_ota", "配置已更新")
    log.info("mqtt_ota", "服务器:", config.server, "端口:", config.port)
end

--- 启动MQTT OTA服务
function mqtt_ota.start()
    if not config.enabled then
        log.info("mqtt_ota", "MQTT OTA已禁用")
        return false
    end

    log.info("mqtt_ota", "启动MQTT OTA服务")
    log.info("mqtt_ota", "服务器:", config.server, "端口:", config.port)

    sys.taskInitEx(mqtt_task_func, task_name)
    return true
end

--- 停止MQTT OTA服务
function mqtt_ota.stop()
    config.enabled = false
    if mqtt_client then
        mqtt_client:disconnect()
    end
    log.info("mqtt_ota", "MQTT OTA服务已停止")
end

--- 检查是否已连接
function mqtt_ota.is_connected()
    return is_connected
end

--- 手动上报状态
function mqtt_ota.report_status()
    return publish_status()
end

--- 获取配置信息
function mqtt_ota.get_config()
    return {
        server = config.server,
        port = config.port,
        enabled = config.enabled,
        connected = is_connected,
        imei = imei,
        cmd_topic = imei and get_cmd_topic() or nil,
        status_topic = imei and get_status_topic() or nil,
    }
end

-- ==================== 初始化日志 ====================
log.info("mqtt_ota", "MQTT OTA模块已加载")

return mqtt_ota
