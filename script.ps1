<#
.SYNOPSIS
    Универсальный скрипт развертывания macOS в Hyper-V для платформ AMD Zen 3 (Ryzen 7 5800HS).
    Автоматизирует проверку зависимостей, настройку VM и критическое патчирование OpenCore.

.DESCRIPTION
    Этот скрипт выполняет полный цикл подготовки хост-системы Windows 11 (AMD Zen 3), 
    включая проверку и установку Hyper-V, WinGet, Git, Python, клонирование репозитория 
    OSX-Hyper-V, интерактивную настройку ресурсов VM и автоматическое применение 
    критических патчей OpenCore, специфичных для процессора AMD Ryzen 7 5800HS и Hyper-V.

.NOTES
    Требует запуска с правами Администратора (будет запрошено автоматически).
    Целевой процессор: AMD Ryzen 7 5800HS (8 физических ядер).
#>

$ErrorActionPreference = "Stop"
$WorkingDir = "$env:TEMP\HyperV_macOS_Deploy"
$RepoUrl = "https://github.com/Qonfused/OSX-Hyper-V"

#region 1. СТИЛЬ И ПРОВЕРКА АДМИНИСТРАТОРА
function Write-Styled ($Message, $Color="White") {
    Write-Host $Message -ForegroundColor $Color
}

function Test-Admin {
    $isAdmin =::new(::GetCurrent()).IsInRole(::Administrator)
    if (-not $isAdmin) {
        Write-Styled "!!! ПОВЫШЕНИЕ ПРИВИЛЕГИЙ ТРЕБУЕТСЯ!!!" -Color Red
        Write-Styled "Скрипт перезапустится с правами Администратора." -Color Yellow
        Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
        exit
    }
}

Test-Admin
cls
Write-Styled "========================================================" -Color Cyan
Write-Styled "   Установка macOS (Hackintosh) в Hyper-V (AMD Zen 3)" -Color Green
Write-Styled "========================================================" -Color Cyan
Write-Styled "Текущая система: ASUS ROG G14 (Ryzen 7 5800HS / RTX 3060)" -Color Yellow
Write-Styled "ВНИМАНИЕ: Видеокарта RTX 3060 не будет работать в macOS." -Color Red
Start-Sleep -Seconds 2
#endregion

#region 2. СБОР МЕТРИК И ПРОВЕРКА HYPER-V
Write-Styled "`n--- Фаза 1: Сбор Системных Данных и Проверка Hyper-V ---" -Color Yellow

# Получение данных о ЦП (8 физических ядер для 5800HS)
$CpuInfo = Get-CimInstance Win32_Processor
$PhysicalCoreCount = ($CpuInfo | Measure-Object -Property NumberOfCores -Sum).Sum
$MaxVCPUs =::Floor($PhysicalCoreCount * 0.75)

# Получение данных о RAM (в ГБ)
$TotalRAMBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
$TotalRAMGB =::Round($TotalRAMBytes / 1GB)
$MaxRAMGB =::Floor($TotalRAMGB * 0.75)

Write-Styled "  Обнаружено ядер ЦП (физических): $PhysicalCoreCount" -Color White
Write-Styled "  Обнаружено RAM (общее): $TotalRAMGB ГБ" -Color White
Write-Styled "  Макс. Рекомендуемые vCPU для VM: $MaxVCPUs (75%)" -Color White
Write-Styled "  Макс. Рекомендуемый RAM для VM: $MaxRAMGB ГБ (75%)" -Color White [1]

# Проверка Hyper-V
function Check-HyperV {
    Write-Styled "`nПроверка роли Hyper-V..."
    $HyperVStatus = Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue
    if ($HyperVStatus -and $HyperVStatus.State -eq 'Enabled') {
        Write-Styled "  Hyper-V включен. ОК." -Color Green
        return $true
    }
    Write-Styled "  Hyper-V не включен." -Color Red
    Write-Styled "  Включить роль Hyper-V? (Y/N)" -Color Yellow
    $Confirm = Read-Host
    if ($Confirm -ceq 'Y') {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart -ErrorAction Stop
        Write-Styled "  Роль Hyper-V включена. Требуется перезагрузка после завершения скрипта." -Color Yellow
        return $true
    } else {
        Write-Styled "  Отмена. Для продолжения требуется Hyper-V." -Color Red
        exit
    }
}
Check-HyperV
#endregion

