PROJECT = "main"
VERSION = "000.000.300"
author = "yankai"

_G.sys     = require("sys")
_G.sysplus = require("sysplus")

log.setLevel("DEBUG")

-- 初始化网络
local config = require("config")
local bme = require("bme")
local fzmqtt = require("fz_mqtt")
local fzfota = require("fz_fota")
local fzmodbus = require("fz_modbus")
local fztools = require("fz_tools")
local fzkeys = require("fz_key")
local fzrelays = require("fz_relay")
local fzadcs = require("fz_adc")
local RX8025T = require("RX8025T")
local rn8302b = require("rn8302b")
local supply = require("supply")
local net_switch = require("net_switch")

-- 485 modbus
local ctrl_485 = nil
local sensor_485 = nil
local display_232 = nil
local ctrl_cmd_buffer = {}
-- mqtt
local mqtt1 = fzmqtt.new(config.mqtt)
-- imei
local imei = mobile.imei()

-- 订阅发布地址
local pub_url = "$thing/up/property/"..imei
local sub_url = "$thing/down/property/"..imei

-- 传感器地址
local do_sat1_addr = 0x0c
local do_sat2_addr = 0x05
local do_sat3_addr = 0x06
local do_sat4_addr = 0x07
local ph1_addr = 0x03
-- 控制板地址
local ctrl_addr = 0x02
local self_addr = 1

-- 两片RN8302B芯片的数据
local rn8302b_chip1_data = {0, 0, 0, 0, 0, 0}
local rn8302b_chip2_data = {0, 0, 0, 0, 0, 0}

-- 缺相检测配置
local PHASE_UNBALANCE_THRESHOLD_ABS = 2.5 
local PHASE_GROUP_CONFIG = {
    {channels = {1, 2, 3}, relay = "k1", chip = 1, fault_key = "fault11"},
    {channels = {4, 5, 6}, relay = "k2", chip = 1, fault_key = "fault12"},
    {channels = {1, 2, 3}, relay = "k3", chip = 2, fault_key = "fault13"},
    {channels = {4, 5, 6}, relay = "k4", chip = 2, fault_key = "fault14"}
}

local READ_GROUP_CONFIG = {
    {chip = 1, channels = {1, 2, 3}},
    {chip = 1, channels = {4, 5, 6}},
    {chip = 2, channels = {1, 2, 3}},
    {chip = 2, channels = {4, 5, 6}}
}

local phase_unbalance_status = {
    group1 = false,
    group2 = false, 
    group3 = false,
    group4 = false
}

local power_type_flag = 3  -- 默认两相电

local current_data = {
    chip1 = {0, 0, 0, 0, 0, 0},
    chip2 = {0, 0, 0, 0, 0, 0}
}

local net_config = {
    ethernet = {
        spi_id = 0,
        cs_pin = 8,
        type = netdrv.CH390,
        baudrate = 51200000,
        ping_ip = "202.89.233.101"
    },
    mobile_4g = {
        ping_ip = "202.89.233.101"
    }
}

local is_reconnecting = false

local command_cache = {}
local CACHE_TIMEOUT = 5 

local CONTROL_MODE = {
    ONE_SENSOR_CONTROL_FOUR_RELAYS = 1,  -- 一个传感器控制四个继电器
    ONE_SENSOR_CONTROL_ONE_RELAY = 2,    -- 一个传感器控制一个继电器
    TWO_SENSORS_CONTROL_FOUR_RELAYS = 3, -- 两个传感器控制四个继电器（传感器1控制K1K2，传感器2控制K3K4）
    THREE_SENSORS_CONTROL_FOUR_RELAYS = 4 -- 三个传感器控制四个继电器（传感器1控制K1，传感器2控制K2，传感器3控制K3K4）
}

-- 继电器操作延时配置
local RELAY_OPERATION_DELAY = {
    ON_DELAY = 1000,   -- 打开继电器延时2秒
    OFF_DELAY = 1000   -- 关闭继电器延时1秒
}

-- 当前控制模式，默认为一个传感器控制四个继电器
local current_control_mode = CONTROL_MODE.TWO_SENSORS_CONTROL_FOUR_RELAYS

-- 删除溶解氧自动控制相关配置

local multi_sensor_data = {
    water_temp1 = 0.0,
    water_temp2 = 0.0,
    water_temp3 = 0.0,
    water_temp4 = 0.0,
    do_sat1 = 0.0,
    do_sat2 = 0.0,
    do_sat3 = 0.0,
    do_sat4 = 0.0,
    ph1 = 0.0,
    sw11 = 0,
    sw12 = 0,
    sw13 = 0,
    sw14 = 0,
    fault11 = 0,
    fault12 = 0,
    fault13 = 0,
    fault14 = 0,
    current11 = 0,
    current12 = 0,
    current13 = 0,
    current14 = 0,
}

