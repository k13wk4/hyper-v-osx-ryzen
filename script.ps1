<#
install_v3.ps1
Universal macOS on Hyper-V installer (v3)
- Saves logs to C:\macos_setup_log.txt
- Creates a one-time scheduled task to resume after reboot if enabling Hyper-V
USAGE: Save to C:\install_v3.ps1 and run from elevated PowerShell:
  powershell -ExecutionPolicy Bypass -File C:\install_v3.ps1
#>

Param(
    [switch]$resume   # internal flag: script was started by scheduled task after reboot
)

# -----------------------------
# Конфигурация логирования
# -----------------------------
$Global:LogPath = "C:\macos_setup_log.txt"
if (-not (Test-Path $Global:LogPath)) {
    New-Item -Path $Global:LogPath -ItemType File -Force | Out-Null
}
function Log([string]$text) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$ts`t$text" | Out-File -FilePath $Global:LogPath -Append -Encoding UTF8
}
function Write-Status([string]$text, [ConsoleColor]$color = "White") {
    $old = $Host.UI.RawUI.ForegroundColor
    $Host.UI.RawUI.ForegroundColor = $color
    Write-Host $text
    $Host.UI.RawUI.ForegroundColor = $old
    Log $text
}

# -----------------------------
# Прерывание безопасно
# -----------------------------
function Abort([string]$reason) {
    Write-Status "ABORT: $reason" Red
    Log "ABORT: $reason"
    Write-Status "См. лог: $Global:LogPath" Yellow
    exit 1
}

# -----------------------------
# Проверка прав администратора
# -----------------------------
function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    if (-not $isAdmin) {
        Log "No admin"
        Write-Status "Ошибка: запустите PowerShell как администратор." Red
        throw "NoAdmin"
    } else {
        Write-Status "Запущено с правами администратора." Green
        Log "Admin confirmed"
    }
}

# -----------------------------
# Утилиты
# -----------------------------
function Run-ProcAndLog($file, $args) {
    try {
        $p = Start-Process -FilePath $file -ArgumentList $args -NoNewWindow -Wait -PassThru -WindowStyle Hidden
        Log "Run-Proc: $file $args ExitCode=$($p.ExitCode)"
        return $p.ExitCode
    } catch {
        Log "Run-Proc exception: $($_.Exception | Out-String)"
        throw
    }
}

# -----------------------------
# Проверки аппаратной виртуализации (умная)
# -----------------------------
function Check-VirtualizationHardware {
    Write-Status "[CHECK] Проверка аппаратной поддержки виртуализации (WMI + systeminfo + bcdedit)..." Cyan
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop
        $virtFirmware = $cpu.VirtualizationFirmwareEnabled
        $vmExt = $cpu.VMMonitorModeExtensions
        $slt = $cpu.SecondLevelAddressTranslationExtensions

        Write-Status "CPU: $($cpu.Name)" Yellow
        Write-Status "VirtualizationFirmwareEnabled: $virtFirmware" Yellow
        Write-Status "VMMonitorModeExtensions: $vmExt" Yellow
        Write-Status "SecondLevelAddressTranslationExtensions: $slt" Yellow
        Log ("CPU object: " + ($cpu | Select-Object -Property Name, VMMonitorModeExtensions, SecondLevelAddressTranslationExtensions, VirtualizationFirmwareEnabled | Out-String))

        # systeminfo fallback
        $sys = (systeminfo 2>$null) -join "`n"
        if ($sys -match "Обнаружена низкоуровневая оболочка") {
            Write-Status "systeminfo сообщает: обнаружена низкоуровневая оболочка (параметры могут быть скрыты) — возможно VBS/Hyper-V активен." Yellow
            Log "systeminfo low-level shell"
        } else {
            if ($sys -match "Virtualization Enabled In Firmware:\s*(Yes|No)") {
                Write-Status "systeminfo: $($Matches[1])" Yellow
                Log "systeminfo virtualization: $($Matches[1])"
            }
            if ($sys -match "Second Level Address Translation:\s*(Yes|No)") {
                Write-Status "systeminfo SLAT: $($Matches[1])" Yellow
                Log "systeminfo slat: $($Matches[1])"
            }
        }

        # bcdedit check
        $bcd = (bcdedit /enum) -join "`n"
        if ($bcd -match "hypervisorlaunchtype\s+(\w+)") {
            $hvLaunch = $Matches[1]
            Write-Status "bcdedit hypervisorlaunchtype: $hvLaunch" Yellow
            Log "bcdedit hypervisorlaunchtype: $hvLaunch"
        } else {
            Write-Status "bcdedit: hypervisorlaunchtype not found" Yellow
            Log "bcdedit no hypervisorlaunchtype entry"
        }

        # Win32_ComputerSystem hypervisor presence
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        $hypervisorPresent = $false
        if ($cs -and $cs.PSObject.Properties.Match("HypervisorPresent").Count -gt 0) {
            $hypervisorPresent = [bool]$cs.HypervisorPresent
            Write-Status "Win32_ComputerSystem.HypervisorPresent: $hypervisorPresent" Yellow
        } else {
            Write-Status "Win32_ComputerSystem.HypervisorPresent unavailable" Yellow
            Log "Win32_ComputerSystem no HypervisorPresent"
        }

        # VBS / HVCI check (Device Guard)
        $deviceGuard = Get-CimInstance -Namespace root\cimv2\security\microsoftsecurity -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
        $vbsRunning = $false
        if ($deviceGuard) {
            # если SecurityServicesRunning содержит код (непусто), то VBS работает
            $svc = $deviceGuard.SecurityServicesRunning
            if ($svc) {
                $vbsRunning = $true
            }
            Write-Status "DeviceGuard.SecurityServicesRunning: $($svc -join ',')" Yellow
            Log "DeviceGuard: $($deviceGuard | Out-String)"
        } else {
            Write-Status "DeviceGuard info not available." Yellow
        }

        # Интерпретация: считаем виртуализацию доступной если:
        # - VirtualizationFirmwareEnabled == True (BIOS) AND (vmExt or slat true)
        # OR
        # - HypervisorPresent == True OR bcd hypervisorlaunchtype == Auto OR systeminfo reports virtualization enabled
        $sysVirtReported = ($sys -match "Virtualization Enabled In Firmware:\s*Yes")
        $hvLaunchAuto = ($hvLaunch -and $hvLaunch.ToLower() -eq "auto")
        $virtOk = $false

        if ($virtFirmware -eq $true -and ($vmExt -eq $true -or $slt -eq $true)) { $virtOk = $true }
        if ($hypervisorPresent -eq $true -or $hvLaunchAuto -eq $true -or $sysVirtReported) { $virtOk = $true }

        return @{
            VirtFirmware = $virtFirmware;
            VMExt = $vmExt;
            SLAT = $slt;
            SysReport = $sysVirtReported;
            HypervisorPresent = $hypervisorPresent;
            BCDLaunch = $hvLaunch;
            VBS = $vbsRunning;
            VirtOk = $virtOk
        }
    } catch {
        Log "Check-VirtualizationHardware exception: $($_.Exception | Out-String)"
        Write-Status "Ошибка при проверке виртуализации: $($_.Exception.Message)" Red
        return $null
    }
}

