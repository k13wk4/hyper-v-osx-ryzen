<#
.SYNOPSIS
    Универсальный скрипт развертывания macOS в Hyper-V для платформ AMD Zen 3 (Ryzen 7 5800HS).
    Полностью совместим с PowerShell 7 и Windows PowerShell 5.1.
#>

$ErrorActionPreference = "Stop"

# Определяем путь к рабочей папке (используем TEMP для автоматической очистки)
$WorkingDir = "$env:TEMP\HyperV_macOS_Deploy"
$RepoUrl = "https://github.com/Qonfused/OSX-Hyper-V"

#region 1. СТИЛЬ И ПРОВЕРКА АДМИНИСТРАТОРА
function Write-Styled ($Message, $Color="White") {
    Write-Host $Message -ForegroundColor $Color
}

function Test-Admin {
    # Проверка, находится ли пользователь в группе Администраторов (SID S-1-5-32-544)
    # Универсальный метод для PS 5.1 и PS 7
    $identity =::GetCurrent()
    $isAdmin = [bool]($identity.Groups -match 'S-1-5-32-544')

    if (-not $isAdmin) {
        Write-Styled "!!! ПОВЫШЕНИЕ ПРИВИЛЕГИЙ ТРЕБУЕТСЯ!!!" -Color Red
        Write-Styled "Скрипт перезапустится с правами Администратора." -Color Yellow
        
        # Запуск самого себя с повышенными правами (используем powershell.exe для надежности)
        $ScriptPath = $MyInvocation.MyCommand.Path
        Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$ScriptPath`""
        exit
    }
}

Test-Admin
cls
Write-Styled "========================================================" -Color Cyan
Write-Styled "   Установка macOS (Hackintosh) в Hyper-V (AMD Zen 3)" -Color Green
Write-Styled "========================================================" -Color Cyan
Write-Styled "Текущая система: ASUS ROG G14 (Ryzen 7 5800HS / 8 ядер)" -Color Yellow
Write-Styled "ВНИМАНИЕ: Дискретный GPU NVIDIA RTX 3060 не будет работать в macOS." -Color Red [1, 2]
Start-Sleep -Seconds 2
#endregion

#region 2. СБОР МЕТРИК И ПРОВЕРКА HYPER-V
Write-Styled "`n--- Фаза 1: Сбор Системных Данных и Проверка Hyper-V ---" -Color Yellow

# Получение данных о ЦП (8 физических ядер для 5800HS) [3]
$CpuInfo = Get-CimInstance Win32_Processor
$PhysicalCoreCount = ($CpuInfo | Measure-Object -Property NumberOfCores -Sum).Sum
# Ограничиваем ресурсы 75% от общего объема
$MaxVCPUs =::Floor($PhysicalCoreCount * 0.75)

# Получение данных о RAM (в ГБ)
$TotalRAMBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
$TotalRAMGB =::Round($TotalRAMBytes / 1GB)
$MaxRAMGB =::Floor($TotalRAMGB * 0.75) [4]

Write-Styled "  Обнаружено ядер ЦП (физических): $PhysicalCoreCount" -Color White
Write-Styled "  Обнаружено RAM (общее): $TotalRAMGB ГБ" -Color White

# Проверка Hyper-V
function Check-HyperV {
    Write-Styled "`nПроверка роли Hyper-V..."
    # Проверка установлена ли роль Hyper-V
    $HyperVStatus = Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue
    if ($HyperVStatus -and $HyperVStatus.State -eq 'Enabled') {
        Write-Styled "  Hyper-V включен. ОК." -Color Green
        return $true
    }
    Write-Styled "  Hyper-V не включен." -Color Red
    $Confirm = Read-Host "  Включить роль Hyper-V? (Y/N)"
    if ($Confirm -ceq 'Y') {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart -ErrorAction Stop
        Write-Styled "  Роль Hyper-V включена. Для ее активации потребуется перезагрузка после завершения скрипта." -Color Yellow
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
    Write-Styled "`nПроверка необходимых инструментов (WinGet, Git, Python)..." -Color Yellow [5]

    # Проверка WinGet (должен быть в Windows 11) [6]
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Styled "  WinGet не найден. Установите App Installer из Microsoft Store и перезапустите скрипт." -Color Red
        exit
    }
    
    # Проверка и установка Git [5]
    if (-not (winget list --id Git.Git -e -q Git -ErrorAction SilentlyContinue)) {
        Write-Styled "  Git не найден. Установка..." -Color Magenta
        winget install --id Git.Git -e --source winget -ErrorAction Stop
    } else {
        Write-Styled "  Git установлен. ОК." -Color Green
    }
    
    # Проверка и установка Python (требуется для OCE-Build) [5]
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
    Write-Styled "Максимальное выделение: $MaxVCPUs vCPU, $MaxRAMGB ГБ RAM."

    $vCPU = 6
    $RAM = 12
    $Size = 100
    $OSVersion = "14" # Sonoma по умолчанию
    $done = $false
    
    do {
        Write-Styled "`nВыберите версию macOS (современные версии совместимы с Zen 3):" -Color White
        Write-Host "1. macOS Ventura (13): Мин. 8 ГБ RAM, 6 vCPUs, 80 ГБ HDD" [7]
        Write-Host "2. macOS Sonoma (14): Мин. 12 ГБ RAM, 6 vCPUs, 100 ГБ HDD (Рекомендуется)" -ForegroundColor Cyan [7]
        Write-Host "3. macOS Sequoia (15): Мин. 16 ГБ RAM, 6 vCPUs, 120 ГБ HDD" [8]
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
                $vCPU = Read-Host "Введите vCPU (рекомендуется 6, макс. $MaxVCPUs)"
                if ([int]$vCPU -lt 4 -or [int]$vCPU -gt $MaxVCPUs) {
                    Write-Styled "  Некорректное количество vCPU или превышение лимита. Установлено 6." -Color Red
                    $vCPU = 6
                }

                # Настройка RAM
                $RAM = Read-Host "Введите RAM в ГБ (рекомендуется 12, макс. $MaxRAMGB)"
                if ([int]$RAM -lt 8 -or [int]$RAM -gt $MaxRAMGB) {
                    Write-Styled "  Некорректное количество RAM или превышение лимита. Установлено 12 ГБ." -Color Red
                    $RAM = 12
                }
                
                # Настройка Диска
                $Size = Read-Host "Введите размер диска в ГБ (мин. 80 ГБ)"
                if ([int]$Size -lt 80) {
                    Write-Styled "  Некорректный размер диска. Установлено 100 ГБ." -Color Red
                    $Size = 100
                }
                
                $OSVersion = Read-Host "Введите целевую версию macOS (13, 14 или 15)"
                if ("13", "14", "15" -notcontains $OSVersion) {
                    Write-Styled "  Некорректная версия. Установлена Sonoma (14)." -Color Red
                    $OSVersion = "14"
                }

                Write-Styled "  Настроено: vCPU=$vCPU, RAM=$RAM ГБ, Диск=$Size ГБ" -Color Yellow
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
        Version = [string]$OSVersion # Версия для create-virtual-machine.ps1 [9]
        vCPU = [int]$vCPU
        RAM = [int]$RAM
        Size = [int]$Size
    }
    return $VMConfig
}

$VMConfig = Show-Menu
Write-Styled "`n--- КОНФИГУРАЦИЯ VM УСТАНОВЛЕНА ---" -Color Green
Write-Styled "VM Имя: $($VMConfig.Name)"
Write-Styled "vCPU: $($VMConfig.vCPU)"
Write-Styled "RAM: $($VMConfig.RAM) ГБ"
Write-Styled "Диск: $($VMConfig.Size) ГБ"
Write-Styled "Версия: macOS $($VMConfig.Version)"
Start-Sleep -Seconds 3
#endregion

#region 5. КЛОНИРОВАНИЕ И СБОРКА РЕПОЗИТОРИЯ
Write-Styled "`n--- Фаза 2: Клонирование и Сборка OpenCore ---" -Color Yellow

# Удаление старой папки
if (Test-Path $WorkingDir) {
    Remove-Item -Path $WorkingDir -Recurse -Force
}
New-Item -Path $WorkingDir -ItemType Directory -Force

# Клонирование репозитория
Write-Styled "Клонирование репозитория Qonfused/OSX-Hyper-V..."
git clone $RepoUrl $WorkingDir -ErrorAction Stop

Set-Location $WorkingDir

# Запуск скрипта сборки (скачивает образ восстановления macOS и создает EFI) [5]
Write-Styled "Запуск скрипта сборки EFI (скачивание образа восстановления macOS)..." -Color Cyan
# На Windows, Python обычно запускается как python, а не python3
$PythonPath = (Get-Command python -ErrorAction SilentlyContinue).Path
if ($PythonPath) {
    Write-Styled "Используем Python: $PythonPath" -Color White
} else {
    Write-Styled "Внимание: не удалось найти 'python' в PATH. Надеемся на автоматический запуск build.ps1." -Color Red
}

.\scripts\build.ps1 -ErrorAction Stop
#endregion

#region 6. СОЗДАНИЕ VM HYPER-V И КРИТИЧЕСКИЙ ПАТЧ
Write-Styled "`n--- Фаза 3: Создание VM и Патчинг AMD Zen 3 (8 ядер) ---" -Color Yellow

$CreateVmScript = ".\dist\Scripts\create-virtual-machine.ps1"

# 6.1 Создание VM с использованием обертки [9]
Write-Styled "Создание виртуальной машины Hyper-V: $($VMConfig.Name)..."
# Передаем конфигурацию в скрипт создания VM
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
        throw "Не удалось смонтировать VHDX."
    }
    
    $ConfigPath = "$($DriveLetter):\EFI\OC\config.plist"
    
    # Загрузка Plist в качестве XML
    [xml]$Plist = Get-Content $ConfigPath -ErrorAction Stop
    
    # Находим массив патчей
    $PatchArray = $Plist.plist.dict.dict | Where-Object { $_.key -eq "Kernel" } | Select-Object -ExpandProperty dict | Where-Object { $_.key -eq "Patch" } | Select-Object -ExpandProperty array

    # 2. Патч 1: Инъекция 8 ядер AMD (Zen 3). Hex для 8 ядер: 08 [3]
    Write-Styled "  Патч ядра: Настройка 8 физических ядер (Ryzen 7 5800HS)..."
    
    # Патчи cpuid_cores_per_package в config.plist (их три)
    # Ищем патчи по комментарию и применяем замену 08
    $CoreCountPatches = $PatchArray.dict | Where-Object { $_.Comment -like "algrey - Force cpuid_cores_per_package*" }
    $HexCoreCount = "08"
    
    $CoreCountPatches | ForEach-Object {
        $OriginalReplaceData = $_.Replace.data
        # Заменяем 00 на 08 в каждом из трех патчей
        $_.Replace.data = $OriginalReplaceData.Replace("00000000", $HexCoreCount + "000000")
    }
    
    # 3. Патч 2: Маскировка Обнаружения VMM Hyper-V (для iServices) [5]
    Write-Styled "  Патч ядра: Маскировка Hyper-V для iServices/App Store..."
    
    # XML-структура для добавления патча VMM
    $NewPatchXml = @"
<dict>
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
</dict>
"@
    
    # Создаем новый XML-узел и добавляем его
    $NewPatch = $Plist.CreateElement("dict")
    $NewPatch.InnerXml = $NewPatchXml
    $PatchArray.AppendChild($NewPatch)
    
    # 4. Настройка SMBIOS и Quirks
    Write-Styled "  Настройка SMBIOS на iMacPro1,1 (рекомендуется для систем без iGPU)..." [10]
    
    # Установка SMBIOS
    $PlatformInfo = $Plist.plist.dict.dict | Where-Object { $_.key -eq "PlatformInfo" } | Select-Object -ExpandProperty dict
    $PlatformInfo.string | Where-Object { $_.key -eq "SystemProductName" }.InnerXml = "iMacPro1,1"
    
    # Ensure ProvideCurrentCpuInfo is True for Zen CPUs [3]
    $QuirksNode = $Plist.plist.dict.dict | Where-Object { $_.key -eq "Kernel" } | Select-Object -ExpandProperty dict
    $QuirksNode.true | Where-Object { $_.key -eq "ProvideCurrentCpuInfo" }.InnerXml = "True"

    # 5. Сохранение и Отмонтирование
    $Plist.Save($ConfigPath)
    Dismount-VHD -Path $VhdPath -Confirm:$false
    Write-Styled "EFI успешно пропатчен и отмонтирован. AMD Zen 3 и iServices готовы." -Color Green
}

