local RN8302B = {}

-- 配置
RN8302B.config = {
    SPI_CS1 = 5,   -- 第一个RN8302B片选
    SPI_CS2 = 4,   -- 第二个RN8302B片选
    SPI_CLK = 3,   -- 时钟引脚
    SPI_MISO = 6,  -- 主入从出
    SPI_MOSI = 7,  -- 主出从入
    calibration_factor = 0.01203,  -- 校准系数
    division_factor = 100000,      -- 分频系数
    delay_us = 5                  -- 微秒级延时（关键修改）
}

-- 初始化GPIO
function RN8302B.init(config_table)
    if config_table then
        for k, v in pairs(config_table) do
            RN8302B.config[k] = v
        end
    end
    
    -- 初始化GPIO引脚（只初始化一次，避免重复初始化）
    if not RN8302B.cs1 then
        RN8302B.cs1 = gpio.setup(RN8302B.config.SPI_CS1, 1, gpio.PULLUP)
    end
    if not RN8302B.cs2 then
        RN8302B.cs2 = gpio.setup(RN8302B.config.SPI_CS2, 1, gpio.PULLUP)
    end
    
    -- 初始化SPI引脚（固定为模块变量）
    if not RN8302B.clk then
        RN8302B.clk = gpio.setup(RN8302B.config.SPI_CLK, 0)
        RN8302B.clk(0)  -- 初始低电平
    end
    if not RN8302B.mosi then
        RN8302B.mosi = gpio.setup(RN8302B.config.SPI_MOSI, 0)
        RN8302B.mosi(0)  -- 初始低电平
    end
    if not RN8302B.miso then
        RN8302B.miso = gpio.setup(RN8302B.config.SPI_MISO, nil, gpio.PULLUP)
    end
    
    log.info("RN8302B", "软件SPI初始化完成")
    return true
end

-- 微秒级硬件延时（关键函数）
local function delay_us(us)
    -- 使用mcu.ticks实现精确延时
        -- 使用循环计数实现近似延时
        local start = mcu.ticks()
        while mcu.ticks() - start < us do
            -- 空循环等待
        end
end

-- 软件SPI单字节传输（使用硬件延时）
local function spi_transfer_byte(byte)
    local received_byte = 0
    
    for bit_pos = 7, 0, -1 do
        -- 设置MOSI（时钟上升沿前稳定）
        local bit_val = (byte >> bit_pos) & 1
        RN8302B.mosi(bit_val)
        delay_us(RN8302B.config.delay_us)  -- 建立时间
        
        -- 时钟上升沿
        RN8302B.clk(1)
        delay_us(RN8302B.config.delay_us)  -- 保持时间
        
        -- 读取MISO（在时钟上升沿后读取）
        local miso_bit = RN8302B.miso()
        received_byte = (received_byte << 1) | miso_bit
        delay_us(RN8302B.config.delay_us)
        
        -- 时钟下降沿
        RN8302B.clk(0)
        delay_us(RN8302B.config.delay_us)  -- 时钟低电平时间
    end
    
    return received_byte
end

-- 读取单个寄存器
local function read_register(nSPI_CS, reg_addr)
    local cs_pin = (nSPI_CS == 1) and RN8302B.cs1 or RN8302B.cs2
    
    cs_pin(0)  -- 片选使能
    delay_us(10)  -- 片选使能到第一个时钟的延时
    
    -- 发送寄存器地址
    spi_transfer_byte(reg_addr)  -- 寄存器地址
    spi_transfer_byte(0x00)      -- 读命令（固定0x00）
    
    -- 读取4个数据字节
    local data1 = spi_transfer_byte(0x00)
    local data2 = spi_transfer_byte(0x00)
    local data3 = spi_transfer_byte(0x00)
    local data4 = spi_transfer_byte(0x00)
    
    -- 额外读取一个字节（有些SPI时序需要）
    spi_transfer_byte(0x00)
    
    cs_pin(1)  -- 取消片选
    delay_us(10)  -- 片选取消后的延时
    
    -- 组合32位数据
    local data = (data1 << 24) | (data2 << 16) | (data3 << 8) | data4
    
    -- 调试日志
    log.debug("RN8302B_READ", string.format("芯片%d 地址0x%02X: 0x%08X", 
        nSPI_CS, reg_addr, data))
    
    return data
end

-- 读取单个电流值（带滤波）
function RN8302B.read_single_current(nSPI_CS, channel, samples)
    samples = samples or 1  -- 默认采样1次
    
    if channel < 1 or channel > 6 then
        log.error("RN8302B", "无效的通道号:", channel)
        return 0
    end
    
    local register_map = {
        [1] = 0x0B, [2] = 0x0C, [3] = 0x0D,
        [4] = 0x07, [5] = 0x08, [6] = 0x09
    }
    
    local reg_addr = register_map[channel]
    local sum = 0
    local valid_samples = 0
    
    -- 多次采样取平均值
    for i = 1, samples do
        local raw_data = read_register(nSPI_CS, reg_addr)
        
        -- 检查数据有效性
        if raw_data ~= 0 and raw_data ~= 0xFFFFFFFF then
            local current = (raw_data / RN8302B.config.division_factor) * 
                           RN8302B.config.calibration_factor
            sum = sum + current
            valid_samples = valid_samples + 1
            
        else
            log.warn("RN8302B", string.format("芯片%d通道%d 采样%d无效: 0x%08X", 
                nSPI_CS, channel, i, raw_data))
        end
        
        -- 采样间隔
        if i < samples then
            delay_us(100)  -- 100us采样间隔
        end
    end
    
    if valid_samples > 0 then
        local avg_current = sum / valid_samples
        
        -- 添加小电流噪声过滤
        if avg_current < 0.01 then
            avg_current = 0
        end
        
        log.debug("RN8302B_RESULT", string.format("芯片%d通道%d: %.3fA (平均%d次)", 
            nSPI_CS, channel, avg_current, valid_samples))
        
        return avg_current
    else
        log.error("RN8302B", string.format("芯片%d通道%d: 所有采样无效", nSPI_CS, channel))
        return 0
    end
end

-- 读取所有电流值
function RN8302B.read_all_currents(nSPI_CS, samples)
    local currents = {0, 0, 0, 0, 0, 0}
    
    for channel = 1, 6 do
        currents[channel] = RN8302B.read_single_current(nSPI_CS, channel, samples or 1)
        delay_us(50)  -- 通道间延时
    end
    
    return currents
end

-- 设置延时参数
function RN8302B.set_delay(delay_us)
    if delay_us then
        RN8302B.config.delay_us = delay_us
        log.info("RN8302B", "延时参数已更新:", delay_us, "us")
    end
end

-- 设置校准参数
function RN8302B.set_calibration(division, calibration)
    if division then
        RN8302B.config.division_factor = division
    end
    if calibration then
        RN8302B.config.calibration_factor = calibration
    end
    log.info("RN8302B", "校准参数已更新")
end

return RN8302B