import Foundation
import Darwin
import CoreAudio
import CoreMediaIO
import IOKit.ps
import IOKit.pwr_mgt
import Network

/// Что Бит знает о компьютере.
struct SystemSnapshot: Equatable {
    var batteryLevel: Int?          // %, nil — батареи нет
    var charging = false
    var onAC = true
    var cpuLoad: Double = 0         // 0...1, среднее примерно за 15 с
    var online = true
    var vpnInterface: String?       // интерфейс VPN с IPv4 (ppp0, utun3, ...), nil — VPN нет
    var diskFreeBytes: Int64?
    var diskTotalBytes: Int64?
    var cameraOn = false
    var micOn = false
    var headphones = false
    var musicPlaying = false        // Apple Music или Spotify сообщили «играет»
    var soundPlaying = false        // вывод звука занят дольше 5 с — играет звук из любого приложения (браузер и т. п.)
    var thermalHot = false          // ProcessInfo.thermalState не ниже .serious
    var lowPower = false
    var memoryPressure = 0          // 0 — норма, 1 — предупреждение, 2 — критично
    var memoryUsed: Double = 0      // 0...1, как «Память занята» в Мониторинге системы: приложения + wired + сжатая
    var rxRate: Double = 0          // байт/с, приём по en*

    var isBatteryLow: Bool { (batteryLevel ?? 100) <= 20 && !onAC }
    var isBusy: Bool { cpuLoad >= 0.8 }
    var isDiskLow: Bool {
        guard let free = diskFreeBytes, let total = diskTotalBytes, total > 0 else { return false }
        return free < 10_000_000_000 || Double(free) / Double(total) < 0.05
    }
    /// Занятая доля диска, 0...1.
    var diskUsed: Double? {
        guard let free = diskFreeBytes, let total = diskTotalBytes, total > 0 else { return nil }
        return 1 - Double(free) / Double(total)
    }
    var inCall: Bool { cameraOn || micOn }
    var isDownloading: Bool { rxRate >= 3_000_000 }
    /// Играет музыка или другой звук; во время звонка не считается.
    var isMusic: Bool { (musicPlaying || soundPlaying) && !inCall }

    /// Строки для меню.
    var summary: [String] {
        var lines: [String] = []
        if let batteryLevel {
            lines.append(L("Батарея: %@ %%", "\(batteryLevel)") + (charging ? L(", заряжается") : onAC ? L(", от сети") : ""))
        }
        lines.append(L("Нагрузка CPU: %@ %%", "\(Int((cpuLoad * 100).rounded()))"))
        lines.append(L("Память: занято %@ %%", "\(Int((memoryUsed * 100).rounded()))"))
        lines.append(L("Сеть: ") + (online ? L("есть") : L("нет")) + String(format: L(", приём %.1f МБ/с"), rxRate / 1_000_000))
        lines.append("VPN: " + (vpnInterface.map { L("подключён (%@)", "\($0)") } ?? L("не подключён")))
        if let free = diskFreeBytes, let total = diskTotalBytes {
            lines.append(L("Диск: свободно %@ ГБ из %@", "\(free / 1_000_000_000)", "\(total / 1_000_000_000)"))
        }
        lines.append(L("Камера: ") + (cameraOn ? L("вкл") : L("выкл")) + L(", микрофон: ") + (micOn ? L("вкл") : L("выкл")))
        lines.append(L("Звук: ") + (headphones ? L("наушники") : L("динамики")) + (isMusic ? L(", играет звук") : ""))
        lines.append(L("Перегрев: ") + (thermalHot ? L("да") : L("нет")) + L(", память: ") + [L("норма"), L("мало"), L("критично")][memoryPressure]
                     + (lowPower ? L(", энергосбережение") : ""))
        return lines
    }
}

/// Опрашивает батарею, CPU, VPN, диск, камеру, микрофон, звук, температуру и сеть раз в 5 секунд;
/// связь, память и музыку получает событиями. Без прав доступа и без приватных API.
@MainActor
final class SystemMonitor {
    private(set) var snapshot = SystemSnapshot()
    /// Вызывается при каждом изменении (старое, новое). Первый опрос проходит молча,
    /// чтобы при запуске «от сети» не считалось подключением зарядки.
    var onChange: ((SystemSnapshot, SystemSnapshot) -> Void)?

