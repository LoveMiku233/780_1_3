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

local power_type_flag = 2  -- 默认两相电

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

local multi_sensor_data = {
    water_temp1 = 0.0,
    water_temp2 = 0.0,
    water_temp3 = 0.0,
    do_sat1 = 0.0,
    do_sat2 = 0.0,
    do_sat3 = 0.0,
    ph1 = 0.0,
    sw11 = 1,
    sw12 = 1,
    sw13 = 1,
    sw14 = 1,
    fault11 = 0,
    fault12 = 0,
    fault13 = 0,
    fault14 = 0,
    current11 = -1,
    current12 = -1,
    current13 = -1,
    current14 = -1,
}

local multi_sensor_data_old = {
    water_temp1 = 0.0,
    water_temp2 = 0.0,
    water_temp3 = 0.0,
    do_sat1 = 0.0,
    do_sat2 = 0.0,
    do_sat3 = 0.0,
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
}

-- 看门狗
if wdt then
    wdt.init(9000)
    sys.timerLoopStart(wdt.feed, 3000)
end

-- 1. 初始化串口和硬件
sys.taskInit(function()
    log.info("main", "start init uart")
    -- 初始化485
    gpio.setup(16, 0)
    gpio.setup(27, 1)
    gpio.setup(22, 1)
    sensor_485 = fzmodbus.new({uartid=1, gpio_485=16, is_485=1, baudrate=9600})
    ctrl_485 = fzmodbus.new({is_485=1, uartid=2, gpio_485=28, baudrate=9600})
    display_232 = fzmodbus.new({uartid=3, baudrate=115200})
    
    -- 初始化其他硬件
    fzrelays.init()
    fzkeys.init()
    bme.init()
    fzadcs.init(0, 4.0)
    rn8302b.init()
    supply.init()
    
    log.info("UART", "232显示屏接口初始化完成")
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
    
    -- 初始化FOTA
    log.info("FOTA", "开始固件更新检查")
    fzfota.init(config)
    fzfota.print_version()
    fzfota.start_timer_update()
    
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

-- 232屏幕数据解析函数 - 专门处理Modbus RTU协议
function display_232_parse(data)
    -- 记录原始数据
    log.info("DISPLAY_232_RAW", "收到原始数据(hex):", data:toHex())
    log.info("DISPLAY_232_RAW", "收到原始数据长度:", #data)
    
    -- 检查数据长度
    if #data == 0 then
        log.warn("DISPLAY_232", "收到空数据")
        return
    end
    
    -- 尝试解析Modbus RTU协议
    local modbus_data = parse_modbus_rtu(data)
    if modbus_data then
        log.info("DISPLAY_232", "Modbus RTU解析成功")
        process_modbus_command(modbus_data, "screen")
    else
        log.warn("DISPLAY_232", "Modbus RTU解析失败，尝试其他格式")
        
        -- 如果不是Modbus RTU，尝试JSON格式
        local clean_data = data:gsub("[\0\r\n]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if #clean_data > 0 then
            local json_data, err = json.decode(clean_data)
            if json_data then
                log.info("DISPLAY_232", "JSON解析成功")
                process_control_command(json_data, "screen")
            else
                log.warn("DISPLAY_232", "JSON解析失败:", err)
            end
        end
    end
end

-- 处理Modbus命令
function process_modbus_command(modbus_data, source)
    log.info("MODBUS_CMD", string.format("处理来自%s的Modbus命令", source))
    
    -- 只处理从机地址为1的命令（假设屏幕发送给地址1）
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
            
            -- 发送确认消息
            local ack_msg = json.encode({
                [key] = state, 
                result = "success",
                source = source,
                timestamp = os.time()
            })
            
            if source == "screen" and display_232 then
                display_232:send_str(ack_msg.."\r\n")
                log.info("MODBUS_CMD", "发送确认消息到屏幕:", ack_msg)
            end
            
            -- 上报状态变化
            update_changed_data({[key] = state})
        else
            log.warn("MODBUS_CMD", "未知的寄存器地址:", string.format("0x%04X", reg.address))
        end
    end
end

-- 云平台数据解析函数
function cloud_parse(data)
    log.info("CLOUD", "收到云平台数据:", data)
    
    local json_data = json.decode(data)
    if json_data == nil then
        log.warn("CLOUD", "JSON解析失败")
        return
    end
    
    -- 调用统一控制处理函数
    process_control_command(json_data, "cloud")
end

-- 统一控制命令处理函数（用于云平台JSON格式）
function process_control_command(json_data, source)
    log.info("CONTROL", string.format("来自%s的控制命令:", source), json.encode(json_data))
    
    for key, val in pairs(json_data) do
        -- 处理本机继电器控制
        if string.match(key, "^sw1[1-4]$") then
            local relay_name = relay_map[key]
            if relay_name then
                log.info("CONTROL", string.format("%s控制继电器 %s -> %s", source, relay_name, val == 1 and "ON" or "OFF"))
                
                -- 直接控制继电器
                fzrelays.set_mode(relay_name, val == 1 and "on" or "off")
                
                -- 更新状态数据
                multi_sensor_data[key] = val
                
                -- 发送确认消息
                local ack_msg = json.encode({
                    [key] = val, 
                    result = "success",
                    source = source,
                    timestamp = os.time()
                })
                
                -- 根据来源发送确认
                if source == "screen" and display_232 then
                    display_232:send_str(ack_msg.."\r\n")
                    log.info("CONTROL", "发送确认消息到屏幕:", ack_msg)
                elseif source == "cloud" and mqtt1 and mqtt1:get_is_connected() then
                    mqtt1:publish("$thing/up/event/"..imei, ack_msg, 0)
                    log.info("CONTROL", "发送确认消息到云平台:", ack_msg)
                end
                
                -- 上报状态变化
                update_changed_data({[key] = val})
                
            else
                log.warn("CONTROL", "未知的继电器:", key)
            end
            
        -- 处理远程控制板继电器
        elseif string.match(key, "^sw[2-4][1-4]$") then
            local ctrl_info = remote_ctrl_map[key]
            if ctrl_info and ctrl_485 then
                log.info("CONTROL", string.format("%s控制远程继电器 %s -> %s", source, key, val == 1 and "ON" or "OFF"))
                
                -- 通过485发送Modbus命令控制远程继电器
                ctrl_485:send_command(
                    ctrl_info.addr,
                    0x06,  -- 写单个寄存器
                    string.char(0x00, ctrl_info.reg, 0x00, val)
                )
                
                -- 发送确认消息
                local ack_msg = json.encode({
                    [key] = val, 
                    result = "success", 
                    source = source,
                    timestamp = os.time()
                })
                
                if source == "screen" and display_232 then
                    display_232:send_str(ack_msg.."\r\n")
                elseif source == "cloud" and mqtt1 and mqtt1:get_is_connected() then
                    mqtt1:publish("$thing/up/event/"..imei, ack_msg, 0)
                end
                
            else
                log.warn("CONTROL", "未知的远程继电器:", key)
            end
            
        -- 数据查询请求
        elseif key == "query" then
            log.info("CONTROL", string.format("%s请求数据查询", source))
            if val == "full" or val == 1 then
                -- 完整数据查询
                update_changed_data(multi_sensor_data)
            else
                -- 状态查询
                get_self_data()
            end
            
        -- 设备重启命令
        elseif key == "reboot" then
            log.warn("CONTROL", string.format("%s请求设备重启", source))
            local ack_msg = json.encode({
                reboot = "scheduled",
                result = "success",
                source = source,
                timestamp = os.time()
            })
            
            if source == "screen" and display_232 then
                display_232:send_str(ack_msg.."\r\n")
            elseif source == "cloud" and mqtt1 and mqtt1:get_is_connected() then
                mqtt1:publish("$thing/up/event/"..imei, ack_msg, 0)
            end
            
            -- 延迟重启
            sys.wait(2000)
            rtos.reboot()
            
        -- 心跳包响应
        elseif key == "heartbeat" then
            log.debug("CONTROL", string.format("收到%s心跳包", source))
            if source == "screen" and display_232 then
                display_232:send_str('{"heartbeat":"ack"}\r\n')
            elseif source == "cloud" and mqtt1 and mqtt1:get_is_connected() then
                mqtt1:publish("$thing/up/event/"..imei, '{"heartbeat":"ack"}', 0)
            end
            
        -- 固件更新检查
        elseif key == "check_update" then
            log.info("CONTROL", string.format("%s请求固件更新检查", source))
            if fzfota then
                fzfota.start_update()
                local ack_msg = json.encode({
                    check_update = "started",
                    result = "success",
                    source = source,
                    timestamp = os.time()
                })
                
                if source == "screen" and display_232 then
                    display_232:send_str(ack_msg.."\r\n")
                elseif source == "cloud" and mqtt1 and mqtt1:get_is_connected() then
                    mqtt1:publish("$thing/up/event/"..imei, ack_msg, 0)
                end
            end
        end
    end
end

-- 更新变化数据
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
        local display_data_str = json.encode(multi_sensor_data, "2f")
        log.info("UPDATE", "上传变化数据:", changed_data_str)
        
        -- 发送到232屏幕
        if display_232 then
            display_232:send_str(display_data_str.."\r\n")
            log.info("DISPLAY_232", "发送数据到屏幕")
        end
        
        -- 发送到MQTT云平台
        if mqtt1 and mqtt1:get_is_connected() then
            mqtt1:publish(pub_url, changed_data_str, 0)
            log.info("CLOUD", "发送数据到云平台")
        end
    else
        log.debug("UPDATE", "数据无变化")
    end
end

-- 传感器数据解析
function sensor_parse(data) 
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

-- 按键处理
sys.taskInit(function()
    while true do
        local _, key_name = sys.waitUntil("KEY")
        fzrelays.toggle(key_name)
        sys.wait(500)
    end
end)

-- 数据采集任务
sys.taskInit(function()
    -- 设置回调函数
    sensor_485:set_receive_callback(false, sensor_parse)
    display_232:set_receive_callback(false, display_232_parse)
    ctrl_485:set_receive_callback(false, ctrl_parse)
    
    -- 定时获取本机数据
    sys.timerLoopStart(get_self_data, 1000)
    
    while true do
        sys.wait(120000)
        supply.on("led_supply1")
        supply.on("led_supply2")
        sys.wait(120000)
        
        -- 读取传感器数据
        sensor_485:send_command(do_sat1_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(1000)
        sensor_485:send_command(do_sat2_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(1000)
        sensor_485:send_command(do_sat3_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(1000)
        sensor_485:send_command(ph1_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(2000)
        
        -- 读取控制板数据
        ctrl_485:send_command(0x02, 0x03, string.char(0x00, 0x00, 0x00, 0x14))
        sys.wait(1000)
        
        -- 关闭供电
        supply.off("led_supply1")
        supply.off("led_supply2")
        sys.wait(600000)
    end
end)

-- 网络状态监控
sys.taskInit(function()
    sys.wait(5000)
    while true do
        local status = net_switch.get_network_status()
        log.info("NET_MONITOR", 
            string.format("网络状态 - 当前: %s, 以太网: %d, 4G: %d", 
            status.current, status.ethernet, status.mobile_4g))
        
        sys.wait(30000)
    end
end)

sys.run()