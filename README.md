# 鱼塘远程控制系统

基于 **Air780EHM** 芯片和 **LuatOS** 系统的智能鱼塘远程控制解决方案。

## 项目概述

本项目实现了一套完整的鱼塘远程监控与控制系统，主要功能包括：

- 📊 **多传感器数据采集**：溶解氧、水温、pH值等水质参数
- ⚡ **电流检测**：基于RN8302B芯片的6路电流检测（双芯片共12路）
- 🛡️ **缺相保护**：三相/两相电机缺相自动断电保护
- 🎛️ **远程控制**：4路继电器远程开关控制
- 📡 **双平台通信**：支持自有MQTT平台和CTWing电信平台
- ⏰ **定时任务**：支持定时开关继电器
- 🖥️ **本地显示**：RS232屏幕状态显示
- 🔄 **OTA升级**：支持远程固件升级

## 硬件配置

### 主控芯片
- **型号**：Air780EHM（4G Cat.1模块）
- **系统**：LuatOS

### 接口配置

| 接口 | 功能 | 说明 |
|------|------|------|
| UART1 | RS485 | 传感器数据采集 |
| UART3 | RS232 | 屏幕显示通信 |
| SPI (软件) | RN8302B | 电流检测芯片 |
| I2C | BME280/RX8025T | 温湿度/实时时钟 |
| GPIO | 继电器/按键 | 控制输出/输入 |

### GPIO引脚分配

#### 继电器引脚
| 继电器 | GPIO引脚 |
|--------|----------|
| K1 | GPIO33 |
| K2 | GPIO29 |
| K3 | GPIO30 |
| K4 | GPIO32 |

#### 按键引脚
| 按键 | GPIO引脚 |
|------|----------|
| K1 | GPIO24 |
| K2 | GPIO1 |
| K3 | GPIO2 |
| K4 | GPIO20 |

#### RN8302B SPI引脚
| 信号 | GPIO引脚 |
|------|----------|
| CS1 | GPIO5 |
| CS2 | GPIO4 |
| CLK | GPIO3 |
| MISO | GPIO6 |
| MOSI | GPIO7 |

## 项目结构

```
780_1_3/
├── core/                           # 固件核心文件
│   ├── LuatOS-SoC_V2014_Air780EHM_113.soc
│   └── pins_Air780EHM.json
├── lib/                            # 库文件
│   ├── bme.lua                     # BME280温湿度传感器驱动
│   ├── config_manager.lua          # 配置管理器
│   ├── fz_adc.lua                  # ADC采集模块
│   ├── fz_fota.lua                 # OTA升级模块
│   ├── fz_key.lua                  # 按键驱动
│   ├── fz_modbus.lua               # Modbus RTU协议
│   ├── fz_mqtt.lua                 # MQTT客户端封装
│   ├── fz_relay.lua                # 继电器控制
│   ├── fz_tools.lua                # 工具函数集
│   ├── fz_uart.lua                 # UART通信封装
│   ├── rn8302b.lua                 # RN8302B电流检测驱动
│   ├── RX8025T.lua                 # RX8025T实时时钟驱动
│   ├── supply.lua                  # 电源管理
│   ├── can.lua                     # CAN总线驱动
│   ├── dhcpsrv.lua                 # DHCP服务器
│   ├── dnsproxy.lua                # DNS代理
│   └── net_switch.lua              # 网络切换管理
├── user/                           # 用户代码
│   ├── main.lua                    # 主程序入口
│   └── config.lua                  # 配置文件
├── luatos.json                     # LuatOS项目配置
└── README.md                       # 项目说明文档
```

## 功能模块说明

### 1. 电流检测模块 (rn8302b.lua)

基于软件SPI实现的RN8302B电流检测驱动：
- 支持双芯片（12路电流检测）
- 可配置校准系数
- 支持多次采样滤波

```lua
local rn8302b = require("rn8302b")
rn8302b.init()
-- 读取芯片1通道1的电流值
local current = rn8302b.read_single_current(1, 1)
```

### 2. 继电器控制模块 (fz_relay.lua)

4路继电器控制：

