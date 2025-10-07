--[[
@file       fz_network.lua
@module     fz_network
@version    0.8.2
@date       2025-08-02
@author     yankai
@brief      网络管理模块
--]]

local version = "0.8.2"
local module  = "fz_network"
local author = "yankai"

-- 引入必要的库文件
local dhcps = require "dhcpsrv"
local dnsproxy = require "dnsproxy"

local _M = {}
local network_status = 0  -- 0: 未连接, 1: 4G, 2: WAN, 3: 4G and LAN
local wan_ready = false
local lan_ready = false
local network_ready_published = false
local rj45_initialized = false
local current_rj45_mode = nil
local wan_check_active = false  -- 标记是否正在执行WAN检查
local wan_connection_lost = false  -- 标记WAN连接是否丢失

local config = {
    enable_rj45 = true,
    enable_lan_when_4g = true,
    lan_delay = 5000,  -- 4G连接后启动LAN的延迟时间 (减少到3秒)
    wan_check_interval = 5000,  -- WAN检查间隔 (增加到3秒)
    wan_recovery_attempts = 10,  -- WAN恢复尝试次数
    skip_lan_link_check = true
}

-- ===========================================================================
-- @function   setup_rj45_spi
-- @brief      设置RJ45 SPI接口
-- ===========================================================================
local function setup_rj45_spi()
    if rj45_initialized then
        return true
    end
    
    -- 确保之前的SPI资源被释放
    -- if spi.close then
    --     spi.close(0)
    --     sys.wait(100)
    -- end
    
    local result = spi.setup(
        0,--串口id
        nil,
        0,--CPHA
        0,--CPOL
        8,--数据宽度
        25600000--,--频率
        -- spi.MSB,--高低位顺序    可选，默认高位在前
        -- spi.master,--主模式     可选，默认主
        -- spi.full--全双工       可选，默认全双工
    )
    log.debug(module, "SPI setup result:", result)
    
    if result == 0 then
        rj45_initialized = true
        log.debug(module, "RJ45 SPI initialized successfully")
        return true
    else
        log.error(module, "SPI setup failed:", result)
        return false
    end
end

-- ===========================================================================
-- @function   reset_network_interfaces
-- @brief      重置网络接口
-- ===========================================================================
local function reset_network_interfaces()
    log.debug(module, "Resetting network interfaces...")
    
    -- 尝试关闭之前的网络驱动
    if netdrv and netdrv.close then
        netdrv.ctrl(socket.LWIP_ETH, netdrv.CTRL_RESET, netdrv.RESET_HARD)
        sys.wait(500)
    end
    
    -- 重置状态变量
    if current_rj45_mode == "lan" then
        -- 停止DHCP服务
        if dhcps and dhcps.stop then
            dhcps.stop()
        end
        
        -- 停止DNS代理
        if dnsproxy and dnsproxy.close then
            dnsproxy.close()
        end
    end
    
    current_rj45_mode = nil
    rj45_initialized = false
end

-- ===========================================================================
-- @function   check_wan_status
-- @brief      检查WAN状态（仅在需要时调用）
-- ===========================================================================
local function check_wan_status()
    if wan_check_active then
        return  -- 避免重复检查
    end
    
    wan_check_active = true
    
    sys.taskInit(function()
        local attempts = 0
        local max_attempts = config.wan_recovery_attempts
        
        while attempts < max_attempts do
            log.debug(module, "Checking WAN status, attempt: " .. (attempts + 1) .. "/" .. max_attempts)
            
            local ipv4, mask, gateway = netdrv.ipv4(socket.LWIP_ETH, "", "", "")
            log.debug(module, "WAN Status - IP:", ipv4, "Mask:", mask, "Gateway:", gateway)
            
            -- 修正IP检查逻辑
            local netdrv_ready = netdrv.ready(socket.LWIP_ETH)
            if netdrv_ready and ipv4 and ipv4 ~= "0.0.0.0" and ipv4 ~= "" then
                log.debug(module, "WAN connection established")
                wan_ready = true
                wan_connection_lost = false
                sys.publish("CH390_WAN_READY")
                wan_check_active = false
                return
            end
            
            attempts = attempts + 1
            sys.wait(config.wan_check_interval)
        end
        
        log.warn(module, "WAN recovery failed after " .. max_attempts .. " attempts")
        
        -- 如果4G已连接且配置允许，切换到LAN模式
        -- if mobile and mobile.status() == 1 and config.enable_lan_when_4g and current_rj45_mode ~= "lan" then
        --     log.debug(module, "WAN unavailable, 4G connected - switching to LAN mode...")
        --     init_lan_mode()
        -- end
        
        wan_check_active = false
    end)
