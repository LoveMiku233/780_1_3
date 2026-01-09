--[[
@file       main.lua
@module     main
@version    000.000.926
@date       2025-09-02
@author     yankai
@brief      鱼塘远程控制系统主程序
@description
    基于Air780EHM芯片和LuatOS系统的鱼塘远程控制解决方案。
    
    主要功能：
    1. 多传感器数据采集（溶解氧、水温、pH值等）
    2. RN8302B六路电流检测与缺相保护
    3. 四路继电器远程控制
    4. 双平台MQTT通信（自有平台 + CTWing平台）
    5. 定时任务管理
    6. 本地按键控制
    7. 232屏幕显示
    8. OTA远程升级
    
    硬件接口：
    - UART1: RS485传感器通信
    - UART3: RS232屏幕通信
    - SPI: RN8302B电流检测芯片
    - I2C: BME280/BMP280温湿度传感器、RX8025T实时时钟
    - GPIO: 继电器控制、按键输入
--]]

PROJECT = "main"
VERSION = "000.000.926"
author = "yankai"

_G.sys     = require("sys")
_G.sysplus = require("sysplus")

log.setLevel("DEBUG")

-- ========== 模块加载 ==========
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
local supply = require("supply")
local rn8302b = require("rn8302b")
-- local net_switch = require("net_switch")
local db = require("config_manager")


-- ========== 通信接口变量 ==========
local ctrl_485 = nil
local sensor_485 = nil
local display_232 = nil
local ctrl_cmd_buffer = {}
-- mqtt - 双平台
local mqtt1 = fzmqtt.new(config.mqtt)  -- 平台1
-- 平台2配置
local ctwing_device_id = string.format("%s%s", config.mqtt2.product_id, mobile.imei())
local mqtt2 = fzmqtt.new({
    user = config.mqtt2.user,
    device_id = ctwing_device_id,
    password = config.mqtt2.password,
    host = config.mqtt2.host,
    port = config.mqtt2.port,
    ssl = config.mqtt2.ssl,
    qos = config.mqtt2.qos,
})

-- imei
local imei = mobile.imei()

-- 订阅发布地址 - 平台1
local pub_url = "$thing/up/property/"..imei
local sub_url = "$thing/down/property/"..imei

-- ctwing平台主题 - 平台2
local ct_pub_url = "sensor_report"
local ct_sub_url = "cmd_send"
local response_url = "cmd_response"
local info_url = "info_report"
local signal_url = "signal_report"
local battery_url = "battery_voltage_low_alarm"

-- 设备信息数据
local info_data = {
    manufacturer_name = "FANZHOU",
    terminal_type = "采控一体",
    module_type = "780控制板",
    hardware_version = "V1.3",
    software_version = VERSION,
    IMEI = imei,
    ICCID = mobile.iccid(),
}

-- 信号强度数据
local signal_data = {
    rsrp = mobile.rsrp(),
    rsrq = mobile.rsrq()
}

-- 传感器地址
local do_sat1_addr = 0x0c
local do_sat2_addr = 0x0D
local do_sat3_addr = 0x0E
local do_sat4_addr = 0x0F
local ph1_addr = 0x03
local ph2_addr = 0x04
local ph3_addr = 0x05
local ph4_addr = 0x06
-- 控制板地址
local ctrl_addr = 0x02
local self_addr = 1

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
    ON_DELAY = 1000,   -- 打开继电器延时1秒
    OFF_DELAY = 1000   -- 关闭继电器延时1秒
}

-- 当前控制模式，默认为一个传感器控制四个继电器
local current_control_mode = CONTROL_MODE.TWO_SENSORS_CONTROL_FOUR_RELAYS

-- 定时任务相关配置
local new_timers_flag = false
local timers = {
    enable = true,
    on_list = {
        -- "时间" = 塘口
    },
    off_list = {
        -- "时间" = 塘口
    }
}

-- 继电器地址映射
local sa = {
    ["sw1"] = {'A', 1},
    ["sw2"] = {'B', 2},
    ["sw3"] = {'C', 3},
    ["sw4"] = {'D', 4},
}

-- ========== 电流检测和缺相保护相关变量 ==========
-- 两片RN8302B芯片的数据
local rn8302b_chip1_data = {0, 0, 0, 0, 0, 0}
local rn8302b_chip2_data = {0, 0, 0, 0, 0, 0}