#region 3. ПРОВЕРКА И УСТАНОВКА ЗАВИСИМОСТЕЙ
function Check-Dependencies {
    Write-Styled "`nПроверка необходимых инструментов (WinGet, Git, Python)..." -Color Yellow

    # Проверка WinGet (должен быть в Windows 11)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Styled "  WinGet не найден. Установите App Installer из Microsoft Store и перезапустите скрипт." -Color Red
        exit
    }
    
    # Проверка и установка Git [2]
    if (-not (winget list --id Git.Git -e -q Git -ErrorAction SilentlyContinue)) {
        Write-Styled "  Git не найден. Установка..." -Color Magenta
        winget install --id Git.Git -e --source winget -ErrorAction Stop
    } else {
        Write-Styled "  Git установлен. ОК." -Color Green
    }
    
    # Проверка и установка Python (требуется для OCE-Build) [2]
    if (-not (winget list --id Python.Python.3.8 -e -q Python -ErrorAction SilentlyContinue)) {
        Write-Styled "  Python не найден. Установка Python 3.8+..." -Color Magenta
        winget install --id Python.Python.3.8 --source winget -ErrorAction Stop
    } else {
        Write-Styled "  Python установлен. ОК." -Color Green
    }
}
Check-Dependencies
#endregion

#region 4. ИНТЕРАКТИВНОЕ МЕНЮ И НАСТРОЙКА VM
function Show-Menu {
    cls
    Write-Styled "========================================================" -Color Cyan
    Write-Styled "   НАСТРОЙКА ВИРТУАЛЬНОЙ МАШИНЫ macOS" -Color Green
    Write-Styled "========================================================" -Color Cyan
    Write-Styled "Хост: $PhysicalCoreCount ядер, $TotalRAMGB ГБ RAM."
    Write-Styled "Рекомендации для AMD Zen 3:"

    $vCPU = 6
    $RAM = 12
    $Size = 80
    $OSVersion = "14"
    $done = $false
    
    do {
        Write-Styled "`nВыберите версию macOS (рекомендуются современные версии, совместимые с Zen 3):" -Color White
        Write-Host "1. macOS Ventura (13): Мин. 8 ГБ RAM, 6 vCPUs, 80 ГБ HDD [3]"
        Write-Host "2. macOS Sonoma (14): Мин. 12 ГБ RAM, 6 vCPUs, 100 ГБ HDD (Рекомендуется)" -ForegroundColor Cyan
        Write-Host "3. macOS Sequoia (15): Мин. 16 ГБ RAM, 6 vCPUs, 120 ГБ HDD [3]"
        Write-Host "C. Настроить ресурсы (Custom)"
        Write-Host "Q. Отменить и выйти"
        
        $selection = Read-Host "Ваш выбор [1/2/3/C/Q]"

        switch ($selection) {
            "1" { $vCPU = 6; $RAM = 8; $Size = 80; $OSVersion = "13"; $done = $true }
            "2" { $vCPU = 6; $RAM = 12; $Size = 100; $OSVersion = "14"; $done = $true }
            "3" { $vCPU = 6; $RAM = 16; $Size = 120; $OSVersion = "15"; $done = $true }
            
            "C" {
                Write-Styled "`n--- Настройка Пользовательских Ресурсов ---" -Color Yellow
                
                # Настройка vCPU
                $vCPU = Read-Host "Введите vCPU (рекомендуется 4-$MaxVCPUs, макс. $MaxVCPUs)"
                if ([int]$vCPU -lt 4 -or [int]$vCPU -gt $MaxVCPUs) {
                    Write-Styled "  Некорректное количество vCPU. Установлено 6 по умолчанию." -Color Red
                    $vCPU = 6
                }

                # Настройка RAM
                $RAM = Read-Host "Введите RAM в ГБ (рекомендуется 12-$MaxRAMGB, макс. $MaxRAMGB)"
                if ([int]$RAM -lt 8 -or [int]$RAM -gt $MaxRAMGB) {
                    Write-Styled "  Некорректное количество RAM. Установлено 12 ГБ по умолчанию." -Color Red
                    $RAM = 12
                }
                
                # Настройка Диска
                $Size = Read-Host "Введите размер диска в ГБ (мин. 80 ГБ)"
                if ([int]$Size -lt 80) {
                    Write-Styled "  Некорректный размер диска. Установлено 100 ГБ по умолчанию." -Color Red
                    $Size = 100
                }
                
                Write-Styled "  Настроено: vCPU=$vCPU, RAM=$RAM ГБ, Диск=$Size ГБ" -Color Yellow

                # Выбор версии для create-virtual-machine.ps1 (важно для правильного скачивания)
                $OSVersion = Read-Host "Введите целевую версию macOS (13, 14 или 15)"
                if ("13", "14", "15" -notcontains $OSVersion) {
                    Write-Styled "  Некорректная версия. Установлена Sonoma (14) по умолчанию." -Color Red
                    $OSVersion = "14"
                }

                $done = $true
            }
            "Q" { exit }
            default { Write-Styled "Неверный выбор. Повторите." -Color Red; Start-Sleep -Seconds 1 }
        }
    } until ($done)

    # Запрос имени VM
    $VmName = Read-Host "`nВведите имя для виртуальной машины (например, 'macOS_Sonoma')"
    if ([string]::IsNullOrWhiteSpace($VmName)) {
        $VmName = "macOS_HyperV_Zen3"
    }

    $VMConfig = @{
        Name = $VmName
        Version = $OSVersion
        vCPU = [int]$vCPU
        RAM = [int]$RAM
        Size = [int]$Size
        SMBIOS = "iMacPro1,1" # Рекомендуется для систем без iGPU [4]
    }
    return $VMConfig
}

