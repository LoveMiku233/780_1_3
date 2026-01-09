--[[
@file       fanzhou_mqtt.lua
@module     fanzhou_mqtt
@version    0.2
@date       2025-05-20
@author     yankai
@brief      支持多实例并发的 MQTT 客户端封装，提供连接、发布、订阅和回调处理
@description
  - 支持自定义连接参数初始化
  - 支持缓冲区缓存消息，实现断线前后无缝发布
  - 支持主题回调映射与异步处理，避免阻塞
  - 每个实例拥有唯一事件前缀，互不干扰
--]]


local version = "0.2"
local module  = "fanzhou_mqtt"
local author = "yankai"

local _M = {}
local mt = { __index = _M }



-- ===========================================================================
-- @function   _M.new
-- @brief      创建一个新的 MQTT 客户端实例
-- @param[in]  cfg table 可选配置表（host、port、ssl、user、password、keepalive、autoreconn、reconnect_interval）
-- @return     table MQTT 实例对象
-- ===========================================================================
function _M.new(cfg)
    local self = {
        config = cfg or {},
        mqttc = nil,
        device_id = nil,
        is_connected = false,
        normal_queue = {},
        topic_callbacks = {},
        instance_id = tostring(math.random(1,10000)),  -- 生成唯一实例标识
        event_prefix = "MQTT_MULTI_"..tostring(math.random(1000,9999)).."_"  -- 唯一事件前缀
    }
    return setmetatable(self, mt)
end

-- ===========================================================================
-- @function   validate_config
-- @brief      验证配置表合法性
-- @param[in]  cfg table 配置表
-- @return     boolean true: 合法；否则断言失败
-- ===========================================================================
local function validate_config(cfg)
    assert(type(cfg)=="table", module.." invalid config")
    assert(cfg.host and cfg.port>0, module.." missing host/port")
    return true
end

-- ===========================================================================
-- @function   _M:init
-- @brief      初始化 MQTT 客户端，设置设备 ID 与认证
-- @return     boolean true: 初始化成功
-- ===========================================================================
function _M:init()
    validate_config(self.config)
    
    -- 设置 device_id
    if self.config.user == "nil" then
        self.config.user = mobile.imei()
    end
    if self.config.device_id == "" then
        self.device_id = mobile.imei() or mcu.unique_id():toHex()
    else
        self.device_id = self.config.device_id
    end
    
    -- 建立 MQTT 客户端
    self.mqttc = mqtt.create(
        nil, 
        self.config.host, 
        self.config.port, 
        self.config.ssl
    )
    
    if self.config.user and self.config.password then
        self.mqttc:auth(self.device_id, self.config.user, self.config.password)
    else
        self.mqttc:auth(self.device_id)
    end
    
    log.debug(module, "instance", self.instance_id, "version", version)
    return true
end

-- ===========================================================================
-- @function   _M:get_instance_id
-- @brief      获取当前实例的事件前缀
-- @return     string 事件前缀，用于区分不同实例
-- ===========================================================================
function _M:get_instance_id() 
    return self.event_prefix
end

-- ===========================================================================
-- @function   _M:connect
-- @brief      建立到 MQTT 服务器的连接，注册事件回调并处理缓存队列
-- @return     boolean true: 连接请求已发送；false: 客户端未初始化
-- ===========================================================================
function _M:connect()
    if not self.mqttc then
        log.error(module, "connect failed: not initialized")
        return false
    end

    -- 注册实例专属事件回调
    self.mqttc:on(function(client, event, topic, payload)
        log.debug(module, "instance", self.instance_id, "event", event)
        if event == "conack" then
            self.is_connected = true
            -- 发布带实例标识的连接事件
            sys.publish(self.event_prefix.."CONNECTED")
            -- 处理队列消息
            for _, msg in ipairs(self.normal_queue) do
                self.mqttc:publish(msg.topic, msg.data, msg.qos)
            end
            self.normal_queue = {}
        elseif event == "recv" then
            -- 发布带实例标识的接收事件
            sys.publish(self.event_prefix.."RECV", topic, payload)
        elseif event == "disconnect" then
            self.is_connected = false
            log.warn(module, "instance", self.instance_id, "disconnected")
        end
    end)

    -- 配置连接参数
    self.mqttc:keepalive(self.config.keepalive or 60)
    self.mqttc:autoreconn(
        self.config.autoreconn ~= false,
        self.config.reconnect_interval or 3000
    )

    -- 启动异步任务处理消息
    self:_start_async_task()
    
    return self.mqttc:connect()
end

-- ===========================================================================
-- @function   _M:publish
-- @brief      发布消息到指定主题；若未连接则入缓存队列
-- @param[in]  topic string 发布主题
-- @param[in]  data string  发布内容
-- @param[in]  qos number?  服务质量（可选，默认为0）
-- @return     boolean       发布是否立即成功
-- ===========================================================================
function _M:publish(topic, data, qos)
    qos = qos or 0
    if self.mqttc and self.mqttc:ready() then
        return self.mqttc:publish(topic, data, qos)
    end
    table.insert(self.normal_queue, {topic=topic, data=data, qos=qos})
    return false
end

-- ===========================================================================
-- @function   _M:subscribe
-- @brief      订阅主题并注册回调
-- @param[in]  topic string     订阅主题
-- @param[in]  qos number?      服务质量（可选，默认为1）
-- @param[in]  callback function 收到消息后的回调函数
-- @return     boolean           订阅是否成功
-- ===========================================================================
function _M:subscribe(topic, qos, callback)
    qos = qos or 1
    if not self.is_connected then
        log.warn(module, "instance", self.instance_id, "subscribe failed: not connected")
        return false
    end
    local ok = self.mqttc:subscribe(topic, qos)
    if ok then
        self.topic_callbacks[topic] = callback
        log.debug(module, "instance", self.instance_id, "subscribed", topic)
    end
    return ok
end

-- ===========================================================================
-- @function   _M:is_connected
-- @brief      获取当前连接状态
-- @return     boolean  true: 已连接，false: 未连接
-- ===========================================================================
function _M:get_is_connected()
    return self.is_connected
end

-- ===========================================================================
-- @function   _M:close
-- @brief      关闭连接并清理实例状态
-- ===========================================================================
function _M:close()
    if self.mqttc then
        self.mqttc:close()
        self.mqttc = nil
        self.is_connected = false
        self.topic_callbacks = {}
        self.normal_queue = {}
    end
end

-- ===========================================================================
-- @function   _M:_start_async_task
-- @brief      启动异步任务，监听并分发接收的消息给回调
-- ===========================================================================
function _M:_start_async_task()
    sys.taskInit(function()
        while true do
            -- 等待本实例的接收事件
            local _, topic, payload = sys.waitUntil(self.event_prefix.."RECV")
            log.debug(module, "instance", self.instance_id, "received", topic)
            
            -- 查找对应的回调函数
            local cb = self.topic_callbacks[topic]
            if cb then
                -- 在独立协程中执行回调避免阻塞
                sys.taskInit(function() 
                    cb(payload) 
                end)
            end
        end
    end)
end

return _M