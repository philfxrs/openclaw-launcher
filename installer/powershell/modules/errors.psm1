# errors.psm1 — OpenClaw Installer Error Code Module
# Centralized error code definitions and exception helpers.
# Compatible with PowerShell 5.1+.

Set-StrictMode -Version Latest

$script:ErrorCodeTable = [ordered]@{
    'E1001' = '安装器初始化失败'
    'E1002' = '管理员权限获取失败'
    'E1003' = '日志初始化失败'
    'E1004' = '系统信息收集失败'
    'E2001' = 'Node.js 检测失败'
    'E2002' = 'Node.js 安装失败'
    'E2003' = 'npm 校验失败'
    'E2004' = 'Git 检测失败'
    'E2005' = 'Git 安装失败'
    'E2006' = '其他依赖安装失败（含 WebView2）'
    'E3001' = 'OpenClaw 安装失败'
    'E3002' = 'OpenClaw 安装后验证失败'
    'E3003' = 'OpenClaw 启动失败'
    'E4001' = '桌面图标创建失败'
    'E4002' = '快捷方式目标无效'
    'E5001' = '重复安装状态异常'
    'E5002' = '恢复安装失败'
    'E9001' = '未分类安装失败'
}

function New-InstallerException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [System.Exception]$InnerException
    )

    $exception = if ($InnerException) {
        New-Object System.Exception($Message, $InnerException)
    } else {
        New-Object System.Exception($Message)
    }

    $exception.Data['OpenClawErrorCode'] = $Code
    return $exception
}

function Get-InstallerErrorCode {
    [CmdletBinding()]
    param(
        [System.Exception]$Exception,
        [string]$DefaultCode = 'E9001'
    )

    $current = $Exception
    while ($current) {
        if ($current.Data -and $current.Data.Contains('OpenClawErrorCode')) {
            return [string]$current.Data['OpenClawErrorCode']
        }

        $current = $current.InnerException
    }

    return $DefaultCode
}

function Get-ErrorCodeDescription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code
    )

    if ($script:ErrorCodeTable.Contains($Code)) {
        return $script:ErrorCodeTable[$Code]
    }

    return '未知错误'
}

function Get-AllErrorCodes {
    return $script:ErrorCodeTable.Clone()
}

Export-ModuleMember -Function New-InstallerException, Get-InstallerErrorCode, Get-ErrorCodeDescription, Get-AllErrorCodes
