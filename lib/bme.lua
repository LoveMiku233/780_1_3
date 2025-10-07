local bme = {}
local i2cid = 1 -- Air 780EPM 通常使用 I2C ID 2
local i2c_speed = i2c.FAST

-- BME280/BMP280 寄存器地址
local BME_ADDR = 0x76 -- BMP280 通常使用 0x76 地址
local BME_CHIP_ID = 0xD0
local BME_RST_REG = 0xE0
local BME_CTRL_HUMIDITY_REG = 0xF2 -- BMP280 没有这个寄存器
local BME_CTRL_MEAS_REG = 0xF4
local BME_CONFIG_REG = 0xF5
local BME_PRESSURE_MSB_REG = 0xF7
local BME_TEMPERATURE_CALIB_DIG_T1_LSB_REG = 0x88

-- 工作模式
local BME_SLEEP_MODE = 0x00
local BME_FORCED_MODE = 0x01
local BME_NORMAL_MODE = 0x03

-- 过采样率
local BME_OVERSAMP_SKIPPED = 0x00
local BME_OVERSAMP_1X = 0x01
local BME_OVERSAMP_2X = 0x02
local BME_OVERSAMP_4X = 0x03
local BME_OVERSAMP_8X = 0x04
local BME_OVERSAMP_16X = 0x05

-- 配置参数
local BME_PRESSURE_OSR = BME_OVERSAMP_8X
local BME_TEMPERATURE_OSR = BME_OVERSAMP_16X
local BME_MODE = bit.bor(bit.lshift(BME_PRESSURE_OSR, 2), bit.lshift(BME_TEMPERATURE_OSR, 5), BME_NORMAL_MODE)

-- 校准数据结构
local bmeCal = {
    dig_T1 = 0, dig_T2 = 0, dig_T3 = 0,
    dig_P1 = 0, dig_P2 = 0, dig_P3 = 0, dig_P4 = 0, dig_P5 = 0,
    dig_P6 = 0, dig_P7 = 0, dig_P8 = 0, dig_P9 = 0,
    t_fine = 0
}

local isInit = false
local bmeRawPressure = 0
local bmeRawTemperature = 0
local sensorType = "UNKNOWN" -- BME280 或 BMP280

