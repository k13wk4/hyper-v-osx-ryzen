# Universal PowerShell Script to Install macOS on Hyper-V
# Supports AMD/Intel CPUs, detects system specs, configures environment, builds EFI
# Designed for use with Qonfused/OSX-Hyper-V

# --- Section 1: System Checks and Hyper-V Activation ---
function Check-HyperV {
    Write-Host "[1/6] Проверка поддержки Hyper-V..." -ForegroundColor Cyan
    try {
        $logPath = "C:\\macos_setup_log.txt"
        "=== Проверка Hyper-V === $(Get-Date)" | Out-File $logPath -Append

        # Проверка версии Windows
        $osSKU = (Get-CimInstance Win32_OperatingSystem).OperatingSystemSKU
        if ($osSKU -in 100,101,121) {
            Write-Warning "⚠️ Ваша версия Windows (Home) не поддерживает Hyper-V"
            "Windows SKU неподдерживаемая" | Out-File $logPath -Append
            return $false
        }

        # Проверка BIOS Virtualization
        $sysInfo = systeminfo
        if ($sysInfo -notmatch "Virtualization Enabled In Firmware:\\s*Yes" -or
            $sysInfo -notmatch "Second Level Address Translation:\\s*Yes") {
            Write-Warning "⚠️ Виртуализация или SLAT не включены в BIOS"
            "BIOS virtualization OFF" | Out-File $logPath -Append
            return $false
        }

        # Проверка и включение Hyper-V
        $hvFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue
        if ($null -eq $hvFeature) {
            Write-Warning "❌ Не удалось получить состояние Hyper-V."
            "Hyper-V feature info missing" | Out-File $logPath -Append
            return $false
        }

        if ($hvFeature.State -ne "Enabled") {
            Write-Host "🔧 Включаем Hyper-V..." -ForegroundColor Yellow
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart | Out-Null
            Write-Host "✅ Hyper-V включен. Перезагрузите ПК и запустите скрипт снова."
            "Hyper-V enabled, reboot required" | Out-File $logPath -Append
            return $false
        }

        Write-Host "✅ Hyper-V включен и готов." -ForegroundColor Green
        "Hyper-V OK" | Out-File $logPath -Append
        return $true
    }
    catch {
        Write-Error "Ошибка при проверке Hyper-V: $($_.Exception.Message)"
        $_.Exception | Out-File $logPath -Append
        return $false
    }
}


# --- Section 2: System Info Detection ---
function Get-SystemSpecs {
    $cpu = Get-CimInstance Win32_Processor
    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $gpu = Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name
    return @{ CPU = $cpu.Name; Cores = $cpu.NumberOfLogicalProcessors; RAM = $ram; GPU = $gpu }
}

# --- Section 3: macOS Version Selection ---
function Select-macOSVersion($cpuName, $ram, $gpuList) {
    $versions = @("10.15","11","12","13","14")
    if ($cpuName -match "AMD") {
        $versions = @("10.15","11","12")
    }
    if ($gpuList -match "NVIDIA") {
        $versions = @("10.15")
    }
    Write-Host "Выберите версию macOS из поддерживаемых:"
    for ($i = 0; $i -lt $versions.Count; $i++) {
        Write-Host "  [$i] macOS ${versions[$i]}"
    }
    $choice = Read-Host "Введите номер версии"
    return $versions[$choice]
}

# --- Section 4: Prerequisites Installation ---
function Install-Tools {
    Write-Host "[2/6] Проверка и установка Git/Python..."
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "Устанавливаем Git..."
        winget install --id Git.Git -e --source winget
    }
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Host "Устанавливаем Python..."
        winget install --id Python.Python.3.11 -e --source winget
    }
}

# --- Section 5: Build EFI for VM ---
function Build-OpenCore($cpuName, $coreCount) {
    Write-Host "[3/6] Сборка OpenCore EFI..."
    if (-not (Test-Path "OSX-Hyper-V")) {
        git clone https://github.com/Qonfused/OSX-Hyper-V
    }
    Set-Location "OSX-Hyper-V"
    if ($cpuName -match "AMD") {
        Write-Host "Обнаружен AMD: применяем патчи..."
        .\scripts\amd.ps1 --cpu $coreCount
    }
    .\scripts\build.ps1
    Set-Location ".."
}

# --- Section 6: Create Hyper-V VM ---
function Create-VM($ver, $cores, $ram, $disk) {
    Write-Host "[4/6] Создание виртуальной машины macOS $ver..."
    $vmName = "macOS_$ver"
    $dist = "OSX-Hyper-V/dist/Scripts"
    & "$dist/create-virtual-machine.ps1" -Name $vmName -Version $ver -CPU $cores -RAM $ram -Size $disk
    Write-Host "[5/6] Виртуальная машина создана: $vmName"
}

# --- Section 7: Master Control ---
Check-HyperV
$specs = Get-SystemSpecs
Install-Tools
$macVersion = Select-macOSVersion $specs.CPU $specs.RAM $specs.GPU
Build-OpenCore $specs.CPU $specs.Cores
Create-VM $macVersion $specs.Cores $specs.RAM 64
Write-Host "[6/6] Готово. Запустите виртуальную машину через Hyper-V Manager."