end


-- ===========================================================================
-- @function   init_wan_mode
-- @brief      初始化WAN模式
-- ===========================================================================
local function init_wan_mode()
    log.debug(module, "Initializing WAN mode...")
    
    sys.taskInit(function()
        sys.wait(2000)  -- 减少延迟
        
        if current_rj45_mode == "wan" then
            log.debug(module, "Already in WAN mode, skip initialization")
            return
        end
        
        -- 确保清除所有LAN配置
        reset_network_interfaces()
        sys.wait(500)  -- 增加等待时间确保重置完成
        
        log.debug(module, "Initializing WAN mode...")
        
        if not setup_rj45_spi() then
            log.error(module, "Failed to setup SPI for WAN mode")
            return
        end
   
         local result = spi.setup(
            0,--串口id
            nil,
            0,--CPHA
            0,--CPOL
            8,--数据宽度
            25600000--,--频率
            -- spi.MSB,--高低位顺序    可选，默认高位在前
            -- spi.master,--主模式     可选，默认主
            -- spi.full--全双工       可选，默认全双工
        )
        log.info("main", "open",result)
        if result ~= 0 then--返回值为0，表示打开成功
            log.info("main", "spi open error",result)
            return
        end

        netdrv.setup(socket.LWIP_ETH, netdrv.CH390, {spi=0,cs=8})
        local dhcp_result = netdrv.dhcp(socket.LWIP_ETH, true)
        log.debug(module, "DHCP client enabled:", dhcp_result)
        current_rj45_mode = "wan"
        
        -- 进行一次初始WAN状态检查
        check_wan_status()
    end)
end

-- ===========================================================================
-- @function   init_lan_mode
-- @brief      初始化LAN模式
-- ===========================================================================
local function init_lan_mode()
    log.debug(module, "Initializing LAN mode...")
    
    sys.taskInit(function()
        sys.wait(1000)  -- 减少延迟
        
        -- 重置网络接口
        reset_network_interfaces()
        
        if not setup_rj45_spi() then
            log.error(module, "Failed to setup SPI for LAN mode")
            return
        end
        
        -- 设置网络驱动
        netdrv.setup(socket.LWIP_ETH, netdrv.CH390, {
            spiid = 0,
            cs = 8
        })
        
        sys.wait(1000)  -- 减少延迟
        
        -- 确保断开任何DHCP客户端
        netdrv.dhcp(socket.LWIP_ETH, false)
        sys.wait(500)
        
        -- 设置静态IP作为LAN网关 (确保使用有效的IP)
        local ipv4, mask, gw = netdrv.ipv4(socket.LWIP_ETH, "192.168.4.1", "255.255.255.0", "192.168.4.1")
        log.debug(module, "LAN static IP configured:", ipv4, mask, gw)
        current_rj45_mode = "lan"
        
        -- 确保IP设置成功
        if not ipv4 or ipv4 == "0.0.0.0" then
            log.error(module, "Failed to set static IP for LAN mode")
            sys.wait(1000)
            -- 再次尝试设置IP
            ipv4, mask, gw = netdrv.ipv4(socket.LWIP_ETH, "192.168.4.1", "255.255.255.0", "192.168.4.1")
            log.debug(module, "LAN static IP retry:", ipv4, mask, gw)
            
            if not ipv4 or ipv4 == "0.0.0.0" then
                log.error(module, "Failed to set LAN IP after retry")
                return
            end
        end
        
        -- 跳过物理链路检测（因为可能没有设备连接）
        local link_established = true
        if not config.skip_lan_link_check then
            local link_wait_count = 0
            while netdrv.link(socket.LWIP_ETH) ~= true and link_wait_count < 20 do
                sys.wait(100)
                link_wait_count = link_wait_count + 1
            end
            link_established = netdrv.link(socket.LWIP_ETH)
        end
        
        if link_established then
            -- 启动DHCP服务器
            local dhcp_result = dhcps.create({
                adapter = socket.LWIP_ETH,
                start = "192.168.4.100",
                end_ip = "192.168.4.200",
                lease = 7200
            })
            log.debug(module, "DHCP server started:", dhcp_result and "success" or "failed")
            
            -- 启动DNS代理
            local dns_result = dnsproxy.setup(socket.LWIP_ETH, socket.LWIP_GP)
            log.debug(module, "DNS proxy started:", dns_result and "success" or "failed")
            
            -- 启用NAT转发
            local nat_result = netdrv.napt(socket.LWIP_GP)
            log.debug(module, "NAT forwarding enabled:", nat_result and "success" or "failed")
            
            lan_ready = true
            log.debug(module, "LAN mode initialization completed")
            sys.publish("CH390_LAN_READY")
        else
            log.error(module, "LAN mode: Physical link failed")
        end
    end)
