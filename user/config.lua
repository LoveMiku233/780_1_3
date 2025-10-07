local config = {
    FIRMWARE_URL = "http://firmware.dtu.fanzhou.cloud/upgrade", -- 固件升级地址
    PRODUCT_KEY = "B5Ae5hbGpXrzJm31L7jzQWBjUrjuolvW",  -- 产品 ota Key
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
    }
}


function config.update(new_cfg)
    for k,v in pairs(new_cfg) do
        config[k] = v
    end
end

return config