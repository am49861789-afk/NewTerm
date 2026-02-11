//
//  TerminalController.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import SwiftUI
import SwiftTerm
import os.log

public protocol TerminalControllerDelegate: AnyObject {
    func refresh(lines: inout [AnyView])
    func refresh(lines: inout [BufferLine], cursor: (Int,Int))
    func scroll(animated: Bool)
    func activateBell()
    func titleDidChange(_ title: String?, isDirty: Bool, hasBell: Bool)
    func currentFileDidChange(_ url: URL?, inWorkingDirectory workingDirectoryURL: URL?)

    func saveFile(url: URL)
    func fileUploadRequested()

    func close()
    func didReceiveError(error: Error)
}

public class TerminalController {

    public weak var delegate: TerminalControllerDelegate?

    public var colorMap: ColorMap {
        get { stringSupplier.colorMap ?? Preferences.shared.colorMap }
        set { stringSupplier.colorMap = newValue }
    }
    public var fontMetrics: FontMetrics {
        get { stringSupplier.fontMetrics ?? Preferences.shared.fontMetrics }
        set { stringSupplier.fontMetrics = newValue }
    }

    public var terminal: Terminal?
    
    private var subProcess: SubProcess?
    private var subProcessFailureError: Error?
    public let stringSupplier = StringSupplier()
    private var lines = [AnyView]()

    private var processLaunchDate: Date?
    private var updateTimer: CADisplayLink?
    private var refreshRate: TimeInterval = 60
    private var isTabVisible = true
    private var isWindowVisible = true
    private var isVisible: Bool { isTabVisible && isWindowVisible }
    private var isDirty = false {
        didSet { updateTitle() }
    }
    private var hasBell = false {
        didSet { updateTitle() }
    }
    private var readBuffer = [UTF8Char]()
    private var bufferLock = NSLock()

    internal var terminalQueue = DispatchQueue(label: "ws.hbang.Terminal.terminal-queue")

    public var screenSize: ScreenSize? {
        didSet { updateScreenSize() }
    }
    public var scrollbackLines: Int { terminal?.getTopVisibleRow() ?? 0 }

    private var lastCursorLocation: (x: Int, y: Int) = (-1, -1)
    private var lastBellDate: Date?

    internal var title: String?
    internal var userAndHostname: String?
    internal var user: String?
    internal var hostname: String?
    internal var isLocalhost: Bool { hostname == nil || hostname == ProcessInfo.processInfo.hostName }
    internal var currentWorkingDirectory: URL?
    internal var currentFile: URL?

    internal var iTermIntegrationVersion: String?
    internal var shell: String?

    internal var logger = Logger(subsystem: "ws.hbang.Terminal", category: "TerminalController")

