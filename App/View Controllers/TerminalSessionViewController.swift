//
//  TerminalSessionViewController.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import os.log
import CoreServices
import SwiftUIX
import SwiftTerm
import NewTermCommon

// MARK: - Protocol Definition
protocol TerminalSessionViewControllerDelegate: AnyObject {
    func terminal(viewController: TerminalSessionViewController, titleDidChange title: String, isDirty: Bool, hasBell: Bool)
    func terminal(viewController: TerminalSessionViewController, screenSizeDidChange screenSize: ScreenSize)
    func terminalDidBecomeActive(viewController: TerminalSessionViewController)
}

// MARK: - Custom TextView
class TerminalTextView: UITextView {
    var onPaste: ((String) -> Void)?
    
    // 只读模式下允许粘贴
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return true }
        return super.canPerformAction(action, withSender: sender)
    }
    
    override func paste(_ sender: Any?) {
        if let string = UIPasteboard.general.string {
            onPaste?(string)
        }
    }
    
    // 优化手势冲突
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPanGestureRecognizer || gestureRecognizer is UILongPressGestureRecognizer {
            return true
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

// MARK: - View Controller
class TerminalSessionViewController: BaseTerminalSplitViewControllerChild {

    // MARK: Public Properties
    var keyboardToolbarHeightChanged: ((Double) -> Void)?
    
    // 必须为 public/internal 以便外部赋值
    var initialCommand: String?
    
    // 【关键修复】重命名为 sessionDelegate，避免与父类 delegate 冲突
    weak var sessionDelegate: TerminalSessionViewControllerDelegate?

    override var isSplitViewResizing: Bool {
        didSet { updateIsSplitViewResizing() }
    }
    override var showsTitleView: Bool {
        didSet { updateShowsTitleView() }
    }
    override var screenSize: ScreenSize? {
        get { terminalController.screenSize }
        set { terminalController.screenSize = newValue }
    }

    // MARK: Private Properties
    private var terminalController = TerminalController()
    private var keyInput = TerminalKeyInput(frame: .zero)
    private var nativeTextView: TerminalTextView!
    
    // 核心引用
    private weak var rawTerminal: SwiftTerm.Terminal?
    private var refreshTimer: Timer?
    
    private var lastTextContent: String = ""
    private var state = TerminalState()
    private var hudState = HUDViewState()
    private var hudView: UIHostingView<AnyView>!
    private var hasAppeared = false
    private var failureError: Error?
    private var isPickingFileForUpload = false

    // MARK: - Init
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        terminalController.delegate = self
        
        // 尝试获取底层 Terminal 对象
        findUnderlyingTerminal()

        do {
            try terminalController.startSubProcess()
        } catch {
            failureError = error
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // 【核心修复】多重查找逻辑
    private func findUnderlyingTerminal() {
        // 1. 直接查找 terminal 属性
        let mirror = Mirror(reflecting: terminalController)
        for child in mirror.children {
            if child.label == "terminal", let t = child.value as? SwiftTerm.Terminal {
                self.rawTerminal = t
                NSLog("NewTermLog: Found terminal via direct mirror")
                return
            }
        }
        
        // 2. 查找 terminalView.terminal 属性
        for child in mirror.children {
            if child.label == "terminalView" {
                let viewMirror = Mirror(reflecting: child.value)
                for vChild in viewMirror.children {
                    if vChild.label == "terminal", let t = vChild.value as? SwiftTerm.Terminal {
                        self.rawTerminal = t
                        NSLog("NewTermLog: Found terminal via terminalView mirror")
                        return
                    }
                }
            }
        }
        NSLog("NewTermLog: Warning - Failed to find underlying Terminal object")
    }

    // MARK: - View Lifecycle
    override func loadView() {
        super.loadView()
        title = .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")

        // 1. Setup TextView
        nativeTextView = TerminalTextView()
        nativeTextView.isEditable = false
        nativeTextView.isSelectable = true
        nativeTextView.isScrollEnabled = true
        nativeTextView.showsVerticalScrollIndicator = true
        
        nativeTextView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        nativeTextView.textColor = UIColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0)
        nativeTextView.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nativeTextView.textContainerInset = UIEdgeInsets(top: 8, left: 5, bottom: 40, right: 5)
        
        nativeTextView.onPaste = { [weak self] text in
            self?.terminalController.write(text.utf8Array)
        }
        
        nativeTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nativeTextView)
        
        NSLayoutConstraint.activate([
            nativeTextView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            nativeTextView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            nativeTextView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            nativeTextView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // 2. Setup Keyboard Input
        keyInput.frame = view.bounds
        keyInput.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        keyInput.textView = nativeTextView
        keyInput.terminalInputDelegate = terminalController
        
        keyInput.keyboardToolbarHeightChanged = { [weak self] height in
            guard let self = self else { return }
            self.keyboardToolbarHeightChanged?(height)
            var insets = self.nativeTextView.contentInset
            insets.bottom = height
            self.nativeTextView.contentInset = insets
            self.nativeTextView.verticalScrollIndicatorInsets.bottom = height
        }
        view.addSubview(keyInput)
        
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        nativeTextView.addGestureRecognizer(tap)
        
        preferencesUpdated()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        startRefreshTimer()

        hudView = UIHostingView(rootView: AnyView(HUDView().environmentObject(self.hudState)))
        hudView.translatesAutoresizingMaskIntoConstraints = false
        hudView.shouldResizeToFitContent = true
        hudView.backgroundColor = .clear
        view.addSubview(hudView)

        NSLayoutConstraint.activate([
            hudView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hudView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])

        addKeyCommand(UIKeyCommand(title: .localize("CLEAR_TERMINAL", comment: ""), image: UIImage(systemName: "text.badge.xmark"), action: #selector(clearTerminal), input: "k", modifierFlags: .command))
        
        #if !targetEnvironment(macCatalyst)
        addKeyCommand(UIKeyCommand(title: .localize("PASSWORD_MANAGER", comment: ""), image: UIImage(systemName: "key.fill"), action: #selector(activatePasswordManager), input: "f", modifierFlags: [ .command ]))
        #endif

        if UIApplication.shared.supportsMultipleScenes {
            NotificationCenter.default.addObserver(self, selector: #selector(sceneDidEnterBackground), name: UIWindowScene.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(sceneWillEnterForeground), name: UIWindowScene.willEnterForegroundNotification, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
    }

    // MARK: - Logic
    func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.syncTerminalContent()
        }
    }
    
    func syncTerminalContent() {
        if rawTerminal == nil {
            findUnderlyingTerminal()
        }
        
        guard let terminal = self.rawTerminal else { return }
        
        let bufferLines = terminal.buffer.lines
        var fullText = ""
        
        // 简单的文本提取
        for i in 0..<bufferLines.count {
            let line = bufferLines[i]
            var lineStr = ""
            for j in 0..<line.count {
                let char = line[j].getCharacter()
                // 仅替换空字符，保留空格以便排版
                if char == Character(UnicodeScalar(0)) {
                    lineStr.append(" ")
                } else {
                    lineStr.append(char)
                }
            }
            // 简单的 rtrim，清理行尾多余空格
            while lineStr.last == " " {
                lineStr.removeLast()
            }
            fullText += lineStr + "\n"
        }
        
        if fullText != lastTextContent {
            lastTextContent = fullText
            DispatchQueue.main.async {
                let isAtBottom = self.nativeTextView.contentOffset.y >= (self.nativeTextView.contentSize.height - self.nativeTextView.bounds.height - 50)
                self.nativeTextView.text = fullText
                if isAtBottom {
                    let range = NSRange(location: self.nativeTextView.text.count - 1, length: 1)
                    self.nativeTextView.scrollRangeToVisible(range)
                }
            }
        }
    }

    @objc func handleTap() {
        if !keyInput.isFirstResponder {
            keyInput.becomeFirstResponder()
        }
    }
    
    @objc func activatePasswordManager() {
        keyInput.activatePasswordManager()
    }
    
    @objc func clearTerminal() {
        terminalController.clearTerminal()
        nativeTextView.text = ""
        lastTextContent = ""
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyInput.becomeFirstResponder()
        terminalController.terminalWillAppear()
        startRefreshTimer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        if let initialCommand = initialCommand?.data(using: .utf8) {
            terminalController.write(initialCommand + EscapeSequences.return)
            self.initialCommand = nil
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        keyInput.resignFirstResponder()
        terminalController.terminalWillDisappear()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        hasAppeared = false
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateScreenSize()
    }

    func updateScreenSize() {
        if isSplitViewResizing { return }
        
        var layoutSize = nativeTextView.bounds.size
        layoutSize.width -= (nativeTextView.textContainerInset.left + nativeTextView.textContainerInset.right)
        layoutSize.height -= (nativeTextView.textContainerInset.top + nativeTextView.textContainerInset.bottom)
        
        if layoutSize.width <= 0 || layoutSize.height <= 0 { return }
        
        let glyphSize = terminalController.fontMetrics.boundingBox
        if glyphSize.width == 0 || glyphSize.height == 0 { return }
        
        let newSize = ScreenSize(cols: UInt16(layoutSize.width / glyphSize.width),
                                 rows: UInt16(layoutSize.height / glyphSize.height.rounded(.up)),
                                 cellSize: glyphSize)
        
        if screenSize != newSize {
            screenSize = newSize
            // 修复：使用 sessionDelegate
            sessionDelegate?.terminal(viewController: self, screenSizeDidChange: newSize)
        }
    }

    private func updateIsSplitViewResizing() {
        state.isSplitViewResizing = isSplitViewResizing
        if !isSplitViewResizing { updateScreenSize() }
    }

    private func updateShowsTitleView() {
        updateScreenSize()
    }

    @objc private func sceneDidEnterBackground(_ notification: Notification) {
        if notification.object as? UIWindowScene == view.window?.windowScene {
            terminalController.windowDidEnterBackground()
        }
    }

    @objc private func sceneWillEnterForeground(_ notification: Notification) {
        if notification.object as? UIWindowScene == view.window?.windowScene {
            terminalController.windowWillEnterForeground()
        }
    }

    @objc private func preferencesUpdated() {
        let fontSize = CGFloat(Preferences.shared.fontSize)
        if let font = UIFont(name: Preferences.shared.fontName, size: fontSize) {
            nativeTextView.font = font
        } else {
            nativeTextView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        state.fontMetrics = terminalController.fontMetrics
        updateScreenSize()
    }
}

// MARK: - Delegate Conformance (修复协议不符)
extension TerminalSessionViewController: TerminalControllerDelegate {
    
    func refresh(lines: inout [AnyView]) {}
    func refresh(lines: inout [BufferLine], cursor: (Int,Int)) {}
    func scroll(animated: Bool = false) {}

    func activateBell() {
        if Preferences.shared.bellHUD {
            hudState.isVisible = true
        }
        HapticController.playBell()
    }

    func titleDidChange(_ title: String?, isDirty: Bool, hasBell: Bool) {
        let newTitle = title ?? .localize("TERMINAL", comment: "")
        // 修复：使用 sessionDelegate
        sessionDelegate?.terminal(viewController: self, titleDidChange: newTitle, isDirty: isDirty, hasBell: hasBell)
    }

    func currentFileDidChange(_ url: URL?, inWorkingDirectory workingDirectoryURL: URL?) {
        #if targetEnvironment(macCatalyst)
        if let windowScene = view.window?.windowScene { windowScene.titlebar?.representedURL = url }
        #endif
    }
    
    // 【关键修复】实现缺失的方法
    func processDidExit(exitCode: Int32) {
        if let splitViewController = parent as? TerminalSplitViewController {
            splitViewController.remove(viewController: self)
        }
    }

    func saveFile(url: URL) {
        let vc = UIDocumentPickerViewController(forExporting: [url], asCopy: false)
        vc.delegate = self
        present(vc, animated: true)
    }

    func fileUploadRequested() {
        isPickingFileForUpload = true
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .directory])
        vc.delegate = self
        present(vc, animated: true)
    }
    
    func didReceiveError(error: Error) {
        let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }
}

extension TerminalSessionViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { terminalController.uploadFile(url: url) }
        isPickingFileForUpload = false
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        isPickingFileForUpload = false
        terminalController.cancelUploadRequest()
    }
}