-- 缺相检测配置 - 两个芯片共12个通道，分为4组
local PHASE_UNBALANCE_THRESHOLD_ABS = 1.25  -- 增大阈值到2.0A
local MIN_CURRENT_THRESHOLD = 0.1          -- 最小有效电流
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

-- 添加电机启动标志和启动时间记录
local motor_start_flags = {
    k1 = 0,  -- 0: 正常状态, 1: 启动中
    k2 = 0,
    k3 = 0, 
    k4 = 0
}

local motor_start_times = {
    k1 = 0,  -- 启动时间戳
    k2 = 0,
    k3 = 0,
    k4 = 0
}

local STARTUP_IGNORE_TIME = 1000  -- 启动后忽略缺相检测的时间(毫秒)

local phase_unbalance_status = {
    group1 = false,
    group2 = false, 
    group3 = false,
    group4 = false
}

-- 添加电源类型标志位
local power_type_flag = 3  -- 默认三相电，2表示两相电，3表示三相电

local current_data = {
    chip1 = {0, 0, 0, 0, 0, 0},
    chip2 = {0, 0, 0, 0, 0, 0}
}

-- 继电器状态变化跟踪
local last_relay_states = {
    k1 = 0,
    k2 = 0,
    k3 = 0,
    k4 = 0
}

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
    ph2 = 0.0,
    ph3 = 0.0,
    ph4 = 0.0,
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

-- ==========电流检测和缺相保护函数 ==========
-- ========== 电机启动检测函数 ==========
function check_motor_start()
    local current_time = os.time() * 1000  -- 转换为毫秒
    
    -- 检查每个继电器的状态变化
    for _, relay_name in ipairs({"k1", "k2", "k3", "k4"}) do
        local current_state = fzrelays.get_mode(relay_name)
        
        -- 如果状态从0变为1，表示电机启动
        if current_state == 1 and last_relay_states[relay_name] == 0 then
            motor_start_flags[relay_name] = 1
            motor_start_times[relay_name] = current_time
            log.info("MOTOR_START", string.format("检测到电机 %s 启动，设置启动标志", relay_name))
            
            -- 启动后立即标记故障为0，避免误报
            local fault_key = "fault1" .. string.sub(relay_name, 2)
            multi_sensor_data[fault_key] = 0
            
            -- 更新缺相状态
            local group_index = tonumber(string.sub(relay_name, 2))
            if group_index then
                phase_unbalance_status["group" .. group_index] = false
            end
        end
        
        -- 检查是否超过启动忽略时间
        if motor_start_flags[relay_name] == 1 then
            local elapsed_time = current_time - motor_start_times[relay_name]
            if elapsed_time >= STARTUP_IGNORE_TIME then
                motor_start_flags[relay_name] = 0
                log.info("MOTOR_START", string.format("电机 %s 启动完成，已过 %d 毫秒，恢复正常检测", relay_name, elapsed_time))
            end
        end
        
        -- 更新最后状态
        last_relay_states[relay_name] = current_state
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
    
    -- 先检查电机启动状态
    check_motor_start()
    
    -- 检查四个三相组
    for i, group_config in ipairs(PHASE_GROUP_CONFIG) do
        -- 检查该组对应的电机是否处于启动状态
        local relay_name = group_config.relay
        local is_starting = (motor_start_flags[relay_name] == 1)
        
        if is_starting then
            -- 电机启动中，跳过缺相检测
            local elapsed_time = (os.time() * 1000) - motor_start_times[relay_name]
            log.info("PHASE_PROTECTION", string.format("组%d对应电机 %s 启动中(已运行 %d 毫秒)，跳过缺相检测", 
                i, relay_name, elapsed_time))
            
            -- 保持故障状态为0（正常）
            local fault_key = group_config.fault_key
            multi_sensor_data[fault_key] = 0
            phase_unbalance_status["group" .. i] = false
        else
            -- 正常状态，进行缺相检测
            local is_unbalanced = check_phase_unbalance_c_style(group_config, rn8302b_chip1_data, rn8302b_chip2_data, i)
            local status_key = "phase_unbalance" .. i
            local relay_key = "sw1" .. i
            local fault_key = group_config.fault_key
            
            -- 更新缺相状态
            local old_status = phase_unbalance_status["group" .. i]
            phase_unbalance_status["group" .. i] = is_unbalanced
            
            -- 更新fault状态：缺相时置1，正常时置0
            multi_sensor_data[fault_key] = is_unbalanced and 1 or 0
            
            -- 如果检测到缺相，执行保护
            if is_unbalanced then
                -- 获取继电器当前状态
                local current_relay_state = fzrelays.get_mode(group_config.relay)
                
                -- 如果继电器是闭合状态，则断开
                if current_relay_state == 1 then
                    log.warn("PHASE_PROTECTION_C", string.format("芯片%d组%d检测到缺相，断开继电器%s", 
                        group_config.chip, i, group_config.relay))
                    
                    -- 断开继电器
                    fzrelays.set_mode(group_config.relay, "off")
                    -- 故障日志记录
                    log.error("PHASE_FAULT", string.format("缺相故障触发：继电器%s已断开", group_config.relay))
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
end