end

-- ===========================================================================
-- @function   update_network_status
-- @brief      更新网络状态
-- ===========================================================================
local function update_network_status()
    local old_status = network_status
    local has_4g = mobile and mobile.status() == 1
    
    if wan_ready and has_4g then
        network_status = 3  -- 4G + WAN
    elseif wan_ready then
        network_status = 2  -- WAN only
    elseif has_4g and lan_ready then
        network_status = 3  -- 4G + LAN
    elseif has_4g then
        network_status = 1  -- 4G only
    else
        network_status = 0  -- No connection
    end
    
    if old_status ~= network_status then
        log.debug(module, string.format("Network status changed: %d -> %d", old_status, network_status))
        
        -- 发布网络就绪事件
        if network_status > 0 and not network_ready_published then
            network_ready_published = true
            log.debug(module, "Publishing net_ready event, status:", network_status)
            sys.publish("net_ready", network_status)
        end
    end
end

-- ===========================================================================
-- @function   check_eth_connection
-- @brief      检查以太网连接状态
-- ===========================================================================
local function check_eth_connection()
    if current_rj45_mode == "wan" then
        -- 只有当WAN模式且连接丢失时才检查
        if wan_connection_lost then
            check_wan_status()
        end
    end
end

-- ===========================================================================
-- @function   ip_ready_func
-- @brief      网络连接成功回调
-- ===========================================================================
local function ip_ready_func(ip, adapter)
    log.debug(module, string.format("Network connected! IP: %s, Adapter: %d", ip or "unknown", adapter))
    
    if adapter == socket.LWIP_GP then  -- 4G连接成功
        -- 确保只有配置允许时才启动LAN
        if config.enable_lan_when_4g and not wan_ready and not lan_ready then
            sys.timerStop(init_lan_mode)
            sys.timerStart(function()
                -- 添加双重检查防止冲突
                if not wan_ready and mobile.status() == 1 then
                    log.debug(module, "Starting LAN mode with 4G...")
                    init_lan_mode()
                end
            end, config.lan_delay)
        end
        
    elseif adapter == socket.LWIP_ETH then
        -- 以太网连接成功
        if current_rj45_mode == "wan" then
            log.debug(module, "WAN connection established via Ethernet")
            wan_ready = true
            wan_connection_lost = false
        elseif current_rj45_mode == "lan" then
            log.debug(module, "LAN connection established via Ethernet")
            lan_ready = true
        end
    end
    
    -- 更新网络状态
    update_network_status()
end

-- ===========================================================================
-- @function   ip_close_func
-- @brief      网络断开回调
-- ===========================================================================
local function ip_close_func(adapter)
    log.warn(module, string.format("Network disconnected! Adapter: %d", adapter))
    
    if adapter == socket.LWIP_GP then
        log.debug(module, "4G connection lost")
    elseif adapter == socket.LWIP_ETH then
        if current_rj45_mode == "wan" then
            log.debug(module, "WAN connection lost")
            wan_ready = false
            wan_connection_lost = true
            
            -- 连接丢失后，触发检查WAN状态
            sys.timerStart(check_wan_status, 5000)
        elseif current_rj45_mode == "lan" then
            log.debug(module, "LAN connection lost")
            lan_ready = false
        end
    end
    
    -- 更新网络状态
    update_network_status()
    
    -- 如果完全断网，重置发布标志
    if network_status == 0 then
        network_ready_published = false
    end
end

-- ===========================================================================
-- @function   link_status_change_func
-- @brief      物理链路状态变化回调
-- ===========================================================================
local function link_status_change_func(adapter, is_connected)
    log.debug(module, string.format("Physical link status changed: Adapter: %d, Connected: %s", 
        adapter, tostring(is_connected)))
    
    if adapter == socket.LWIP_ETH then
        if is_connected then
            log.debug(module, "Ethernet cable connected")
            if current_rj45_mode == "wan" and wan_connection_lost then
                -- 链路恢复，触发WAN状态检查
                check_wan_status()
            end
        else
            log.debug(module, "Ethernet cable disconnected")
            if current_rj45_mode == "wan" then
                wan_connection_lost = true
                wan_ready = false
                update_network_status()
            end
        end
    end
