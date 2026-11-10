// vz: Virtualization.framework 的 Linux VM 執行器。
// 參數解析、cmdline 組裝都在 vz.sh; 這裡只負責把參數變成 VZVirtualMachineConfiguration 並執行。
// 用法 (通常由 vz.sh 呼叫):
//   vz --disk PATH --cpus N --memory-mb N
//      (--kernel PATH [--initrd PATH] --cmdline STR | --efi-vars PATH)
//      [--cdrom ISO] [--mac MAC] [--share 標籤:路徑[:ro]]... [--gui --width W --height H]
// 無 --gui: 終端機接 guest 的 hvc0 (virtio console); Ctrl-A x 強制結束, Ctrl-A Ctrl-A 送出一個 Ctrl-A。
// 有 --gui: 開視窗; hvc0 一樣接終端機。
import AppKit
import Foundation
import Virtualization

// MARK: - 參數

struct Options {
    var disk = ""
    var cpus = 4
    var memoryMB = 4096
    var kernel: String?
    var initrd: String?
    var cmdline = ""
    var efiVars: String?
    var cdrom: String?
    var mac: String?
    var shares: [(tag: String, path: String, readOnly: Bool)] = []
    var gui = false
    var width = 1920
    var height = 1200
    var mic = false
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("vz: \(msg)\n".utf8))
    exit(1)
}

func parseArgs() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { die("\(flag) 需要一個值") }
        return v
    }
    func intValue(_ flag: String) -> Int {
        guard let n = Int(value(flag)), n > 0 else { die("\(flag) 要是正整數") }
        return n
    }
    while let a = it.next() {
        switch a {
        case "--disk": o.disk = value(a)
        case "--cpus": o.cpus = intValue(a)
        case "--memory-mb": o.memoryMB = intValue(a)
        case "--kernel": o.kernel = value(a)
        case "--initrd": o.initrd = value(a)
        case "--cmdline": o.cmdline = value(a)
        case "--efi-vars": o.efiVars = value(a)
        case "--cdrom": o.cdrom = value(a)
        case "--mac": o.mac = value(a)
        case "--width": o.width = intValue(a)
        case "--height": o.height = intValue(a)
        case "--gui": o.gui = true
        case "--mic": o.mic = true
        case "--share":
            let parts = value(a).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { die("--share 格式: 標籤:路徑[:ro]") }
            o.shares.append((parts[0], parts[1], parts.count > 2 && parts[2] == "ro"))
        default: die("未知參數: \(a)")
        }
    }
    if o.disk.isEmpty { die("缺少 --disk") }
    if o.kernel == nil && o.efiVars == nil { die("要給 --kernel (直接開機) 或 --efi-vars (UEFI)") }
    return o
}

// MARK: - VM 設定

func makeConfiguration(_ o: Options) throws -> VZVirtualMachineConfiguration {
    let c = VZVirtualMachineConfiguration()
    c.cpuCount = o.cpus
    c.memorySize = UInt64(o.memoryMB) * 1024 * 1024
    c.platform = VZGenericPlatformConfiguration()

    // 開機
    if let kernel = o.kernel {
        let b = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: kernel))
        if let initrd = o.initrd { b.initialRamdiskURL = URL(fileURLWithPath: initrd) }
        b.commandLine = o.cmdline
        c.bootLoader = b
    } else if let varsPath = o.efiVars {
        let b = VZEFIBootLoader()
        let url = URL(fileURLWithPath: varsPath)
        b.variableStore = FileManager.default.fileExists(atPath: varsPath)
            ? VZEFIVariableStore(url: url)
            : try VZEFIVariableStore(creatingVariableStoreAt: url)
        c.bootLoader = b
    }

    // 儲存: raw 磁碟, flush 用 fsync (不是預設的 F_FULLFSYNC, 後者每次 guest flush 都慢很多)
    var storage: [VZStorageDeviceConfiguration] = []
    let disk = try VZDiskImageStorageDeviceAttachment(
        url: URL(fileURLWithPath: o.disk), readOnly: false, cachingMode: .automatic, synchronizationMode: .fsync)
    storage.append(VZVirtioBlockDeviceConfiguration(attachment: disk))
    if let iso = o.cdrom {
        let a = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: iso), readOnly: true)
        storage.append(VZUSBMassStorageDeviceConfiguration(attachment: a))
    }
    c.storageDevices = storage

    // 網路: NAT
    let net = VZVirtioNetworkDeviceConfiguration()
    net.attachment = VZNATNetworkDeviceAttachment()
    if let m = o.mac {
        guard let addr = VZMACAddress(string: m) else { die("MAC 格式不對: \(m)") }
        net.macAddress = addr
    }
    c.networkDevices = [net]

    c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    // 序列主控台 (guest 的 hvc0): 輸入經過 Ctrl-A 過濾器, 輸出直接到 stdout
    let port = VZVirtioConsoleDeviceSerialPortConfiguration()
    port.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: consoleInput.fileHandleForReading,
        fileHandleForWriting: FileHandle.standardOutput)
    c.serialPorts = [port]

    // 共享資料夾 (virtio-fs)
    var fsDevices: [VZDirectorySharingDeviceConfiguration] = []
    for s in o.shares {
        guard FileManager.default.fileExists(atPath: s.path) else {
            FileHandle.standardError.write(Data("略過共享 \(s.tag): 資料夾不存在 (\(s.path))\n".utf8))
            continue
        }
        try VZVirtioFileSystemDeviceConfiguration.validateTag(s.tag)
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: s.tag)
        fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: s.path), readOnly: s.readOnly))
        fsDevices.append(fs)
    }
    c.directorySharingDevices = fsDevices

    // 音效 (輸出; --mic 加輸入, macOS 會詢問權限)
    let sound = VZVirtioSoundDeviceConfiguration()
    let out = VZVirtioSoundDeviceOutputStreamConfiguration()
    out.sink = VZHostAudioOutputStreamSink()
    sound.streams = [out]
    if o.mic {
        let inp = VZVirtioSoundDeviceInputStreamConfiguration()
        inp.source = VZHostAudioInputStreamSource()
        sound.streams.append(inp)
    }
    c.audioDevices = [sound]

    // 顯示與輸入 (只有 --gui)
    if o.gui {
        let gpu = VZVirtioGraphicsDeviceConfiguration()
        gpu.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: o.width, heightInPixels: o.height)]
        c.graphicsDevices = [gpu]
        c.keyboards = [VZUSBKeyboardConfiguration()]
        c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    try c.validate()
    return c
}

