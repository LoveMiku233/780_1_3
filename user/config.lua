--[[
@file       config.lua
@module     config
@version    0.1
@date       2025-09-02
@author     yankai
@brief      系统配置模块
@description
    包含系统所有配置参数：
    1. 固件升级URL和产品密钥
    2. MQTT平台1（自有平台）配置
    3. MQTT平台2（CTWing电信平台）配置
    
    使用方法：
    local config = require("config")
    -- 访问配置
    local mqtt_host = config.mqtt.host
    -- 更新配置
    config.update({mqtt = {port = 1884}})
--]]

local config = {
    FIRMWARE_URL = "http://firmware.dtu.fanzhou.cloud/upgrade", -- 固件升级地址
    PRODUCT_KEY = "XJUDU1KX70pyrXS6aofI1qy7plwBj69X",  -- 产品 ota Key
    project_key = "a",  -- 不使用也需要填
    mqtt = {
        user = "nil",
        device_id = "", -- 设备ID,如果不填则使用imei或芯片ID
        -- 一型一密
        password = "rlKt2WnP9N3QmCT4",   
        host = "mqtt.fanzhou.cloud",
        port = 1883,
        ssl = false,
        qos = 1
    },
    mqtt2 = {
        device_id = "", -- 设备ID,如果不填则使用imei或芯片ID
        product_id = "17268131", -- 产品ID
        user = "nil",
        -- 一型一密
        password = "ibJJBhgwAfLovDG7ZWpaVKc8rkjCGe9-WWfQbWE3W5Y",
        host = "2000586160.non-nb.ctwing.cn",
        port = 1883,
        ssl = false,
        qos = 0
    },
}


function config.update(new_cfg)
    for k,v in pairs(new_cfg) do
        config[k] = v
    end
end

return config