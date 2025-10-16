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

-- 缺相检测配置 - 两个芯片共12个通道，分为4组
local PHASE_UNBALANCE_THRESHOLD_ABS = 2.5 
local PHASE_GROUP_CONFIG = {
    {channels = {1, 2, 3}, relay = "k1", chip = 1, fault_key = "fault11"},    -- 第一组：芯片1通道1-3 -> fault11
    {channels = {4, 5, 6}, relay = "k2", chip = 1, fault_key = "fault12"},    -- 第二组：芯片1通道4-6 -> fault12
    {channels = {1, 2, 3}, relay = "k3", chip = 2, fault_key = "fault13"},    -- 第三组：芯片2通道1-3 -> fault13
    {channels = {4, 5, 6}, relay = "k4", chip = 2, fault_key = "fault14"}     -- 第四组：芯片2通道4-6 -> fault14
}

-- 读取组配置 - 分四次读取，每次读取三个通道
local READ_GROUP_CONFIG = {
    {chip = 1, channels = {1, 2, 3}},   -- 第一次：芯片1通道1-3
    {chip = 1, channels = {4, 5, 6}},   -- 第二次：芯片1通道4-6
    {chip = 2, channels = {1, 2, 3}},   -- 第三次：芯片2通道1-3
    {chip = 2, channels = {4, 5, 6}}    -- 第四次：芯片2通道4-6
}

local phase_unbalance_status = {
    group1 = false,
    group2 = false, 
    group3 = false,
    group4 = false
}

-- 添加电源类型标志位
local power_type_flag = 2  -- 默认三相电，2表示两相电，3表示三相电

local current_data = {
    chip1 = {0, 0, 0, 0, 0, 0},
    chip2 = {0, 0, 0, 0, 0, 0}
}