$VMConfig = Show-Menu
Write-Styled "`n--- КОНФИГУРАЦИЯ VM УСТАНОВЛЕНА ---" -Color Green
Write-Styled "VM Имя: $($VMConfig.Name)"
Write-Styled "vCPU: $($VMConfig.vCPU)"
Write-Styled "RAM: $($VMConfig.RAM) ГБ"
Write-Styled "Диск: $($VMConfig.Size) ГБ"
Write-Styled "Версия: $($VMConfig.Version)"
Start-Sleep -Seconds 3
#endregion

#region 5. КЛОНИРОВАНИЕ И СБОРКА РЕПОЗИТОРИЯ
Write-Styled "`n--- Фаза 2: Клонирование и Сборка OpenCore ---" -Color Yellow

# Удаление старой папки, если она существует
if (Test-Path $WorkingDir) {
    Remove-Item -Path $WorkingDir -Recurse -Force
}
New-Item -Path $WorkingDir -ItemType Directory -Force

# Клонирование репозитория
Write-Styled "Клонирование репозитория Qonfused/OSX-Hyper-V..."
git clone $RepoUrl $WorkingDir -ErrorAction Stop

Set-Location $WorkingDir

# Запуск скрипта сборки (скачивает образ восстановления macOS и создает EFI) [2]
Write-Styled "Запуск скрипта сборки EFI (скачивание образа восстановления macOS)..." -Color Cyan
.\scripts\build.ps1 -ErrorAction Stop

#endregion

#region 6. СОЗДАНИЕ VM HYPER-V И КРИТИЧЕСКИЙ ПАТЧ
Write-Styled "`n--- Фаза 3: Создание VM и Патчинг AMD Zen 3 (8 ядер) ---" -Color Yellow

