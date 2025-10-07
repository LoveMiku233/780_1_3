local RN8302B = {}

-- 默认GPIO引脚配置
RN8302B.config = {
    SPI_CS1 = 5,   -- 第一个RN8302B片选
    SPI_CS2 = 4,   -- 第二个RN8302B片选
    SPI_CLK = 3,   -- 时钟引脚
    SPI_MISO = 6,  -- 主入从出
    SPI_MOSI = 7,  -- 主出从入
    calibration_factor = 0.01203,  -- 校准系数
    division_factor = 100000,      -- 分频系数
    delay_count = 1000             -- 软件延时计数器（替代sys.wait）
}

-- 内部变量
local cs1, cs2 = nil, nil

-- 软件延时函数（替代sys.wait，避免协程问题）
local function software_delay(count)
    for i = 1, count do
        -- 空循环实现延时
    end
end

-- 初始化RN8302B
function RN8302B.init(config_table)
    if config_table then
        for k, v in pairs(config_table) do
            RN8302B.config[k] = v
        end
    end
    
    -- 初始化GPIO引脚
    cs1 = gpio.setup(RN8302B.config.SPI_CS1, 1, gpio.PULLUP)
    cs2 = gpio.setup(RN8302B.config.SPI_CS2, 1, gpio.PULLUP)
    
    if not cs1 or not cs2 then
        log.error("RN8302B", "GPIO初始化失败")
        return false
    end
    
    log.info("RN8302B", "初始化完成")
    return true
end

-- 软件SPI单字节传输（移除sys.wait）
local function spi_transfer_byte(byte)
    local clk = gpio.setup(RN8302B.config.SPI_CLK, 0)
    local mosi = gpio.setup(RN8302B.config.SPI_MOSI, 0)
    local miso = gpio.setup(RN8302B.config.SPI_MISO, nil, gpio.PULLUP)
    
    local received_byte = 0
    
    for bit_pos = 7, 0, -1 do
        -- 设置MOSI
        local bit_val = (byte >> bit_pos) & 1
        mosi(bit_val)
        software_delay(RN8302B.config.delay_count)  -- 使用软件延时
        
        -- 时钟上升沿
        clk(1)
        software_delay(RN8302B.config.delay_count)
        
        -- 读取MISO
        local miso_bit = miso()
        received_byte = (received_byte << 1) | miso_bit
        software_delay(RN8302B.config.delay_count)
        
        -- 时钟下降沿
        clk(0)
        software_delay(RN8302B.config.delay_count)
    end
    
    return received_byte
end

-- 读取单个寄存器（移除sys.wait）
local function read_register(nSPI_CS, reg_addr)
    local cs_pin = (nSPI_CS == 1) and cs1 or cs2
    
    cs_pin(0)  -- 片选使能
    software_delay(RN8302B.config.delay_count * 2)  -- 延长片选等待时间
    
    -- 发送寄存器地址和读命令
    spi_transfer_byte(reg_addr)  -- 发送寄存器地址
    spi_transfer_byte(0x00)      -- 发送读命令
    
    -- 读取4个数据字节
    local data1 = spi_transfer_byte(0x00)
    local data2 = spi_transfer_byte(0x00)
    local data3 = spi_transfer_byte(0x00)
    local data4 = spi_transfer_byte(0x00)
    
    -- 额外读取一个字节（时序需要）
    spi_transfer_byte(0x00)
    
    cs_pin(1)  -- 取消片选
    
    -- 组合32位数据
    local data = (data1 << 24) | (data2 << 16) | (data3 << 8) | data4
    return data
end

-- 读取所有电流值
function RN8302B.read_all_currents(nSPI_CS)
    local currents = {0, 0, 0, 0, 0, 0}
    
    -- 电流值对应的寄存器地址
    local current_registers = {
        0x0B,  -- 电流1
        0x0C,  -- 电流2  
        0x0D,  -- 电流3
        0x07,  -- 电流4
        0x08,  -- 电流5
        0x09   -- 电流6
    }
    
    for i, reg_addr in ipairs(current_registers) do
        local raw_data = read_register(nSPI_CS, reg_addr)
        
        -- 转换为电流值
        if raw_data ~= 0 and raw_data ~= 0xFFFFFFFF then
            currents[i] = (raw_data / RN8302B.config.division_factor) * RN8302B.config.calibration_factor
        else
            currents[i] = 0
        end
    end
    
    return currents
end

-- 读取单个电流值
function RN8302B.read_single_current(nSPI_CS, channel)
    if channel < 1 or channel > 6 then
        log.error("RN8302B", "无效的通道号:", channel)
        return 0
    end
    
    local register_map = {
        [1] = 0x0B, [2] = 0x0C, [3] = 0x0D,
        [4] = 0x07, [5] = 0x08, [6] = 0x09
    }
    
    local reg_addr = register_map[channel]
    local raw_data = read_register(nSPI_CS, reg_addr)
    
    if raw_data ~= 0 and raw_data ~= 0xFFFFFFFF then
        return (raw_data / RN8302B.config.division_factor) * RN8302B.config.calibration_factor
    else
        return 0
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

-- 设置延时参数（用于调整SPI速度）
function RN8302B.set_delay(delay_count)
    if delay_count then
        RN8302B.config.delay_count = delay_count
        log.info("RN8302B", "延时参数已更新:", delay_count)
    end
end

-- 获取库版本信息
function RN8302B.version()
    return "RN8302B库 v1.0.0 (修正版)"
end

return RN8302B