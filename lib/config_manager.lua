local version = "0.1"
local module  = "config_manager"
local author = "yankai"

-- 初始化fskv数据库
if not fskv.init() then
    log.error("config", "fskv初始化失败!")
    sys.wait(1000)
    rtos.reboot()
end

local ConfigManager = {}
ConfigManager.__index = ConfigManager

-- 配置缓存
local config_cache = {}

-- 配置变更回调注册表
local change_callbacks = {}

-- 深度合并函数
local function deep_merge(t1, t2)
    for k, v in pairs(t2) do
        if type(v) == "table" then
            if type(t1[k]) ~= "table" then
                t1[k] = {}
            end
            deep_merge(t1[k], v)
        else
            t1[k] = v
        end
    end
end

-- ===========================================================================
-- @function   ConfigManager.load
-- @brief      加载配置文件
-- ===========================================================================
function ConfigManager.load(name, default)
    -- 检查是否已加载
    if config_cache[name] then
        return config_cache[name]
    end
    
    -- 尝试从fskv加载
    local config = fskv.get(name)
    
    -- 如果不存在，使用默认配置并保存
    if not config then
        config = default
        fskv.set(name, config)
        log.debug("config", "创建新配置", name)
    else
        log.debug("config", "加载配置", name)
    end
    
    -- 缓存配置
    config_cache[name] = config
    return config
end

-- ===========================================================================
-- @function   ConfigManager.update
-- @brief      更新配置
-- ===========================================================================
function ConfigManager.update(name, new_config, save_to_flash)
    if save_to_flash == nil then save_to_flash = true end
    
    -- 获取当前配置
    local current = config_cache[name]
    if not current then
        log.warn("config", "尝试更新未加载的配置", name)
        return false
    end
    
    -- 执行深度合并更新
    deep_merge(current, new_config)
    
    -- 保存到Flash
    if save_to_flash then
        fskv.set(name, current)
    end
    
    -- 触发变更回调
    if change_callbacks[name] then
        for _, callback in ipairs(change_callbacks[name]) do
            callback(current)
        end
    end
    
    log.debug("config", "配置已更新", name)
    return true
end

-- ===========================================================================
-- @function   ConfigManager.register_change_callback
-- @brief      注册配置变更回调
-- ===========================================================================
function ConfigManager.register_change_callback(name, callback)
    if not change_callbacks[name] then
        change_callbacks[name] = {}
    end
    table.insert(change_callbacks[name], callback)
    log.debug("config", "注册配置变更回调", name)
end

-- ===========================================================================
-- @function   ConfigManager.get
-- @brief      获取配置值
-- ===========================================================================
function ConfigManager.get(name, path)
    local config = config_cache[name]
    if not config then
        log.warn("config", "尝试获取未加载的配置", name)
        return nil
    end
    
    if not path then return config end
    
    -- 根据路径获取值
    local keys = {}
    for key in path:gmatch("[^%.]+") do
        table.insert(keys, key)
    end
    
    local value = config
    for _, key in ipairs(keys) do
        if type(value) ~= "table" then return nil end
        value = value[key]
    end
    
    return value
end


-- ===========================================================================
-- @function   ConfigManager.add_key
-- @brief      添加新键值对到配置
-- ===========================================================================
function ConfigManager.add_key(name, key_path, value, save_to_flash)
    if save_to_flash == nil then save_to_flash = true end
    
    -- 获取当前配置
    local config = config_cache[name]
    if not config then
        log.warn("config", "尝试向未加载配置中添加键", name)
        return false
    end
    
    -- 分解键路径
    local keys = {}
    for key in key_path:gmatch("[^%.]+") do
        table.insert(keys, key)
    end
    
    -- 查找或创建父级结构
    local parent = config
    for i, key in ipairs(keys) do
        if i < #keys then
            -- 创建中间表格（如果不存在）
            if type(parent[key]) ~= "table" then
                parent[key] = {}
            end
            parent = parent[key]
        else
            -- 设置最终键值
            parent[key] = value
        end
    end
    
    -- 保存到Flash
    if save_to_flash then
        fskv.set(name, config)
    end
    
    -- 触发变更回调
    if change_callbacks[name] then
        for _, callback in ipairs(change_callbacks[name]) do
            callback(config)
        end
    end
    
    log.debug("config", "配置键已添加", name, key_path)
    return true
end


-- ===========================================================================
-- @function   ConfigManager.delete_key
-- @brief      删除键值
-- ===========================================================================
function ConfigManager.delete_key(name, key_path, save_to_flash)
    if save_to_flash == nil then save_to_flash = true end
    
    -- 获取当前配置
    local config = config_cache[name]
    if not config then
        log.warn("config", "尝试删除未加载配置中的键", name)
        return false
    end
    
    -- 分解键路径
    local keys = {}
    for key in key_path:gmatch("[^%.]+") do
        table.insert(keys, key)
    end
    
    -- 查找并删除键
    local parent = config
    for i, key in ipairs(keys) do
        if i < #keys then
            if type(parent[key]) ~= "table" then
                log.warn("config", "路径不存在或不是表格", key_path)
                return false
            end
            parent = parent[key]
        else
            if parent[key] == nil then
                log.warn("config", "要删除的键不存在", key)
                return false
            end
            parent[key] = nil
        end
    end
    
    -- 保存到Flash
    if save_to_flash then
        fskv.set(name, config)
    end
    
    -- 触发变更回调
    if change_callbacks[name] then
        for _, callback in ipairs(change_callbacks[name]) do
            callback(config)
        end
    end
    
    log.debug("config", "配置键已删除", name, key_path)
    return true
end

-- ===========================================================================
-- @function   ConfigManager.status
-- @brief      获取配置系统状态
-- ===========================================================================
function ConfigManager.status()
    local used, total, count = fskv.status()
    return {
        config_count = count,
        cache_count = #config_cache,
        used = used,
        total = total,
        free_percent = math.floor((total - used) / total * 100)
    }
end

-- 打印配置系统状态
sys.timerLoopStart(function()
    local stat = ConfigManager.status()
    log.debug("config", 
        "配置状态:", 
        "配置数:"..stat.config_count,
        "缓存数:"..stat.cache_count,
        "使用:"..stat.used.."/"..stat.total.."字节",
        "空闲:"..stat.free_percent.."%")
end, 120000) -- 每2分钟打印一次

return ConfigManager