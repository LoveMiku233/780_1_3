-- RX8025T实时时钟芯片驱动 for AIR780E
-- 解决主电源供电后时间重置问题

local RX8025T = {}
RX8025T.__index = RX8025T

-- 寄存器地址定义
local REG_SEC = 0x00    -- 秒
local REG_MIN = 0x01    -- 分
local REG_HOUR = 0x02   -- 时
local REG_WEEK = 0x03   -- 星期
local REG_DAY = 0x04    -- 日
local REG_MONTH = 0x05  -- 月
local REG_YEAR = 0x06   -- 年
local REG_CTRL1 = 0x0E  -- 控制寄存器1
local REG_CTRL2 = 0x0F  -- 控制寄存器2

-- I2C配置
local I2C_ID = 1
local I2C_ADDR = 0x32

-- 初始化状态标记
local initialized = false
local last_power_status = nil

-- 初始化I2C
local function i2c_init()
    return i2c.setup(I2C_ID, i2c.SLOW)
end

-- 十进制转BCD编码
local function dec_to_bcd(dec)
    return (math.floor(dec / 10) * 16) + (dec % 10)
end

-- BCD编码转十进制
local function bcd_to_dec(bcd)
    return (math.floor(bcd / 16) * 10) + (bcd % 16)
end

-- 检测电源状态（主电源或电池备份）
function RX8025T.get_power_status()
    i2c.send(I2C_ID, I2C_ADDR, REG_SEC)
    local sec_data = i2c.recv(I2C_ID, I2C_ADDR, 1)
    
    if sec_data and #sec_data == 1 then
        -- 检查秒寄存器的高位(振荡器停止标志)
        -- 如果设置了，表示曾经由电池供电
        local oscillator_stopped = bit.band(sec_data:byte(1), 0x80) ~= 0
        return oscillator_stopped and "battery" or "main"
    end
    return "unknown"
end

-- 清除振荡器停止标志
function RX8025T.clear_oscillator_stop_flag()
    i2c.send(I2C_ID, I2C_ADDR, REG_SEC)
    local sec_data = i2c.recv(I2C_ID, I2C_ADDR, 1)
    
    if sec_data and #sec_data == 1 then
        -- 清除振荡器停止标志
        i2c.send(I2C_ID, I2C_ADDR, {REG_SEC, bit.band(sec_data:byte(1), 0x7F)})
        return true
    end
    return false
end

-- 检查控制寄存器是否需要初始化
local function check_control_registers()
    -- 读取控制寄存器1
    i2c.send(I2C_ID, I2C_ADDR, REG_CTRL1)
    local ctrl1 = i2c.recv(I2C_ID, I2C_ADDR, 1)
    
    -- 读取控制寄存器2
    i2c.send(I2C_ID, I2C_ADDR, REG_CTRL2)
    local ctrl2 = i2c.recv(I2C_ID, I2C_ADDR, 1)
    
    -- 如果无法读取寄存器，则需要初始化
    if not ctrl1 or not ctrl2 or #ctrl1 ~= 1 or #ctrl2 ~= 1 then
        return true, 0x20, 0x00
    end
    
    -- 获取当前控制寄存器值
    local current_ctrl1 = ctrl1:byte(1)
    local current_ctrl2 = ctrl2:byte(1)
    
    -- 期望的控制寄存器值
    local expected_ctrl1 = 0x20  -- 正常模式，时间更新中断禁用
    local expected_ctrl2 = 0x00  -- 24小时模式，频率输出禁用
    
    -- 检查是否需要初始化
    local need_init = (bit.band(current_ctrl1, 0x3F) ~= expected_ctrl1) or (current_ctrl2 ~= expected_ctrl2)
    
    return need_init, expected_ctrl1, expected_ctrl2
end

-- 初始化RX8025T（智能初始化，避免时间重置）
function RX8025T.init()
    if initialized then
        return true  -- 已经初始化过，不需要再次初始化
    end
    
    if not i2c_init() then
        return false
    end
    
    -- 获取当前电源状态
    local current_power_status = RX8025T.get_power_status()
    last_power_status = current_power_status
    
    -- 检查控制寄存器是否需要初始化
    local need_init, ctrl1_val, ctrl2_val = check_control_registers()
    
    if current_power_status == "battery" then
        -- 如果是由电池供电，清除振荡器停止标志
        RX8025T.clear_oscillator_stop_flag()
        
        -- 只有在控制寄存器需要初始化时才设置
        if need_init then
            i2c.send(I2C_ID, I2C_ADDR, {REG_CTRL1, ctrl1_val})
            i2c.send(I2C_ID, I2C_ADDR, {REG_CTRL2, ctrl2_val})
        end
    else
        -- 如果是主电源供电，检查是否需要初始化控制寄存器
        if need_init then
            i2c.send(I2C_ID, I2C_ADDR, {REG_CTRL1, ctrl1_val})
            i2c.send(I2C_ID, I2C_ADDR, {REG_CTRL2, ctrl2_val})
        end
    end
    
    initialized = true
    return true
end