local multi_sensor_data_old = {
    water_temp1 = 0.0,
    water_temp2 = 0.0,
    water_temp3 = 0.0,
    water_temp4 = 0.0,
    do_sat1 = 0.0,
    do_sat2 = 0.0,
    do_sat3 = 0.0,
    do_sat4 = 0.0,
    ph1 = 0.0,
    sw11 = 0,
    sw12 = 0,
    sw13 = 0,
    sw14 = 0,
    fault11 = 0,
    fault12 = 0,
    fault13 = 0,
    fault14 = 0,
    current11 = 0,
    current12 = 0,
    current13 = 0,
    current14 = 0,
}

-- 继电器映射表 - 本机继电器
local relay_map = {
    ["sw11"] = "k1",
    ["sw12"] = "k2", 
    ["sw13"] = "k3",
    ["sw14"] = "k4"
}

-- Modbus寄存器到继电器的映射
local modbus_register_map = {
    [0x0001] = "k1",  -- 寄存器地址0001 -> K1
    [0x0002] = "k2",  -- 寄存器地址0002 -> K2  
    [0x0003] = "k3",  -- 寄存器地址0003 -> K3
    [0x0004] = "k4",  -- 寄存器地址0004 -> K4
}

-- 远程控制板映射表
local remote_ctrl_map = {
    ["sw21"] = {addr = 0x02, reg = 1},
    ["sw22"] = {addr = 0x02, reg = 2},
    ["sw23"] = {addr = 0x02, reg = 3},
    ["sw24"] = {addr = 0x02, reg = 4},
    ["sw31"] = {addr = 0x03, reg = 1},
    ["sw32"] = {addr = 0x03, reg = 2},
    ["sw33"] = {addr = 0x03, reg = 3},
    ["sw34"] = {addr = 0x03, reg = 4},
    ["sw41"] = {addr = 0x04, reg = 1},
    ["sw42"] = {addr = 0x04, reg = 2},
    ["sw43"] = {addr = 0x04, reg = 3},
    ["sw44"] = {addr = 0x04, reg = 4}
}

local MODBUS_SLAVE_ADDR = 0x01  -- 本机Modbus从站地址

-- 添加Modbus寄存器映射表
local modbus_holding_registers = {
    [0x0000] = 0,  -- 继电器K1状态
    [0x0001] = 0,  -- 继电器K2状态
    [0x0002] = 0,  -- 继电器K3状态
    [0x0003] = 0,  -- 继电器K4状态
    [0x0004] = 0,  -- 故障状态1
    [0x0005] = 0,  -- 故障状态2
    [0x0006] = 0,  -- 故障状态3
    [0x0007] = 0,  -- 故障状态4
    -- 电流值寄存器 (每个电流值占2个寄存器，32位浮点数)
    [0x0008] = 0, [0x0009] = 0,  -- 电流11
    [0x000A] = 0, [0x000B] = 0,  -- 电流12
    [0x000C] = 0, [0x000D] = 0,  -- 电流13
    [0x000E] = 0, [0x000F] = 0,  -- 电流14
    -- 传感器数据寄存器
    [0x0010] = 0,  -- 水温1 (实际值×10)
    [0x0011] = 0,  -- 溶解氧1 (实际值×100)
    [0x0012] = 0,  -- 水温2
    [0x0013] = 0,  -- 溶解氧2
    [0x0014] = 0,  -- 水温3
    [0x0015] = 0,  -- 溶解氧3
    [0x0016] = 0, [0x0017] = 0,  -- pH1 (32位浮点数)
    [0x0018] = CONTROL_MODE.ONE_SENSOR_CONTROL_FOUR_RELAYS  -- 控制模式
}

-- 看门狗
if wdt then
    wdt.init(9000)
    sys.timerLoopStart(wdt.feed, 3000)
end

-- ========== 控制模式设置函数 ==========
-- 设置控制模式
function set_control_mode(mode)
    if mode == CONTROL_MODE.ONE_SENSOR_CONTROL_FOUR_RELAYS or 
       mode == CONTROL_MODE.ONE_SENSOR_CONTROL_ONE_RELAY or
       mode == CONTROL_MODE.TWO_SENSORS_CONTROL_FOUR_RELAYS or
       mode == CONTROL_MODE.THREE_SENSORS_CONTROL_FOUR_RELAYS then
        
        current_control_mode = mode
        multi_sensor_data.control_mode = mode
        modbus_holding_registers[0x0018] = mode
        
        local mode_description = ""
        if mode == CONTROL_MODE.ONE_SENSOR_CONTROL_FOUR_RELAYS then
            mode_description = "一个传感器控制四个继电器"
        elseif mode == CONTROL_MODE.ONE_SENSOR_CONTROL_ONE_RELAY then
            mode_description = "一个传感器控制一个继电器"
        elseif mode == CONTROL_MODE.TWO_SENSORS_CONTROL_FOUR_RELAYS then
            mode_description = "两个传感器控制四个继电器（传感器1控制K1K2，传感器2控制K3K4）"
        elseif mode == CONTROL_MODE.THREE_SENSORS_CONTROL_FOUR_RELAYS then
            mode_description = "三个传感器控制四个继电器（传感器1控制K1，传感器2控制K2，传感器3控制K3K4）"
        end
        
        log.info("CONTROL_MODE", string.format("控制模式已设置为: %s", mode_description))
        
        -- 上报模式变化
        update_changed_data({control_mode = mode})
        
        return true
    else
        log.error("CONTROL_MODE", "无效的控制模式:", mode)
        return false
    end
