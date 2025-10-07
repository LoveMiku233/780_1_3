--[[
@file       fanzhou_fota.lua
@module     fanzhou_fota
@version    0.1
@date       2025-05-20
@author     yankai
@brief      远程固件升级（FOTA）管理模块，支持 URL 下载、结果回调与定时检查
@description
  - 支持自定义升级服务器 URL、版本号与项目 Key
  - 提供初始化、启动定时检查与升级回调
  - 支持重启、错误日志记录与多种错误码反馈
--]]

local version = "0.1"
local module  = "fanzhou_fota"
local author = "yankai"

libfota2 = require "libfota2"

local _M = {}

local ota_opts = {
}


-- ===========================================================================
-- @function   fota_cb
-- @brief      升级结果回调，处理成功/错误并重启或记录日志
-- @param[in]  ret number 返回码：0 成功，1 连接失败，2 URL 错误，3 服务器断开，4 接收错误，5 版本格式错误
-- ===========================================================================  
local function fota_cb(ret)
    log.info("fota", ret)
    if ret == 0 then
        log.info("升级包下载成功,重启模块")
        rtos.reboot()
    elseif ret == 1 then
        log.info("连接失败", "请检查url拼写或服务器配置(是否为内网)")
    elseif ret == 2 then
        log.info("url错误", "检查url拼写")
    elseif ret == 3 then
        log.info("服务器断开", "检查服务器白名单配置")
    elseif ret == 4 then
        log.info("接收报文错误", "检查模块固件或升级包内文件是否正常")
    elseif ret == 5 then
        log.info("版本号书写错误", "iot平台版本号需要使用xxx.yyy.zzz形式")
    else
        log.info("不是上面几种情况 ret为", ret)
    end
end

-- ===========================================================================
-- @function   _M.print_version
-- @brief      打印脚本与核心固件的版本号
-- ===========================================================================  
function _M.print_version()
    log.info("fota", "脚本版本号", VERSION, "core版本号", rtos.version())
end



-- ===========================================================================
-- @function   _M.init
-- @brief      初始化 FOTA 配置，合并用户传入参数并打印版本信息
-- @param[in]  config table 用户配置（update_url, version, project_key, firmware_name, project）
-- ===========================================================================  
function _M.init(config)
    sys.taskInit(function()
        -- 合并配置参数到ota_opts
        if config.update_url then
            ota_opts.url = config.update_url
        end
        if config.project_key then
            ota_opts.project_key = config.project_key
        end

        _M.print_version()
        -- 开始检查
        libfota2.request(fota_cb, ota_opts)
    end)
end


-- ===========================================================================
-- @function   _M.start_timer_update
-- @brief      启动定时升级检查任务，每 24 小时请求一次升级
-- ===========================================================================  
function _M.start_timer_update()
    log.info("开始检查升级")
    -- 24小时检查一次
    sys.timerLoopStart(libfota2.request, 24 * 3600000, fota_cb, ota_opts)
end

return _M