// MARK: - 終端機 (raw mode + Ctrl-A 過濾)

let consoleInput = Pipe()
var savedTermios = termios()
var termiosSaved = false

func restoreTerminal() {
    if termiosSaved { tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios); termiosSaved = false }
}

func setupTerminal(onForceQuit: @escaping () -> Void) {
    if isatty(STDIN_FILENO) != 0 {
        tcgetattr(STDIN_FILENO, &savedTermios)
        termiosSaved = true
        var raw = savedTermios
        cfmakeraw(&raw)
        raw.c_oflag |= tcflag_t(OPOST)     // 輸出的換行照常處理
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        atexit { restoreTerminal() }
    }
    var sawCtrlA = false
    FileHandle.standardInput.readabilityHandler = { h in
        let data = h.availableData
        if data.isEmpty { h.readabilityHandler = nil; return }
        var out = Data()
        for b in data {
            if sawCtrlA {
                sawCtrlA = false
                if b == UInt8(ascii: "x") { DispatchQueue.main.async(execute: onForceQuit); return }
                if b == 0x01 { out.append(0x01) } else { out.append(0x01); out.append(b) }
            } else if b == 0x01 {
                sawCtrlA = true
            } else {
                out.append(b)
            }
        }
        if !out.isEmpty { consoleInput.fileHandleForWriting.write(out) }
    }
}

// MARK: - 執行

final class Delegate: NSObject, VZVirtualMachineDelegate, NSApplicationDelegate, NSWindowDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        restoreTerminal()
        exit(0)
    }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        restoreTerminal()
        FileHandle.standardError.write(Data("\nvz: VM 異常停止: \(error)\n".utf8))
        exit(1)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cmd-Q / 關視窗: 請 guest 正常關機 (等同按電源鍵); 關不掉再用 Ctrl-A x 或 kill
        requestGuestStop()
        return .terminateCancel
    }
}

let opts = parseArgs()
let delegate = Delegate()
var vm: VZVirtualMachine!

func requestGuestStop() {
    guard vm != nil, vm.state == .running else { return }
    try? vm.requestStop()
}

func forceStop() {
    guard vm != nil else { exit(1) }
    vm.stop { _ in restoreTerminal(); exit(0) }
}

let config: VZVirtualMachineConfiguration
do { config = try makeConfiguration(opts) } catch { die("設定無效: \(error)") }
vm = VZVirtualMachine(configuration: config)
vm.delegate = delegate
setupTerminal(onForceQuit: forceStop)

// SIGTERM / SIGHUP: 請 guest 正常關機
signal(SIGTERM, SIG_IGN); signal(SIGHUP, SIG_IGN)
let sigSources = [SIGTERM, SIGHUP].map { sig -> DispatchSourceSignal in
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { requestGuestStop() }
    s.resume()
    return s
}
_ = sigSources

func startVM() {
    vm.start { result in
        if case .failure(let e) = result {
            restoreTerminal()
            die("啟動失敗: \(e)")
        }
    }
}

if opts.gui {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.delegate = delegate

    let menu = NSMenu()
    let appItem = NSMenuItem(); menu.addItem(appItem)
    let appMenu = NSMenu(); appItem.submenu = appMenu
    appMenu.addItem(withTitle: "結束 (請 guest 關機)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    app.mainMenu = menu

    let view = VZVirtualMachineView()
    view.virtualMachine = vm
    view.capturesSystemKeys = true
    view.automaticallyReconfiguresDisplay = true
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: min(opts.width, 1440) / 1, height: min(opts.height, 900)),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
    window.title = URL(fileURLWithPath: opts.disk).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    window.contentView = view
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    app.activate(ignoringOtherApps: true)
    DispatchQueue.main.async { startVM() }
    app.run()
} else {
    DispatchQueue.main.async { startVM() }
    dispatchMain()
}