-- RN8302B电流监测任务 - 分四次读取，每次读取三个通道
sys.taskInit(function()
    
    sys.wait(200)
    
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
                sys.wait(100)  -- 每个通道读取间隔
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
                
                -- 缺相检测（包含启动跳过逻辑）
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
                    
                    -- 记录电机启动状态
                    for _, relay in ipairs({"k1", "k2", "k3", "k4"}) do
                        if motor_start_flags[relay] == 1 then
                            local elapsed = (os.time() * 1000) - motor_start_times[relay]
                            log.info("MOTOR_STATUS", string.format("电机 %s 启动中，已运行 %d 毫秒", relay, elapsed))
                        end
                    end
                else
                    log.info("RN8302B", "一轮完整读取完成")
                end
            end
        end 
        sys.wait(200)  -- 组间读取间隔
    end
end)

-- ========== 双平台MQTT处理函数 ==========
-- 平台1数据解析
function platform1_parse(data)
    log.info("PLATFORM1", "收到平台1数据:", data)
    
    local json_data = json.decode(data)
    if json_data == nil then
        log.warn("PLATFORM1", "JSON解析失败")
        return
    end
    
    -- 处理定时配置
    if json_data.timer then
        process_timer_config(json_data.timer)
        return
    end
    
    -- 处理控制模式设置
    if json_data.control_mode then
        handle_control_mode_setting(json_data)
        return
    end
    
    -- 原有的控制命令处理
    process_control_command(json_data, "platform1")
end

-- 平台2数据解析
function platform2_parse(data)
    log.info("PLATFORM2", "收到平台2数据:", data)
    
    -- ctwing平台特有的任务响应格式
    if string.match(data, "taskId") then
        local json_data = json.decode(data)
        if json_data == nil or json_data.payload == nil then
            return
        end
        
        -- 处理控制命令
        process_control_command(json_data.payload, "platform2")
        
        -- 回复ctwing平台
        local response = {
            ["taskId"] = json_data.taskId,
            ["resultPayload"] = json_data.payload
        }
        
        log.info("CTWING_RESPONSE", json.encode(response))
        if mqtt2 and mqtt2:get_is_connected() then
            mqtt2:publish(response_url, json.encode(response), 0)
        end
    else
        -- 普通控制命令
        local json_data = json.decode(data)
        if json_data then
            process_control_command(json_data, "platform2")
        end
    end
end

-- 信号强度和电池电压上报函数
function update_signal_battery_data()
    local info_data_str = json.encode(info_data)
    log.info("CTWING_INFO", "上报设备信息到平台2:", info_data_str)

    signal_data.rsrp = mobile.rsrp()
    signal_data.rsrq = mobile.rsrq()
    local signal_data_str = json.encode(signal_data)
    log.info("CTWING_SIGNAL", "上报信号强度到平台2:", signal_data_str)
    
    mqtt2:publish(signal_url, signal_data_str, 0)
    mqtt2:publish(info_url, info_data_str, 0)
end

