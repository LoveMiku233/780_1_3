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


local version = "0.1"
local module  = "fanzhou_key"
local author = "yankai"

local keys = {
    k1 = 24,
    k2 = 1,
    k3 = 2,
    k4 = 20
}

local _M = {}  -- 模块接口
_M.is_init = false -- 是否初始

function _M.init()
    for name, pin in pairs(keys) do
        -- 设置中断模式
        gpio.setup(pin, function()
            sys.publish("KEY", name)
            log.debug(module, name, pin)
        end, gpio.PULLUP, gpio.FALLING)
        gpio.debounce(pin, 300, 1)
        log.debug(module, string.format("KEY %s (PIN %d) initialized", name, pin))
    end
    _M.is_init = true
    log.debug("All keys initialized")
end

function _M.get_key_io(key)
    return keys[key]
end

return _M