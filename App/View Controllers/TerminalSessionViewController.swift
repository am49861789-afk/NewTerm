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

// 自定义 TextView 以支持只读模式下的粘贴功能
class TerminalTextView: UITextView {
    // 粘贴回调
    var onPaste: ((String) -> Void)?
    
    // 允许粘贴，即使是不可编辑状态
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }
    
    // 拦截粘贴操作
    override func paste(_ sender: Any?) {
        if let string = UIPasteboard.general.string {
            onPaste?(string)
        }
    }
    
    // 禁用放大镜等不需要的交互（可选）
    // override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    //    return super.gestureRecognizerShouldBegin(gestureRecognizer)
    // }
}

class TerminalSessionViewController: BaseTerminalSplitViewControllerChild {

    var keyboardToolbarHeightChanged: ((Double) -> Void)?
    var initialCommand: String?

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

    private var terminalController = TerminalController()
    private var keyInput = TerminalKeyInput(frame: .zero)
    
    // 使用自定义的 TextView
    private var nativeTextView: TerminalTextView!
    
    // 关键：通过反射持有的 Terminal 对象引用
    private weak var rawTerminal: SwiftTerm.Terminal?
    
    private var state = TerminalState()
    private var lines = [BufferLine]()
    private var cursor = (x: Int(-1), y: Int(-1))

    private var hudState = HUDViewState()
    private var hudView: UIHostingView<AnyView>!

    private var hasAppeared = false
    private var hasStarted = false
    private var failureError: Error?
    private var isPickingFileForUpload = false

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)

        terminalController.delegate = self
        
        // MARK: - 核心黑科技：使用 Mirror 获取 internal 的 terminal 对象
        // 这样我们就能直接访问数据，解决报错和白屏问题
        let mirror = Mirror(reflecting: terminalController)
        for child in mirror.children {
            if child.label == "terminal" {
                self.rawTerminal = child.value as? SwiftTerm.Terminal
                break
            }
        }

        do {
            try terminalController.startSubProcess()
            hasStarted = true
        } catch {
            failureError = error
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        super.loadView()

        title = .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")

        // 1. 初始化 Native TextView
        nativeTextView = TerminalTextView()
        nativeTextView.isEditable = false       // 只读
        nativeTextView.isSelectable = true      // 允许选中
        nativeTextView.isScrollEnabled = true
        nativeTextView.showsVerticalScrollIndicator = true
        nativeTextView.textContainerInset = UIEdgeInsets(top: 8, left: 5, bottom: 20, right: 5)
        
        // 设置回调：当用户点击菜单中的“粘贴”时，发送到终端
        nativeTextView.onPaste = { [weak self] text in
            self?.terminalController.write(text.utf8Array)
        }
        
        // 外观设置：深色背景，浅色文字
        nativeTextView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        nativeTextView.textColor = .lightGray
        // 初始字体
        nativeTextView.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        
        nativeTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nativeTextView)
        
        // 布局
        NSLayoutConstraint.activate([
            nativeTextView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            nativeTextView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            nativeTextView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            nativeTextView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // 2. 键盘输入绑定
        keyInput.frame = view.bounds
        keyInput.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        keyInput.textView = nativeTextView 
        
        keyInput.keyboardToolbarHeightChanged = { [weak self] height in
            guard let self = self else { return }
            self.keyboardToolbarHeightChanged?(height)
            var insets = self.nativeTextView.contentInset
            insets.bottom = height
            self.nativeTextView.contentInset = insets
            self.nativeTextView.verticalScrollIndicatorInsets.bottom = height
        }
        
        keyInput.terminalInputDelegate = terminalController
        view.addSubview(keyInput)
        
        // 确保点击能唤起键盘
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        nativeTextView.addGestureRecognizer(tap)
        
        preferencesUpdated()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hudView = UIHostingView(rootView: AnyView(
            HUDView()
                .environmentObject(self.hudState)
        ))
        hudView.translatesAutoresizingMaskIntoConstraints = false
        hudView.shouldResizeToFitContent = true
        hudView.backgroundColor = .clear
        view.addSubview(hudView)

        NSLayoutConstraint.activate([
            hudView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hudView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])

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
    
    @objc func handleTap() {
        if !keyInput.isFirstResponder {
            keyInput.becomeFirstResponder()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyInput.becomeFirstResponder()
        terminalController.terminalWillAppear()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        if let error = failureError {
            didReceiveError(error: error)
        } else {
            if let initialCommand = initialCommand?.data(using: .utf8) {
                terminalController.write(initialCommand + EscapeSequences.return)
            }
        }
        initialCommand = nil
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
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

    // MARK: - Screen Update
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
        let fontName = Preferences.shared.fontName
        
        // 安全获取字体
        if let customFont = UIFont(name: fontName, size: fontSize) {
            nativeTextView.font = customFont
        } else {
            nativeTextView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        
        // 重新计算屏幕大小
        state.fontMetrics = terminalController.fontMetrics
        updateScreenSize()
    }
}

// MARK: - 核心渲染逻辑 (从 rawTerminal 读取)
extension TerminalSessionViewController: TerminalControllerDelegate {

    // 这个方法会被调用，我们忽略它的 AnyView 参数，改用我们自己的数据源
    func refresh(lines: inout [AnyView]) {
        // 使用 Mirror 捕获的 rawTerminal
        guard let terminal = self.rawTerminal else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 简单的文本构建：直接拼接所有行
            // 性能优化：在生产环境中可以只更新差异，但对于终端来说，全量更新通常是可接受的
            // 除非缓冲区非常大
            var fullText = ""
            let bufferLines = terminal.buffer.lines
            
            for i in 0..<bufferLines.count {
                let line = bufferLines[i]
                var lineStr = ""
                for j in 0..<line.count {
                    let charData = line[j]
                    let char = charData.getCharacter()
                    if char == Character(UnicodeScalar(0)) {
                        lineStr.append(" ")
                    } else {
                        lineStr.append(char)
                    }
                }
                // 去除右侧空格可以避免 TextWrapper 导致的奇怪换行，但可能影响 ASCII art
                 lineStr = lineStr.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                fullText += lineStr + "\n"
            }
            
            // 只有变化时才赋值，防止光标跳动太厉害
            if self.nativeTextView.text != fullText {
                let isAtBottom = self.nativeTextView.contentOffset.y >= (self.nativeTextView.contentSize.height - self.nativeTextView.bounds.height - 30)
                
                self.nativeTextView.text = fullText
                
                if isAtBottom {
                    let bottomRange = NSRange(location: self.nativeTextView.text.count - 1, length: 1)
                    self.nativeTextView.scrollRangeToVisible(bottomRange)
                }
            }
        }
    }
    
    func refresh(lines: inout [BufferLine], cursor: (Int,Int)) {
        // 忽略
    }
    
    func scroll(animated: Bool = false) {
        // UITextView 自动处理
    }

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

    @objc func activatePasswordManager() {
        keyInput.activatePasswordManager()
    }

    @objc func close() {
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