-- ========== 定时任务相关函数 ==========
-- 定时任务检查函数
function timer_task()
    local now_time = os.date("*t")
    log.info("TIMER_TASK", string.format("当前时间: %02d:%02d", now_time.hour, now_time.min))
    
    -- 检查定时任务是否启用
    if not timers.enable then
        log.debug("TIMER_TASK", "定时任务未启用")
        return
    end
    
    -- 处理开启任务
    for idx, timer in ipairs(timers.on_list) do
        log.debug("TIMER_CHECK", string.format("检查开启任务: 继电器%d %02d:%02d", 
                 timer.id, timer.hour, timer.min))
        
        if timer.hour == now_time.hour and timer.min == now_time.min then
            log.info("TIMER_ON", string.format("执行定时开启: 继电器 sw1%d", timer.id))
            
            -- 使用协程执行继电器操作
            sys.taskInit(function()
                timer_control_relay(timer.id, "on")
            end)
        end
    end
    
    -- 处理关闭任务
    for idx, timer in ipairs(timers.off_list) do
        log.debug("TIMER_CHECK", string.format("检查关闭任务: 继电器%d %02d:%02d", 
                 timer.id, timer.hour, timer.min))
        
        if timer.hour == now_time.hour and timer.min == now_time.min then
            log.info("TIMER_OFF", string.format("执行定时关闭: 继电器 sw1%d", timer.id))
            
            -- 使用协程执行继电器操作
            sys.taskInit(function()
                timer_control_relay(timer.id, "off")
            end)
        end
    end
end

function timer_control_relay(relay_id, action)
    local relay_key = "sw1" .. tostring(relay_id)
    local relay_name = relay_map[relay_key]
    
    if not relay_name then
        log.error("TIMER_ERROR", "未知的继电器:", relay_key)
        return
    end

    -- 检查当前状态，避免重复操作
    local current_state = fzrelays.get_mode(relay_name)
    local target_state = action
    local target_value = action == "on" and 1 or 0
    
    log.info("TIMER_STATE", string.format("继电器 %s 当前状态: %s, 目标状态: %s", 
             relay_name, current_state, target_state))
    
    if (current_state == 1 and target_value == 1) or (current_state == 0 and target_value == 0) then
        log.info("TIMER_SKIP", string.format("继电器 %s 已处于目标状态，跳过", relay_name))
        return
    end
    
    log.info("TIMER_ACTION", string.format("%s继电器 %s", action, relay_name))
    
    -- 根据操作类型添加延时
    if action == "on" then
        sys.wait(RELAY_OPERATION_DELAY.ON_DELAY)
    else
        sys.wait(RELAY_OPERATION_DELAY.OFF_DELAY)
    end
    
    -- 控制继电器
    fzrelays.set_mode(relay_name, target_state)
    
    -- 等待继电器稳定
    sys.wait(1000)
    
    -- 重新读取实际状态
    local state_value = fzrelays.get_mode(relay_name)
    

    -- 更新状态数据
    multi_sensor_data[relay_key] = state_value
    
    -- 立即同步到屏幕
    send_full_status_to_screen()
    
    -- 上报状态变化到双平台
    local report_success = false
    local report_attempts = 0
    
    while not report_success and report_attempts < 3 do
        report_attempts = report_attempts + 1
        
        -- 直接构造上报数据
        local report_data = {
            [relay_key] = state_value,
        }
        
        local report_str = json.encode(report_data)
        log.info("TIMER_REPORT", string.format("尝试上报定时任务结果(第%d次): %s", report_attempts, report_str))
        
        if (mqtt1 and mqtt1:get_is_connected()) or (mqtt2 and mqtt2:get_is_connected()) then
            -- 上报到平台1
            if mqtt1 and mqtt1:get_is_connected() then
                local publish_result = mqtt1:publish(pub_url, report_str, 0)
                if publish_result then
                    log.info("TIMER_REPORT_SUCCESS", "定时任务状态上报平台1成功")
                else
                    log.warn("TIMER_REPORT_FAIL", "定时任务状态上报平台1失败")
                end
            end
            
            -- 上报到平台2
            if mqtt2 and mqtt2:get_is_connected() then
                local publish_result = mqtt2:publish(ct_pub_url, report_str, 0)
                if publish_result then
                    log.info("TIMER_REPORT_SUCCESS", "定时任务状态上报平台2成功")
                else
                    log.warn("TIMER_REPORT_FAIL", "定时任务状态上报平台2失败")
                end
            end
            
            report_success = true
        else
            log.warn("TIMER_REPORT", "MQTT未连接，等待重试")
            sys.wait(2000)
        end
    end
    
    if not report_success then
        log.error("TIMER_REPORT", "定时任务状态上报完全失败")
        -- 将变化数据缓存，等待下次连接时上报
        update_changed_data({[relay_key] = state_value})
    end
    log.info("TIMER_SUCCESS", string.format("成功%s继电器 %s", action, relay_name))
