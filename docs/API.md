# API 文档

鱼塘远程控制系统 API 参考文档

## 目录

1. [继电器控制模块 (fz_relay)](#继电器控制模块-fz_relay)
2. [电流检测模块 (rn8302b)](#电流检测模块-rn8302b)
3. [MQTT通信模块 (fz_mqtt)](#mqtt通信模块-fz_mqtt)
4. [Modbus通信模块 (fz_modbus)](#modbus通信模块-fz_modbus)
5. [配置管理模块 (config_manager)](#配置管理模块-config_manager)
6. [工具函数模块 (fz_tools)](#工具函数模块-fz_tools)
7. [按键模块 (fz_key)](#按键模块-fz_key)
8. [ADC模块 (fz_adc)](#adc模块-fz_adc)
9. [OTA升级模块 (fz_fota)](#ota升级模块-fz_fota)

---

## 继电器控制模块 (fz_relay)

### 概述

提供4路继电器的控制功能，包括开关控制、状态读取和状态切换。

### 引入模块

```lua
local fzrelays = require("fz_relay")
```

### API

#### `fzrelays.init()`

初始化所有继电器引脚。

**返回值**：无

**示例**：
```lua
fzrelays.init()
```

---

#### `fzrelays.on(relay_name)`

打开指定继电器。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| relay_name | string | 继电器名称（"k1", "k2", "k3", "k4"） |

**返回值**：boolean - 操作是否成功

**示例**：
```lua
fzrelays.on("k1")  -- 打开继电器K1
```

---

#### `fzrelays.off(relay_name)`

关闭指定继电器。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| relay_name | string | 继电器名称 |

**返回值**：boolean - 操作是否成功

**示例**：
```lua
fzrelays.off("k2")  -- 关闭继电器K2
```

---

#### `fzrelays.toggle(relay_name)`

切换继电器状态（开变关，关变开）。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| relay_name | string | 继电器名称 |

**返回值**：number|nil - 切换后的状态（1=开，0=关），无效名称返回nil

**示例**：
```lua
local new_state = fzrelays.toggle("k3")
print("新状态:", new_state)
```

---

#### `fzrelays.get_mode(relay_name)`

获取继电器当前状态。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| relay_name | string | 继电器名称 |

**返回值**：number - 继电器状态（1=开，0=关）

**示例**：
```lua
local state = fzrelays.get_mode("k1")
if state == 1 then
    print("继电器K1已打开")
end
```

---

#### `fzrelays.set_mode(relay_name, mode)`

设置继电器模式。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| relay_name | string | 继电器名称 |
| mode | string | 模式（"on" 或 "off"） |

**返回值**：boolean - 操作是否成功

**示例**：
```lua
fzrelays.set_mode("k4", "on")   -- 打开
fzrelays.set_mode("k4", "off")  -- 关闭
```

---

## 电流检测模块 (rn8302b)

### 概述

基于软件SPI实现的RN8302B电流检测芯片驱动，支持双芯片12路电流检测。

### 引入模块

```lua
local rn8302b = require("rn8302b")
```

### API

#### `rn8302b.init(config_table)`

初始化RN8302B模块。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| config_table | table | 可选配置表 |

**配置表字段**：
| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| SPI_CS1 | number | 5 | 芯片1片选引脚 |
| SPI_CS2 | number | 4 | 芯片2片选引脚 |
| SPI_CLK | number | 3 | 时钟引脚 |
| SPI_MISO | number | 6 | MISO引脚 |
| SPI_MOSI | number | 7 | MOSI引脚 |
| calibration_factor | number | 0.01203 | 校准系数 |
| division_factor | number | 100000 | 分频系数 |
| delay_us | number | 5 | 微秒级延时 |

**返回值**：boolean - 初始化是否成功

**示例**：
```lua
rn8302b.init()
-- 或自定义配置
rn8302b.init({
    calibration_factor = 0.012,
    delay_us = 10
})
```

---

#### `rn8302b.read_single_current(nSPI_CS, channel, samples)`

读取单个通道的电流值。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| nSPI_CS | number | 芯片选择（1或2） |
| channel | number | 通道号（1-6） |
| samples | number | 可选，采样次数，默认1 |

**返回值**：number - 电流值（安培）

**示例**：
```lua
-- 读取芯片1通道1的电流
local current = rn8302b.read_single_current(1, 1)
print("电流:", current, "A")

-- 读取5次取平均值
local avg_current = rn8302b.read_single_current(1, 1, 5)
```

---

#### `rn8302b.read_all_currents(nSPI_CS, samples)`

读取指定芯片的所有6个通道电流值。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| nSPI_CS | number | 芯片选择（1或2） |
| samples | number | 可选，每通道采样次数 |

**返回值**：table - 包含6个电流值的数组

**示例**：
```lua
local currents = rn8302b.read_all_currents(1)
for i, current in ipairs(currents) do
    print("通道" .. i .. ":", current, "A")
end
```

---

#### `rn8302b.set_calibration(division, calibration)`

设置校准参数。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| division | number | 分频系数 |
| calibration | number | 校准系数 |

**示例**：
```lua
rn8302b.set_calibration(100000, 0.012)
```

---

## MQTT通信模块 (fz_mqtt)

### 概述

支持多实例的MQTT客户端封装，提供连接、发布、订阅和回调处理功能。

### 引入模块

```lua
local fzmqtt = require("fz_mqtt")
```

### API

#### `fzmqtt.new(cfg)`

创建新的MQTT客户端实例。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| cfg | table | 配置表 |

**配置表字段**：
| 字段 | 类型 | 说明 |
|------|------|------|
| host | string | 服务器地址 |
| port | number | 端口号 |
| ssl | boolean | 是否启用SSL |
| user | string | 用户名 |
| password | string | 密码 |
| device_id | string | 设备ID |
| keepalive | number | 心跳间隔（秒） |
| autoreconn | boolean | 是否自动重连 |
| reconnect_interval | number | 重连间隔（毫秒） |

**返回值**：table - MQTT实例

**示例**：
```lua
local mqtt = fzmqtt.new({
    host = "mqtt.example.com",
    port = 1883,
    user = "user",
    password = "pass"
})
```

---

#### `mqtt:init()`

初始化MQTT客户端。

**返回值**：boolean - 初始化是否成功

**示例**：
```lua
mqtt:init()
```

---

#### `mqtt:connect()`

连接到MQTT服务器。

**返回值**：boolean - 连接请求是否成功发送

**示例**：
```lua
mqtt:connect()
sys.waitUntil(mqtt:get_instance_id().."CONNECTED")
```

---

#### `mqtt:publish(topic, data, qos)`

发布消息。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| topic | string | 发布主题 |
| data | string | 消息内容 |
| qos | number | 服务质量（0, 1, 2） |

**返回值**：boolean - 发布是否成功

**示例**：
```lua
mqtt:publish("sensor/data", '{"temp":25.5}', 0)
```

---

#### `mqtt:subscribe(topic, qos, callback)`

订阅主题。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| topic | string | 订阅主题 |
| qos | number | 服务质量 |
| callback | function | 收到消息的回调函数 |

**返回值**：boolean - 订阅是否成功

**示例**：
```lua
mqtt:subscribe("control/cmd", 0, function(payload)
    local data = json.decode(payload)
    print("收到命令:", data)
end)
```

---

#### `mqtt:get_is_connected()`

获取连接状态。

**返回值**：boolean - 是否已连接

**示例**：
```lua
if mqtt:get_is_connected() then
    print("MQTT已连接")
end
```

---

#### `mqtt:close()`

关闭连接并清理资源。

**示例**：
```lua
mqtt:close()
```

---

## Modbus通信模块 (fz_modbus)

### 概述

提供Modbus RTU协议的封装与串口通信支持。

### 引入模块

```lua
local fzmodbus = require("fz_modbus")
```

### API

#### `fzmodbus.new(config)`

创建Modbus实例。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| config | table | 配置表 |

**配置表字段**：
| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| is_485 | number | 0 | 是否为485模式 |
| uartid | number | 1 | 串口ID |
| baudrate | number | 9600 | 波特率 |
| databits | number | 8 | 数据位 |
| stopbits | number | 1 | 停止位 |
| gpio_485 | number | 27 | 485方向控制引脚 |

**返回值**：table - Modbus实例

**示例**：
```lua
local modbus = fzmodbus.new({
    uartid = 1,
    baudrate = 9600,
    is_485 = 1,
    gpio_485 = 16
})
```

---

#### `modbus:send_command(addr, fun, data, interval)`

发送Modbus命令。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| addr | number | 从站地址 |
| fun | number | 功能码 |
| data | string | 数据部分 |
| interval | number | 可选，定时发送间隔 |

**示例**：
```lua
-- 读取保持寄存器
modbus:send_command(0x01, 0x03, string.char(0x00, 0x00, 0x00, 0x04))
```

---

#### `modbus:set_receive_callback(need_handle, callback)`

设置接收回调。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| need_handle | boolean | 是否自动解析帧 |
| callback | function | 回调函数 |

**示例**：
```lua
modbus:set_receive_callback(true, function(frame)
    print("地址:", frame.addr)
    print("功能码:", frame.fun)
    print("数据:", frame.payload:toHex())
end)
```

---

## 配置管理模块 (config_manager)

### 概述

基于fskv的配置管理器，支持配置的加载、保存和更新。

### 引入模块

```lua
local db = require("config_manager")
```

### API

#### `db.load(name, default)`

加载配置。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| name | string | 配置名称 |
| default | table | 默认配置 |

**返回值**：table - 配置数据

**示例**：
```lua
local timers = db.load("timers", {
    enable = false,
    on_list = {},
    off_list = {}
})
```

---

#### `db.update(name, new_config, save_to_flash)`

更新配置。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| name | string | 配置名称 |
| new_config | table | 新配置 |
| save_to_flash | boolean | 是否保存到Flash |

**返回值**：boolean - 更新是否成功

**示例**：
```lua
db.update("timers", {enable = true})
```

---

#### `db.get(name, path)`

获取配置值。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| name | string | 配置名称 |
| path | string | 可选，配置路径（用点分隔） |

**返回值**：any - 配置值

**示例**：
```lua
local enable = db.get("timers", "enable")
```

---

## 工具函数模块 (fz_tools)

### 概述

常用工具函数集合。

### 引入模块

```lua
local fztools = require("fz_tools")
```

### API

#### `fztools.check_crc(data)`

检查Modbus CRC校验。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| data | string/table | 数据（字符串或字节数组） |

**返回值**：boolean - CRC是否正确

**示例**：
```lua
if fztools.check_crc(data) then
    print("CRC校验通过")
end
```

---

#### `fztools.hex_to_bytes(hex_str)`

将十六进制字符串转换为字节数组。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| hex_str | string | 十六进制字符串 |

**返回值**：table - 字节数组

**示例**：
```lua
local bytes = fztools.hex_to_bytes("010304")
-- bytes = {1, 3, 4}
```

---

#### `fztools.hexToBinary(hexStr)`

将十六进制字符串转换为二进制字符串。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| hexStr | string | 十六进制字符串 |

**返回值**：string - 二进制字符串

**示例**：
```lua
local binary = fztools.hexToBinary("48656C6C6F")
-- binary = "Hello"
```

---

#### `fztools.timeToBCD()`

获取当前时间的BCD格式。

**返回值**：string - BCD格式时间字符串（YYMMDDhhmmss）

**示例**：
```lua
local bcdTime = fztools.timeToBCD()
-- 返回如 "250902143022"
```

---

## 按键模块 (fz_key)

### 概述

按键输入处理模块，支持中断检测和消抖。

### 引入模块

```lua
local fzkeys = require("fz_key")
```

### API

#### `fzkeys.init()`

初始化所有按键。

**示例**：
```lua
fzkeys.init()
```

---

#### 按键事件

按键按下后会发布 `KEY` 事件，可通过 `sys.waitUntil` 接收：

```lua
sys.taskInit(function()
    while true do
        local _, key_name = sys.waitUntil("KEY")
        print("按键按下:", key_name)  -- "k1", "k2", "k3" 或 "k4"
    end
end)
```

---

## ADC模块 (fz_adc)

### 概述

ADC电压采集模块。

### 引入模块

```lua
local fzadcs = require("fz_adc")
```

### API

#### `fzadcs.init(adc_channel, max_voltage)`

初始化ADC通道。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| adc_channel | number | ADC通道号 |
| max_voltage | number | 最大电压（V） |

**示例**：
```lua
fzadcs.init(0, 4.0)  -- 初始化通道0，最大电压4V
```

---

#### `fzadcs.get_adc(adc_channel)`

获取ADC电压值。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| adc_channel | number | ADC通道号 |

**返回值**：number - 电压值（mV）

**示例**：
```lua
local voltage = fzadcs.get_adc(0)
print("电压:", voltage, "mV")
```

---

## OTA升级模块 (fz_fota)

### 概述

远程固件升级模块。

### 引入模块

```lua
local fzfota = require("fz_fota")
```

### API

#### `fzfota.init(config)`

初始化OTA模块。

**参数**：
| 参数 | 类型 | 说明 |
|------|------|------|
| config | table | 配置表 |

**配置表字段**：
| 字段 | 类型 | 说明 |
|------|------|------|
| update_url | string | 升级服务器URL |
| project_key | string | 项目密钥 |

**示例**：
```lua
fzfota.init({
    update_url = "http://firmware.example.com/upgrade?imei=xxx",
    project_key = "your_key"
})
```

---

#### `fzfota.start_timer_update()`

启动定时检查升级任务（每24小时检查一次）。

**示例**：
```lua
fzfota.start_timer_update()
```

---

#### `fzfota.print_version()`

打印当前固件版本信息。

**示例**：
```lua
fzfota.print_version()
-- 输出: 脚本版本号 xxx core版本号 xxx
```

---

## 附录

### 错误处理

所有模块的API在发生错误时通常会：
1. 返回 `false` 或 `nil`
2. 通过 `log.error()` 或 `log.warn()` 输出错误信息

建议在调用API时检查返回值：

```lua
local result = mqtt:connect()
if not result then
    log.error("MQTT", "连接失败")
end
```

### 日志级别

系统使用以下日志级别：
- `log.debug()` - 调试信息
- `log.info()` - 一般信息
- `log.warn()` - 警告信息
- `log.error()` - 错误信息

可通过 `log.setLevel()` 设置日志级别：

```lua
log.setLevel("DEBUG")  -- 显示所有日志
log.setLevel("INFO")   -- 隐藏DEBUG日志
log.setLevel("WARN")   -- 只显示警告和错误
```
