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