end

-- 处理定时配置
function process_timer_config(timer_data)
    log.info("TIMER_CONFIG", "收到定时配置:", type(timer_data) == "table" and json.encode(timer_data) or timer_data)
    
    -- 如果timer_data是字符串，尝试解析JSON
    if type(timer_data) == "string" then
        local success, parsed = pcall(json.decode, timer_data)
        if success then
            timer_data = parsed
            log.info("TIMER_CONFIG", "解析字符串定时配置成功")
        else
            log.error("TIMER_CONFIG", "解析定时配置字符串失败:", timer_data)
            return
        end
    end
    
    if timer_data == "reset" then
        -- 重置定时配置
        timers.on_list = {}
        timers.off_list = {}
        timers.enable = false
        db.update("timers", timers)
        log.info("TIMER_CONFIG", "定时配置已重置")
        
        -- 发送确认消息到双平台
        local response_data = json.encode({timer = "reset ok"})
        if mqtt1 and mqtt1:get_is_connected() then
            mqtt1:publish(pub_url, response_data, 0)
        end
        if mqtt2 and mqtt2:get_is_connected() then
            mqtt2:publish(ct_pub_url, response_data, 0)
        end
        return
    end
    
    -- 解析定时配置
    if type(timer_data) == "table" then
        timers.on_list = {}
        timers.off_list = {}
        timers.enable = true
        
        for key, val in pairs(timer_data) do
            -- 支持格式: "11_1357" 表示继电器1在13:57
            -- 格式说明: [第一个数字固定为1][继电器编号]_[小时][分钟]
            local id_part, time_part = string.match(key, "^(%d+)_(%d+)$")
            
            if id_part and time_part then
                -- 解析继电器编号 (取第二位数字)
                local id_num = nil
                if #id_part == 2 then
                    id_num = tonumber(string.sub(id_part, 2, 2))
                else
                    -- 如果只有一位数字，直接使用
                    id_num = tonumber(id_part)
                end
                
                -- 解析时间
                local hour_num = tonumber(string.sub(time_part, 1, 2))
                local min_num = tonumber(string.sub(time_part, 3, 4))
                
                if id_num and hour_num and min_num and id_num >= 1 and id_num <= 4 then
                    local timer_entry = {id = id_num, hour = hour_num, min = min_num}
                    
                    if val == 1 then
                        table.insert(timers.on_list, timer_entry)
                        log.info("TIMER_ADD", string.format("添加开启定时: 继电器%d %02d:%02d", 
                                id_num, hour_num, min_num))
                    elseif val == 0 then
                        table.insert(timers.off_list, timer_entry)
                        log.info("TIMER_ADD", string.format("添加关闭定时: 继电器%d %02d:%02d", 
                                id_num, hour_num, min_num))
                    else
                        log.warn("TIMER_CONFIG", "无效的定时动作值:", key, val)
                    end
                else
                    log.warn("TIMER_CONFIG", "无效的定时配置参数:", key, val, "继电器ID:", id_num, "时间:", hour_num, ":", min_num)
                end
            else
                log.warn("TIMER_CONFIG", "格式错误的定时配置:", key)
            end
        end
        
        -- 保存配置
        db.update("timers", timers)
        log.info("TIMER_CONFIG", "定时配置已更新并保存")
        log.info("TIMER_CONFIG", "开启任务数量:", #timers.on_list)
        log.info("TIMER_CONFIG", "关闭任务数量:", #timers.off_list)
        
        -- 打印所有定时任务
        for i, timer in ipairs(timers.on_list) do
            log.info("TIMER_ON_DETAIL", string.format("开启任务%d: 继电器%d %02d:%02d", 
                    i, timer.id, timer.hour, timer.min))
        end
        for i, timer in ipairs(timers.off_list) do
            log.info("TIMER_OFF_DETAIL", string.format("关闭任务%d: 继电器%d %02d:%02d", 
                    i, timer.id, timer.hour, timer.min))
        end
        
        -- 发送确认消息到双平台
        local response_data = json.encode({timer = "sync ok"})
        if mqtt1 and mqtt1:get_is_connected() then
            mqtt1:publish(pub_url, response_data, 0)
        end
        if mqtt2 and mqtt2:get_is_connected() then
            mqtt2:publish(ct_pub_url, response_data, 0)
        end
    else
        log.error("TIMER_CONFIG", "无效的定时配置数据类型:", type(timer_data))
    end
end


-- 232屏幕数据解析函数
function display_232_parse(data)
    -- 记录原始数据
    log.info("DISPLAY_232_RAW", "收到原始数据(hex):", data:toHex())
    log.info("DISPLAY_232_RAW", "收到原始数据长度:", #data)
    

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
    sensor_485 = fzmodbus.new({uartid=1, gpio_485=16, is_485=1, baudrate=9600})
    --ctrl_485 = fzmodbus.new({is_485=1, uartid=2, gpio_485=28, baudrate=9600})
    display_232 = fzmodbus.new({uartid=3, baudrate=115200})
    
    -- 初始化其他硬件
    fzrelays.init()
    fzkeys.init()
    bme.init()
    fzadcs.init(0, 4.0)
    supply.init()
     -- 初始化RN8302B（增加采样次数）
    rn8302b.init()
    
    log.info("UART", "232显示屏接口初始化完成")
    send_full_status_to_screen()
end)

-- 3. 双平台MQTT和FOTA初始化
sys.taskInit(function()
    sys.waitUntil("IP_READY")
    log.info("MQTT", "开始初始化双平台MQTT...")
    
    -- 更新配置
    config.mqtt.device_id = string.format("%s%s", config.mqtt.product_id, mobile.imei())
    config.update_url = string.format("###%s?imei=%s&productKey=%s&core=%s&version=%s", 
    config.FIRMWARE_URL, mobile.imei(), config.PRODUCT_KEY, rtos.version(), VERSION)
    
    -- 初始化FOTA
    log.info("FOTA", "开始固件更新检查")
    fzfota.init(config)
    fzfota.print_version()
    fzfota.start_timer_update()
    
    -- 初始化平台1 MQTT
    mqtt1:init() 
    mqtt1:connect()
    sys.waitUntil(mqtt1:get_instance_id().."CONNECTED")
    mqtt1:subscribe(sub_url, 0, platform1_parse)

    -- 初始化平台2 MQTT
    mqtt2:init()
    mqtt2:connect()
    sys.waitUntil(mqtt2:get_instance_id().."CONNECTED")
    mqtt2:subscribe(ct_sub_url, 0, platform2_parse)
    
    -- 上报设备信息到平台2
    update_signal_battery_data()
    
    log.info("MQTT", "双平台MQTT初始化完成")
end)

-- 重启后状态上报任务
sys.taskInit(function()
    -- 等待系统基本初始化完成
    sys.wait(5000)
    
    -- 等待MQTT连接
    local mqtt_wait_start = os.time()
    while (mqtt1 and not mqtt1:get_is_connected()) and (mqtt2 and not mqtt2:get_is_connected()) do
        if os.time() - mqtt_wait_start > 30 then
            log.warn("REBOOT_REPORT", "等待MQTT连接超时")
            break
        end
        log.info("REBOOT_REPORT", "等待MQTT连接...")
        sys.wait(1000)
    end
    
    -- 收集所有当前状态数据
    local reboot_report_data = {}
    
    -- 读取继电器状态
    reboot_report_data.sw11 = fzrelays.get_mode("k1")
    reboot_report_data.sw12 = fzrelays.get_mode("k2")
    reboot_report_data.sw13 = fzrelays.get_mode("k3")
    reboot_report_data.sw14 = fzrelays.get_mode("k4")

    reboot_report_data.water_temp1 = multi_sensor_data.water_temp1 or 0.0
    reboot_report_data.water_temp2 = multi_sensor_data.water_temp2 or 0.0
    reboot_report_data.water_temp3 = multi_sensor_data.water_temp3 or 0.0
    reboot_report_data.water_temp4 = multi_sensor_data.water_temp4 or 0.0
    reboot_report_data.do_sat1 = multi_sensor_data.do_sat1 or 0.0
    reboot_report_data.do_sat2 = multi_sensor_data.do_sat2 or 0.0
    reboot_report_data.do_sat3 = multi_sensor_data.do_sat3 or 0.0
    reboot_report_data.do_sat4 = multi_sensor_data.do_sat4 or 0.0
    reboot_report_data.ph1 = multi_sensor_data.ph1 or 0.0
    reboot_report_data.ph2 = multi_sensor_data.ph2 or 0.0
    reboot_report_data.ph3 = multi_sensor_data.ph3 or 0.0
    reboot_report_data.ph4 = multi_sensor_data.ph4 or 0.0
    
    log.info("REBOOT_REPORT", "准备上报重启后完整状态")
    log.info("REBOOT_REPORT_DATA", json.encode(reboot_report_data, "1f"))

    mqtt1:publish(pub_url, json.encode(reboot_report_data, "1f"), 0)
    mqtt2:publish(ct_pub_url, json.encode(reboot_report_data, "1f"), 0) 

    -- 同步到屏幕
    send_full_status_to_screen()
    
end)

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
            
            -- 立即同步到屏幕
            send_full_status_to_screen()
            
            -- 上报状态变化到双平台
            update_changed_data({[key] = state})
        else
            log.warn("MODBUS_CMD", "未知的寄存器地址:", string.format("0x%04X", reg.address))
        end
    end
end

-- 修改手动控制命令处理，增加延时和屏幕同步
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
    
    local has_changes = false

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
                
                if (current_state == 1 and val == 1) or (current_state == 0 and val == 0) then
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
                    
                    -- 等待继电器稳定
                    sys.wait(500)
                    
                    -- 重新读取实际状态
                    local actual_value = fzrelays.get_mode(relay_name)
                    local actual_state = (actual_value == 1) and "on" or "off"
                    
                    log.info("CONTROL_ACTUAL", string.format("继电器 %s 实际状态: %s (值: %d)", 
                             relay_name, actual_state, actual_value))
                    
                    -- 更新状态数据
                    multi_sensor_data[key] = actual_value
                    has_changes = true
                end
            else
                log.warn("CONTROL", "未知的继电器:", key)
            end    
        end
    end

    -- 如果有状态变化，立即同步到屏幕和双平台
    if has_changes then
        -- 立即同步到屏幕
        send_full_status_to_screen()
        
        -- 上报状态变化到双平台
        local changed_data = {}
        for key, val in pairs(json_data) do
            if string.match(key, "^sw1[1-4]$") then
                changed_data[key] = multi_sensor_data[key]  -- 使用实际读取的状态值
            end
        end
        if next(changed_data) ~= nil then
            update_changed_data(changed_data)
        end
    end
end

-- 更新变化数据（发送到双平台和屏幕）
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
        local changed_data_str = json.encode(changed_data, "1f")
        log.info("UPDATE", "上传变化数据到双平台:", changed_data_str)
        -- 发送到平台1
        mqtt1:publish(pub_url, changed_data_str, 0)
        -- 发送到平台2
        mqtt2:publish(ct_pub_url, changed_data_str, 0)
        
        
    else
        log.debug("UPDATE", "数据无变化")
    end
    send_full_status_to_screen()
end

-- 传感器数据解析
function sensor_parse(data) 
    display_232:send_str(data)
    local payload = fztools.hex_to_bytes(data:toHex())
    if fztools.check_crc(payload) then
        if (payload[1] == do_sat1_addr) then
            _, multi_sensor_data.do_sat1 = pack.unpack(string.char(payload[4],payload[5],payload[6],payload[7]),"<f")
            _, multi_sensor_data.water_temp1 = pack.unpack(string.char(payload[8],payload[9],payload[10],payload[11]),"<f")
        elseif (payload[1] == do_sat2_addr) then
            _, multi_sensor_data.do_sat2 = pack.unpack(string.char(payload[4],payload[5],payload[6],payload[7]),"<f")
            _, multi_sensor_data.water_temp2 = pack.unpack(string.char(payload[8],payload[9],payload[10],payload[11]),"<f")
        elseif (payload[1] == do_sat3_addr) then
            _, multi_sensor_data.water_temp3 = pack.unpack(string.char(payload[8],payload[9],payload[10],payload[11]),"<f") 
            _, multi_sensor_data.do_sat3 = pack.unpack(string.char(payload[4],payload[5],payload[6],payload[7]),"<f")
        elseif (payload[1] == do_sat4_addr) then
            _, multi_sensor_data.do_sat4 = pack.unpack(string.char(payload[4],payload[5],payload[6],payload[7]),"<f")
            _, multi_sensor_data.water_temp4 = pack.unpack(string.char(payload[8],payload[9],payload[10],payload[11]),"<f")
        elseif (payload[1] == ph1_addr) then
            multi_sensor_data.ph1 = (bit.lshift(payload[6], 8) + payload[7]) * 0.01
        elseif (payload[1] == ph2_addr) then
            multi_sensor_data.ph2 = (bit.lshift(payload[6], 8) + payload[7]) * 0.01
        elseif (payload[1] == ph3_addr) then
            multi_sensor_data.ph3 = (bit.lshift(payload[6], 8) + payload[7]) * 0.01
        elseif (payload[1] == ph4_addr) then
            multi_sensor_data.ph4 = (bit.lshift(payload[6], 8) + payload[7]) * 0.01
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

-- 修改get_self_data函数，移植的电流检测
function get_self_data() 
    -- 转换为数值
    multi_sensor_data.sw11 = fzrelays.get_mode("k1")
    multi_sensor_data.sw12 = fzrelays.get_mode("k2")
    multi_sensor_data.sw13 = fzrelays.get_mode("k3")
    multi_sensor_data.sw14 = fzrelays.get_mode("k4")
    
    -- 移植的电流数据
    multi_sensor_data.current11 = rn8302b_chip1_data[1] or 0
    multi_sensor_data.current12 = rn8302b_chip1_data[4] or 0
    multi_sensor_data.current13 = rn8302b_chip2_data[1] or 0
    multi_sensor_data.current14 = rn8302b_chip2_data[4] or 0
    
    update_changed_data(multi_sensor_data)
end

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
        
        -- 更新本地数据
        local data_key = "sw1" .. string.sub(key_name, 2)
        multi_sensor_data[data_key] = fzrelays.get_mode(key_name)
        
        -- 发送完整状态数据到屏幕
        send_full_status_to_screen()
        
        -- 上报状态变化到双平台
        update_changed_data(multi_sensor_data)
        
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
        sensor_485:send_command(do_sat1_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x04))
        sys.wait(1000)
        sensor_485:send_command(do_sat2_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x04))
        sys.wait(1000)
        sensor_485:send_command(do_sat3_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x04))
        sys.wait(1000)
        sensor_485:send_command(do_sat4_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x04))
        sys.wait(1000)
        sensor_485:send_command(ph1_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(1000)
        sensor_485:send_command(ph2_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(1000)
        sensor_485:send_command(ph3_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(1000)
        sensor_485:send_command(ph4_addr, 0x03, string.char(0x00, 0x00, 0x00, 0x03))
        sys.wait(1000)
    end
end)

sys.taskInit(function()
   while true do
        sys.wait(1000)
        supply.on("led_supply1")
        sys.wait(5 * 60 * 1000)
        -- 关闭供电
        supply.off("led_supply1")
        sys.wait(15 * 60 * 1000)
    end
end)

-- ========== 定时任务和定时重启初始化 ==========
sys.taskInit(function()
    sys.wait(1000)
    
    -- 开启定时任务检查（每分钟检查一次，提高精度）
    sys.timerLoopStart(timer_task, 60000)
    log.info("TIMER_INIT", "定时任务检查已启动（每分钟检查一次）")
    -- 24小时定时重启
    sys.timerLoopStart(function()
        log.info("SYSTEM_REBOOT", "执行24小时定时重启")
        rtos.reboot()
    end, 24 * 3600 * 1000 * 3)  --三天重启一次
    
    log.info("SYSTEM_INIT", "系统初始化完成，定时重启已设置")
end)
       
sys.run()