    private var ready = false
    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var memorySource: DispatchSourceMemoryPressure?
    private let host = mach_host_self()
    private var previousTicks: [UInt32]?
    private var cpuSamples: [Double] = []
    private var previousRx: [String: UInt32] = [:]
    private var previousRxTime = Date()
    private var polls = 0
    private var outputRunPolls = 0

    func start() {
        poll()
        ready = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.update { $0.online = online } }
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        let memory = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        memory.setEventHandler { [weak self, weak memory] in
            guard let event = memory?.data else { return }
            let level = event.contains(.critical) ? 2 : event.contains(.warning) ? 1 : 0
            MainActor.assumeIsolated { self?.update { $0.memoryPressure = level } }
        }
        memory.resume()
        memorySource = memory

        // Плееры сами рассылают смену состояния; при запуске Бита считаем, что музыка не играет.
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let playing = note.userInfo?["Player State"] as? String == "Playing"
                MainActor.assumeIsolated { self?.update { $0.musicPlaying = playing } }
            }
        }

        // Сменился звуковой выход (подключили наушники) — опросить сразу, не ждать 5 секунд.
        var output = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &output, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.poll() }
        }

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func update(_ change: (inout SystemSnapshot) -> Void) {
        var next = snapshot
        change(&next)
        guard next != snapshot else { return }
        let old = snapshot
        snapshot = next
        if ready { onChange?(old, next) }
    }

    private func poll() {
        let battery = readBattery()
        let cpu = readCPU()
        let memory = readMemory()
        let vpn = readVPN()
        let rx = readRxRate()
        // Диск меняется медленно — раз в минуту.
        let disk = polls % 12 == 0 ? readDisk() : (snapshot.diskFreeBytes, snapshot.diskTotalBytes)
        polls += 1
        let input = Self.audioDevice(kAudioHardwarePropertyDefaultInputDevice)
        let output = Self.audioDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let process = ProcessInfo.processInfo
        let outputRunning = output.map { Self.audioUInt32($0, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 } ?? false
        outputRunPolls = outputRunning ? outputRunPolls + 1 : 0
        update { s in
            s.batteryLevel = battery.level
            s.charging = battery.charging
            s.onAC = battery.onAC
            if let cpu { s.cpuLoad = cpu }
            if let memory { s.memoryUsed = memory }
            s.vpnInterface = vpn
            if let rx { s.rxRate = rx }
            s.diskFreeBytes = disk.0
            s.diskTotalBytes = disk.1
            s.cameraOn = Self.cameraRunning()
            s.micOn = input.map { Self.audioUInt32($0, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 } ?? false
            s.headphones = output.map(Self.isHeadphones) ?? false
            s.soundPlaying = outputRunPolls >= 2  // два опроса подряд — не короткий системный звук
            s.thermalHot = process.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            s.lowPower = process.isLowPowerModeEnabled
        }
    }

    private func readBattery() -> (level: Int?, charging: Bool, onAC: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, false, true)
        }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (max > 0 ? current * 100 / max : nil, charging, onAC)
        }
        return (nil, false, true)
    }

    /// Доля занятого времени всех ядер с прошлого опроса, сглаженная по трём опросам.
    private func readCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let ticks = [t.0, t.1, t.2, t.3]  // user, system, idle, nice
        defer { previousTicks = ticks }
        guard let previous = previousTicks else { return nil }
        let delta = zip(ticks, previous).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        cpuSamples.append((total - delta[Int(CPU_STATE_IDLE)]) / total)
        if cpuSamples.count > 3 { cpuSamples.removeFirst() }
        return cpuSamples.reduce(0, +) / Double(cpuSamples.count)
    }

    /// Занятая память: страницы приложений (без очищаемых), wired и сжатые — как в Мониторинге системы.
    private func readMemory() -> Double? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = Double(info.internal_page_count) - Double(info.purgeable_count) + Double(info.wire_count)
            + Double(info.compressor_page_count)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        return min(max(pages * Double(vm_kernel_page_size) / total, 0), 1)
    }

    /// Обходит интерфейсы. Возвращает VPN — поднятый туннель с IPv4: ppp (L2TP/PPTP), utun (IKEv2, WireGuard и др.), ipsec.
    private func readVPN() -> String? {
        var found: String?
        Self.forEachInterface { ifa, name in
            guard found == nil, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0 else { return }
            if ["ppp", "utun", "ipsec", "tun", "wg"].contains(where: { name.hasPrefix($0) }) { found = name }
        }
        return found
    }

    /// Скорость приёма по физическим интерфейсам en*. Счётчики 32-битные, поэтому разница — с переполнением.
    private func readRxRate() -> Double? {
        var current: [String: UInt32] = [:]
        Self.forEachInterface { ifa, name in
            guard name.hasPrefix("en"), let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.ifa_data else { return }
            current[name] = data.assumingMemoryBound(to: if_data.self).pointee.ifi_ibytes
        }
        let now = Date()
        defer { previousRx = current; previousRxTime = now }
        let elapsed = now.timeIntervalSince(previousRxTime)
        guard !previousRx.isEmpty, elapsed > 0 else { return nil }
        let bytes = current.reduce(0.0) { sum, item in
            guard let old = previousRx[item.key] else { return sum }
            return sum + Double(item.value &- old)
        }
        return bytes / elapsed
    }

    private static func forEachInterface(_ body: (ifaddrs, String) -> Void) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            body(pointer.pointee, String(cString: pointer.pointee.ifa_name))
        }
    }

    private func readDisk() -> (Int64?, Int64?) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage, values?.volumeTotalCapacity.map(Int64.init))
    }

    // MARK: - Звук и камера (CoreAudio, CoreMediaIO; разрешения не нужны — читаем только «занято ли»)

    private static func audioDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func audioUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    /// Наушники: Bluetooth-устройство вывода, встроенный выход с источником «наушники» ('hdpn')
    /// или устройство с «наушниковым» именем (USB-гарнитуры и т. п.).
    private static func isHeadphones(_ id: AudioDeviceID) -> Bool {
        let transport = audioUInt32(id, kAudioDevicePropertyTransportType)
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        if transport == kAudioDeviceTransportTypeBuiltIn
            && audioUInt32(id, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput) == 0x6864_706E { return true }
        let name = deviceName(id).lowercased()
        return ["наушник", "гарнитур", "headphone", "headset", "airpods", "earpods", "buds", "beats"].contains { name.contains($0) }
    }

    private static func deviceName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return "" }
        return (name?.takeRetainedValue() as String?) ?? ""
    }

    private static func cameraRunning() -> Bool {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return false }
        var devices = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return false }
        for device in devices {
            var running = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var value: UInt32 = 0
            var dataUsed: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &dataUsed, &value) == noErr,
               value != 0 { return true }
        }
        return false
    }
}