$CreateVmScript = ".\dist\Scripts\create-virtual-machine.ps1"

# 6.1 Создание VM с использованием обертки [5]
Write-Styled "Создание виртуальной машины Hyper-V: $($VMConfig.Name)..."
& $CreateVmScript -name $VMConfig.Name -version $VMConfig.Version -cpu $VMConfig.vCPU -ram $VMConfig.RAM -size $VMConfig.Size -ErrorAction Stop

# 6.2 Критический Патчинг config.plist для AMD Zen 3 (8 ядер) и Hyper-V
function Apply-CriticalPatches {
    Write-Styled "`nПрименение критических патчей OpenCore (AMD Zen 3 и Hyper-V)..." -Color Cyan

    $VhdPath = "C:\Users\Public\Documents\Hyper-V\Virtual Hard Disks\$($VMConfig.Name)\EFI.vhdx"
    
    # 1. Монтирование VHDX
    Write-Styled "  Монтирование EFI VHDX..."
    $MountedDisk = Mount-VHD -Path $VhdPath -PassThru | Get-Disk -ErrorAction Stop
    $MountedDisk | Get-Partition | Get-Volume | Select-Object -ExpandProperty DriveLetter | Out-Variable -Force DriveLetter
    
    if (-not $DriveLetter) {
        throw "Не удалось смонтировать VHDX. Проверьте права доступа."
    }
    
    $ConfigPath = "$($DriveLetter):\EFI\OC\config.plist"
    
    # Загрузка Plist в качестве XML
    [xml]$Plist = Get-Content $ConfigPath -ErrorAction Stop
    $PatchArray = $Plist.'plist'.dict.dict.array

    # 2. Патч 1: Инъекция 8 ядер AMD (Zen 3). Hex для 8 ядер: 08 [6]
    Write-Styled "  Патч ядра: Настройка 8 физических ядер (Ryzen 7 5800HS)..."
    
    # Патчи cpuid_cores_per_package в config.plist (их три)
    # Находим патчи по комментарию и применяем замену
    $CoreCountPatches = $PatchArray.dict | Where-Object { $_.Comment -like "algrey - Force cpuid_cores_per_package*" }

    $CoreCountPatches | ForEach-Object {
        $OriginalReplaceData = $_.Replace.data
        
        # Определяем, какой из трех патчей редактируем (по исходному значению 00)
        if ($OriginalReplaceData -eq "B80000000000") {
            # Patch 1 & 2 (10.13-10.15)
            $_.Replace.data = "B80800000000" 
        } elseif ($OriginalReplaceData -eq "BA0000000000") {
            # Patch 2 (10.15) - дублируется выше, но для надежности
            $_.Replace.data = "BA0800000000"
        } elseif ($OriginalReplaceData -eq "BA0000000090") {
            # Patch 3 (11+)
            $_.Replace.data = "BA0800000090"
        }
    }
    
    # 3. Патч 2: Маскировка Обнаружения VMM Hyper-V (для iServices) [2]
    Write-Styled "  Патч ядра: Маскировка Hyper-V для iServices/App Store..."
    
    # Создаем новый узел для патча VMM
    $NewPatch = $Plist.CreateElement("dict")
    $NewPatch.InnerXml = @"
        <key>Arch</key><string>x86_64</string>
        <key>Base</key><string></string>
        <key>Comment</key><string>HyperV VMM Detect Fix (kern.hv_vmm_present=0)</string>
        <key>Count</key><integer>1</integer>
        <key>Enabled</key><true/>
        <key>Find</key><data>6b65726e2e68765f766d6d5f70726573656e7400</data>
        <key>Limit</key><integer>0</integer>
        <key>Mask</key><data></data>
        <key>MaxKernel</key><string></string>
        <key>MinKernel</key><string>13.0.0</string>
        <key>Replace</key><data>6b65726e2e68765f766d6d5f70726573656e7430</data>
        <key>ReplaceMask</key><data></data>
        <key>Skip</key><integer>0</integer>
        <key>Table</key><string></string>
    "@
    
    # Добавляем новый патч в массив Kernel -> Patch
    $PatchArray.AppendChild($NewPatch)
    
    # 4. Настройка SMBIOS и Quirks (Проверка ProvideCurrentCpuInfo = True) [6]
    Write-Styled "  Настройка SMBIOS: iMacPro1,1..."
    
    $SMBIOSNode = $Plist.'plist'.dict.dict | Where-Object { $_.key -eq "PlatformInfo" }
    $SMBIOSNode.dict.string | Where-Object { $_.key -eq "SystemProductName" }.InnerXml = "iMacPro1,1"
    
    # Ensure ProvideCurrentCpuInfo is True for Zen CPUs
    $QuirksNode = $Plist.'plist'.dict.dict | Where-Object { $_.key -eq "Kernel" }
    $QuirksNode.dict.string | Where-Object { $_.key -eq "ProvideCurrentCpuInfo" }.InnerXml = "True"

    # 5. Сохранение и Отмонтирование
    $Plist.Save($ConfigPath)
    Dismount-VHD -Path $VhdPath -Confirm:$false
    Write-Styled "EFI успешно пропатчен и отмонтирован." -Color Green
}