```lua
local fzrelays = require("fz_relay")
fzrelays.init()
-- 打开继电器K1
fzrelays.set_mode("k1", "on")
-- 关闭继电器K2
fzrelays.set_mode("k2", "off")
-- 切换继电器K3状态
fzrelays.toggle("k3")
-- 获取继电器K4状态
local state = fzrelays.get_mode("k4")
```

### 3. MQTT通信模块 (fz_mqtt.lua)

支持多实例的MQTT客户端：

```lua
local fzmqtt = require("fz_mqtt")
local mqtt1 = fzmqtt.new({
    host = "mqtt.example.com",
    port = 1883,
    user = "username",
    password = "password"
})
mqtt1:init()
mqtt1:connect()
mqtt1:subscribe("topic", 0, function(payload)
    print("收到消息:", payload)
end)
mqtt1:publish("topic", "hello", 0)
```

### 4. 缺相保护

系统支持三相电和两相电的缺相检测：
- 电流差值阈值：1.25A
- 最小有效电流：0.1A
- 电机启动保护时间：1000ms

检测到缺相时自动断开对应继电器。

### 5. 定时任务

支持通过MQTT配置定时开关任务：

```json
{
    "timer": {
        "11_0800": 1,   // 继电器1在08:00打开
        "11_1800": 0    // 继电器1在18:00关闭
    }
}
```

格式说明：
- 键格式：`[1][继电器编号]_[小时][分钟]`
- 值：1表示开启，0表示关闭

## MQTT通信协议

### 平台1（自有平台）

| 主题类型 | 格式 |
|----------|------|
| 发布（上报） | `$thing/up/property/{IMEI}` |
| 订阅（下发） | `$thing/down/property/{IMEI}` |

### 平台2（CTWing）

| 主题类型 | 主题名称 |
|----------|----------|
| 传感器上报 | `sensor_report` |
| 命令下发 | `cmd_send` |
| 命令响应 | `cmd_response` |
| 设备信息 | `info_report` |
| 信号强度 | `signal_report` |

### 数据格式

#### 传感器数据上报
```json
{
    "water_temp1": 25.5,
    "do_sat1": 8.5,
    "ph1": 7.2,
    "sw11": 1,
    "sw12": 0,
    "fault11": 0,
    "current11": 3.5
}
```

#### 继电器控制命令
```json
{
    "sw11": 1,  // 打开继电器1
    "sw12": 0   // 关闭继电器2
}
```

## 传感器地址

| 传感器类型 | Modbus地址 |
|------------|------------|
| 溶解氧1 | 0x0C |
| 溶解氧2 | 0x0D |
| 溶解氧3 | 0x0E |
| 溶解氧4 | 0x0F |
| pH1 | 0x03 |
| pH2 | 0x04 |
| pH3 | 0x05 |
| pH4 | 0x06 |

## 配置说明

### config.lua 配置项

```lua
local config = {
    -- 固件升级配置
    FIRMWARE_URL = "http://firmware.dtu.fanzhou.cloud/upgrade",
    PRODUCT_KEY = "YOUR_PRODUCT_KEY",
    
    -- 平台1 MQTT配置
    mqtt = {
        host = "mqtt.fanzhou.cloud",
        port = 1883,
        ssl = false,
        qos = 1,
        user = "nil",
        password = "YOUR_PASSWORD"
    },
    
    -- 平台2 CTWing配置
    mqtt2 = {
        host = "xxx.non-nb.ctwing.cn",
        port = 1883,
        product_id = "YOUR_PRODUCT_ID",
        password = "YOUR_PASSWORD"
    }
}
```

## 系统特性

### 看门狗
- 初始化超时：9秒
- 喂狗间隔：3秒

### 定时重启
- 周期：72小时（3天）

### 电流检测周期
- 采样间隔：200ms
- 组间切换：100ms

### 传感器采集周期
- 每个传感器间隔：1秒

## 开发环境

1. **开发工具**：LuaTools
2. **固件版本**：LuatOS-SoC_V2014_Air780EHM
3. **编程语言**：Lua 5.3

## 编译与烧录

1. 使用 LuaTools 打开项目
2. 选择正确的固件核心文件
3. 编译生成 .soc 文件
4. 通过USB连接设备进行烧录

## 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| 000.000.926 | 2025-09-02 | 当前版本 |

## 作者

**yankai** - 繁州科技

## 许可证

本项目为繁州科技内部项目，保留所有权利。