/// Кофе-режим: пока включён, Mac не гасит экран и не засыпает от простоя (как `caffeinate -d`).
/// Полезно на долгих операциях по RDP и VPN: соединение не рвётся.
@MainActor
final class CoffeeMode {
    private var assertion: IOPMAssertionID = 0
    private(set) var since: Date?
    var isOn: Bool { since != nil }

    func set(_ on: Bool) {
        if on, since == nil {
            let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "MyPetBit: coffee mode" as CFString, &assertion)
            if ok == kIOReturnSuccess { since = Date() }
        } else if !on, since != nil {
            IOPMAssertionRelease(assertion)
            since = nil
        }
    }
}

/// Резкий рост нагрузки: процессор, память, место на диске. Только логика, без системы — проверяется тестами.
/// Сравнивает текущее значение с тем, что было несколько минут назад: высокая нагрузка сама по себе не повод
/// (сборка всегда грузит процессор), повод — когда спокойный Mac вдруг загрузился.
struct LoadSpikes {
    enum Kind: String { case cpu, memory, disk }

    struct Spike: Equatable {
        let kind: Kind
        /// CPU и память — доля 0...1; диск — занятые байты.
        let now: Double
        let before: Double
        /// За сколько минут вырос (для диска).
        let minutes: Int
    }

