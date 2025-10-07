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
_M.is_init = false -- 是否初始

function _M.init()
    for name, pin in pairs(relays) do
        gpio.setup(pin, 1)
        log.debug(module, string.format("relays %s (PIN %d) initialized", name, pin))
    end
    _M.is_init = true
    log.debug("All relays initialized")
end

function _M.on(relay_name)
    if _M.is_init == false then
        _M.init()
    end
    local pin = relays[relay_name]
    if not pin then
        log.debug(module, "Error: Invalid LED name - " .. tostring(relay_name))
        return false
    end
    gpio.set(pin, 0)
    log.debug(module, "LED ON: " .. relay_name)
    return true
end

-- ===========================================================================
-- @function   off
-- @brief      关闭指定名称的 LED（置为高电平）
-- @param[in]  relay_name string  LED 名称
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
-- @brief      切换 LED 状态
-- @param[in]  relay_name string  LED 名称
-- @return     number|nil       新状态（0: 开, 1: 关），无效名称返回 nil
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
    
    log.debug(module, string.format("RELAY %s toggled: %s", 
        relay_name, 
        new_state == 1 and "ON" or "OFF"))
    
    return new_state
end


function _M.get_mode(relay_name)
    if _M.is_init == false then
        _M.init()
    end
    local state = gpio.get(relays[relay_name])
    return 1 - state
end

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