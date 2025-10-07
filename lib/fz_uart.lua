--[[
@file       fanzhou_uart.lua
@module     fanzhou_uart
@version    0.1
@date       2025-05-20
@author     yankai
@brief      串口（UART/RS485）封装模块，支持发送、接收及485方向控制
@description
  - 支持配置表初始化，包含 UART 参数与 485 GPIO 控制
  - 提供定时/单次发送功能
  - 提供接收回调注册，自动读取缓冲区数据
--]]

local version = "0.1"
local module  = "fanzhou_uart"
local author = "yankai"

-- 默认配置
local DEFAULT_CONFIG = {
    is_485 = 0,
    uartid = 2, -- 串口ID
    baudrate = 9600, -- 波特率
    databits = 8, -- 数据位
    stopbits = 1, -- 停止位
    parity = uart.None, -- 校验位
    endianness = uart.LSB, -- 字节序
    buffer_size = 1024, -- 缓冲区大小
    gpio_485 = 27, -- 485转向GPIO
    rx_level = 0, -- 485模式下RX的GPIO电平
    tx_delay = 10000 -- 485模式下TX向RX转换的延迟时间（us）
}

local FzUart = {}
FzUart.__index = FzUart

-- ===========================================================================
-- @function   FzUart.new
-- @brief      构造并初始化 UART/RS485 实例
-- @param[in]  config table 可选配置表，字段同 DEFAULT_CONFIG
-- @return     table FzUart 实例
-- ===========================================================================
function FzUart.new(config)
    local self = setmetatable({}, FzUart)
    
    -- 合并配置参数
    self.config = {}
    for key, default_value in pairs(DEFAULT_CONFIG) do
        self.config[key] = config and config[key] or default_value
    end

    -- 初始化硬件
    if self.config.is_485 == 1 then
        uart.setup(
            self.config.uartid,
            self.config.baudrate,
            self.config.databits,
            self.config.stopbits,
            self.config.parity,
            self.config.endianness,
            self.config.buffer_size,
            self.config.gpio_485,
            self.config.rx_level,
            self.config.tx_delay
        )
    else
        uart.setup(
            self.config.uartid,
            self.config.baudrate,
            self.config.databits,
            self.config.stopbits,
            self.config.parity,
            self.config.endianness,
            self.config.buffer_size
        )
    end

    log.debug("UART实例已创建，配置:", json.encode(self.config))
    return self
end

-- ===========================================================================
-- @function   FzUart:send_str
-- @brief      发送字符串数据，支持定时与单次发送
-- @param[in]  data string    要发送的数据
-- @param[in]  interval number? 定时间隔（毫秒，可选）
-- ===========================================================================
function FzUart:send_str(data, interval)
    if interval then
        sys.timerLoopStart(function()
            log.debug("UART"..self.config.uartid.." 定时发送:", data)
            uart.write(self.config.uartid, data)
            if self.config.is_485 then  uart.wait485(self.config.uartid) end
        end, interval)
    else
        uart.write(self.config.uartid, data)
        if self.config.is_485 then  uart.wait485(self.config.uartid) end
        log.debug("UART"..self.config.uartid.." 单次发送:", data)
    end
end

-- ===========================================================================
-- @function   FzUart:set_receive_callback
-- @brief      注册接收回调，自动读取所有接收缓冲区数据
-- @param[in]  callback function 接收数据回调，参数为读取到的字符串
-- ===========================================================================
function FzUart:set_receive_callback(callback)
    uart.on(self.config.uartid, "receive", function(id, len)
        local s = ""
        repeat
            s = uart.read(id, 128)
            if #s > 0 then
                callback(s)
            end
        until s == ""
    end)
end


return FzUart