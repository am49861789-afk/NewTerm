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

// MARK: - 协议定义 (修复编译错误)
protocol TerminalSessionViewControllerDelegate: AnyObject {
    func terminal(viewController: TerminalSessionViewController, titleDidChange title: String, isDirty: Bool, hasBell: Bool)
    func terminal(viewController: TerminalSessionViewController, screenSizeDidChange screenSize: ScreenSize)
    func terminalDidBecomeActive(viewController: TerminalSessionViewController)
}

// MARK: - 自定义 TextView (支持只读模式下的粘贴)
class TerminalTextView: UITextView {
    var onPaste: ((String) -> Void)?
    
    // 允许在只读模式下显示“粘贴”菜单
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return true }
        return super.canPerformAction(action, withSender: sender)
    }
    
    // 拦截粘贴操作，将文本发送给终端
    override func paste(_ sender: Any?) {
        if let string = UIPasteboard.general.string {
            onPaste?(string)
        }
    }
    
    // 禁用放大镜等干扰手势 (可选)
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
    
    // 修复：移除 private，允许外部访问
    var initialCommand: String?
    
    // 修复：添加 delegate 定义
    weak var delegate: TerminalSessionViewControllerDelegate?

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
    
    // 核心组件：原生文本视图
    private var nativeTextView: TerminalTextView!
    
    // 核心技术：通过反射获取底层的 SwiftTerm 实例
    private weak var rawTerminal: SwiftTerm.Terminal?
    
    // 核心技术：定时刷新器
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

        // 使用 Mirror 反射获取 internal 属性 'terminal'
        // 这是解决白屏问题的关键，我们需要直接访问数据源
        let mirror = Mirror(reflecting: terminalController)
        for child in mirror.children {
            if child.label == "terminal" {
                self.rawTerminal = child.value as? SwiftTerm.Terminal
                break
            }
        }

        do {
            try terminalController.startSubProcess()
        } catch {
            failureError = error
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle
    override func loadView() {
        super.loadView()

        title = .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")

        // 1. 配置原生 TextView
        nativeTextView = TerminalTextView()
        nativeTextView.isEditable = false       // 只读
        nativeTextView.isSelectable = true      // 允许选中
        nativeTextView.isScrollEnabled = true
        nativeTextView.showsVerticalScrollIndicator = true
        
        // 外观设置 (深色模式)
        nativeTextView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        nativeTextView.textColor = UIColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0)
        nativeTextView.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nativeTextView.textContainerInset = UIEdgeInsets(top: 8, left: 5, bottom: 40, right: 5)
        
        // 粘贴回调
        nativeTextView.onPaste = { [weak self] text in
            self?.terminalController.write(text.utf8Array)
        }
        
        nativeTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nativeTextView)
        
        // 布局
        NSLayoutConstraint.activate([
            nativeTextView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            nativeTextView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            nativeTextView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            nativeTextView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // 2. 配置键盘输入
        keyInput.frame = view.bounds
        keyInput.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        keyInput.textView = nativeTextView // 绑定到 TextView，确保键盘交互正常
        keyInput.terminalInputDelegate = terminalController
        
        keyInput.keyboardToolbarHeightChanged = { [weak self] height in
            guard let self = self else { return }
            self.keyboardToolbarHeightChanged?(height)
            // 调整底部边距，避免键盘遮挡内容
            var insets = self.nativeTextView.contentInset
            insets.bottom = height
            self.nativeTextView.contentInset = insets
            self.nativeTextView.verticalScrollIndicatorInsets.bottom = height
        }
        view.addSubview(keyInput)
        
        // 点击手势：确保点击空白处也能唤起键盘
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        nativeTextView.addGestureRecognizer(tap)
        
        preferencesUpdated()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 启动定时器，强制刷新内容
        startRefreshTimer()

        // 配置 HUD
        hudView = UIHostingView(rootView: AnyView(
            HUDView().environmentObject(self.hudState)
        ))
        hudView.translatesAutoresizingMaskIntoConstraints = false
        hudView.shouldResizeToFitContent = true
        hudView.backgroundColor = .clear
        view.addSubview(hudView)

        NSLayoutConstraint.activate([
            hudView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hudView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])

        // 注册快捷键
        addKeyCommand(UIKeyCommand(title: .localize("CLEAR_TERMINAL", comment: "VoiceOver label for a button that clears the terminal."),
                                   image: UIImage(systemName: "text.badge.xmark"),
                                   action: #selector(self.clearTerminal),
                                   input: "k",
                                   modifierFlags: .command))

        #if !targetEnvironment(macCatalyst)
        addKeyCommand(UIKeyCommand(title: .localize("PASSWORD_MANAGER", comment: "VoiceOver label for the password manager button."),
                                   image: UIImage(systemName: "key.fill"),
                                   action: #selector(self.activatePasswordManager),
                                   input: "f",
                                   modifierFlags: [ .command ]))
        #endif

        if UIApplication.shared.supportsMultipleScenes {
            NotificationCenter.default.addObserver(self, selector: #selector(self.sceneDidEnterBackground), name: UIWindowScene.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(self.sceneWillEnterForeground), name: UIWindowScene.willEnterForegroundNotification, object: nil)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(self.preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
    }

    // MARK: - 核心逻辑：定时同步屏幕内容
    
    func startRefreshTimer() {
        refreshTimer?.invalidate()
        // 每 0.1 秒检查一次终端内容并更新到 TextView
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.syncTerminalContent()
        }
    }
    
    func syncTerminalContent() {
        // 二次尝试获取 rawTerminal (防止初始化时尚未准备好)
        if rawTerminal == nil {
            let mirror = Mirror(reflecting: terminalController)
            for child in mirror.children {
                if child.label == "terminal" {
                    self.rawTerminal = child.value as? SwiftTerm.Terminal
                    break
                }
            }
        }
        
        guard let terminal = self.rawTerminal else { return }
        
        // 直接从 buffer 读取每一行文字
        let bufferLines = terminal.buffer.lines
        var fullText = ""
        
        for i in 0..<bufferLines.count {
            let line = bufferLines[i]
            var lineStr = ""
            for j in 0..<line.count {
                let char = line[j].getCharacter()
                if char == Character(UnicodeScalar(0)) {
                    lineStr.append(" ") // 保持排版对齐
                } else {
                    lineStr.append(char)
                }
            }
            // 去除行尾多余空格
            while lineStr.last == " " {
                lineStr.removeLast()
            }
            fullText += lineStr + "\n"
        }
        
        // 如果内容有变化，则更新 UI
        if fullText != lastTextContent {
            lastTextContent = fullText
            
            DispatchQueue.main.async {
                // 判断是否需要自动滚动到底部
                let isAtBottom = self.nativeTextView.contentOffset.y >= (self.nativeTextView.contentSize.height - self.nativeTextView.bounds.height - 50)
                
                self.nativeTextView.text = fullText
                
                if isAtBottom {
                    let range = NSRange(location: self.nativeTextView.text.count - 1, length: 1)
                    self.nativeTextView.scrollRangeToVisible(range)
                }
            }
        }
    }

    // MARK: - Actions & Helpers
    
    @objc func handleTap() {
        if !keyInput.isFirstResponder {
            keyInput.becomeFirstResponder()
        }
    }
    
    @objc func activatePasswordManager() {
        keyInput.activatePasswordManager()
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
        
        if let error = failureError {
            didReceiveError(error: error)
        } else {
            if let initialCommand = initialCommand?.data(using: .utf8) {
                terminalController.write(initialCommand + EscapeSequences.return)
                self.initialCommand = nil
            }
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
            delegate?.terminal(viewController: self, screenSizeDidChange: newSize)
        }
    }

    @objc func clearTerminal() {
        terminalController.clearTerminal()
        nativeTextView.text = ""
        lastTextContent = ""
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
        // 更新字体
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

// MARK: - Delegate Conformance
extension TerminalSessionViewController: TerminalControllerDelegate {

    // 占位实现
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
        let newTitle = title ?? .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")
        delegate?.terminal(viewController: self,
                           titleDidChange: newTitle,
                           isDirty: isDirty,
                           hasBell: hasBell)
    }

    func currentFileDidChange(_ url: URL?, inWorkingDirectory workingDirectoryURL: URL?) {
        #if targetEnvironment(macCatalyst)
        if let windowScene = view.window?.windowScene {
            windowScene.titlebar?.representedURL = url
        }
        #endif
    }

    func saveFile(url: URL) {
        let viewController = UIDocumentPickerViewController(forExporting: [url], asCopy: false)
        viewController.delegate = self
        present(viewController, animated: true, completion: nil)
    }

    func fileUploadRequested() {
        isPickingFileForUpload = true
        let viewController = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .directory])
        viewController.delegate = self
        present(viewController, animated: true, completion: nil)
    }
    
    // 修复：实现缺失的 delegate 方法
    func processDidExit(exitCode: Int32) {
        // 进程退出时的处理，例如关闭当前 Tab
        if let splitViewController = parent as? TerminalSplitViewController {
            splitViewController.remove(viewController: self)
        }
    }

    func didReceiveError(error: Error) {
        if !hasAppeared {
            failureError = error
            return
        }
        failureError = nil

        let alertController = UIAlertController(title: .localize("TERMINAL_LAUNCH_FAILED_TITLE", comment: "Alert title displayed when a terminal could not be launched."),
                                                message: .localize("TERMINAL_LAUNCH_FAILED_BODY", comment: "Alert body displayed when a terminal could not be launched."),
                                                preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: .ok, style: .cancel, handler: nil))
        present(alertController, animated: true, completion: nil)
    }
}

extension TerminalSessionViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard isPickingFileForUpload, let url = urls.first else { return }
        terminalController.uploadFile(url: url)
        isPickingFileForUpload = false
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if isPickingFileForUpload {
            isPickingFileForUpload = false
            terminalController.cancelUploadRequest()
        } else {
            terminalController.deleteDownloadCache()
        }
    }
}