Apply-CriticalPatches

#endregion

#region 7. ЗАКЛЮЧИТЕЛЬНЫЕ ИНСТРУКЦИИ
Write-Styled "`n--- Фаза 4: Установка и Завершение ---" -Color Yellow

Write-Styled "`nВСЕ АВТОМАТИЗИРОВАННЫЕ ШАГИ ЗАВЕРШЕНЫ УСПЕШНО." -Color Green
Write-Styled "Дальнейшие шаги (ВЫПОЛНЯТЬ ВРУЧНУЮ):" -Color Yellow

Write-Styled "`nШАГ 1: Проверка Настроек VM в Hyper-V Manager" -Color White
Write-Styled "  1. Откройте Hyper-V Manager (Диспетчер Hyper-V)."
Write-Styled "  2. Щелкните правой кнопкой мыши на VM '$($VMConfig.Name)' -> Настройки (Settings)."
Write-Styled "  3. 'Контроллер SCSI' -> 'Жесткий диск' -> Убедитесь, что там находится VHDX размером $($VMConfig.Size) ГБ."
Write-Styled "  4. 'Безопасность' -> Отключите 'Включить безопасную загрузку' (Secure Boot)." [5]
Write-Styled "  5. 'Память' -> Убедитесь, что выделено $($VMConfig.RAM) ГБ."

Write-Styled "`nШАГ 2: Первый Запуск и Установка macOS" -Color White
Write-Styled "  1. Запустите VM '$($VMConfig.Name)' и подключитесь к ней."
Write-Styled "  2. Выберите 'macOS Base System' в меню OpenCore."
Write-Styled "  3. Дождитесь загрузки в среду восстановления macOS."
Write-Styled "  4. В меню выберите 'Дисковая утилита' (Disk Utility)."
Write-Styled "  5. В Дисковой утилите выберите виртуальный диск (размером $($VMConfig.Size) ГБ) и 'Стереть' (Erase). Выберите формат APFS."
Write-Styled "  6. Выйдите из Дисковой утилиты и выберите 'Переустановить macOS' (Reinstall macOS)."

Write-Styled "`nШАГ 3: После Установки" -Color White
Write-Styled "  После завершения установки (несколько перезагрузок) VM загрузится в финальное меню OpenCore. Выберите диск с установленной macOS."
Write-Styled "  Благодаря патчам, App Store и iServices (iMessage, FaceTime) должны работать корректно."

Write-Styled "`n*** ВАЖНОЕ ПРИМЕЧАНИЕ ***" -Color Red
Write-Styled "Если вы включали Hyper-V, может потребоваться перезагрузка Windows 11 для завершения установки роли." -Color Red

Write-Styled "`nНажмите Enter для выхода."
Read-Host
#endregion