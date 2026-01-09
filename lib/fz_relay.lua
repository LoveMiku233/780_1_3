--[[
@file       fz_relay.lua
@module     fanzhou_relay
@version    0.1
@date       2025-06-09
@author     yankai
@brief      继电器控制模块，提供初始化、开关控制、状态切换等功能
@description
    1. 提供继电器初始化、开关控制、模式设置功能
    2. 支持单个继电器精确控制
    3. 支持继电器状态读取和切换
    
    GPIO引脚配置：
    - k1: GPIO33
    - k2: GPIO29
    - k3: GPIO30
    - k4: GPIO32
    
    注意：继电器采用低电平有效设计（GPIO=0时继电器闭合）
--]]

local version = "0.1"
local module  = "fanzhou_relay"
local author = "yankai"

local relays = {
    k1 = 33,
    k2 = 29,
    k3 = 30,
    k4 = 32
}

local _M = {}  -- 模块接口
_M.is_init = false -- 是否已初始化

-- ===========================================================================
-- @function   init
-- @brief      初始化所有继电器引脚为输出模式，并默认关闭（高电平）
-- @return     nil
-- ===========================================================================
function _M.init()
    for name, pin in pairs(relays) do
        gpio.setup(pin, 1)
        gpio.set(pin, 1)
        log.debug(module, string.format("RELAY %s (PIN %d) initialized", name, pin))
    end
    _M.is_init = true
    log.debug(module, "All relays initialized")
end

-- ===========================================================================
-- @function   on
-- @brief      打开指定名称的继电器（置为低电平）
-- @param[in]  relay_name string  继电器名称（"k1", "k2", "k3", "k4"）
-- @return     boolean          是否成功
-- ===========================================================================
function _M.on(relay_name)
    if _M.is_init == false then
        _M.init()
    end
    local pin = relays[relay_name]
    if not pin then
        log.debug(module, "Error: Invalid RELAY name - " .. tostring(relay_name))
        return false
    end
    gpio.set(pin, 0)
    log.debug(module, "RELAY ON: " .. relay_name)
    return true
end

-- ===========================================================================
-- @function   off
-- @brief      关闭指定名称的继电器（置为高电平）
-- @param[in]  relay_name string  继电器名称
-- @return     boolean          是否成功
-- ===========================================================================
function _M.off(relay_name)
    if _M.is_init == false then
        _M.init()
    end
    local pin = relays[relay_name]
    if not pin then
        log.debug(module, "Error: Invalid RELAY name - " .. tostring(relay_name))
        return false
    end
    gpio.set(pin, 1)
    log.debug(module, "RELAY OFF: " .. relay_name)
    return true
end

-- ===========================================================================
-- @function   toggle
-- @brief      切换继电器状态（开变关，关变开）
-- @param[in]  relay_name string  继电器名称
-- @return     number|nil       新状态（1: 开, 0: 关），无效名称返回 nil
-- ===========================================================================
function _M.toggle(relay_name)
    if _M.is_init == false then
        _M.init()
    end
    local pin = relays[relay_name]
    if not pin then
        log.debug(module, "Error: Invalid RELAY name - " .. tostring(relay_name))
        return nil
    end
    
    gpio.toggle(pin)
    
    -- 读取切换后的状态（GPIO为0表示继电器开，为1表示继电器关）
    local gpio_state = gpio.get(pin)
    local new_state = 1 - gpio_state  -- 转换为继电器逻辑状态
    
    log.debug(module, string.format("RELAY %s toggled: %s", 
        relay_name, 
        new_state == 1 and "ON" or "OFF"))
    
    return new_state
end

-- ===========================================================================
-- @function   get_mode
-- @brief      获取继电器当前状态
-- @param[in]  relay_name string  继电器名称
-- @return     number  继电器状态（1=开，0=关）
-- ===========================================================================
function _M.get_mode(relay_name)
    if _M.is_init == false then
        _M.init()
    end
    local state = gpio.get(relays[relay_name])
    return 1 - state
end

-- ===========================================================================
-- @function   set_mode
-- @brief      设置继电器模式
-- @param[in]  relay_name string  继电器名称
-- @param[in]  mode string  模式（"on" 或 "off"）
-- @return     boolean  操作是否成功
-- ===========================================================================
function _M.set_mode(relay_name, mode, ...)
    if _M.is_init == false then
        _M.init()
    end
    local pin = relays[relay_name]
    if not pin then
        log.debug(module, "Error: Invalid RELAY name - " .. tostring(relay_name))
        return false
    end

    if mode == "on" then
        return _M.on(relay_name)
        
    elseif mode == "off" then
        return _M.off(relay_name)
    else
        log.debug(module, "Error: Invalid mode - " .. tostring(mode))
        return false
    end
end

return _M