# -----------------------------
# Проверка/включение Hyper-V, планировщик для автоповтора
# -----------------------------
function Ensure-HyperV {
    param([switch]$createResumeTask)
    Write-Status "[ACTION] Проверка роли Hyper-V..." Cyan
    try {
        $hvFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue
        if ($hvFeature -and $hvFeature.State -eq "Enabled") {
            Write-Status "Hyper-V role: Enabled" Green
            return @{ Ok = $true; Action = "AlreadyEnabled" }
        }

        Write-Status "Hyper-V не включён. Нужно включить компонент." Yellow
        if (-not $createResumeTask) {
            $ans = Read-Host "Включить Hyper-V сейчас и создать задачу автозапуска после перезагрузки? (Y/N)"
            if ($ans -notmatch '^[Yy]') { return @{ Ok=$false; Action="UserAbort"} }
        }

        # Включаем Hyper-V
        Write-Status "Включаем Hyper-V..." Yellow
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart | Out-Null
        Log "Enable-WindowsOptionalFeature executed"

        # Создаём одноразовую задачу Планировщика для автоповтора после перезагрузки
        $taskName = "InstallMacOSResumeTask"
        $scriptPathForTask = "C:\install_v3.ps1"
        if (-not (Test-Path $scriptPathForTask)) {
            Write-Status "Ошибка: для автозапуска требуется чтобы скрипт находился по C:\install_v3.ps1. Пожалуйста, сохраните файл туда и запустите снова." Red
            Log "Script not found at C:\install_v3.ps1 for task creation"
            return @{ Ok=$false; Action="ScriptNotFound" }
        }

        # команда запуска в задаче: powershell -ExecutionPolicy Bypass -File "C:\install_v3.ps1" -resume
        $taskCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPathForTask`" -resume"
        # create task as SYSTEM on startup
        $createArgs = "/Create /SC ONSTART /TN `"$taskName`" /TR `"$taskCmd`" /RL HIGHEST /F /RU SYSTEM"
        Write-Status "Создаём задачу планировщика: $taskName" Yellow
        $cc = Start-Process -FilePath schtasks -ArgumentList $createArgs -Wait -NoNewWindow -PassThru
        Log "schtasks create exit $($cc.ExitCode)"
        if ($cc.ExitCode -ne 0) {
            Write-Status "Не удалось создать задачу Планировщика (schtasks exit $($cc.ExitCode))." Red
            Log "schtasks create failed"
            return @{ Ok = $false; Action="TaskCreateFailed" }
        }

        Write-Status "Задача создана: $taskName. Сейчас система перезагрузится для завершения включения Hyper-V." Yellow
        Log "About to restart computer for Hyper-V enable"
        Start-Sleep -Seconds 2
        Restart-Computer -Force
        return @{ Ok = $true; Action = "Restarting" }
    } catch {
        Log "Ensure-HyperV exception: $($_.Exception | Out-String)"
        Write-Status "Ошибка при попытке включения Hyper-V: $($_.Exception.Message)" Red
        return @{ Ok = $false; Action="Exception" }
    }
}