end

-- 解析控制模式设置指令
function parse_control_mode_command(data)
    local bytes = {data:byte(1, #data)}
    
    -- 检查指令格式: FA 02 XX FE
    if bytes[1] == 0xFA and bytes[2] == 0x02 and bytes[4] == 0xFE then
        local mode = bytes[3]
        
        if mode == 0x01 then
            -- 设置为一个传感器控制四个继电器模式
            set_control_mode(CONTROL_MODE.ONE_SENSOR_CONTROL_FOUR_RELAYS)
            return true
        elseif mode == 0x02 then
            -- 设置为一个传感器控制一个继电器模式
            set_control_mode(CONTROL_MODE.ONE_SENSOR_CONTROL_ONE_RELAY)
            return true
        elseif mode == 0x03 then
            -- 设置为两个传感器控制四个继电器模式
            set_control_mode(CONTROL_MODE.TWO_SENSORS_CONTROL_FOUR_RELAYS)
            return true
        elseif mode == 0x04 then
            -- 设置为三个传感器控制四个继电器模式
            set_control_mode(CONTROL_MODE.THREE_SENSORS_CONTROL_FOUR_RELAYS)
            return true
        else
            log.warn("CONTROL_MODE", "未知的控制模式指令:", string.format("%02X", mode))
        end
    end
    
    return false
end

-- 修改232屏幕数据解析函数，移除自动控制相关解析
function display_232_parse(data)
    -- 记录原始数据
    log.info("DISPLAY_232_RAW", "收到原始数据(hex):", data:toHex())
    log.info("DISPLAY_232_RAW", "收到原始数据长度:", #data)
    
    -- 检查是否是控制模式设置指令
    if #data == 4 then
        local success = parse_control_mode_command(data)
        if success then
            log.info("CONTROL_MODE", "成功解析控制模式设置指令")
            return
        end
    end
    
    -- 原有的JSON解析逻辑
    local clean_data = data:gsub("[\0\r\n]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #clean_data > 0 then
        local json_data, err = json.decode(clean_data)
        if json_data then
            log.info("DISPLAY_232", "JSON解析成功")
            
            -- 处理屏幕确认消息
            if json_data.type == "key_ack" then
                log.info("KEY_ACK", string.format("屏幕确认收到按键%s状态", json_data.key or "unknown"))
                return
            elseif json_data.type == "sync_ack" then
                log.info("SYNC_ACK", "屏幕确认收到状态同步")
                return
            elseif json_data.type == "control_mode" then
                -- 处理控制模式设置
                handle_control_mode_setting(json_data)
                return
            end
            
            -- 处理控制命令
            process_control_command(json_data, "screen")
            return
        else
            log.warn("DISPLAY_232", "JSON解析失败:", err)
        end
    end
    
    -- 原有的Modbus RTU解析逻辑
    local modbus_data = parse_modbus_rtu(data)
    if modbus_data then
        log.info("DISPLAY_232", "Modbus RTU解析成功")
        process_modbus_command(modbus_data, "screen")
    else
        log.warn("DISPLAY_232", "Modbus RTU解析失败")
    end
end

-- 处理控制模式设置
function handle_control_mode_setting(control_data)
    log.info("CONTROL_MODE", "收到控制模式设置:", json.encode(control_data))
    
    if control_data.mode then
        local mode = tonumber(control_data.mode)
        if mode == CONTROL_MODE.ONE_SENSOR_CONTROL_FOUR_RELAYS or mode == CONTROL_MODE.ONE_SENSOR_CONTROL_ONE_RELAY then
            set_control_mode(mode)
        else
            log.error("CONTROL_MODE", "无效的控制模式值:", mode)
        end
    end
end

-- 修改云平台数据解析函数，移除自动控制相关处理
function cloud_parse(data)
    log.info("CLOUD", "收到云平台数据:", data)
    
    local json_data = json.decode(data)
    if json_data == nil then
        log.warn("CLOUD", "JSON解析失败")
        return
    end
    
    -- 处理控制模式设置
    if json_data.control_mode then
        handle_control_mode_setting(json_data.control_mode)
        return
    end
    
    -- 原有的控制命令处理
    process_control_command(json_data, "cloud")
end

-- 修正发送完整状态到屏幕函数
function send_full_status_to_screen()
    if not display_232 then
        log.warn("SCREEN", "232显示屏未初始化")
        return false
    end
    
    -- 获取所有状态数据
    local sw11 = multi_sensor_data.sw11 or 0
    local sw12 = multi_sensor_data.sw12 or 0
    local sw13 = multi_sensor_data.sw13 or 0
    local sw14 = multi_sensor_data.sw14 or 0
    
    local fault11 = multi_sensor_data.fault11 or 0
    local fault12 = multi_sensor_data.fault12 or 0
    local fault13 = multi_sensor_data.fault13 or 0
    local fault14 = multi_sensor_data.fault14 or 0
    
    -- 获取并处理电流值
    local current11 = multi_sensor_data.current11 or 0
    local current12 = multi_sensor_data.current12 or 0
    local current13 = multi_sensor_data.current13 or 0
    local current14 = multi_sensor_data.current14 or 0
    
    -- 四舍五入到两位小数
    current11 = math.floor(current11 * 100 + 0.5) / 100
    current12 = math.floor(current12 * 100 + 0.5) / 100
    current13 = math.floor(current13 * 100 + 0.5) / 100
    current14 = math.floor(current14 * 100 + 0.5) / 100
    
    log.info("CURRENT_SEND", string.format("发送电流值: %.2f, %.2f, %.2f, %.2f A", 
             current11, current12, current13, current14))
    
    -- 将浮点数转换为4字节大端序
    local function float_to_bytes_big_endian(value)
        local bytes = pack.pack(">f", value)  -- 大端序
        return bytes:byte(1), bytes:byte(2), bytes:byte(3), bytes:byte(4)
    end
    
    -- 获取字节
    local c11_b1, c11_b2, c11_b3, c11_b4 = float_to_bytes_big_endian(current11)
    local c12_b1, c12_b2, c12_b3, c12_b4 = float_to_bytes_big_endian(current12)
    local c13_b1, c13_b2, c13_b3, c13_b4 = float_to_bytes_big_endian(current13)
    local c14_b1, c14_b2, c14_b3, c14_b4 = float_to_bytes_big_endian(current14)
    
    -- 构建Modbus帧
    local slave_addr = 0x01
    local function_code = 0x03
    local byte_count = 0x20
    
    local data_part = string.char(
        -- 继电器状态
        0x00, sw11, 0x00, sw12, 0x00, sw13, 0x00, sw14,
        -- 缺相状态
        0x00, fault11, 0x00, fault12, 0x00, fault13, 0x00, fault14,
        -- 电流值（大端序）
        c11_b1, c11_b2, c11_b3, c11_b4,
        c12_b1, c12_b2, c12_b3, c12_b4,
        c13_b1, c13_b2, c13_b3, c13_b4,
        c14_b1, c14_b2, c14_b3, c14_b4
    )
    
    local frame_without_crc = string.char(slave_addr, function_code, byte_count) .. data_part
    local crc = calculate_modbus_crc(frame_without_crc)
    local modbus_frame = frame_without_crc .. string.char(bit.band(crc, 0xFF), bit.rshift(crc, 8))
    
     display_232:send_str(modbus_frame)
end

-- 1. 初始化串口和硬件
sys.taskInit(function()
    log.info("main", "start init uart")
    -- 初始化485
    --gpio.setup(16, 1)
    gpio.setup(27, 1)
    gpio.setup(22, 1)
    sensor_485 = fzmodbus.new({uartid=2, gpio_485=23, is_485=1, baudrate=9600})
    --ctrl_485 = fzmodbus.new({is_485=1, uartid=2, gpio_485=28, baudrate=9600})
    display_232 = fzmodbus.new({uartid=3, baudrate=115200})
    
    -- 初始化其他硬件
    fzrelays.init()
    fzkeys.init()
    bme.init()
    fzadcs.init(0, 4.0)
    rn8302b.init()
    supply.init()
    
    log.info("UART", "232显示屏接口初始化完成")
    send_full_status_to_screen()
end)

-- 2. 网络切换初始化
sys.taskInit(function()
    sys.wait(3000)
        
    log.info("main", "开始初始化网络切换...")
        
    local success = net_switch.init(net_config, network_status_callback)
    if not success then
        log.error("main", "网络切换初始化失败")
        return
    end
        
    log.info("main", "网络切换初始化完成，等待网络就绪...")
        sys.waitUntil("IP_READY", 30000)
        log.info("main", "网络已就绪，开始业务初始化...")
end)

-- 3. MQTT和FOTA初始化
sys.taskInit(function()
    -- 等待网络连接
    local network_wait_start = os.time()
    while not net_switch.is_connected() do
        if os.time() - network_wait_start > 60 then
            log.warn("MQTT", "等待网络超时，尝试继续初始化")
            break
        end
        log.info("MQTT", "等待网络连接...")
        sys.wait(2000)
    end
    
    log.info("MQTT", "开始初始化MQTT...")
    
    -- 更新配置
    config.mqtt.device_id = string.format("%s%s", config.mqtt.product_id, mobile.imei())
    config.update_url = string.format("###%s?imei=%s&productKey=%s&core=%s&version=%s", 
    config.FIRMWARE_URL, mobile.imei(), config.PRODUCT_KEY, rtos.version(), VERSION)
    
    
    -- 初始化MQTT
    mqtt1 = fzmqtt.new(config.mqtt)
    
    local mqtt_init_success = false
    local init_attempts = 0
    
    while not mqtt_init_success and init_attempts < 3 do
        init_attempts = init_attempts + 1
        
        if mqtt1:init() then
            if mqtt1:connect() then
                local mqtt_start = os.time()
                while os.time() - mqtt_start < 20 do
                    if mqtt1:get_is_connected() then
                        log.info("MQTT", "MQTT连接成功")
                        
                        local sub_ok = mqtt1:subscribe(sub_url, 0, cloud_parse)
                        if sub_ok then
                            log.info("MQTT", "订阅主题成功:", sub_url)
                            mqtt_init_success = true
                            
                            -- 上报完整设备状态
                            sys.wait(2000)
                            update_changed_data(multi_sensor_data)
                            break
                        else
                            log.error("MQTT", "订阅主题失败")
                        end
                    end
                    sys.wait(1000)
                end
            end
        end
        
        if not mqtt_init_success then
            log.warn("MQTT", "MQTT初始化失败，5秒后重试")
            sys.wait(5000)
        end
    end
    
    if not mqtt_init_success then
        log.error("MQTT", "MQTT初始化完全失败")
    end
end)

-- 网络状态回调
function network_status_callback(event_type, data)
    if event_type == "ethernet" then
        if data == 2 then
            log.info("NET_CALLBACK", "以太网连接成功")
        elseif data == 0 then
            log.warn("NET_CALLBACK", "以太网连接断开")
        end
    elseif event_type == "4g" then
        if data == 2 then
            log.info("NET_CALLBACK", "4G网络连接成功")
        elseif data == 0 then
            log.warn("NET_CALLBACK", "4G网络连接断开")
        end
    elseif event_type == "switch" then
        log.info("NET_CALLBACK", "网络切换到:", data)
        
        if data ~= "none" then
            sys.taskInit(function()
                sys.wait(3000)
                
                if mqtt1 then
                    log.info("MQTT_RECONNECT", "网络切换，重启MQTT连接...")
                    
                    mqtt1:close()
                    sys.wait(2000)
                    
                    mqtt1:init()
                    mqtt1:connect()
                    log.info("FOTA", "开始固件更新检查")
                    fzfota.init(config)
                    fzfota.print_version()
                    fzfota.start_timer_update()
                    local mqtt_start = os.time()
                    local reconnect_success = false
                    
                    while os.time() - mqtt_start < 30 do
                        if mqtt1:get_is_connected() then
                            log.info("MQTT_RECONNECT", "MQTT重新连接成功")
                            
                            -- 重新订阅主题
                            mqtt1:subscribe(sub_url, 0, cloud_parse)
                            
                            sys.wait(1000)
                            update_changed_data(multi_sensor_data)
                            reconnect_success = true
                            break
                        end
                        sys.wait(1000)
                    end
                end
            end)
        end
    end
end

-- Modbus RTU协议解析函数
function parse_modbus_rtu(data)
    log.info("MODBUS_RTU", "开始解析Modbus RTU数据")
    
    local payload = fztools.hex_to_bytes(data:toHex())
    if #payload < 8 then
        log.warn("MODBUS_RTU", "数据长度不足")
        return nil
    end
    
    -- 检查CRC校验
    if not fztools.check_crc(payload) then
        log.warn("MODBUS_RTU", "CRC校验失败")
        return nil
    end
    
    -- 解析Modbus RTU帧
    local slave_addr = payload[1]
    local function_code = payload[2]
    local start_addr = bit.lshift(payload[3], 8) + payload[4]
    local reg_count = bit.lshift(payload[5], 8) + payload[6]
    local byte_count = payload[7]
    
    log.info("MODBUS_RTU", string.format("从机地址: 0x%02X, 功能码: 0x%02X", slave_addr, function_code))
    log.info("MODBUS_RTU", string.format("起始地址: 0x%04X, 寄存器数量: %d", start_addr, reg_count))
    log.info("MODBUS_RTU", string.format("字节数: %d", byte_count))
    
    -- 只处理功能码0x10（写多个寄存器）
    if function_code == 0x10 then
        -- 解析写入的数据
        local register_data = {}
        for i = 1, reg_count do
            local data_index = 8 + (i-1)*2
            if data_index + 1 <= #payload then
                local value = bit.lshift(payload[data_index], 8) + payload[data_index + 1]
                table.insert(register_data, {
                    address = start_addr + i - 1,
                    value = value
                })
                log.info("MODBUS_RTU", string.format("寄存器 0x%04X = 0x%04X (%d)", 
                    start_addr + i - 1, value, value))
            end
        end
        
        return {
            slave_addr = slave_addr,
            function_code = function_code,
            registers = register_data
        }
    else
        log.warn("MODBUS_RTU", "不支持的功能码:", function_code)
        return nil
    end
end

-- 处理Modbus命令
function process_modbus_command(modbus_data, source)
    log.info("MODBUS_CMD", string.format("处理来自%s的Modbus命令", source))
    
    -- 只处理从机地址为1的命令
    if modbus_data.slave_addr ~= 0x01 then
        log.warn("MODBUS_CMD", "非本机从机地址:", modbus_data.slave_addr)
        return
    end
    
    -- 处理每个寄存器写入
    for _, reg in ipairs(modbus_data.registers) do
        local relay_name = modbus_register_map[reg.address]
        if relay_name then
            -- 寄存器值：0x0000表示关闭，0x0001表示开启
            local state = reg.value == 0x0001 and 1 or 0
            log.info("MODBUS_CMD", string.format("控制继电器 %s -> %s", relay_name, state == 1 and "ON" or "OFF"))
            
            -- 控制继电器
            fzrelays.set_mode(relay_name, state == 1 and "on" or "off")
            
            -- 更新状态数据
            local key = "sw1" .. string.sub(relay_name, 2)
            multi_sensor_data[key] = state   
            -- 上报状态变化
            update_changed_data({[key] = state})
        else
            log.warn("MODBUS_CMD", "未知的寄存器地址:", string.format("0x%04X", reg.address))
        end
    end
end

-- 修改手动控制命令处理，增加延时
function process_control_command(json_data, source)
    log.info("CONTROL", string.format("来自%s的控制命令:", source), json.encode(json_data))
    
    -- 生成命令指纹用于去重
    local command_fingerprint = json.encode(json_data) .. "_" .. source
    local current_time = os.time()
    
    -- 检查是否为重复命令
    if command_cache[command_fingerprint] and 
       current_time - command_cache[command_fingerprint] < CACHE_TIMEOUT then
        log.info("COMMAND_DEDUP", "检测到重复命令，跳过执行:", command_fingerprint)
        return
    end
    
    -- 缓存命令时间戳
    command_cache[command_fingerprint] = current_time
    -- 清理过期缓存
    for fp, time in pairs(command_cache) do
        if current_time - time > CACHE_TIMEOUT then
            command_cache[fp] = nil
        end
    end
    
    -- 原有命令处理逻辑
    for key, val in pairs(json_data) do
        -- 处理本机继电器控制
        if string.match(key, "^sw1[1-4]$") then
            local relay_name = relay_map[key]
            if relay_name then
                log.info("CONTROL", string.format("%s控制继电器 %s -> %s", source, relay_name, val == 1 and "ON" or "OFF"))
                
                -- 检查状态是否已经一致，避免不必要的操作
                local current_state = fzrelays.get_mode(relay_name)
                local target_state = val == 1 and "on" or "off"
                
                if (current_state == "on" and val == 1) or (current_state == "off" and val == 0) then
                    log.info("CONTROL", string.format("继电器 %s 状态已为目标状态，跳过", relay_name))
                else
                    -- 根据操作类型添加延时
                    if val == 1 then
                        -- 打开操作，添加较长延时
                        sys.wait(RELAY_OPERATION_DELAY.ON_DELAY)
                    else
                        -- 关闭操作，添加较短延时
                        sys.wait(RELAY_OPERATION_DELAY.OFF_DELAY)
                    end
                    
                    -- 控制继电器
                    fzrelays.set_mode(relay_name, target_state)
                    
                    -- 更新状态数据
                    multi_sensor_data[key] = val
                end
         
                -- 上报状态变化
                update_changed_data({[key] = val})
                
            else
                log.warn("CONTROL", "未知的继电器:", key)
            end    
        end
        -- 如果是云平台控制且本机继电器状态有变化，同步到屏幕
        if source == "cloud" then
            log.info("SCREEN_SYNC", "云平台控制导致继电器状态变化，同步到屏幕")
            send_full_status_to_screen()
        end
    end
end

-- 更新变化数据（只发送到MQTT，不发送到屏幕）
function update_changed_data(new_data)
    if type(new_data) ~= "table" then
        log.error("UPDATE", "无效数据:", type(new_data))
        return
    end

    local changed_data = {}
    local has_changes = false
    
    for key, new_value in pairs(new_data) do
        local old_value = multi_sensor_data_old[key]
        
        local should_update = false
        
        if old_value == nil then
            should_update = true
        else
            local new_type = type(new_value)
            local old_type = type(old_value)
            
            if new_type == "number" and old_type == "number" then
                if math.abs(new_value - old_value) > 0.1 then
                    should_update = true
                end
            elseif new_type == "string" and old_type == "string" then
                if new_value ~= old_value then
                    should_update = true
                end
            elseif new_type ~= old_type then
                should_update = true
            else
                if tostring(new_value) ~= tostring(old_value) then
                    should_update = true
                end
            end
        end
        
        if should_update then
            changed_data[key] = new_value
            multi_sensor_data_old[key] = new_value
            has_changes = true
            log.debug("UPDATE", string.format("字段 %s 变化: %s -> %s", 
                key, tostring(old_value), tostring(new_value)))
        end
    end
    
    if has_changes then
        local changed_data_str = json.encode(changed_data, "2f")
        log.info("UPDATE", "上传变化数据到MQTT:", changed_data_str)
        
        -- 只发送到MQTT云平台，不发送到屏幕

        mqtt1:publish(pub_url, changed_data_str, 0)
        send_full_status_to_screen()
        
        -- 注意：不再向屏幕发送完整数据，只通过按键状态和485原始数据同步
    else
        log.debug("UPDATE", "数据无变化")
    end
end

-- 传感器数据解析
function sensor_parse(data) 
    display_232:send_str(data)
    local payload = fztools.hex_to_bytes(data:toHex())
    if fztools.check_crc(payload) then
        if (payload[1] == do_sat1_addr) then
            multi_sensor_data.water_temp1 = (bit.lshift(payload[4], 8) + payload[5]) * 0.1
            multi_sensor_data.do_sat1 = (bit.lshift(payload[6], 8) + payload[7]) * 0.01
        elseif (payload[1] == do_sat2_addr) then
            multi_sensor_data.water_temp2 = (bit.lshift(payload[4], 8) + payload[5]) * 0.1
            multi_sensor_data.do_sat2 = (bit.lshift(payload[6], 8) + payload[7]) * 0.01
        elseif (payload[1] == do_sat3_addr) then
            multi_sensor_data.water_temp3 = (bit.lshift(payload[4], 8) + payload[5]) * 0.1
            multi_sensor_data.do_sat3 = (bit.lshift(payload[6], 8) + payload[7]) * 0.01
        elseif (payload[1] == do_sat4_addr) then
            multi_sensor_data.do_sat4 = (bit.lshift(payload[4], 4) + payload[5]) * 0.01
            multi_sensor_data.water_temp4 = (bit.lshift(payload[6], 4) + payload[7]) * 0.01
        elseif (payload[1] == ph1_addr) then
            _, multi_sensor_data.ph1 = pack.unpack(string.char(payload[4],payload[5],payload[6],payload[7]),">f")
        end
        update_changed_data(multi_sensor_data)
    else 
        log.info("crc", "parse err!")
    end
end

-- 控制板数据解析
function ctrl_parse(data)
    log.info("CTRL_485", "收到控制板数据")
    local payload = fztools.hex_to_bytes(data:toHex())
    if fztools.check_crc(payload) then
        if payload[1] == 0x02 and payload[2] == 0x03 then
            -- 解析远程控制板状态
            multi_sensor_data.sw21 = payload[5]
            multi_sensor_data.sw22 = payload[7]
            multi_sensor_data.sw23 = payload[9]
            multi_sensor_data.sw24 = payload[11]
            multi_sensor_data.fault21 = payload[13]
            multi_sensor_data.fault22 = payload[15]
            multi_sensor_data.fault23 = payload[17]
            multi_sensor_data.fault24 = payload[19]
            _, multi_sensor_data.current21 = pack.unpack(string.char(payload[20],payload[21],payload[22],payload[23]),">f")
            _, multi_sensor_data.current22 = pack.unpack(string.char(payload[24],payload[25],payload[26],payload[27]),">f")
            _, multi_sensor_data.current23 = pack.unpack(string.char(payload[28],payload[29],payload[30],payload[31]),">f")
            _, multi_sensor_data.current24 = pack.unpack(string.char(payload[32],payload[33],payload[34],payload[35]),">f")
        end
        update_changed_data(multi_sensor_data)
    else
        log.info("crc", "控制板数据CRC错误")
    end
end

-- 获取本机数据
function get_self_data()
    multi_sensor_data.sw11 = fzrelays.get_mode("k1")
    multi_sensor_data.sw12 = fzrelays.get_mode("k2")
    multi_sensor_data.sw13 = fzrelays.get_mode("k3")
    multi_sensor_data.sw14 = fzrelays.get_mode("k4")
    
    if rn8302b_chip1_data then
        multi_sensor_data.current11 = rn8302b_chip1_data[1] or 0
        multi_sensor_data.current12 = rn8302b_chip1_data[4] or 0
    end
    
    if rn8302b_chip2_data then
        multi_sensor_data.current13 = rn8302b_chip2_data[1] or 0
        multi_sensor_data.current14 = rn8302b_chip2_data[4] or 0
    end
    
    update_changed_data(multi_sensor_data)
end

-- RN8302B电流监测任务
sys.taskInit(function()
    if not rn8302b.init() then
        log.error("MAIN", "RN8302B初始化失败")
        return
    end
    
    sys.wait(2000)
    
    local read_cycle = 0
    local current_read_group = 1
    
    while true do
        read_cycle = read_cycle + 1
        
        local group_config = READ_GROUP_CONFIG[current_read_group]
        
        if group_config then
            log.debug("RN8302B_READ", string.format("读取: 芯片%d通道%d-%d", 
                group_config.chip, group_config.channels[1], group_config.channels[3]))
            
            local currents = {}
            for i, channel in ipairs(group_config.channels) do
                currents[channel] = rn8302b.read_single_current(group_config.chip, channel)
                sys.wait(30)
            end
            
            if group_config.chip == 1 then
                for channel, value in pairs(currents) do
                    rn8302b_chip1_data[channel] = value
                end
                for channel, value in pairs(currents) do
                    current_data.chip1[channel] = value
                end
            else
                for channel, value in pairs(currents) do
                    rn8302b_chip2_data[channel] = value
                end
                for channel, value in pairs(currents) do
                    current_data.chip2[channel] = value
                end
            end
            
            -- 更新到传感器数据结构
            if group_config.chip == 1 then
                if current_read_group == 1 then
                    multi_sensor_data.current11 = currents[1] or 0
                elseif current_read_group == 2 then
                    multi_sensor_data.current12 = currents[4] or 0
                end
            else
                if current_read_group == 3 then
                    multi_sensor_data.current13 = currents[1] or 0
                elseif current_read_group == 4 then
                    multi_sensor_data.current14 = currents[4] or 0
                end
            end
            
            log.debug("RN8302B_GROUP", string.format("组%d读取完成", current_read_group))
            
            current_read_group = current_read_group + 1
            if current_read_group > 4 then
                current_read_group = 1
                
                if read_cycle % 5 == 0 then
                    log.info("RN8302B_FULL", "芯片1电流:", 
                        string.format("[%.3f, %.3f, %.3f, %.3f, %.3f, %.3f]A", 
                        rn8302b_chip1_data[1] or 0, rn8302b_chip1_data[2] or 0, 
                        rn8302b_chip1_data[3] or 0, rn8302b_chip1_data[4] or 0,
                        rn8302b_chip1_data[5] or 0, rn8302b_chip1_data[6] or 0))
                    log.info("RN8302B_FULL", "芯片2电流:", 
                        string.format("[%.3f, %.3f, %.3f, %.3f, %.3f, %.3f]A", 
                        rn8302b_chip2_data[1] or 0, rn8302b_chip2_data[2] or 0, 
                        rn8302b_chip2_data[3] or 0, rn8302b_chip2_data[4] or 0,
                        rn8302b_chip2_data[5] or 0, rn8302b_chip2_data[6] or 0))
                end
            end
        end 
        sys.wait(500)
    end
end)

function calculate_modbus_crc(data_str)
    local crc = 0xFFFF
    for i = 1, #data_str do
        crc = bit.bxor(crc, data_str:byte(i))
        for _ = 1, 8 do
            local flag = bit.band(crc, 1)
            crc = bit.rshift(crc, 1)
            if flag == 1 then
                crc = bit.bxor(crc, 0xA001)
            end
        end
    end
    return crc
end

-- 按键处理任务
sys.taskInit(function()
    while true do
        local _, key_name = sys.waitUntil("KEY")
        
        log.info("KEY_PRESS", "检测到按键:", key_name)
        
        -- 切换继电器状态
        fzrelays.toggle(key_name)
        
        -- 等待状态稳定
        sys.wait(100)
        
        -- 获取继电器状态
        local state_value = fzrelays.get_mode(key_name)
        
        log.info("KEY_STATUS", string.format("继电器 %s 状态: %d", key_name, state_value))
        
        -- 更新本地数据
        local data_key = "sw1" .. string.sub(key_name, 2)
        multi_sensor_data[data_key] = state_value
        
        -- 发送完整状态数据到屏幕
        send_full_status_to_screen()
        
        -- 上报状态变化到MQTT
        update_changed_data({[data_key] = state_value})
        
        sys.wait(500)  -- 防抖延迟
    end
end)

-- 数据采集任务
sys.taskInit(function()
    -- 设置回调函数
    sensor_485:set_receive_callback(false,sensor_parse)
    
    display_232:set_receive_callback(false, display_232_parse)
    
    sys.timerLoopStart(get_self_data, 1000)
    
    while true do
        --sys.wait(120000)
        --supply.on("led_supply1")
        --supply.on("led_supply2")
        --sys.wait(120000)
        
        -- 读取传感器数据
        sensor_485:send_command(do_sat1_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(1000)
        sensor_485:send_command(do_sat2_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(1000)
        sensor_485:send_command(do_sat3_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(1000)
        sensor_485:send_command(do_sat4_addr, 0x03, string.char(0x00, 0x01, 0x00, 0x06))
        sys.wait(1000)
        sensor_485:send_command(ph1_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(2000)
       -- 关闭供电
        --supply.off("led_supply1")
        --supply.off("led_supply2")
        --sys.wait(600000)
    end
end)
       
sys.run()