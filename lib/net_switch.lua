-- net_switch.lua 修复版本

--[[

@brief 以太网和4G网络切换管理库，以太网优先
@description
  - 支持外挂SPI以太网（CH390芯片）
  - 自动检测网络状态并切换
  - 以太网优先，4G作为备用
  - 提供网络状态回调通知
--]]

local net_switch = {}
local sys = require("sys")

-- 网络状态
local net_states = {
    DISCONNECTED = 0,
    CONNECTING = 1,
    CONNECTED = 2
}

-- 网络类型
local net_types = {
    ETHERNET = "ethernet",
    MOBILE_4G = "4g",
    NONE = "none"
}

-- 配置参数
local config = {
    -- 以太网配置
    ethernet = {
        spi_id = 0,           -- SPI设备ID
        cs_pin = 8,          -- 片选引脚
        type = netdrv.CH390,  -- 网卡芯片类型
        baudrate = 51200000,  -- SPI波特率
        ping_ip = "202.89.233.101", 
        ping_interval = 10000 -- 检测间隔(ms)
    },
    -- 4G网络配置
    mobile_4g = {
        ping_ip = "202.89.233.101",
        ping_interval = 10000
    }
}

-- 内部状态
local state = {
    current_net = net_types.NONE,
    ethernet_status = net_states.DISCONNECTED,
    mobile_4g_status = net_states.DISCONNECTED,
    is_initialized = false,
    status_callback = nil,
    check_timer = nil
}

-- ===========================================================================
-- @function   net_switch.init
-- @brief      初始化网络切换模块
-- @param[in]  user_config table 用户配置（可选）
-- @param[in]  callback function 状态回调函数
-- @return     boolean 初始化是否成功
-- ===========================================================================
function net_switch.init(user_config, callback)
    if state.is_initialized then
        log.warn("NET_SWITCH", "模块已经初始化")
        return true
    end
    
    -- 合并配置
    if user_config then
        for key, value in pairs(user_config) do
            if config[key] then
                for k, v in pairs(value) do
                    config[key][k] = v
                end
            end
        end
    end
    
    -- 设置状态回调
    if type(callback) == "function" then
        state.status_callback = callback
    end
    
    log.info("NET_SWITCH", "初始化网络切换模块")
    log.info("NET_SWITCH", "以太网配置:", json.encode(config.ethernet))
    
    -- 初始化以太网
    if not net_switch._init_ethernet() then
        log.error("NET_SWITCH", "以太网初始化失败")
        -- 即使以太网失败也继续，使用4G网络
    end
    
    -- 4G网络自动初始化
    state.mobile_4g_status = net_states.CONNECTING
    
    state.is_initialized = true
    
    -- 开始网络检测
    net_switch._start_network_check()
    
    return true
end

-- ===========================================================================
-- @function   net_switch._init_ethernet
-- @brief      初始化外挂SPI以太网
-- @return     boolean 初始化是否成功
-- ===========================================================================
function net_switch._init_ethernet()
    log.info("NET_SWITCH", "开始初始化SPI以太网")
    
    -- 打开以太网电源
    if config.ethernet.pwr_pin then
        gpio.setup(config.ethernet.pwr_pin, 1, gpio.PULLUP)
        sys.wait(100)
    end
    
    -- 配置SPI
    local spi_result = spi.setup(
        config.ethernet.spi_id,
        nil, 0,  -- CPHA
        0,       -- CPOL
        8,       -- 数据宽度
        config.ethernet.baudrate
    )
    
    if spi_result ~= 0 then
        log.error("NET_SWITCH", "SPI初始化失败:", spi_result)
        if config.ethernet.pwr_pin then
            gpio.close(config.ethernet.pwr_pin)
        end
        return false
    end
    
    -- 初始化以太网驱动
    local opts = {
        spi = config.ethernet.spi_id,
        cs = config.ethernet.cs_pin
    }
    
    if not netdrv.setup(socket.LWIP_ETH, config.ethernet.type, opts) then
        log.error("NET_SWITCH", "以太网驱动初始化失败")
        if config.ethernet.pwr_pin then
            gpio.close(config.ethernet.pwr_pin)
        end
        return false
    end
    
    -- 启用DHCP
    netdrv.dhcp(socket.LWIP_ETH, true)
    state.ethernet_status = net_states.CONNECTING
    
    log.info("NET_SWITCH", "SPI以太网初始化完成")
    return true