-- 读取寄存器值
local function readReg(addr, reg, len)
    if i2c.send(i2cid, addr, reg) then
        local data = i2c.recv(i2cid, addr, len)
        if data and #data == len then
            return data
        else
           -- log.warn("BME", "读取寄存器失败", reg, "长度:", #data, "期望:", len)
        end
    else
        --log.warn("BME", "发送寄存器地址失败", reg)
    end
    return nil
end

-- 写入寄存器值
local function writeReg(addr, reg, value)
    if i2c.send(i2cid, addr, string.char(reg, value)) then
        return true
    else
        --log.warn("BME", "写入寄存器失败", reg, value)
        return false
    end
end

-- 初始化BME280/BMP280
function bme.init()
    if isInit then
        return true
    end
    
    -- 初始化I2C
    if i2c.setup(i2cid, i2c_speed) ~= i2c_speed then
        --log.error("BME", "I2C初始化失败")
        return false
    end
    
    --log.info("BME", "I2C初始化成功")
    sys.wait(20)
    
    -- 检查芯片ID
    local chip_id_data = readReg(BME_ADDR, BME_CHIP_ID, 1)
    if not chip_id_data then
        --log.error("BME", "无法读取芯片ID")
        return false
    end
    
    local chip_id = string.byte(chip_id_data)
    --log.info("BME", "芯片ID:", string.format("0x%X", chip_id))
    
    -- 确定传感器类型
    if chip_id == 0x58 then
        sensorType = "BMP280"
        log.info("BME", "检测到BMP280传感器")
    elseif chip_id == 0x60 then
        sensorType = "BME280"
        log.info("BME", "检测到BME280传感器")
    else
        --log.error("BME", "未知传感器类型")
        return false
    end
    
    -- 读取温度校准数据
    local calib_data = readReg(BME_ADDR, BME_TEMPERATURE_CALIB_DIG_T1_LSB_REG, 24)
    if not calib_data or #calib_data ~= 24 then
        log.error("BME", "读取温度校准数据失败")
        return false
    end
    
    -- 解析校准数据
    bmeCal.dig_T1 = string.unpack("<H", calib_data, 1)
    bmeCal.dig_T2 = string.unpack("<h", calib_data, 3)
    bmeCal.dig_T3 = string.unpack("<h", calib_data, 5)
    bmeCal.dig_P1 = string.unpack("<H", calib_data, 7)
    bmeCal.dig_P2 = string.unpack("<h", calib_data, 9)
    bmeCal.dig_P3 = string.unpack("<h", calib_data, 11)
    bmeCal.dig_P4 = string.unpack("<h", calib_data, 13)
    bmeCal.dig_P5 = string.unpack("<h", calib_data, 15)
    bmeCal.dig_P6 = string.unpack("<h", calib_data, 17)
    bmeCal.dig_P7 = string.unpack("<h", calib_data, 19)
    bmeCal.dig_P8 = string.unpack("<h", calib_data, 21)
    bmeCal.dig_P9 = string.unpack("<h", calib_data, 23)
    
    log.info("BME", "温度校准数据读取成功")
    log.info("BME", "dig_T1:", bmeCal.dig_T1)
    log.info("BME", "dig_T2:", bmeCal.dig_T2)
    log.info("BME", "dig_T3:", bmeCal.dig_T3)
    
    -- 配置传感器
    if not writeReg(BME_ADDR, BME_CTRL_MEAS_REG, BME_MODE) then
        log.warn("BME", "配置测量控制寄存器失败")
    end
    
    if not writeReg(BME_ADDR, BME_CONFIG_REG, bit.lshift(5, 2)) then
        log.warn("BME", "配置寄存器失败")
    end
    
    isInit = true
    log.info("BME", "初始化完成")
    return true
end

-- 读取原始数据
local function bmeGetRawData()
    local data_len = (sensorType == "BME280") and 8 or 6
    local data = readReg(BME_ADDR, BME_PRESSURE_MSB_REG, data_len)
    if not data or #data ~= data_len then
        log.warn("BME", "读取原始数据失败")
        return false
    end
    
    -- 解析压力和温度数据
    bmeRawPressure = bit.bor(
        bit.lshift(string.byte(data, 1), 12), 
        bit.lshift(string.byte(data, 2), 4),
        bit.rshift(string.byte(data, 3), 4)
    )
    
    bmeRawTemperature = bit.bor(
        bit.lshift(string.byte(data, 4), 12), 
        bit.lshift(string.byte(data, 5), 4),
        bit.rshift(string.byte(data, 6), 4)
    )
    
    log.info("BME", "Raw Pressure:", bmeRawPressure)
    log.info("BME", "Raw Temperature:", bmeRawTemperature)
    
    return true
end

-- 温度补偿计算
local function bmeCompensateT(adcT)
    local var1, var2, T
    
    -- 确保使用有符号整数运算
    adcT = adcT & 0xFFFFFFFF  -- 确保32位
    
    var1 = (bit.rshift(adcT, 3) - (bmeCal.dig_T1 * 2))
    var1 = (var1 * bmeCal.dig_T2) / 2048
    
    var2 = (bit.rshift(adcT, 4) - bmeCal.dig_T1)
    var2 = (var2 * var2) / 4096
    var2 = (var2 * bmeCal.dig_T3) / 16384
    
    bmeCal.t_fine = var1 + var2
    T = (bmeCal.t_fine * 5 + 128) / 256
    
    log.info("BME", "Compensated T:", T, "t_fine:", bmeCal.t_fine)
    return T
end

-- 气压补偿计算
local function bmeCompensateP(adcP)
    local var1, var2, p
    
    var1 = bmeCal.t_fine / 2 - 64000
    var2 = var1 * var1 * bmeCal.dig_P6 / 32768
    var2 = var2 + var1 * bmeCal.dig_P5 * 2
    var2 = var2 / 4 + bmeCal.dig_P4 * 65536
    
    var1 = (bmeCal.dig_P3 * var1 * var1 / 524288 + bmeCal.dig_P2 * var1) / 524288
    var1 = (1 + var1 / 32768) * bmeCal.dig_P1
    
    if var1 == 0 then
        return 0
    end
    
    p = 1048576 - adcP
    p = (p - var2 / 4096) * 6250 / var1
    var1 = bmeCal.dig_P9 * p * p / 2147483648
    var2 = p * bmeCal.dig_P8 / 32768
    p = p + (var1 + var2 + bmeCal.dig_P7) / 16
    
    log.info("BME", "Compensated P:", p)
    return p
end

-- 获取传感器数据
function bme.getData()
    if not isInit then
        if not bme.init() then
            return nil, nil, nil
        end
    end
    
    if not bmeGetRawData() then
        return nil, nil, nil
    end
    
    -- 计算温度和气压
    local t = bmeCompensateT(bmeRawTemperature) / 100.0
    local p = bmeCompensateP(bmeRawPressure) / 100.0  -- 转换为hPa
    
    -- BMP280 没有湿度传感器
    local h = (sensorType == "BME280") and 50.0 or nil  -- 临时值，BMP280返回nil
    
    log.info("BME", "Final Values - P:", p, "T:", t, "H:", h)
    
    return p, t, h
end

-- 获取传感器类型
function bme.getSensorType()
    return sensorType
end

return bme