    private struct Sample {
        let time: Date
        let cpu: Double
        let memory: Double
        let diskUsedBytes: Double?
    }

    private var history: [Sample] = []
    /// После всплеска — молчит, пока значение не опустится (и не меньше паузы), чтобы не повторяться.
    private var armed: Set<Kind> = [.cpu, .memory, .disk]
    private var last: [Kind: Date] = [:]

    mutating func add(cpu: Double, memory: Double, diskUsedBytes: Double?, diskTotalBytes: Double?, at now: Date = Date()) -> [Spike] {
        history.append(Sample(time: now, cpu: cpu, memory: memory, diskUsedBytes: diskUsedBytes))
        history.removeAll { now.timeIntervalSince($0.time) > 15 * 60 }
        func age(_ s: Sample) -> TimeInterval { now.timeIntervalSince(s.time) }
        func cooled(_ kind: Kind, _ pause: TimeInterval) -> Bool { last[kind].map { now.timeIntervalSince($0) >= pause } ?? true }
        var spikes: [Spike] = []

        // Процессор: сейчас 75 % и больше, а последние минуты (кроме последних 30 с) было спокойно — до 35 %.
        if cpu < 0.5 { armed.insert(.cpu) }
        let calm = history.filter { (30...300).contains(age($0)) }.map(\.cpu).sorted()
        if armed.contains(.cpu), cpu >= 0.75, calm.count >= 6, calm[calm.count / 2] <= 0.35, cooled(.cpu, 10 * 60) {
            spikes.append(Spike(kind: .cpu, now: cpu, before: calm[calm.count / 2], minutes: 0))
            armed.remove(.cpu)
            last[.cpu] = now
        }

        // Память: занято 85 % и больше и выросло на 15 пунктов за последние 5 минут.
        if memory < 0.8 { armed.insert(.memory) }
        if armed.contains(.memory), memory >= 0.85,
           let low = history.filter({ (20...300).contains(age($0)) }).map(\.memory).min(), memory - low >= 0.15,
           cooled(.memory, 10 * 60) {
            spikes.append(Spike(kind: .memory, now: memory, before: low, minutes: 0))
            armed.remove(.memory)
            last[.memory] = now
        }

        // Диск: за 10 минут занято больше на 5 ГБ и не меньше 2 % диска.
        if let used = diskUsedBytes, let total = diskTotalBytes, total > 0,
           let first = history.first(where: { age($0) <= 10 * 60 && $0.diskUsedBytes != nil }), let before = first.diskUsedBytes,
           used - before >= max(5e9, total * 0.02), cooled(.disk, 30 * 60) {
            spikes.append(Spike(kind: .disk, now: used, before: before, minutes: max(1, Int((age(first) / 60).rounded()))))
            last[.disk] = now
        }
        return spikes
    }
}

/// Самый тяжёлый процесс по процессору или памяти — через `ps` в отдельном процессе (видит и чужие процессы).
enum TopProcess {
    /// done: имя и значение — проценты CPU (может быть больше 100 на нескольких ядрах) или байты памяти.
    @MainActor static func find(memory: Bool, _ done: @escaping @MainActor ((name: String, value: Double)?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            // -A все процессы, -c короткое имя, -r по CPU, -m по памяти; rss — в КБ.
            process.arguments = memory ? ["-Amco", "rss=,comm="] : ["-Arco", "pcpu=,comm="]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            var result: (name: String, value: Double)?
            if (try? process.run()) != nil {
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                result = parse(text).map { (name: $0.name, value: memory ? $0.value * 1024 : $0.value) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(result) }
            }
        }
    }

    /// Первая строка вывода `ps`: число и имя (в имени бывают пробелы). Сам `ps` пропускается.
    static func parse(_ output: String) -> (name: String, value: Double)? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let value = Double(trimmed[..<space].replacingOccurrences(of: ",", with: ".")) else { continue }
            let name = trimmed[space...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "ps" else { continue }
            return (name, value)
        }
        return nil
    }
}