end

-- ===========================================================================
-- @function   net_switch._check_ethernet
-- @brief      检查以太网连接状态
-- @return     boolean 是否连接成功
-- ===========================================================================
function net_switch._check_ethernet()
    if state.ethernet_status == net_states.DISCONNECTED then
        return false
    end
    
    -- 检查IP地址
    local ip = netdrv.ipv4(socket.LWIP_ETH)
    if not ip or ip == "0.0.0.0" then
        log.debug("NET_SWITCH", "以太网未获取到IP")
        state.ethernet_status = net_states.CONNECTING
        return false
    end
    
    -- 检查物理连接
    if not netdrv.ready(socket.LWIP_ETH) then
        log.debug("NET_SWITCH", "以太网物理连接未就绪")
        state.ethernet_status = net_states.CONNECTING
        return false
    end
    
    -- 如果之前不是已连接状态，更新状态
    if state.ethernet_status ~= net_states.CONNECTED then
        state.ethernet_status = net_states.CONNECTED
        log.info("NET_SWITCH", "以太网连接成功, IP:", ip)
        net_switch._notify_status_change(net_types.ETHERNET, net_states.CONNECTED)
    end
    
    return true
end

-- ===========================================================================
-- @function   net_switch._check_mobile_4g
-- @brief      检查4G网络连接状态
-- @return     boolean 是否连接成功
-- ===========================================================================
function net_switch._check_mobile_4g()
    -- 检查移动网络状态 - 修复：使用正确的方法检查4G网络
    local sim_ready = false
    
    -- 方法1: 检查SIM卡状态（如果可用）
    if mobile and mobile.sim then
        sim_ready = mobile.sim() -- 检查SIM卡是否就绪
    end
    
    -- 方法2: 检查网络注册状态（如果可用）
    local net_ready = false
    if mobile and mobile.imei then
        -- 如果有IMEI，说明模块基本正常
        local imei = mobile.imei()
        net_ready = imei and string.len(imei) > 0
    end
    
    -- 如果SIM卡和网络都不可用，则标记为断开
    if not sim_ready and not net_ready then
        log.debug("NET_SWITCH", "4G网络未就绪")
        state.mobile_4g_status = net_states.CONNECTING
        return false
    end
    
    -- 检查IP地址
    local ip = netdrv.ipv4(socket.LWIP_GP)
    if not ip or ip == "0.0.0.0" then
        log.debug("NET_SWITCH", "4G网络未获取到IP")
        state.mobile_4g_status = net_states.CONNECTING
        return false
    end
    
    -- 如果之前不是已连接状态，更新状态
    if state.mobile_4g_status ~= net_states.CONNECTED then
        state.mobile_4g_status = net_states.CONNECTED
        log.info("NET_SWITCH", "4G网络连接成功, IP:", ip)
        net_switch._notify_status_change(net_types.MOBILE_4G, net_states.CONNECTED)
    end
    
    return true
end

-- ===========================================================================
-- @function   net_switch._switch_network
-- @brief      根据优先级切换网络
-- ===========================================================================
function net_switch._switch_network()
    local old_net = state.current_net
    
    -- 以太网优先
    if state.ethernet_status == net_states.CONNECTED then
        if state.current_net ~= net_types.ETHERNET then
            log.info("NET_SWITCH", "切换到以太网")
            socket.dft(socket.LWIP_ETH)
            state.current_net = net_types.ETHERNET
            net_switch._notify_network_switch(net_types.ETHERNET)
        end
    -- 以太网不可用，使用4G
    elseif state.mobile_4g_status == net_states.CONNECTED then
        if state.current_net ~= net_types.MOBILE_4G then
            log.info("NET_SWITCH", "切换到4G网络")
            socket.dft(socket.LWIP_GP)
            state.current_net = net_types.MOBILE_4G
            net_switch._notify_network_switch(net_types.MOBILE_4G)
        end
    -- 都没有网络
    else
        if state.current_net ~= net_types.NONE then
            log.warn("NET_SWITCH", "所有网络连接断开")
            state.current_net = net_types.NONE
            net_switch._notify_network_switch(net_types.NONE)
        end
    end
    
    -- 记录网络切换
    if old_net ~= state.current_net then
        log.info("NET_SWITCH", string.format("网络切换: %s -> %s", old_net, state.current_net))
    end