    public init() {
        let options = TerminalOptions(termName: "xterm-256color",
                                                                    scrollback: 10000)
        terminal = Terminal(delegate: self, options: options)

        stringSupplier.terminal = terminal

        NotificationCenter.default.addObserver(self, selector: #selector(self.preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
        preferencesUpdated()

        startUpdateTimer(fps: refreshRate)

        NotificationCenter.default.addObserver(self, selector: #selector(self.appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)

        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(self.powerStateChanged), name: UIDevice.batteryStateDidChangeNotification, object: nil)

        if #available(macOS 12, *) {
            NotificationCenter.default.addObserver(self, selector: #selector(self.powerStateChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        }
    }

    @objc private func preferencesUpdated() {
        let preferences = Preferences.shared
        stringSupplier.colorMap = preferences.colorMap
        stringSupplier.fontMetrics = preferences.fontMetrics

        powerStateChanged()
        terminalQueue.async {
            self.terminal?.refresh(startRow: 0, endRow: self.terminal?.rows ?? 0)
        }
    }

    @objc private func powerStateChanged() {
        let preferences = Preferences.shared
        if #available(macOS 12, *),
             ProcessInfo.processInfo.isLowPowerModeEnabled && preferences.reduceRefreshRateInLPM {
            refreshRate = 15
        } else {
            let currentRate = UIDevice.current.batteryState == .unplugged ? preferences.refreshRateOnBattery : preferences.refreshRateOnAC
            refreshRate = TimeInterval(min(currentRate, UIScreen.main.maximumFramesPerSecond))
        }
        if isVisible {
            startUpdateTimer(fps: refreshRate)
        }
    }

    public func windowDidEnterBackground() {
        startUpdateTimer(fps: UIApplication.shared.supportsMultipleScenes ? 10 : 1)
        isWindowVisible = false
    }

    public func windowWillEnterForeground() {
        isWindowVisible = true
        if isVisible {
            startUpdateTimer(fps: refreshRate)
        }
    }

    @objc private func appWillResignActive() {
        stopUpdatingTimer()
        isWindowVisible = false
    }

    @objc private func appDidBecomeActive() {
        startUpdateTimer(fps: refreshRate)
        isWindowVisible = true
    }

    public func terminalWillAppear() {
        startUpdateTimer(fps: refreshRate)
        isTabVisible = true
    }

    public func terminalWillDisappear() {
        startUpdateTimer(fps: 1)
        isTabVisible = false
    }

    private func startUpdateTimer(fps: TimeInterval) {
        updateTimer?.invalidate()
        updateTimer = CADisplayLink(target: self, selector: #selector(self.updateTimerFired))
        updateTimer?.preferredFramesPerSecond = Int(fps)
        updateTimer?.add(to: .main, forMode: .default)
    }

    private func stopUpdatingTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    // MARK: - Sub Process

    public func startSubProcess() throws {
        subProcess = SubProcess()
        subProcess!.delegate = self
        processLaunchDate = Date()
        do {
            try subProcess!.start()
        } catch {
            subProcessFailureError = error
            throw error
        }
    }

    public func stopSubProcess() throws {
        try subProcess!.stop()
        stopUpdatingTimer()
    }

    // MARK: - Terminal

    public func readInputStream(_ data: [UTF8Char]) {
        var buflen = 0
        bufferLock.lock()
        self.readBuffer += data
        buflen = self.readBuffer.count
        bufferLock.unlock()
        
        if buflen > 100 {
            terminalQueue.sync {
            }
        }
    }

    private func readInputStream(_ data: Data) {
        readInputStream([UTF8Char](data))
    }

    public func write(_ data: [UTF8Char]) {
        subProcess?.write(data: data)
    }

    public func write(_ data: Data) {
        write([UTF8Char](data))
    }

    @objc private func updateTimerFired() {
        terminalQueue.async {
            var buffer = [UTF8Char]()
            
            self.bufferLock.lock()
            if !self.readBuffer.isEmpty {
                buffer = self.readBuffer
                self.readBuffer.removeAll()
            }
            self.bufferLock.unlock()
            
            if !buffer.isEmpty {
                self.terminal?.feed(byteArray: buffer)
            }

            guard let terminal = self.terminal else {
                return
            }

            let scrollbackRows = terminal.getTopVisibleRow()
            var cursorLocation = terminal.getCursorLocation()
            cursorLocation.y += scrollbackRows

            let updateRange = terminal.getScrollInvariantUpdateRange() ?? (0, 0)
            if updateRange == (0, 0) && cursorLocation == self.lastCursorLocation {
                return
            }
            terminal.clearUpdateRange()

            let scrollInvariantRows = scrollbackRows + terminal.rows
            self.lastCursorLocation = cursorLocation
            
            var count = scrollInvariantRows
            if scrollbackRows == 0 && !terminal.buffers.isAlternateBuffer {
                // If no scrollback, render screen height
                count = terminal.rows
                // Or if we want to be strict about used lines:
                // count = terminal.buffer.y + 1
            }

            // FIXED: Use getLine() to correctly fetch history and screen lines
            var alllines = [BufferLine]()
            for i in 0..<count {
                if let line = terminal.getLine(row: i) {
                    alllines.append(line)
                } else {
                    // Fallback to empty line if needed
                    alllines.append(terminal.buffer.lines[0]) // Dummy safe
                }
            }
            
            DispatchQueue.main.async {
                self.delegate?.refresh(lines: &alllines, cursor: cursorLocation)

                if !self.isVisible && !self.isDirty {
                    self.isDirty = true
                }
            }
        }
    }

    public func clearTerminal() {
        terminalQueue.async {
            self.terminal?.resetToInitialState()
        }

        if let screenSize = screenSize {
            var newScreenSize = screenSize
            newScreenSize.cols -= 1
            self.subProcess?.screenSize = newScreenSize

            DispatchQueue.main.async {
                self.subProcess?.screenSize = screenSize
            }
        }
    }

    private func updateScreenSize() {
        terminalQueue.async {
            if let screenSize = self.screenSize, let terminal = self.terminal,
               screenSize.cols != terminal.cols || screenSize.rows != terminal.rows {
                
                self.subProcess?.screenSize = screenSize
                
                terminal.resize(cols: Int(screenSize.cols), rows: Int(screenSize.rows))
                
                self.subProcess?.activeProcess()
                
                if let error = self.subProcessFailureError {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.readInputStream(ColorBars.render(screenSize: screenSize, message: message))
                }
            }
        }
    }

    private func updateTitle() {
        var newTitle: String? = nil
        if let title = title,
             !title.isEmpty {
            newTitle = title
        }
        if let hostname = hostname {
            let user = self.user == NSUserName() ? nil : self.user
            let cleanedHostname = hostname.replacingOccurrences(of: #"\.local$"#, with: "", options: .regularExpression, range: hostname.startIndex..<hostname.endIndex)
            let hostString: String
            if isLocalhost {
                hostString = user ?? ""
            } else {
                hostString = "\(user ?? "")\(user == nil ? "" : "@")\(cleanedHostname)"
            }
            if !hostString.isEmpty {
                newTitle = "[\(hostString)] \(newTitle ?? "")"
            }
        }
        self.delegate?.titleDidChange(newTitle,
                                                                    isDirty: isDirty,
                                                                    hasBell: hasBell)
    }

    deinit {
        updateTimer?.invalidate()
    }

}

extension TerminalController: TerminalDelegate {

    public func isProcessTrusted(source: Terminal) -> Bool { isLocalhost }

    public func send(source: Terminal, data: ArraySlice<UInt8>) {
        terminalQueue.async {
            self.write([UTF8Char](data))
        }
    }

    public func bell(source: Terminal) {
        DispatchQueue.main.async {
            if self.lastBellDate == nil || self.lastBellDate! < Date(timeIntervalSinceNow: -1) {
                self.lastBellDate = Date()
                self.delegate?.activateBell()
            }

            if !self.isVisible && !self.hasBell {
                self.hasBell = true
            }
        }
    }

    public func showCursor(source: Terminal) {
        stringSupplier.cursorVisible = true
    }

    public func hideCursor(source: Terminal) {
        stringSupplier.cursorVisible = false
    }

    public func mouseModeChanged(source: Terminal) {
    }

    public func titleChanged(source: Terminal, title: String) {
        self.title = title
        DispatchQueue.main.async {
            self.updateTitle()
        }
    }

    public func sizeChanged(source: Terminal) {
    }

    public func setTerminalTitle(source: Terminal, title: String) {
        titleChanged(source: source, title: title)
    }

    public func hostCurrentDirectoryUpdate(source: Terminal, directory: String?) {
        if let directory = directory {
            currentWorkingDirectory = URL(fileURLWithPath: directory)
            DispatchQueue.main.async {
                self.delegate?.currentFileDidChange(self.currentFile ?? self.currentWorkingDirectory,
                                                                                        inWorkingDirectory: self.currentWorkingDirectory)
            }
        }
    }

    public func rangeChanged(source: Terminal, startY: Int, endY: Int) {
    }

}

extension TerminalController: SubProcessDelegate {

    func subProcessDidConnect() {
    }

    func subProcess(didReceiveData data: [UTF8Char]) {
        readInputStream(data)
    }

    func subProcess(didDisconnectWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.delegate?.didReceiveError(error: error)
            }
        } else {
            DispatchQueue.main.async {
                self.delegate?.close()
            }
        }
    }

    func subProcess(didReceiveError error: Error) {
        DispatchQueue.main.async {
            self.delegate?.didReceiveError(error: error)
        }
    }

}

extension TerminalController: TerminalInputProtocol {
    public func receiveKeyboardInput(data: [UTF8Char]) {
        self.write(data)
    }
    
    public var applicationCursor: Bool {
        return self.terminal?.applicationCursor ?? false
    }
    
    public func getAllText() -> String? {
        return nil
    }
}