end

-- ===========================================================================
-- @function   公共接口函数
-- ===========================================================================
function _M.get_network_status()
    return network_status
end

function _M.get_network_status_text()
    local status_text = {
        [0] = "未连接",
        [1] = "4G",
        [2] = "WAN", 
        [3] = "4G+LAN",
        [4] = "WIFI"
    }
    return status_text[network_status] or "未知"
end

function _M.get_rj45_status()
    if not rj45_initialized then
        return {
            ip = "0.0.0.0",
            mask = "0.0.0.0",
            gateway = "0.0.0.0", 
            link = false,
            ready = false,
            mode = "none"
        }
    end
    
    local ipv4, mask, gateway = netdrv.ipv4(socket.LWIP_ETH, "", "", "")
    local link_status = netdrv.link and netdrv.link(socket.LWIP_ETH) or false
    local ready_status = netdrv.ready and netdrv.ready(socket.LWIP_ETH) or false
    
    return {
        ip = ipv4 or "0.0.0.0",
        mask = mask or "0.0.0.0", 
        gateway = gateway or "0.0.0.0",
        link = link_status,
        ready = ready_status,
        mode = current_rj45_mode or "none"
    }
end

-- 手动强制重置网络
function _M.reset_network()
    log.debug(module, "Manual network reset requested")
    reset_network_interfaces()
    sys.wait(1000)
    
    -- 如果有4G连接，重新初始化LAN模式
    if mobile and mobile.status() == 1 then
        init_lan_mode()
    else
        init_wan_mode()
    end
    
    return true
end

-- 手动检查网络状态
function _M.check_network()
    log.debug(module, "Manual network check requested")
    
    if current_rj45_mode == "wan" then
        check_wan_status()
    end
    
    return true
end

function _M.set_config(key, value)
    if config[key] ~= nil then
        config[key] = value
        log.debug(module, string.format("Config updated: %s = %s", key, tostring(value)))
    else
        log.warn(module, string.format("Unknown config key: %s", key))
    end
end

function _M.get_config(key)
    return config[key]
end

-- 兼容接口
function _M.init(is_wan)
    log.info("ch390", "打开LDO供电")
    gpio.setup(20, 1)  --打开lan供电
    if is_wan then
        init_wan_mode()
    else
        init_lan_mode()
    end
end

-- ===========================================================================
-- @function   test_network_connectivity
-- @brief      检测网络连接
-- ===========================================================================
function _M.test_network_connectivity()
    -- 测试网络连通性
    local code, headers, body = http.request("GET", "http://httpbin.org/ip", nil, nil, 5000).wait()
    if code == 200 then
        log.debug("main", "Network connectivity test passed")
        return true
    else
        log.error("main", "Network connectivity test failed, code:", code)
        return false
    end
end

-- ===========================================================================
-- @function   模块初始化
-- ===========================================================================
sys.taskInit(function()
    log.debug(module, string.format("Network module initialized v%s", version))
    
    -- 订阅系统网络事件
    sys.subscribe("IP_READY", ip_ready_func)
    sys.subscribe("IP_LOSE", ip_close_func)
    
    -- 订阅物理链路状态变化事件
    if netdrv and netdrv.on_link_status_change then
        netdrv.on_link_status_change(link_status_change_func)
    end
    
    -- 订阅自定义事件
    sys.subscribe("CH390_WAN_READY", function()
        log.debug(module, "CH390 WAN Ready event received")
        update_network_status()
    end)
    
    sys.subscribe("CH390_LAN_READY", function()
        log.debug(module, "CH390 LAN Ready event received")
        update_network_status()
    end)
    
    sys.wait(1000)  -- 减少延迟
    
    -- 启动网络连接
    if config.enable_rj45 then
        if mobile and mobile.status() == 1 and config.enable_lan_when_4g then
            log.debug(module, "4G already connected, starting LAN mode...")
            init_lan_mode()
        else
            log.debug(module, "Starting WAN connection...")
            init_wan_mode()
        end
    else
        log.debug(module, "RJ45 disabled, waiting for 4G...")
    end
end)

return _M