end

-- ===========================================================================
-- @function   net_switch._notify_status_change
-- @brief      通知网络状态变化
-- @param[in]  net_type string 网络类型
-- @param[in]  status number 连接状态
-- ===========================================================================
function net_switch._notify_status_change(net_type, status)
    if state.status_callback then
        state.status_callback(net_type, status)
    end
end

-- ===========================================================================
-- @function   net_switch._notify_network_switch
-- @brief      通知网络切换
-- @param[in]  new_net string 新的网络类型
-- ===========================================================================
function net_switch._notify_network_switch(new_net)
    if state.status_callback then
        state.status_callback("switch", new_net)
    end
end

-- ===========================================================================
-- @function   net_switch._start_network_check
-- @brief      启动网络状态检测
-- ===========================================================================
function net_switch._start_network_check()
    if state.check_timer then
        sys.timerStop(state.check_timer)
    end
    
    state.check_timer = sys.timerLoopStart(function()
        -- 检查各网络状态
        net_switch._check_ethernet()
        net_switch._check_mobile_4g()
        
        -- 根据优先级切换网络
        net_switch._switch_network()
        
        -- 记录当前状态（调试用）
        if state.current_net ~= net_types.NONE then
            local ip = net_switch.get_current_ip()
            log.debug("NET_SWITCH", string.format("当前网络: %s, IP: %s", state.current_net, ip))
        end
    end, 5000) -- 每5秒检测一次
end

-- ===========================================================================
-- @function   net_switch.get_current_network
-- @brief      获取当前使用的网络类型
-- @return     string 网络类型
-- ===========================================================================
function net_switch.get_current_network()
    return state.current_net
end

-- ===========================================================================
-- @function   net_switch.get_current_ip
-- @brief      获取当前网络的IP地址
-- @return     string IP地址
-- ===========================================================================
function net_switch.get_current_ip()
    if state.current_net == net_types.ETHERNET then
        return netdrv.ipv4(socket.LWIP_ETH) or "0.0.0.0"
    elseif state.current_net == net_types.MOBILE_4G then
        return netdrv.ipv4(socket.LWIP_GP) or "0.0.0.0"
    else
        return "0.0.0.0"
    end
end

-- ===========================================================================
-- @function   net_switch.get_network_status
-- @brief      获取各网络状态
-- @return     table 网络状态表
-- ===========================================================================
function net_switch.get_network_status()
    return {
        current = state.current_net,
        ethernet = state.ethernet_status,
        mobile_4g = state.mobile_4g_status,
        ethernet_ip = netdrv.ipv4(socket.LWIP_ETH) or "0.0.0.0",
        mobile_4g_ip = netdrv.ipv4(socket.LWIP_GP) or "0.0.0.0"
    }
end

-- ===========================================================================
-- @function   net_switch.is_connected
-- @brief      检查是否有网络连接
-- @return     boolean 是否已连接
-- ===========================================================================
function net_switch.is_connected()
    return state.current_net ~= net_types.NONE
end

-- ===========================================================================
-- @function   net_switch.deinit
-- @brief      反初始化网络切换模块
-- ===========================================================================
function net_switch.deinit()
    if state.check_timer then
        sys.timerStop(state.check_timer)
        state.check_timer = nil
    end
    
    if config.ethernet.pwr_pin then
        gpio.close(config.ethernet.pwr_pin)
    end
    
    state.is_initialized = false
    state.current_net = net_types.NONE
    state.ethernet_status = net_states.DISCONNECTED
    state.mobile_4g_status = net_states.DISCONNECTED
    
    log.info("NET_SWITCH", "网络切换模块已反初始化")
end

return net_switch