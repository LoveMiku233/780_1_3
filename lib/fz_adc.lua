--[[
  @file        fanzhou_adc.lua      
  @author      yankai          
  @date        2025-07-18           
  @brief       ADC模块
  @version     0.1                    
  @module      fanzhou_adc    
  @description
    1. 采集供电电压
    TODO:   
        
--]]

local version = "0.1"
local module  = "fanzhou_adc"
local author = "yankai"


local _M = {}  -- 模块接口

-- ===========================================================================
-- @function   init
-- @brief      初始化所有 adc 电平
-- @return     nil
-- ===========================================================================
function _M.init(adc_channel, max_voltage) 
    if max_voltage <= 3.6 then
        adc.setRange(adc.ADC_RANGE_MAX)
    else 
        adc.setRange(adc.ADC_RANGE_MIN)
    end
    -- 打开adc
    adc.open(adc_channel)
    -- 采集一次
    adc.get(adc_channel)
end

-- ===========================================================================
-- @function   close
-- @brief      关闭指定通道adc
-- @return     nil
-- ===========================================================================
function _M.close(adc_channel)
    adc.close(adc_channel)
end

-- ===========================================================================
-- @function   get_adc
-- @brief      获取指定通道adc电压mv
-- @return     int
-- ===========================================================================
function _M.get_adc(adc_channel) 
    return adc.get(adc_channel)
end

return _M