Apply-CriticalPatches

#endregion

#region 7. ЗАКЛЮЧИТЕЛЬНЫЕ ИНСТРУКЦИИ
Write-Styled "`n--- Фаза 4: Установка и Завершение ---" -Color Yellow

Write-Styled "`nВСЕ АВТОМАТИЗИРОВАННЫЕ ШАГИ ЗАВЕРШЕНЫ УСПЕШНО." -Color Green
Write-Styled "Дальнейшие шаги (ВЫПОЛНЯТЬ ВРУЧНУЮ):" -Color Yellow

Write-Styled "`nШАГ 1: Проверка Настроек VM в Hyper-V Manager" -Color White
Write-Styled "  1. Откройте Hyper-V Manager."
Write-Styled "  2. Щелкните правой кнопкой мыши на VM '$($VMConfig.Name)' -> Настройки (Settings)."
Write-Styled "  3. 'Безопасность' -> Отключите 'Включить безопасную загрузку' (Secure Boot)." [9]
Write-Styled "  4. 'Память' -> Убедитесь, что выделено $($VMConfig.RAM) ГБ."

Write-Styled "`nШАГ 2: Первый Запуск и Установка macOS" -Color White
Write-Styled "  1. Запустите VM '$($VMConfig.Name)' и подключитесь к ней."
Write-Styled "  2. Выберите 'macOS Base System' в меню OpenCore."
Write-Styled "  3. Запустите 'Дисковая утилита' (Disk Utility) в среде восстановления macOS."
Write-Styled "  4. 'Стереть' (Erase) виртуальный диск (размером $($VMConfig.Size) ГБ), формат APFS." [5]
Write-Styled "  5. Выйдите из Дисковой утилиты и выберите 'Переустановить macOS'."

Write-Styled "`nШАГ 3: После Установки" -Color White
Write-Styled "  После установки iServices (App Store, iCloud) должны работать благодаря примененным патчам." [5]

Write-Styled "`n*** ВАЖНОЕ ПРИМЕЧАНИЕ ***" -Color Red
Write-Styled "Если вы включали Hyper-V, может потребоваться перезагрузка Windows 11." -Color Red

Write-Styled "`nНажмите Enter для выхода."
Read-Host
#endregion