local net_config = {
    ethernet = {
        spi_id = 0,           -- SPI设备ID
        cs_pin = 8,          -- 片选引脚
        type = netdrv.CH390,  -- 网卡芯片类型
        baudrate = 51200000,  -- SPI波特率
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
    -- 控制板数据
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
    -- 控制板数据
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

local sa = {
    ["sw11"] = {1,"k1",1},
    ["sw12"] = {1,"k2",2},
    ["sw13"] = {1,"k3",3},
    ["sw14"] = {1,"k4",4},
    ["sw21"] = {2,0x02,1},
    ["sw22"] = {2,0x02,2},
    ["sw23"] = {2,0x02,3},
    ["sw24"] = {2,0x02,4},
    ["sw31"] = {3,0x03,1},
    ["sw32"] = {3,0x03,2},
    ["sw33"] = {3,0x03,3},
    ["sw34"] = {3,0x03,4},
    ["sw41"] = {4,0x04,1},
    ["sw42"] = {4,0x04,2},
    ["sw43"] = {4,0x04,3},
    ["sw44"] = {4,0x04,4}
}

-- 看门狗
if wdt then
    wdt.init(9000) -- 初始化watchdog设置为9s
    sys.timerLoopStart(wdt.feed, 3000) -- 3s喂一次狗
end


-- 1. 初始化串口
sys.taskInit(function()
    log.info("main", "start init uart")
    -- 初始化485
    gpio.setup(16, 0)
    gpio.setup(27,1)
    gpio.setup(22,1)
    sensor_485 = fzmodbus.new({uartid=1, gpio_485=16, is_485=1, baudrate=9600})
    ctrl_485 = fzmodbus.new({is_485=1, uartid=2, gpio_485=28, baudrate=9600})
    display_232 = fzmodbus.new({uartid=3, baudrate=115200})
    -- 初始化继电器
    fzrelays.init()
    -- 初始化按键
    fzkeys.init()
    -- 初始化bme280
    bme.init()
    -- -- 初始化adc
    -- fzadcs.init(0, 4.0)
    -- -- 初始化rn8302b 
    -- rn8302b.init()
    -- -- 初始化供电模块
    -- supply.init()

end)


----------------------------------------------------------------------测试用-----------------------------------------------------

sys.taskInit(function()
    while true do
        local pres, temp, humi = bme.getData()
        log.info("BME280", "pres:", pres, "temp:", temp)
        sys.wait(1000)
    end
end)

sys.taskInit(function()
    sys.wait(1000)
    if not RX8025T.init() then
        return
    end

    --RX8025T.set_time(25,10,7,15,26,0)

    local time_data = RX8025T.read_time()
    if time_data then
        log.info("当前时间",RX8025T.format_time(time_data))
    end

    while true do
        local time_data = RX8025T.read_time()
        if time_data then
            log.info("当前时间",RX8025T.format_time(time_data))
        end
        sys.wait(1000)
    end
end)

sys.taskInit(function()
    while true do
        -- 采集电压mv
        voltage = fzadcs.get_adc(0)
        log.info("获取adc为:", voltage)
        -- 12V = 1.18V 0 = 0      
        voltage = voltage / 1000 * 10.169
        log.info("测得电压为：", voltage)
        sys.wait(5000)
    end
end)
------------------------------------------------------------------网咯切换-------------------------------------------------------------------
local function network_status_callback(event_type, data)
    if event_type == "ethernet" then
        if data == 2 then -- CONNECTED
            log.info("NET_CALLBACK", "以太网连接成功")
        elseif data == 0 then -- DISCONNECTED
            log.warn("NET_CALLBACK", "以太网连接断开")
        end
    elseif event_type == "4g" then
        if data == 2 then -- CONNECTED
            log.info("NET_CALLBACK", "4G网络连接成功")
        elseif data == 0 then -- DISCONNECTED
            log.warn("NET_CALLBACK", "4G网络连接断开")
        end
    elseif event_type == "switch" then
        log.info("NET_CALLBACK", "网络切换到:", data)
        
        -- 网络切换后重启MQTT连接
        if data ~= "none" then
            sys.taskInit(function()
                sys.wait(3000) -- 等待网络稳定
                
                if mqtt1 then
                    log.info("MQTT_RECONNECT", "网络切换，重启MQTT连接...")
                    
                    -- 先关闭现有连接
                    mqtt1:close()
                    sys.wait(2000)
                    
                    -- 重新初始化并连接
                    mqtt1:init()
                    mqtt1:connect()
                    
                    -- 等待MQTT连接建立并重新订阅
                    local mqtt_start = os.time()
                    local reconnect_success = false
                    
                    while os.time() - mqtt_start < 30 do -- 最多等待30秒
                        if mqtt1:get_is_connected() then
                            log.info("MQTT_RECONNECT", "MQTT重新连接成功")
                            
                            -- 重新订阅主题
                            local sub_result = mqtt1:subscribe(sub_url, 0, cloud_parse)
                            --if sub_result then
                               -- log.info("MQTT_RECONNECT", "重新订阅主题成功:", sub_url)
                            --else
                                --log.error("MQTT_RECONNECT", "重新订阅主题失败:", sub_url)
                            --end
                            
                            -- 重新上报设备状态
                            sys.wait(1000)
                            update_changed_data(multi_sensor_data)
                            
                            reconnect_success = true
                            break
                        end
                        sys.wait(1000)
                    end
                    
                    --if not reconnect_success then
                       -- log.error("MQTT_RECONNECT", "MQTT重连超时")
                   -- end
                end
            end)
        end
    end
end

sys.taskInit(function()
    local last_sync_time = 0
    local sync_interval = 3600 -- 1小时同步一次
    
    while true do
        local current_time = os.time()
        
        -- 检查是否需要时间同步（首次运行或间隔时间到）
        if last_sync_time == 0 or (current_time - last_sync_time) > sync_interval then
            if net_switch.is_connected() then
                log.info("TIME_SYNC", "开始时间同步...")
                socket.sntp()
                
                -- 等待时间同步完成
                local sync_start = os.time()
                local sync_success = false
                
                while os.time() - sync_start < 10 do
                    local t = os.date("*t")
                    if t.year > 2020 then -- 时间已经同步
                        log.info("TIME_SYNC", "时间同步成功:", 
                            string.format("%04d-%02d-%02d %02d:%02d:%02d", 
                            t.year, t.month, t.day, t.hour, t.min, t.sec))
                        
                        -- 发送时间到显示屏
                        if display_232 then
                            local json_time = string.format(
                                '{"year":%d,"mon":%d,"day":%d,"hour":%d,"min":%d,"sec":%d}',
                                t.year, t.month, t.day, t.hour, t.min, t.sec
                            )
                            display_232:send_str(json_time.."\r\n")
                        end
                        
                        last_sync_time = os.time()
                        sync_success = true
                        break
                    end
                    sys.wait(1000)
                end
                
                --if not sync_success then
                    --log.warn("TIME_SYNC", "时间同步失败")
                --end
            else
                --log.warn("TIME_SYNC", "无网络连接，跳过时间同步")
            end
        end
        
        sys.wait(60000) -- 每分钟检查一次
    end
end)

-- 2. 初始化网络切换
sys.taskInit(function()
    sys.wait(3000)  -- 等待硬件初始化完成
    
    log.info("main", "开始初始化网络切换...")
    
    -- 初始化网络切换模块
    local success = net_switch.init(net_config, network_status_callback)
    if not success then
        log.error("main", "网络切换初始化失败")
        return
    end
    
    log.info("main", "网络切换初始化完成，等待网络就绪...")
    
    -- 等待网络就绪
    sys.waitUntil("IP_READY", 30000)
    
    log.info("main", "网络已就绪，开始业务初始化...")
end)

-- 3. MQTT 和 FOTA 初始化
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
        --log.info("MQTT", fmt("第%d次尝试初始化MQTT", init_attempts))
        
        if mqtt1:init() then
            if mqtt1:connect() then
                -- 等待MQTT连接建立
                local mqtt_start = os.time()
                while os.time() - mqtt_start < 20 do
                    if mqtt1:get_is_connected() then
                        log.info("MQTT", "MQTT连接成功")
                        
                        -- 订阅主题
                        local sub_ok = mqtt1:subscribe(sub_url, 0, cloud_parse)
                        if sub_ok then
                            log.info("MQTT", "订阅主题成功:", sub_url)
                            mqtt_init_success = true
                            
                            -- 发送设备上线消息
                            local online_msg = json.encode({
                                deviceStatus = "online",
                                imei = imei,
                                timestamp = os.time(),
                                network = net_switch.get_current_network(),
                                ip = net_switch.get_current_ip()
                            })
                            mqtt1:publish("$thing/up/event/"..imei, online_msg, 0)
                            
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
            log.warn("MQTT", fmt("MQTT初始化失败，%d秒后重试", 5))
            sys.wait(5000)
        end
    end
    
    if not mqtt_init_success then
        log.error("MQTT", "MQTT初始化完全失败")
    end
    
    -- 初始化电源类型
    set_power_type(2)
end)

sys.taskInit(function()
    sys.wait(5000)
    while true do
        local status = net_switch.get_network_status()
        log.info("NET_MONITOR", 
            string.format("网络状态 - 当前: %s, 以太网: %d, 4G: %d", 
            status.current, status.ethernet, status.mobile_4g))
        
        if net_switch.is_connected() then
            local ip = net_switch.get_current_ip()
            log.info("NET_MONITOR", "当前IP:", ip)
            multi_sensor_data.network_type = status.current
            multi_sensor_data.network_ip = ip
        else
            log.warn("NET_MONITOR", "无网络连接")
            multi_sensor_data.network_type = "none"
            multi_sensor_data.network_ip = "0.0.0.0"
        end
        
        sys.wait(30000) -- 30秒打印一次状态
    end
end)
-------------------------------------------电流检测--------------------------------------------------

function check_phase_unbalance_c_style(group_config, chip1_data, chip2_data, group_index)
    local currents = {}
    local chip_data = (group_config.chip == 1) and chip1_data or chip2_data
    
    if not chip_data then
        return false
    end
    
    -- 获取对应芯片的三个通道电流
    for i, channel in ipairs(group_config.channels) do
        currents[i] = chip_data[channel] or 0
    end
    
    local current1 = currents[1]
    local current2 = currents[2] 
    local current3 = currents[3]
    
    -- 如果所有通道电流都很小，认为没有负载，不进行缺相判断
    if current1 < 0.05 and current2 < 0.05 and current3 < 0.05 then
        return false
    end
    
    -- 根据电源类型进行不同的检测
    local is_unbalanced = false
    
    if power_type_flag == 3 then
        -- 三相电检测：直接比较三相电流之间的差值
        is_unbalanced = (math.abs(current1 - current2) > PHASE_UNBALANCE_THRESHOLD_ABS) or
                       (math.abs(current1 - current3) > PHASE_UNBALANCE_THRESHOLD_ABS) or
                       (math.abs(current2 - current3) > PHASE_UNBALANCE_THRESHOLD_ABS)
        
        log.info("PHASE_CHECK_3PHASE", string.format("三相电-组%d: 电流[%.3fA, %.3fA, %.3fA]", 
            group_index, current1, current2, current3))
    else
        -- 两相电检测：检测任意两相之间的电流差值
        -- 计算所有两两组合的电流差值
        local diff12 = math.abs(current1 - current2)
        local diff13 = math.abs(current1 - current3) 
        local diff23 = math.abs(current2 - current3)
        
        -- 两相电的缺相判断：任意两相之间的电流差值超过阈值
        is_unbalanced = (diff12 > PHASE_UNBALANCE_THRESHOLD_ABS) or
                       (diff13 > PHASE_UNBALANCE_THRESHOLD_ABS) or
                       (diff23 > PHASE_UNBALANCE_THRESHOLD_ABS)
        
        -- 记录哪两相之间出现了不平衡
        local unbalanced_pairs = {}
        if diff12 > PHASE_UNBALANCE_THRESHOLD_ABS then table.insert(unbalanced_pairs, "1-2") end
        if diff13 > PHASE_UNBALANCE_THRESHOLD_ABS then table.insert(unbalanced_pairs, "1-3") end
        if diff23 > PHASE_UNBALANCE_THRESHOLD_ABS then table.insert(unbalanced_pairs, "2-3") end
        
        log.info("PHASE_CHECK_2PHASE", string.format("两相电-组%d: 电流[%.3fA, %.3fA, %.3fA] 差值[%.3f,%.3f,%.3f] 不平衡相位:%s", 
            group_index, current1, current2, current3, diff12, diff13, diff23,
            table.concat(unbalanced_pairs, ",")))
    end
    
    -- 记录详细的检测信息
    log.info("PHASE_CHECK_C_STYLE", string.format("组%d: 差值[%.3f, %.3f, %.3f] 阈值:%.3f 缺相:%s", 
        group_index, 
        math.abs(current1 - current2), 
        math.abs(current1 - current3), 
        math.abs(current2 - current3),
        PHASE_UNBALANCE_THRESHOLD_ABS,
        is_unbalanced and "是" or "否"))
    
    return is_unbalanced
end

function execute_phase_protection_c_style()
    if not rn8302b_chip1_data and not rn8302b_chip2_data then
        return
    end
    
    -- 检查四个三相组
    for i, group_config in ipairs(PHASE_GROUP_CONFIG) do
        local is_unbalanced = check_phase_unbalance_c_style(group_config, rn8302b_chip1_data, rn8302b_chip2_data, i)
        local status_key = "phase_unbalance" .. i
        local relay_key = "sw1" .. i
        local fault_key = "fault1"..i
        
        -- 更新缺相状态
        local old_status = phase_unbalance_status["group" .. i]
        phase_unbalance_status["group" .. i] = is_unbalanced
        
        -- 更新fault状态：缺相时置1，正常时置0
        multi_sensor_data[fault_key] = is_unbalanced and 1 or 0
        
        -- 如果检测到缺相，无论状态是否变化，都执行保护
        if is_unbalanced then
            -- 获取继电器当前状态
            local current_relay_state = fzrelays.get_mode(group_config.relay)
            
            -- 如果继电器是闭合状态，则断开
            if current_relay_state == 1 then
                log.warn("PHASE_PROTECTION_C", string.format("芯片%d组%d检测到缺相，断开继电器%s", 
                    group_config.chip, i, group_config.relay))
                
                -- 断开继电器
                fzrelays.set_mode(group_config.relay, "off")
                
                -- 更新继电器状态到数据结构
                multi_sensor_data[relay_key] = 0
                
                -- 记录保护动作
                log.error("PHASE_PROTECTION_ACTION_C", 
                    string.format("缺相保护动作：断开%s，组%d电流异常", group_config.relay, i))
            end
        end
        
        -- 状态发生变化时上报
        if is_unbalanced ~= old_status then
            -- 上报所有fault
            for j = 1, 4 do
                local fault_key = "fault1"..j
                update_changed_data({[fault_key] = multi_sensor_data[fault_key]})
            end
        end
    end
end

-- 添加设置电源类型的函数
function set_power_type(power_type)
    if power_type == 2 or power_type == 3 then
        power_type_flag = power_type
        multi_sensor_data.power_type = power_type
        log.info("POWER_TYPE", string.format("电源类型设置为: %d相电", power_type))
        -- 立即上报电源类型变化
        update_changed_data({power_type = power_type})
        return true
    else
        log.error("POWER_TYPE", "无效的电源类型:", power_type)
        return false
    end
end

-- RN8302B电流监测任务 - 分四次读取，每次读取三个通道
sys.taskInit(function()
    if not rn8302b.init() then
        log.error("MAIN", "RN8302B初始化失败")
        return
    end
    
    sys.wait(2000)
    
    local read_cycle = 0
    local current_read_group = 1  -- 当前读取组索引
    
    while true do
        read_cycle = read_cycle + 1
        
        -- 获取当前读取组的配置
        local group_config = READ_GROUP_CONFIG[current_read_group]
        
        if group_config then
            log.info("RN8302B_READ", string.format("第%d次读取: 芯片%d通道%d-%d", 
                current_read_group, group_config.chip, 
                group_config.channels[1], group_config.channels[3]))
            
            -- 读取当前组的三个通道
            local currents = {}
            for i, channel in ipairs(group_config.channels) do
                currents[channel] = rn8302b.read_single_current(group_config.chip, channel)
                sys.wait(30)  -- 每个通道读取间隔
            end
            
            -- 更新对应芯片的数据
            if group_config.chip == 1 then
                for channel, value in pairs(currents) do
                    rn8302b_chip1_data[channel] = value
                end
                -- 更新到current_data用于历史比较
                for channel, value in pairs(currents) do
                    current_data.chip1[channel] = value
                end
            else
                for channel, value in pairs(currents) do
                    rn8302b_chip2_data[channel] = value
                end
                -- 更新到current_data用于历史比较
                for channel, value in pairs(currents) do
                    current_data.chip2[channel] = value
                end
            end
            
            -- 更新到传感器数据结构中
            if group_config.chip == 1 then
                if current_read_group == 1 then
                    -- 第一次读取：芯片1通道1-3，更新current11
                    multi_sensor_data.current11 = currents[1] or 0
                elseif current_read_group == 2 then
                    -- 第二次读取：芯片1通道4-6，更新current12
                    multi_sensor_data.current12 = currents[4] or 0
                end
            else
                if current_read_group == 3 then
                    -- 第三次读取：芯片2通道1-3，更新current13
                    multi_sensor_data.current13 = currents[1] or 0
                elseif current_read_group == 4 then
                    -- 第四次读取：芯片2通道4-6，更新current14
                    multi_sensor_data.current14 = currents[4] or 0
                end
            end
            
            log.info("RN8302B_GROUP", string.format("组%d读取完成", current_read_group))
            
            -- 移动到下一组
            current_read_group = current_read_group + 1
            if current_read_group > 4 then
                current_read_group = 1
                
                -- 缺相检测
                execute_phase_protection_c_style()
                
                -- 每5个周期完整记录一次日志
                if read_cycle % 5 == 0 then
                    log.info("RN8302B_FULL", "芯片1电流数据:", 
                        string.format("[%.3f, %.3f, %.3f, %.3f, %.3f, %.3f]A", 
                        rn8302b_chip1_data[1] or 0, rn8302b_chip1_data[2] or 0, 
                        rn8302b_chip1_data[3] or 0, rn8302b_chip1_data[4] or 0,
                        rn8302b_chip1_data[5] or 0, rn8302b_chip1_data[6] or 0))
                    log.info("RN8302B_FULL", "芯片2电流数据:", 
                        string.format("[%.3f, %.3f, %.3f, %.3f, %.3f, %.3f]A", 
                        rn8302b_chip2_data[1] or 0, rn8302b_chip2_data[2] or 0, 
                        rn8302b_chip2_data[3] or 0, rn8302b_chip2_data[4] or 0,
                        rn8302b_chip2_data[5] or 0, rn8302b_chip2_data[6] or 0))
                    
                    -- 记录缺相状态和对应的fault值
                    log.info("PHASE_STATUS", string.format("缺相状态: 组1:%s(fault11=%d) 组2:%s(fault12=%d) 组3:%s(fault13=%d) 组4:%s(fault14=%d)",
                        phase_unbalance_status.group1 and "异常" or "正常", multi_sensor_data.fault11,
                        phase_unbalance_status.group2 and "异常" or "正常", multi_sensor_data.fault12, 
                        phase_unbalance_status.group3 and "异常" or "正常", multi_sensor_data.fault13,
                        phase_unbalance_status.group4 and "异常" or "正常", multi_sensor_data.fault14))
                    
                    -- 记录当前电源类型
                    log.info("POWER_TYPE_STATUS", string.format("当前电源类型: %d相电", power_type_flag))
                else
                    log.info("RN8302B", "一轮完整读取完成")
                end
            end
        end 
        sys.wait(500)  -- 组间读取间隔
    end
end)

----------------------------------------------------------------------------------------------------------------------------------------

function update_changed_data(new_data)
    if type(new_data) ~= "table" then
        log.error("UPDATE", "无效数据:", type(new_data))
        return
    end

    local changed_data = {}
    local has_changes = false
    
    for key, new_value in pairs(new_data) do
        local old_value = multi_sensor_data_old[key]
        
        -- 安全地比较值，处理不同类型的数据
        local should_update = false
        
        if old_value == nil then
            -- 新字段，总是更新
            should_update = true
        else
            local new_type = type(new_value)
            local old_type = type(old_value)
            
            if new_type == "number" and old_type == "number" then
                -- 都是数字，比较差值
                if math.abs(new_value - old_value) > 0.1 then
                    should_update = true
                end
            elseif new_type == "string" and old_type == "string" then
                -- 都是字符串，直接比较
                if new_value ~= old_value then
                    should_update = true
                end
            elseif new_type ~= old_type then
                -- 类型不同，总是更新
                should_update = true
            else
                -- 其他类型，使用安全比较
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
        
        if display_232 then
            display_232:send_str(display_data_str.."\r\n")
        end
        
        if mqtt1 and mqtt1:get_is_connected() then
            mqtt1:publish(pub_url, changed_data_str, 0)
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

-- 控制命令缓存
function push_ctrl_cmd(cmd)
    if #ctrl_cmd_buffer > 4 then  -- 限制命令队列长度
        table.remove(ctrl_cmd_buffer, 1)  -- 淘汰最旧命令
    end
    table.insert(ctrl_cmd_buffer, cmd)
end

-- 从缓冲区取出命令
function pop_ctrl_cmd()
    if #ctrl_cmd_buffer > 0 then
        return table.remove(ctrl_cmd_buffer, 1)
    end
    return nil
end
sys.taskInit(function()
    while true do
        local cmd = pop_ctrl_cmd()
        if cmd then
            -- 执行控制命令
            fzrelays.set_mode(cmd.addr, cmd.val == 1 and "on" or "off")
            log.info("ctrl_exec", json.encode(cmd))
            display_232:send_str(json.encode({[cmd.addr] = cmd.val}).."\r\n")
            sys.wait(500) 
        else
            sys.wait(100) 
        end
    end
end)

-- 控制板数据解析
function ctrl_parse(data)
    log.info("ctrl", data)
    local payload = fztools.hex_to_bytes(data:toHex())
    if fztools.check_crc(payload) then
        if payload[1] == 0x02 and payload[2] == 0x03 then
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
        log.info("crc", "parse err")
    end
end

-- 控制数据
function receive_parse(id, data)
    local json_data = json.decode(data);
    if json_data == nil then
        return
    end
    for key, val in pairs(json_data) do 
        if string.match(key,"^sw") then
            if not sa[key] then
                log.info("processData", "match failed!")
                return
            end
            
            if sa[key][1] == self_addr then
                push_ctrl_cmd({addr = sa[key][2], val = val})
                -- fzrelays.set_mode(sa[key][2], val == 1 and "on" or "off")
            else
                ctrl_485:send_command(
                    sa[key][2],
                    0x06,
                    string.char(0x00, sa[key][3], 0x00, val)
                )
            end
            display_232:send_str(json.encode({key = val}).."\r\n")
        elseif string.match(key, "heartbeat") then
            last_time = os.time()
            display_status = 1
        elseif string.match(key, "timer") or string.match(key, "query") then
            if id == 1 then
                mqtt1:publish(pub_url, data, 0)
            elseif id == 2 then
                display_232:send_str(data.."\r\n") 
            end
        elseif key == "power_type" then
            -- 处理电源类型设置
            if set_power_type(val) then
                log.info("POWER_TYPE_SET", string.format("从%s接收到电源类型设置: %d相电", 
                    id == 1 and "屏幕" or "云平台", val))
            end
        end
    end
end

-- 本机数据采集
function get_self_data()
    multi_sensor_data.sw11 = fzrelays.get_mode("k1")
    multi_sensor_data.sw12 = fzrelays.get_mode("k2")
    multi_sensor_data.sw13 = fzrelays.get_mode("k3")
    multi_sensor_data.sw14 = fzrelays.get_mode("k4")
    
    -- 使用两片芯片的数据
    if rn8302b_chip1_data then
        multi_sensor_data.current11 = rn8302b_chip1_data[1] or 0  -- 芯片1通道1
        multi_sensor_data.current12 = rn8302b_chip1_data[4] or 0  -- 芯片1通道4
    end
    
    if rn8302b_chip2_data then
        multi_sensor_data.current13 = rn8302b_chip2_data[1] or 0  -- 芯片2通道1
        multi_sensor_data.current14 = rn8302b_chip2_data[4] or 0  -- 芯片2通道4
    end
    
    -- fault11-fault14现在由缺相检测函数更新，这里不再重置
    -- power_type已经在设置时更新
    
    update_changed_data(multi_sensor_data)
end

-- 从云平台接收数据
function cloud_parse(data)
    log.info("display", data)
    receive_parse(2, data)
end

-- 从屏幕接收数据
function display_parse(data)
    log.info("display", data)
    receive_parse(1, data)
end

-- 按键处理
sys.taskInit(function()
    while true do
        local _, key_name = sys.waitUntil("KEY")
        fzrelays.toggle(key_name)
        sys.wait(500)
    end
end)

-- 数据获取
sys.taskInit(function()
    sensor_485:set_receive_callback(false, sensor_parse)
    display_232:set_receive_callback(false, display_parse)
    
    sys.timerLoopStart(get_self_data, 1000)
    
    while true do
        sys.wait(120000)
        supply.on("led_supply1")
        supply.on("led_supply2")
        sys.wait(120000)
        sensor_485:send_command(do_sat1_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(1000)
        sensor_485:send_command(do_sat2_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(1000)
        sensor_485:send_command(do_sat3_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(1000)
        sensor_485:send_command(ph1_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(2000)
                -- 关闭供电模块
        supply.off("led_supply1")
        supply.off("led_supply2")
        sys.wait(600000)
    end
end)

sys.run()