-- 检查是否需要设置时间（只在特定条件下设置）
function RX8025T.need_time_set()
    -- 获取当前电源状态
    local current_power_status = RX8025T.get_power_status()
    
    -- 如果电源状态发生变化（从电池切换到主电源），可能需要设置时间
    if last_power_status and last_power_status ~= current_power_status then
        -- 检查时间是否合理（年份在2000-2099之间）
        local time_data = RX8025T.read_time()
        if time_data and (time_data.year < 2000 or time_data.year > 2099) then
            return true
        end
    end
    
    last_power_status = current_power_status
    return false
end

-- 设置时间（安全版本，避免不必要的时间设置）
function RX8025T.safe_set_time(year, month, day, hour, min, sec)
    -- 确保已经初始化
    if not initialized then
        RX8025T.init()
    end
    
    -- 只有在需要时才设置时间
    if not RX8025T.need_time_set() then
        return true  -- 不需要设置时间
    end
    
    -- 参数验证
    year = year % 100
    month = math.max(1, math.min(12, month))
    day = math.max(1, math.min(31, day))
    hour = math.max(0, math.min(23, hour))
    min = math.max(0, math.min(59, min))
    sec = math.max(0, math.min(59, sec))
    
    -- 停止时钟更新
    i2c.send(I2C_ID, I2C_ADDR, {REG_CTRL1, 0x21})
    
    -- 写入时间数据 - 逐个寄存器写入
    i2c.send(I2C_ID, I2C_ADDR, {REG_SEC, dec_to_bcd(sec)})
    i2c.send(I2C_ID, I2C_ADDR, {REG_MIN, dec_to_bcd(min)})
    i2c.send(I2C_ID, I2C_ADDR, {REG_HOUR, dec_to_bcd(hour)})
    i2c.send(I2C_ID, I2C_ADDR, {REG_DAY, dec_to_bcd(day)})
    i2c.send(I2C_ID, I2C_ADDR, {REG_MONTH, dec_to_bcd(month)})
    i2c.send(I2C_ID, I2C_ADDR, {REG_YEAR, dec_to_bcd(year)})
    
    -- 恢复时钟更新
    i2c.send(I2C_ID, I2C_ADDR, {REG_CTRL1, 0x20})
    
    return true
end

-- 设置时间（强制设置，不考虑条件）
function RX8025T.set_time(year, month, day, hour, min, sec)
    -- 确保已经初始化
    if not initialized then
        RX8025T.init()
    end
    
    -- 参数验证
    year = year % 100
    month = math.max(1, math.min(12, month))
    day = math.max(1, math.min(31, day))
    hour = math.max(0, math.min(23, hour))
    min = math.max(0, math.min(59, min))
    sec = math.max(0, math.min(59, sec))
    
    -- 停止时钟更新
    i2c.send(I2C_ID, I2C_ADDR, {REG_CTRL1, 0x21})
    
    -- 写入时间数据 - 逐个寄存器写入
    i2c.send(I2C_ID, I2C_ADDR, {REG_SEC, dec_to_bcd(sec)})
    i2c.send(I2C_ID, I2C_ADDR, {REG_MIN, dec_to_bcd(min)})
    i2c.send(I2C_ID, I2C_ADDR, {REG_HOUR, dec_to_bcd(hour)})
    i2c.send(I2C_ID, I2C_ADDR, {REG_DAY, dec_to_bcd(day)})
    i2c.send(I2C_ID, I2C_ADDR, {REG_MONTH, dec_to_bcd(month)})
    i2c.send(I2C_ID, I2C_ADDR, {REG_YEAR, dec_to_bcd(year)})
    
    -- 恢复时钟更新
    i2c.send(I2C_ID, I2C_ADDR, {REG_CTRL1, 0x20})
    
    return true
end

-- 读取时间
function RX8025T.read_time()
    -- 确保已经初始化
    if not initialized then
        RX8025T.init()
    end
    
    -- 发送起始寄存器地址
    i2c.send(I2C_ID, I2C_ADDR, REG_SEC)
    
    -- 读取7个字节的时间数据
    local data = i2c.recv(I2C_ID, I2C_ADDR, 7)
    
    if not data or #data ~= 7 then
        return nil
    end
    
    -- 解析时间数据（不包含星期）
    local time_data = {
        sec = bcd_to_dec(bit.band(data:byte(1), 0x7F)),   -- 秒 (去掉振荡器状态位)
        min = bcd_to_dec(data:byte(2)),                   -- 分
        hour = bcd_to_dec(bit.band(data:byte(3), 0x3F)),  -- 时 (24小时模式)
        day = bcd_to_dec(data:byte(5)),                   -- 日
        month = bcd_to_dec(bit.band(data:byte(6), 0x1F)), -- 月
        year = bcd_to_dec(data:byte(7)) + 2000            -- 年 (假设为2000-2099)
    }
    
    return time_data
end

function RX8025T.format_time(time_data)
    if not time_data then return "无效时间" end
    
    return string.format("%04d-%02d-%02d %02d:%02d:%02d",
        time_data.year, time_data.month, time_data.day,
        time_data.hour, time_data.min, time_data.sec)
end

-- 检查设备是否连接
function RX8025T.check()
    -- 确保已经初始化
    if not initialized then
        RX8025T.init()
    end
    
    i2c.send(I2C_ID, I2C_ADDR, REG_CTRL1)
    local data = i2c.recv(I2C_ID, I2C_ADDR, 1)
    
    return data and #data == 1
end

return RX8025T