# -----------------------------
# Удаление запланированной задачи (после resume)
# -----------------------------
function Remove-ResumeTask {
    $taskName = "InstallMacOSResumeTask"
    try {
        Write-Status "Удаляем временную задачу: $taskName" Cyan
        $cc = Start-Process -FilePath schtasks -ArgumentList "/Delete /TN `"$taskName`" /F" -Wait -NoNewWindow -PassThru -ErrorAction SilentlyContinue
        Log "schtasks delete exit $($cc.ExitCode)"
    } catch {
        Log "Remove-ResumeTask exception: $($_.Exception | Out-String)"
        Write-Status "Не удалось удалить задачу Планировщика (возможно её нет)." Yellow
    }
}

# -----------------------------
# Установка инструментов
# -----------------------------
function Ensure-Tools {
    Write-Status "[TOOLS] Проверяем git, python, 7zip..." Cyan
    try {
        # winget check (оставляем)
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $winget) {
            Write-Status "winget не найден. Пожалуйста, установите winget вручную и перезапустите скрипт." Red
            Log "winget missing"
            return $false
        }

        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Write-Status "Устанавливаем git через winget..." Yellow
            winget install --id Git.Git -e --source winget --silent | Out-Null
            Start-Sleep -Seconds 2
        } else { Write-Status "git: OK" Green }

        if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
            Write-Status "Устанавливаем python через winget..." Yellow
            winget install --id Python.Python.3 -e --source winget --silent | Out-Null
            Start-Sleep -Seconds 2
        } else { Write-Status "python: OK" Green }

        # ИСПРАВЛЕННАЯ ПРОВЕРКА 7-ZIP
        
        # 1. Сначала проверяем, доступна ли команда 7z в PATH (как в оригинале)
        if (Get-Command 7z -ErrorAction SilentlyContinue) {
            Write-Status "7zip: OK" Green
            # Если найдена, завершаем проверку 7-Zip
        } else {
            # Команда 7z НЕ найдена в PATH. Проверяем, установлен ли 7-Zip вообще.
            
            # Поиск пути установки 7-Zip через реестр
            $7ZipEntry = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* | Where-Object { 
                $_.DisplayName -like "7-Zip*" -and $_.InstallLocation 
            } | Select-Object -First 1

            if ($7ZipEntry) {
                # 7-Zip установлен, но не в PATH. Добавляем путь.
                $7ZipPath = $7ZipEntry.InstallLocation
                Write-Status "7zip установлен, но не в PATH. Добавляем $7ZipPath в PATH..." Yellow
                
                # Добавление пути в пользовательскую PATH
                $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
                if ($userPath -notlike "*$7ZipPath*") {
                    $newPath = "$userPath;$7ZipPath"
                    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
                    Write-Status "7zip: Путь успешно добавлен в PATH (требуется перезапуск консоли)." Green
                } else {
                    Write-Status "7zip: Путь уже в PATH, но переменная не обновилась." Yellow
                }
                
            } else {
                # 7-Zip не установлен вообще. Запускаем установку.
                Write-Status "7zip не найден. Попытка установить через winget..." Yellow
                winget install --id 7zip.7zip -e --source winget --silent | Out-Null
                Start-Sleep -Seconds 5 # Даем время на установку
                
                # Пробуем найти и добавить в PATH сразу после установки (хотя лучше перезапустить скрипт)
                $7ZipPostInstallEntry = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* | Where-Object { 
                    $_.DisplayName -like "7-Zip*" -and $_.InstallLocation 
                } | Select-Object -First 1
                
                if ($7ZipPostInstallEntry) {
                     $7ZipPath = $7ZipPostInstallEntry.InstallLocation
                     $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
                     if ($userPath -notlike "*$7ZipPath*") {
                        $newPath = "$userPath;$7ZipPath"
                        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
                        Write-Status "Установка завершена. Путь добавлен в PATH. Успешно!" Green
                     }
                } else {
                    Write-Status "Установка 7zip завершена, но путь установки не найден." Red
                }
            }
        }

        return $true
    } catch {
        Log "Ensure-Tools exception: $($_.Exception | Out-String)"
        Write-Status "Ошибка при установке инструментов: $($_.Exception.Message)" Red
        return $false
    }
}

# -----------------------------
# Получение характеристик системы
# -----------------------------
function Get-SystemSpecs {
    Write-Status "[INFO] Считываем характеристики системы..." Cyan
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $name = $cpu.Name
        $cores = $cpu.NumberOfLogicalProcessors
        $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        $gpus = (Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name) -join "; "
        Log "Specs: CPU=$name; Cores=$cores; RAM=${ram}GB; GPUs=$gpus"
        return @{ CPU = $name; Cores = $cores; RAM = $ram; GPUs = $gpus }
    } catch {
        Log "Get-SystemSpecs exception: $($_.Exception | Out-String)"
        Write-Status "Не удалось получить системные характеристики: $($_.Exception.Message)" Red
        throw
    }
}

# -----------------------------
# Выбор версии macOS
# -----------------------------
function Choose-macOS {
    param([string]$cpuName, [string]$gpus)
    # Предполагается, что Write-Status определена где-то еще
    Write-Status "[CHOICE] Выбор версии macOS (подбор на основе CPU/GPU)..." Cyan

    $all = @{
        "10.15" = @{ name="Catalina (10.15)"; minRam=4; recRam=8; recCores=2; disk=64 }
        "11"    = @{ name="Big Sur (11.x)";   minRam=8; recRam=8; recCores=2; disk=64 }
        "12"    = @{ name="Monterey (12.x)";  minRam=8; recRam=8; recCores=2; disk=64 }
        "13"    = @{ name="Ventura (13.x)";   minRam=8; recRam=8; recCores=2; disk=64 }
        "14"    = @{ name="Sonoma (14.x)";    minRam=8; recRam=8; recCores=2; disk=64 }
        "15"    = @{ name="Sequoia (15.x)";   minRam=8; recRam=8; recCores=2; disk=64 } 
        "26"    = @{ name="Tahoe (26.x)";     minRam=8; recRam=16; recCores=4; disk=64 } 
    }

    $supported = $all.Keys

    if ($cpuName -match "AMD") {
        # Определяем рекомендованные (более стабильные) версии для AMD
        $recommendedKeys = @("10.15","11","12")
        # Предполагается, что Write-Status определена где-то еще
        Write-Status "[WARN] Обнаружен AMD процессор." Yellow
        Write-Status "[WARN] Для максимальной стабильности рекомендуется выбрать версии: $($recommendedKeys -join ', ')." Yellow
        Write-Status "[WARN] Новые версии могут работать, но требуют дополнительных патчей и более сложной настройки." Yellow
    }
    
    $i = 0; $menu = @()
    foreach ($k in $supported) {
        $m = $all[$k]
        $tag = ""
        # Добавляем метку "Рекомендовано" для AMD, если эта версия входит в рекомендованные
        if ($cpuName -match "AMD" -and $recommendedKeys -contains $k) {
             $tag = " [РЕКОМЕНДОВАНО AMD]"
        }
        
        # ИСПРАВЛЕНИЕ ОШИБКИ: Плейсхолдер {2} для $tag, далее {3} до {6}.
        Write-Host ("[{0}] {1}{2} — minRAM {3}GB, recRAM {4}GB, recCores {5}, disk {6}GB" -f $i, $m.name, $tag, $m.minRam, $m.recRam, $m.recCores, $m.disk)
        
        $menu += $k
        $i++
    }

    $sel = Read-Host "Введите номер версии (например 0)"
    # Предполагается, что Abort определена где-то еще
    if (-not ([int]::TryParse($sel,[ref]$null))) { Abort "Неправильный ввод." }
    $sel = [int]$sel
    if ($sel -lt 0 -or $sel -ge $menu.Count) { Abort "Индекс вне диапазона." }
    $ver = $menu[$sel]
    $meta = $all[$ver]
    # Предполагается, что Write-Status определена где-то еще
    Write-Status "Выбрано: $($meta.name)" Green
    return @{ Version = $ver; Meta = $meta }
}

# -----------------------------
# Сборка OpenCore (Qonfused)
# -----------------------------
function Build-OSXHyperV {
    param([string]$cpuName, [int]$cores)
    Write-Status "[BUILD] Скачивание и сборка Qonfused/OSX-Hyper-V..." Cyan
    try {
        $dest = Join-Path -Path $env:TEMP -ChildPath "OSX-Hyper-V"
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        $repo = "https://github.com/Qonfused/OSX-Hyper-V.git"
        Write-Status "git clone $repo -> $dest" Yellow
        git clone $repo $dest 2>&1 | ForEach-Object { Log $_ }
        if (-not (Test-Path $dest)) { Abort "Не удалось скачать репозиторий." }

        Push-Location $dest
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force

        if ($cpuName -match "AMD") {
            if (Test-Path ".\scripts\amd.ps1") {
                Write-Status "Запуск scripts\\amd.ps1 --cpu $cores" Yellow
                & .\scripts\amd.ps1 --cpu $cores 2>&1 | ForEach-Object { Log $_ }
            } else {
                Write-Status "amd.ps1 не найден в репозитории — продолжаем без него." Yellow
                Log "amd.ps1 missing"
            }
        }

        if (Test-Path ".\scripts\build.ps1") {
            Write-Status "Запуск scripts\\build.ps1" Yellow
            & .\scripts\build.ps1 2>&1 | ForEach-Object { Log $_ }
        } else {
            Log (Get-ChildItem -Recurse | Out-String)
            Abort "build.ps1 не найден в репозитории (структура изменилась)."
        }

        Pop-Location
        Write-Status "Сборка завершена. Проверьте %TEMP%\\OSX-Hyper-V\\dist" Green
        return $dest
    } catch {
        Log "Build-OSXHyperV exception: $($_.Exception | Out-String)"
        Abort "Ошибка при сборке: $($_.Exception.Message)"
    }
}

# -----------------------------
# Создание VM
# -----------------------------
function Create-VMFromDist {
    param([string]$repoPath, [string]$version, [int]$cores, [int]$ram, [int]$disk)
    Write-Status "[VM] Создание VM через dist/Scripts..." Cyan
    $scriptPath = Join-Path -Path $repoPath -ChildPath "dist\Scripts\create-virtual-machine.ps1"
    if (-not (Test-Path $scriptPath)) { Abort "create-virtual-machine.ps1 не найден. Убедитесь, что build.ps1 создал dist/Scripts." }

    Write-Status "Запускаем: $scriptPath -Name macOS_$version -Version $version -CPU $cores -RAM $ram -Size $disk" Yellow
    & $scriptPath -Name ("macOS_$version") -Version $version -CPU $cores -RAM $ram -Size $disk 2>&1 | ForEach-Object { Log $_ }
    Write-Status "Команда создания VM завершена (проверьте Hyper-V Manager)." Green
}

# -----------------------------
# MAIN
# -----------------------------
try {
    Assert-Admin
    Log "=== START install_v3 ==="

    # Если мы запущены в режиме resume - удаляем задачу и продолжаем
    if ($resume) {
        Write-Status "Resume flag detected: script запущен после перезагрузки (задача планировщика)." Cyan
        Remove-ResumeTask
    }

    # Проверка аппаратной поддержки виртуализации (умная)
    $virt = Check-VirtualizationHardware
    if (-not $virt) { Abort "Не удалось проверить виртуализацию (см лог)." }

    if (-not $virt.VirtOk) {
        # если firmware true но vmext/slat false, возможно VBS/hypervisor взял ресурсы. Рассмотрим случаи:
        if ($virt.VirtFirmware -eq $true -and ($virt.VMExt -eq $false -and $virt.SLAT -eq $false)) {
            Write-Status "BIOS отмечает VirtualizationFirmwareEnabled=True, но VMExt/SLAT = False." Yellow
            Write-Status "Это может быть вызвано тем, что Windows уже зарезервировала виртуализацию (VBS/Hyper-V). Попробуем дальнейшие проверки." Yellow
            if ($virt.HypervisorPresent -or $virt.BCDLaunch -eq "Auto" -or $virt.SysReport) {
                Write-Status "Hypervisor/VBS выглядит активным — считаем, что виртуализация доступна для Hyper-V." Green
            } else {
                Write-Status "Похоже, аппаратная виртуализация не полностью доступна. Проверьте в BIOS включен ли SVM/AMD-V и IOMMU." Red
                Write-Status "Если у вас включён Memory integrity (Core isolation), попробуйте временно выключить её в Windows Security -> Device security -> Core isolation -> Memory integrity (Off) и перезагрузить." Yellow
                Abort "Аппаратная виртуализация не обнаружена/недоступна."
            }
        } else {
            Write-Status "Аппаратная виртуализация отсутствует или явно отключена в BIOS." Red
            Abort "Аппаратная виртуализация отсутствует."
        }
    }

    # Проверим роль Hyper-V и при необходимости включим через Ensure-HyperV (создаст задачу и перезагрузит)
    $hvEnsure = Ensure-HyperV
    if (-not $hvEnsure.Ok) {
        if ($hvEnsure.Action -eq "UserAbort") {
            Abort "Пользователь отказался включать Hyper-V."
        } elseif ($hvEnsure.Action -eq "ScriptNotFound") {
            Abort "Скрипт должен быть сохранён в C:\\install_v3.ps1 для автоповтора. Сохраните и запустите снова."
        } else {
            # Если Ensure-HyperV вернул false, но не требовал restart - прекращаем
            if ($hvEnsure.Action -ne "Restarting") {
                Abort "Hyper-V не активен и не был включён. Дальнейшая установка невозможна."
            } else {
                # Restarting: машина перезагрузится, и запустится задача resume
                # Скрипт не будет доходить сюда, т.к. Restart-Computer вызван.
                Exit 0
            }
        }
    }

    # Если мы здесь — Hyper-V доступен/включён
    Write-Status "Hyper-V активен — продолжаем." Green

    # Проверяем инструменты (git, python, 7zip)
    $toolsOk = Ensure-Tools
    if (-not $toolsOk) { Abort "Не удалось установить инструменты (см лог)." }

    # Считываем систему
    $specs = Get-SystemSpecs
    Write-Status "CPU: $($specs.CPU) | Cores: $($specs.Cores) | RAM: ${($specs.RAM)}GB | GPUs: $($specs.GPUs)" Cyan

    # Выбор macOS
    $choice = Choose-macOS -cpuName $specs.CPU -gpus $specs.GPUs
    $ver = $choice.Version
    $meta = $choice.Meta

    # Сборка OpenCore / OSX-Hyper-V
    $repoPath = Build-OSXHyperV -cpuName $specs.CPU -cores $specs.Cores

    # Создание VM
    Create-VMFromDist -repoPath $repoPath -version $ver -cores $meta.recCores -ram $meta.recRam -disk $meta.disk

    Write-Status "Установка завершена (или инициирована). Проверьте Hyper-V Manager для запуска VM." Green
    Log "=== FINISH SUCCESS ==="
    Write-Status "Лог: $Global:LogPath" Yellow
    exit 0

} catch {
    Log "Unhandled exception: $($_.Exception | Out-String)"
    Write-Status "Скрипт завершился с ошибкой: $($_.Exception.Message)" Red
    Write-Status "См. лог: $Global:LogPath" Yellow
    exit 1
}
