--[[
@file       fanzhou_modbus.lua
@module     fanzhou_modbus
@version    0.1
@date       2025-05-20
@author     yankai
@brief      提供 Modbus RTU 协议的封装与串口通信支持，可用于串口设备通信
@description
  - 支持配置参数初始化
  - 支持 CRC16 校验、数据帧打包和解析
  - 提供串口收发、回调机制、定时发送功能
--]]


local version = "0.1"
local module  = "fanzhou_modbus"
local author = "yankai"


-- TODO 待修复

-- 默认配置
local DEFAULT_CONFIG = {
    is_485 = 0,
    uartid = 1, -- 串口ID
    baudrate = 9600, -- 波特率
    databits = 8, -- 数据位
    stopbits = 1, -- 停止位
    parity = uart.None, -- 校验位
    endianness = uart.LSB, -- 字节序
    buffer_size = 1024, -- 缓冲区大小
    gpio_485 = 27, -- 485转向GPIO
    rx_level = 0, -- 485模式下RX的GPIO电平
    tx_delay = 2000 -- 485模式下TX向RX转换的延迟时间（us）
}

local FzModbus = {}
FzModbus.__index = FzModbus

-- ===========================================================================
-- @function   FzModbus.new
-- @brief      创建 Modbus 对象并初始化串口
-- @param[in]  config table 用户自定义配置
-- @return     FzModbus 对象
-- ===========================================================================
function FzModbus.new(config)
    local self = setmetatable({}, FzModbus)

    -- 合并配置参数
    self.config = {}
    for key, default_value in pairs(DEFAULT_CONFIG) do
        if config and config[key] ~= nil then
            self.config[key] = config[key]
        else
            self.config[key] = default_value
        end
    end

    -- 初始化UART
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

    log.debug("FzModbus 当前串口初始化配置为:", json.encode(self.config))
    return self
end

-- ===========================================================================
-- @function   FzModbus:crc16
-- @brief      计算 CRC16 校验码
-- @param[in]  data string 要校验的数据
-- @return     number CRC 校验值
-- ===========================================================================
function FzModbus:crc16(data)
    local crc16_data = crypto.crc16_modbus(data)
    return crc16_data
end

-- ===========================================================================
-- @function   FzModbus:parse_frame
-- @brief      解析 Modbus RTU 数据帧并校验 CRC
-- @param[in]  data string 接收到的数据
-- @return     table|nil 有效帧数据或错误
-- ===========================================================================
function FzModbus:parse_frame(data)
    local str = data or 0X00
    local addr = str:byte(1) or 0X00 -- 地址位
    local fun = str:byte(2) or 0X00 -- 功能码
    local byte = str:byte(3) or 0X00 -- 有效字节数
    local payload = str:sub(4, 4 + byte - 1) or 0X00 -- 数据部分
    local crc_data = str:sub(-2, -1) or 0X00
    local idx, crc = pack.unpack(crc_data, "H") -- CRC校验值

    -- 校验CRC
    if crc == self:crc16(str:sub(1, -3)) then
        log.debug("modbus_rtu CRC校验成功")
        return {
            addr = addr,
            fun = fun,
            byte = byte,
            payload = payload,
            crc = crc
        }
    else
        log.debug("modbus_rtu CRC校验失败", crc)
        return nil, "CRC error"
    end
end

-- ===========================================================================
-- @function   FzModbus:build_frame
-- @brief      构建 Modbus RTU 数据帧（带 CRC）
-- @param[in]  addr number 从站地址
-- @param[in]  fun number 功能码
-- @param[in]  data string 数据部分
-- @return     string 构建完成的数据帧
-- ===========================================================================
function FzModbus:build_frame(addr, fun, data)
    local frame = string.char(addr, fun) .. data
    local crc = self:crc16(frame)
    local pack_crc = pack.pack("H", crc)
    return frame .. pack_crc
end

-- ===========================================================================
-- @function   FzModbus:send_command
-- @brief      发送 Modbus 指令，支持定时发送
-- @param[in]  addr number 从站地址
-- @param[in]  fun number 功能码
-- @param[in]  data string 数据内容
-- @param[in]  interval number? 定时间隔（可选）
-- ===========================================================================
function FzModbus:send_command(addr, fun, data, interval)
    local cmd = self:build_frame(addr, fun, data)
    if interval then
        sys.timerLoopStart(function()
            log.debug("每隔" .. interval .. "秒发一次指令", cmd:toHex())
            uart.write(self.config.uartid, cmd)
            if self.config.is_485 == 1 then  uart.wait485(self.config.uartid) end
        end, interval)
    else
        uart.write(self.config.uartid, cmd)
        log.debug("modbus send", cmd:toHex())
        if self.config.is_485 == 1 then  uart.wait485(self.config.uartid) end
    end
end

-- ===========================================================================
-- @function   FzModbus:read
-- @brief      读取串口数据
-- @return     string 串口接收到的数据
-- ===========================================================================
function FzModbus:read() 
    local s = ""
    s = uart.read(self.config.uartid, 128)
    return s
end


-- ===========================================================================
-- @function   FzModbus:set_receive_callback
-- @brief      设置串口接收回调函数
-- @param[in]  need_handle boolean 是否解析数据帧
-- @param[in]  callback function 回调函数
-- ===========================================================================
function FzModbus:set_receive_callback(need_handle, callback)
    uart.on(self.config.uartid, "receive", function(id, len)
        log.debug("UART"..id, "收到数据，长度", len)
        local s = ""
        repeat
            s = uart.read(id, 128)
            if #s > 0 then
                log.debug("modbus read", s:toHex())
                if need_handle == true then
                    local frame, err = self:parse_frame(s)
                    if frame then
                        callback(frame)
                    else
                        log.debug("modbus_rtu 数据错误", err)
                    end
                else
                    callback(s)
                end
            end
        until s == ""
    end)
end

-- ===========================================================================
-- @function   FzModbus:send_str
-- @brief      发送原始数据字符串，支持定时发送
-- @param[in]  data string 原始数据
-- @param[in]  interval number? 定时间隔（可选）
-- ===========================================================================
function FzModbus:send_str(data, interval)
    if interval then
        sys.timerLoopStart(function()
            log.debug("每隔" .. interval .. "秒发一次指令", data)
            uart.write(self.config.uartid, data)
            if self.config.is_485 == 1 then  uart.wait485(self.config.uartid) end
        end, interval)
    else
        uart.write(self.config.uartid, data)
        if self.config.is_485 == 1 then  uart.wait485(self.config.uartid) end
        log.debug("modbus send str", data)
    end
end

-- ===========================================================================
-- @function   FzModbus:set_sent_callback
-- @brief      设置串口发送完成的回调函数
-- @param[in]  callback function 发送完成后的回调函数
-- ===========================================================================
function FzModbus:set_sent_callback(callback)
    uart.on(self.config.uartid, "sent", function(id)
        log.debug("modbus read", id)
        if callback then
            callback(id)
        end
    end)
end

return FzModbus