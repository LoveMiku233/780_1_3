--[[
@file       fanzhou_tools.lua
@module     fanzhou_tools
@version    0.1
@date       2025-05-22
@author     yankai
@brief      常用工具函数集合，涵盖设备信息打印、Hex/Binary 转换、BCD 编码、校验计算等
@description
  - 打印设备网络与 SIM 卡信息
  - Hex 字符串与二进制/字节数组相互转换
  - BCD 编码与时间转换
  - 异或校验与 CRC 计算
--]]

local version = "0.1"
local module  = "fanzhou_tools"
local author = "yankai"

local _M = {}

-- ===========================================================================
-- @function   _M.printImei
-- @brief      打印设备的 IMEI、IMSI、SN、信号及网络状态等信息
-- @return     nil
-- ===========================================================================
function _M.printImei() 
    log.debug("imei", mobile.imei())
        log.debug("imsi", mobile.imsi())
        local sn = mobile.sn()
        if sn then
            log.debug("sn",   sn:toHex())
        end
        log.debug("status", mobile.status())


        log.debug("iccid", mobile.iccid())
        log.debug("csq", mobile.csq()) -- 4G模块的CSQ并不能完全代表强度
        log.debug("rssi", mobile.rssi()) -- 需要综合rssi/rsrq/rsrp/snr一起判断
        log.debug("rsrq", mobile.rsrq())
        log.debug("rsrp", mobile.rsrp())
        log.debug("snr", mobile.snr())
        log.debug("simid", mobile.simid()) -- 这里是获取当前SIM卡槽
        log.debug("apn", mobile.apn(0,1))
        log.debug("ip", socket.localIP())
        log.debug("lua", rtos.memdebug())
        -- sys内存
        log.debug("sys", rtos.memdebug("sys"))
end


-- ===========================================================================
-- @function   _M.check_crc
-- @brief      检查crc (兼容字符串和字节数组)
-- @return     是否正确
-- ===========================================================================
function _M.check_crc(data)
    -- 检查数据类型并统一处理
    local is_string = type(data) == "string"
    local len = is_string and #data or #data

    -- 确保数据长度足够包含 CRC
    if len < 2 then
        return false
    end

    -- CRC-16/MODBUS 参数
    local crc = 0xFFFF
    local poly = 0xA001  -- 0x8005 的位反转

    -- 计算除最后两个字节外的 CRC
    for i = 1, len - 2 do
        -- 根据数据类型获取字节
        local byte
        if is_string then
            byte = data:byte(i)   -- 字符串用 byte() 方法
        else
            byte = data[i]        -- 字节数组直接索引
        end
        
        crc = crc ~ byte
        for _ = 1, 8 do
            local lsb = crc & 1
            crc = crc >> 1
            if lsb == 1 then
                crc = crc ~ poly
            end
        end
    end

    -- 提取数据中的 CRC 值（小端序）
    local last1, last2
    if is_string then
        last1 = data:byte(len - 1)
        last2 = data:byte(len)
    else
        last1 = data[len - 1]
        last2 = data[len]
    end
    
    local received_crc = last1 | (last2 << 8)

    -- 比较计算出的 CRC 和接收到的 CRC
    return crc == received_crc
end

-- ===========================================================================
-- @function   _M.hexToBinary
-- @brief      将十六进制字符串转换为二进制字符串
-- @param[in]  hexStr string 十六进制表示，每两个字符对应一个字节
-- @return     string       二进制字符串
-- ===========================================================================
function _M.hexToBinary(hexStr)
    local binaryData = {}
    for i = 1, #hexStr, 2 do
        local byte = tonumber(hexStr:sub(i, i+1), 16) -- 每两个字符转换为一个字节
        table.insert(binaryData, string.char(byte))
    end
    return table.concat(binaryData) -- 拼接成二进制字符串
end

-- ===========================================================================
-- @function   _M.hex_to_bytes
-- @brief      将十六进制字符串转换为字节（数值）数组
-- @param[in]  hex_str string 十六进制字符串
-- @return     table         字节数值数组
-- ===========================================================================
function _M.hex_to_bytes(hex_str)
    local bytes = {}
    for i=1, #hex_str, 2 do
        bytes[#bytes+1] = tonumber(hex_str:sub(i, i+1), 16)
    end
    return bytes
end

-- ===========================================================================
-- @function   _M.stringToBytes
-- @brief      将十六进制字符串转换为字节数值数组（同 hex_to_bytes）
-- @param[in]  hexStr string 十六进制字符串
-- @return     table        字节数值数组
-- ===========================================================================
function _M.stringToBytes(hexStr)
    local bytes = {}
    for i = 1, #hexStr, 2 do
        local byteStr = hexStr:sub(i, i+1)
        local byte = tonumber(byteStr, 16)
        table.insert(bytes, byte)
    end
    return bytes
end

-- ===========================================================================
-- @function   _M.encodeBcdNum
-- @brief      对数字字符串进行 BCD 编码，不足位补零，多余截断
-- @param[in]  d string 数字字符串
-- @param[in]  n number 固定长度
-- @return     string     BCD 编码后的二进制字符串
-- ===========================================================================
function _M.encodeBcdNum(d, n)
    if d:len() < n then
        return (string.rep('0', n - d:len()) .. d):fromHex()
    else
        return (d:sub(1, n)):fromHex()
    end
end

-- ===========================================================================
-- @function   _M.calculateXor
-- @brief      计算十六进制字符串的异或校验值
-- @param[in]  data string 十六进制字符串
-- @return     number       异或校验结果
-- ===========================================================================
function _M.calculateXor(data)
    local sum = 0
    for i = 1, #data, 2 do
        local byte = tonumber(data:sub(i, i+1), 16)

        -- 检查是否转换成功
        if not byte then
           error("Invalid hex character in input string!")
           error(string.format("Invalid hex character: '%s' at position %d", byteStr, i))
        end

        -- 打印当前字节的值（十六进制和十进制）
        --print(string.format("当前字节: %s (十进制: %d)", byteStr, byte))
        sum = bit.bxor(sum, byte)
        -- 打印异或后的中间结果
        --print(string.format("异或后 sum = %d (十六进制: 0x%X)", sum, sum))
    end
    return sum
end

-- ===========================================================================
-- @function   _M.calCrc
-- @brief      调用异或函数计算 CRC，并打印结果
-- @param[in]  hexStr string 输入的十六进制字符串
-- @return     number       CRC 校验值
-- ===========================================================================
function _M.calCrc(hexStr)
    -- 解析hexStr转换为十六进制字符数组
    local byteArray = HexOutput(hexStr)
    -- 计算 CRC
    local crc = _M.calculateXor(byteArray)
    log.debug("CRCxor:",crc)
    -- 返回 CRC 值
    return crc
end

-- ===========================================================================
-- @function   _M.timeToBCD
-- @brief      获取当前时间，并转换为 BCD 格式字符串（YYMMDDhhmmss）
-- @return     string BCD 格式时间字符串
-- ===========================================================================
function _M.timeToBCD()
    local t = os.date("*t")

    -- 转换为BCD格式
    local year = string.format("%02d", t.year % 100)
    local month = string.format("%02d", t.month)
    local day = string.format("%02d", t.day)
    local hour = string.format("%02d", t.hour)
    local min = string.format("%02d", t.min)
    local sec = string.format("%02d", t.sec)

    -- 组合BCD格式字符串
    local bcdTime = year .. month .. day .. hour .. min .. sec

    return bcdTime
end

return _M