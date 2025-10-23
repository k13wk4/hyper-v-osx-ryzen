<#
.SYNOPSIS
  Универсальный PowerShell-инсталлятор macOS в Hyper-V (v2)
.DESCRIPTION
  Считывает железо, проверяет Hyper-V/виртуализацию, ставит зависимости,
  скачивает и собирает OpenCore (Qonfused/OSX-Hyper-V), создаёт VM.
.NOTES
  Запускать из elevated PowerShell (Run as Administrator).
  Лог файл: C:\macos_setup_log.txt
#>

# -------------------------
# Настройки логирования
# -------------------------
$Global:LogPath = "C:\macos_setup_log.txt"
if (-not (Test-Path $Global:LogPath)) {
    New-Item -Path $Global:LogPath -ItemType File -Force | Out-Null
}
function Log {
    param([string]$Text)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$ts `t $Text" | Out-File -FilePath $Global:LogPath -Append -Encoding UTF8
}
function Write-Status {
    param([string]$Text, [ConsoleColor]$Color = "White")
    $old = $Host.UI.RawUI.ForegroundColor
    $Host.UI.RawUI.ForegroundColor = $Color
    Write-Host $Text
    $Host.UI.RawUI.ForegroundColor = $old
    Log $Text
}

# -------------------------
# Проверка прав администратора
# -------------------------
function Assert-Admin {
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
        if (-not $isAdmin) {
            Write-Status "ERROR: Скрипт должен быть запущен с правами администратора! (Run as Administrator)" Red
            Log "Прерывание: нет прав администратора."
            throw "NoAdmin"
        } else {
            Write-Status "Запущено с правами администратора." Green
        }
    } catch {
        throw
    }
}

# -------------------------
# Небольшие утилиты
# -------------------------
function Safe-Invoke {
    param([scriptblock]$Script, [string]$ErrorMsg)
    try {
        & $Script
    } catch {
        Write-Status "Ошибка: $ErrorMsg - $($_.Exception.Message)" Red
        Log "Exception: $($_.Exception | Out-String)"
        throw $_
    }
}

# -------------------------
# Проверки аппаратной поддержки виртуализации
# -------------------------
function Check-HardwareSupport {
    Write-Status "[1/6] Проверяем аппаратную поддержку виртуализации..." Cyan
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor
        $vtx = $cpu.VMMonitorModeExtensions
        $slt = $cpu.SecondLevelAddressTranslationExtensions
        $name = $cpu.Name
        Write-Status "CPU: $name" Yellow
        Write-Status "VMMonitorModeExtensions (VT-x / SVM): $vtx" Yellow
        Write-Status "SecondLevelAddressTranslationExtensions (SLAT): $slt" Yellow
        Log "Processor raw object: $(($cpu | Select-Object -Property * | Out-String))"

        if (-not $vtx -or -not $slt) {
            Write-Status "WARN: Процессор не имеет необходимых аппаратных расширений (VT-x/SVM или SLAT)." Yellow
            return $false
        }
        return $true
    } catch {
        Write-Status "Не удалось определить аппаратную поддержку виртуализации: $($_.Exception.Message)" Red
        Log $_.Exception
        return $false
    }
}

# -------------------------
# Проверки состояния Hyper-V / гипервизора
# -------------------------
function Check-HyperV {
    Write-Status "[2/6] Проверяем состояние Hyper-V и гипервизора..." Cyan
    try {
        # 1) Проверяем роль Hyper-V (Windows feature)
        $hvFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue
        if ($null -eq $hvFeature) {
            Write-Status "WARN: Не удалось получить состояние роли Hyper-V." Yellow
            Log "Get-WindowsOptionalFeature вернул null."
        } else {
            Write-Status "Hyper-V feature state: $($hvFeature.State)" Yellow
            Log "Hyper-V feature raw: $($hvFeature | Out-String)"
        }

        # 2) Проверяем присутствие гипервизора в системе
        $hypervisorPresent = $false
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            if ($cs.PSObject.Properties.Match("HypervisorPresent").Count -gt 0) {
                $hypervisorPresent = [bool]$cs.HypervisorPresent
                Write-Status "HypervisorPresent (Win32_ComputerSystem): $hypervisorPresent" Yellow
            } else {
                Write-Status "Win32_ComputerSystem.HypervisorPresent не доступен на этой системе." Yellow
            }
            Log "Win32_ComputerSystem: $($cs | Out-String)"
        } catch {
            Write-Status "Не удалось прочитать Win32_ComputerSystem: $($_.Exception.Message)" Yellow
            Log $_.Exception
        }

        # 3) Проверяем загрузочную опцию гипервизора в BCD
        $bcd = bcdedit /enum | Out-String
        $hvLaunch = ($bcd -match "hypervisorlaunchtype\s+(\w+)") | Out-Null
        $hvLaunchType = ""
        if ($bcd -match "hypervisorlaunchtype\s+(\w+)") {
            $hvLaunchType = $Matches[1]
            Write-Status "bcdedit hypervisorlaunchtype: $hvLaunchType" Yellow
            Log "bcdedit: $bcd"
        } else {
            Write-Status "bcdedit не обнаружил hypervisorlaunchtype." Yellow
            Log "bcdedit raw: $bcd"
        }

        # 4) systeminfo fallback (может быть скрыто если VBS запущен)
        $sysinfo = systeminfo 2>$null
        if ($sysinfo -match "Обнаружена низкоуровневая оболочка") {
            Write-Status "systeminfo сообщает: Обнаружена низкоуровневая оболочка. Некоторые параметры скрыты (возможно включён VBS/гипервизор)." Yellow
            Log "systeminfo low-level shell: $sysinfo"
        } else {
            # попытка получить строки Virtualization Enabled In Firmware/Second Level...
            if ($sysinfo -match "Virtualization Enabled In Firmware:\s*(Yes|No)") {
                $virtEnabled = $Matches[1]
                Write-Status "Virtualization Enabled In Firmware: $virtEnabled" Yellow
            }
            if ($sysinfo -match "Second Level Address Translation:\s*(Yes|No)") {
                $sltVal = $Matches[1]
                Write-Status "Second Level Address Translation: $sltVal" Yellow
            }
            Log "systeminfo: $sysinfo"
        }

        # Решение о состоянии: если роль Hyper-V включена или hypervisorPresent true или bcd hypervisorlaunchtype = Auto, считаем что гипервизор доступен/включён
        $hvEnabled = $false
        if ($hvFeature -and $hvFeature.State -eq "Enabled") { $hvEnabled = $true }
        if ($hypervisorPresent) { $hvEnabled = $true }
        if ($hvLaunchType -and $hvLaunchType.ToLower() -eq "auto") { $hvEnabled = $true }

        if (-not $hvEnabled) {
            Write-Status "Hyper-V не активен или требуется включение (репозитория/зависимости не установлены)." Yellow
            return @{ Ok = $false; Reason = "HyperVNotEnabled" }
        } else {
            Write-Status "Hyper-V доступен/включён." Green
            return @{ Ok = $true; Reason = "" }
        }
    } catch {
        Write-Status "Ошибка при проверке Hyper-V: $($_.Exception.Message)" Red
        Log $_.Exception
        return @{ Ok = $false; Reason = "Exception" }
    }
}

# -------------------------
# Установка инструментов (git, python) если нужны
# -------------------------
function Install-Tools {
    Write-Status "[3/6] Проверка и установка необходимых инструментов (git, python, 7zip)..." Cyan
    try {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Write-Status "Git не найден. Ставит через winget..." Yellow
            winget install --id Git.Git -e --source winget --silent | Out-Null
            Start-Sleep -Seconds 3
        } else { Write-Status "Git: OK" Green }

        if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
            Write-Status "Python не найден. Ставит через winget..." Yellow
            winget install --id Python.Python.3 -e --source winget --silent | Out-Null
            Start-Sleep -Seconds 3
        } else { Write-Status "Python: OK" Green }

        # 7zip - полезен для распаковки zip
        if (-not (Get-Command 7z -ErrorAction SilentlyContinue)) {
            Write-Status "7zip не найден. Попробуем winget..." Yellow
            winget install --id Igor.Petrov.7zip -e --source winget -h | Out-Null
            # Пробуем альтернативно установить p7zip если выше не сработало.
        } else { Write-Status "7zip: OK" Green }

        return $true
    } catch {
        Write-Status "Ошибка при установке инструментов: $($_.Exception.Message)" Red
        Log $_.Exception
        return $false
    }
}

# -------------------------
# Сбор информации о системе
# -------------------------
function Get-SystemSpecs {
    Write-Status "[4/6] Считываем информацию о системе..." Cyan
    try {
        $cpuObj = Get-CimInstance Win32_Processor | Select-Object -First 1
        $cpuName = $cpuObj.Name
        $logical = $cpuObj.NumberOfLogicalProcessors
        $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        $gpus = (Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name) -join ", "
        Log "System specs: CPU=$cpuName; Logical=$logical; RAM=${ram}GB; GPUs=$gpus"
        return @{ CPU = $cpuName; Cores = $logical; RAM = $ram; GPUs = $gpus }
    } catch {
        Write-Status "Не удалось получить информацию о системе: $($_.Exception.Message)" Red
        Log $_.Exception
        throw $_
    }
}

# -------------------------
# Выбор версии macOS
# -------------------------
function Select-macOSVersion {
    param([string]$cpuName, [string]$gpus)
    Write-Status "[5/6] Выбор версии macOS" Cyan

    # словарь: ключ = версия идентификатор, value = @{name, minRam, recommendedRam, recommendedCores, diskGB}
    $all = @{
        "10.15" = @{ name="Catalina (10.15)"; minRam=4; recRam=8; recCores=2; disk=64 }
        "11"    = @{ name="Big Sur (11.x)"; minRam=8; recRam=8; recCores=2; disk=64 }
        "12"    = @{ name="Monterey (12.x)"; minRam=8; recRam=8; recCores=2; disk=64 }
        "13"    = @{ name="Ventura (13.x)"; minRam=8; recRam=8; recCores=2; disk=64 }
        "14"    = @{ name="Sonoma (14.x)"; minRam=8; recRam=8; recCores=2; disk=64 }
    }

    # ограничение при AMD CPU
    if ($cpuName -match "AMD") {
        # оставляем более проверенные сборки на AMD
        $supportedKeys = @("10.15","11","12")
    } else {
        $supportedKeys = $all.Keys
    }

    # ограничение при NVIDIA в GPU (но это не строго — Hyper-V использует синтетику)
    if ($gpus -match "NVIDIA") {
        Write-Status "Обнаружена NVIDIA GPU - аппаратная графика для macOS через Hyper-V, вероятно, недоступна. Это не блокер." Yellow
    }

    # Отображаем список
    $idx = 0
    $menu = @()
    foreach ($k in $supportedKeys) {
        $item = $all[$k]
        Write-Host ("[{0}] {1} — minRAM {2}GB, recRAM {3}GB, recCores {4}, disk {5}GB" -f $idx, $item.name, $item.minRam, $item.recRam, $item.recCores, $item.disk)
        $menu += $k
        $idx++
    }

    $selIndex = Read-Host "Введите номер версии (например 0)"
    if (-not ([int]::TryParse($selIndex,[ref]$null))) {
        Write-Status "Неправильный ввод. Выход." Red
        throw "BadInput"
    }
    $selIndex = [int]$selIndex
    if ($selIndex -lt 0 -or $selIndex -ge $menu.Count) {
        Write-Status "Индекс вне диапазона." Red
        throw "IndexOutOfRange"
    }
    $ver = $menu[$selIndex]
    $chosen = $all[$ver]
    Write-Status "Выбрано: $($chosen.name)" Green
    return @{ Version = $ver; Meta = $chosen }
}

# -------------------------
# Скачивание репозитория и сборка EFI (Qonfused)
# -------------------------
function Build-OpenCore {
    param([string]$cpuName, [int]$cores)
    Write-Status "[6/6] Скачиваем OSX-Hyper-V и запускаем сборку OpenCore (если доступно)..." Cyan
    try {
        $repoUrl = "https://github.com/Qonfused/OSX-Hyper-V.git"
        $dest = "$env:TEMP\OSX-Hyper-V"
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        git clone $repoUrl $dest
        if (-not (Test-Path $dest)) {
            Write-Status "Не удалось скачать репозиторий." Red
            throw "GitCloneFailed"
        }
        Push-Location $dest
        # Устанавливаем политику исполнения для локальной сессии
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force

        if ($cpuName -match "AMD") {
            Write-Status "Запуск скрипта amd.ps1 для генерации AMD-патчей..." Yellow
            if (Test-Path ".\scripts\amd.ps1") {
                & .\scripts\amd.ps1 --cpu $cores
            } else {
                Write-Status "amd.ps1 не найден в репозитории." Red
            }
        }

        if (Test-Path ".\scripts\build.ps1") {
            Write-Status "Запуск build.ps1..." Yellow
            & .\scripts\build.ps1
        } else {
            Write-Status "build.ps1 не найден - возможно структура репозитория изменилась." Red
            Log (Get-ChildItem -Recurse | Out-String)
            Pop-Location
            throw "BuildScriptMissing"
        }
        Pop-Location
        Write-Status "Сборка завершена (проверьте ./dist в репозитории)." Green
        return $dest
    } catch {
        Write-Status "Ошибка при сборке OpenCore: $($_.Exception.Message)" Red
        Log $_.Exception
        throw
    }
}

# -------------------------
# Создание виртуальной машины (через скрипты dist/Scripts)
# -------------------------
function Create-VM {
    param(
        [string]$RepoPath,
        [string]$Version,
        [int]$Cores,
        [int]$RAM,
        [int]$DiskGB
    )
    Write-Status "Создаём виртуальную машину через скрипты из $RepoPath/dist/Scripts ..." Cyan
    try {
        $scriptPath = Join-Path -Path $RepoPath -ChildPath "dist\Scripts\create-virtual-machine.ps1"
        if (-not (Test-Path $scriptPath)) {
            Write-Status "Скрипт create-virtual-machine.ps1 не найден. Проверьте папку dist/Scripts." Red
            Log (Get-ChildItem -Path (Join-Path $RepoPath "dist") -Recurse -Force | Out-String)
            throw "CreateScriptMissing"
        }
        # Формируем параметры
        $vmName = "macOS_$Version"
        Write-Status "Выполнение: $scriptPath -Name $vmName -Version $Version -CPU $Cores -RAM $RAM -Size $DiskGB" Yellow
        & $scriptPath -Name $vmName -Version $Version -CPU $Cores -RAM $RAM -Size $DiskGB
        Write-Status "VM создана: $vmName (если скрипт завершился без ошибок)." Green
    } catch {
        Write-Status "Ошибка при создании VM: $($_.Exception.Message)" Red
        Log $_.Exception
        throw
    }
}

# -------------------------
# Главная логика
# -------------------------
try {
    Assert-Admin

    Log "=== START INSTALL v2 ==="
    Write-Status "Начинаем проверку системы..." Cyan

    $hwOk = Check-HardwareSupport
    if (-not $hwOk) {
        Write-Status "Критическая ошибка: аппаратная поддержка виртуализации отсутствует или не полная. Останов." Red
        throw "HardwareMissing"
    }

    $hv = Check-HyperV
    if (-not $hv.Ok) {
        # Если Hyper-V не включён — предлагаем включить
        if ($hv.Reason -eq "HyperVNotEnabled") {
            Write-Status "Hyper-V не включён. Хотите включить Hyper-V сейчас и перезагрузить систему? (Y/N)" Yellow
            $ans = Read-Host
            if ($ans -match '^[Yy]') {
                Write-Status "Включаем Hyper-V..." Yellow
                Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart | Out-Null
                Write-Status "Hyper-V включён. НЕОБХОДИМА ПЕРЕЗАГРУЗКА. Перезагрузить прямо сейчас? (Y/N)" Yellow
                $r = Read-Host
                if ($r -match '^[Yy]') {
                    Log "User chose to restart the machine now."
                    Restart-Computer -Force
                    exit 0
                } else {
                    Write-Status "Прервали для перезагрузки. Запустите скрипт снова после перезагрузки." Yellow
                    exit 0
                }
            } else {
                Write-Status "Hyper-V не включён — скрипт завершён." Red
                exit 1
            }
        } else {
            Write-Status "Hyper-V: неизвестное состояние — скрипт завершён." Red
            exit 1
        }
    }

    # Инструменты
    $toolsOk = Install-Tools
    if (-not $toolsOk) {
        Write-Status "Не удалось установить необходимые инструменты. Проверьте winget и подключение к сети." Red
        throw "ToolsInstallFailed"
    }

    # Сбор характеристик
    $specs = Get-SystemSpecs
    $selection = Select-macOSVersion -cpuName $specs.CPU -gpus $specs.GPUs
    $ver = $selection.Version
    $meta = $selection.Meta

    # Подготовка сборки/скачивание и сборка EFI
    $repoPath = Build-OpenCore -cpuName $specs.CPU -cores $specs.Cores

    # Создание VM с рекомендованными параметрами (можно изменить)
    $recRAM = $meta.recRam
    $recCores = $meta.recCores
    $diskGB = $meta.disk
    Create-VM -RepoPath $repoPath -Version $ver -Cores $recCores -RAM $recRAM -DiskGB $diskGB

    Write-Status "Установка завершена. Проверьте Hyper-V Manager и запустите VM." Green
    Log "=== FINISH SUCCESS ==="
} catch {
    Write-Status "Скрипт завершился с ошибкой: $($_.Exception.Message)" Red
    Log ("Fatal exception: " + ($_ | Out-String))
    Write-Status "Лог доступен в $Global:LogPath" Yellow
    throw
}
