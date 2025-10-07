--[[
  @file        fanzhou_led.lua      
  @author      yankai          
  @date        2025-06-09           
  @brief       LED 控制模块，提供初始化、开关控制、状态切换等功能
  @version     0.1                    
  @module      fanzhou_led     
  @description
    1. 提供 LED 初始化、开关控制、模式设置功能
    2. 支持单个 LED 精确控制
    TODO:   
        支持 LED 状态切换和模式设置
--]]

----------------------------------实际时控制可控电源的------------------------------------------
local version = "0.1"
local module  = "fanzhou_led"
local author = "yankai"

-- -- LED引脚配置表
-- local leds = {
--     led_in = 29,  -- 内部状态指示灯
--     led_4g = 30,  -- 4G网络状态灯
--     led_wan = 31, -- WAN口状态灯
--     led_lan = 32  -- LAN口状态灯
-- }

-- fix
local leds = {
    led_supply2 = 22,
    led_supply1 = 27,
    
}

local leds_mode = {
    led_supply2 = 0,
    led_supply1 = 0,
}

local _M = {}  -- 模块接口
_M.is_init = false -- 是否初始
_M.led_task_count = 0

-- ===========================================================================
-- @function   init
-- @brief      初始化所有 LED 引脚为输出，并默认关闭 LED（高电平）
-- @return     nil
-- ===========================================================================
function _M.init()
    for name, pin in pairs(leds) do
        gpio.setup(pin, 1)  -- 设置为输出模式
        gpio.set(pin, 1)     -- 默认关闭LED
        log.debug(module, string.format("LED %s (PIN %d) initialized", name, pin))
    end
    _M.is_init = true
    sys.timerLoopStart(_M.led_task, 500)
    log.debug("All LEDs initialized")
end

-- ===========================================================================
-- @function   on
-- @brief      打开指定名称的 LED（置为低电平）
-- @param[in]  led_name string  LED 名称（如 "led_supply1"）
-- @return     boolean          是否成功
-- ===========================================================================
function _M.on(led_name)
    if _M.is_init == false then
        _M.init()
    end
    local pin = leds[led_name]
    if not pin then
        log.debug(module, "Error: Invalid LED name - " .. tostring(led_name))
        return false
    end
    leds_mode[led_name] = 0
    gpio.set(pin, 0)
    log.debug(module, "LED ON: " .. led_name)
    return true
end

-- ===========================================================================
-- @function   off
-- @brief      关闭指定名称的 LED（置为高电平）
-- @param[in]  led_name string  LED 名称
-- @return     boolean          是否成功
-- ===========================================================================
function _M.off(led_name)
    if _M.is_init == false then
        _M.init()
    end
    local pin = leds[led_name]
    if not pin then
        log.debug(module, "Error: Invalid LED name - " .. tostring(led_name))
        return false
    end
    leds_mode[led_name] = 0
    gpio.set(pin, 1)
    log.debug(module, "LED OFF: " .. led_name)
    return true
end

-- ===========================================================================
-- @function   toggle
-- @brief      切换 LED 状态
-- @param[in]  led_name string  LED 名称
-- @return     number|nil       新状态（0: 开, 1: 关），无效名称返回 nil
-- ===========================================================================
function _M.toggle(led_name)
    if _M.is_init == false then
        _M.init()
    end
    local pin = leds[led_name]
    if not pin then
        log.debug(module, "Error: Invalid LED name - " .. tostring(led_name))
        return nil
    end
    
    gpio.toggle(pin)
    
    log.debug(module, string.format("LED %s toggled: %s", 
        led_name, 
        new_state == 1 and "ON" or "OFF"))
    
    return new_state
end

-- ===========================================================================
-- @function   set_mode
-- @brief      设置 LED 的工作模式（支持 "on", "off", "blink"）
-- @param[in]  led_name string  LED 名称
-- @param[in]  mode string      工作模式
-- @param[in]  ...              附加参数（如 blink 模式下的频率）
-- @return     boolean          是否设置成功
--
-- @example
--   _M.set_mode("led_wan", "blink", 2)  -- 以 2Hz 闪烁
-- ===========================================================================
function _M.set_mode(led_name, mode, ...)
    if _M.is_init == false then
        _M.init()
    end
    local pin = leds[led_name]
    if not pin then
        log.debug(module, "Error: Invalid LED name - " .. tostring(led_name))
        return false
    end

    if mode == "on" then
        leds_mode[led_name] = 0
        return _M.on(led_name)
        
    elseif mode == "off" then
        leds_mode[led_name] = 0
        return _M.off(led_name)

    elseif mode == "blink" then
        -- 实现闪烁
        leds_mode[led_name] = select(1, ...) or 1
    else
        log.debug(module, "Error: Invalid mode - " .. tostring(mode))
        return false
    end
end

function _M.led_task()
    -- 
    if _M.led_task_count == 13 then
        _M.led_task_count = 1
    end

    for name, mode in pairs(leds_mode) do
        -- 根据模式来判断是否亮灭
        if ((mode > 0) and (_M.led_task_count % mode) == 0) then
            _M.toggle(name)
        end
    end
end


return _M