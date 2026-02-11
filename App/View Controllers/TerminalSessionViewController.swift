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
    
    // 使用原生的 UITextView，保证100%原生选中体验
    private var nativeTextView: UITextView!
    
    // 缓存一些状态
    private var state = TerminalState()
    private var lastContentHeight: CGFloat = 0

    private var hudState = HUDViewState()
    private var hudView: UIHostingView<AnyView>!

    private var hasAppeared = false
    private var hasStarted = false
    private var failureError: Error?
    private var isPickingFileForUpload = false

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)

        terminalController.delegate = self

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

        // 1. 初始化原生的 UITextView
        nativeTextView = UITextView()
        nativeTextView.isEditable = false       // 只读，但可选择
        nativeTextView.isSelectable = true      // 开启原生选中！
        nativeTextView.isScrollEnabled = true
        nativeTextView.showsVerticalScrollIndicator = true
        nativeTextView.textContainerInset = UIEdgeInsets(top: 8, left: 5, bottom: 20, right: 5)
        
        // 外观设置：深色背景，浅色文字
        nativeTextView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        nativeTextView.textColor = .lightGray
        nativeTextView.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        
        // 布局设置
        nativeTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nativeTextView)
        
        // 填满整个屏幕
        NSLayoutConstraint.activate([
            nativeTextView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            nativeTextView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            nativeTextView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            nativeTextView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // 2. 键盘输入处理
        keyInput.frame = view.bounds
        keyInput.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        // 绑定键盘
        keyInput.textView = nativeTextView 
        
        keyInput.keyboardToolbarHeightChanged = { [weak self] height in
            guard let self = self else { return }
            self.keyboardToolbarHeightChanged?(height)
            // 调整底部间距，防止键盘遮挡内容
            var insets = self.nativeTextView.contentInset
            insets.bottom = height
            self.nativeTextView.contentInset = insets
            self.nativeTextView.verticalScrollIndicatorInsets.bottom = height
        }
        
        keyInput.terminalInputDelegate = terminalController
        view.addSubview(keyInput)
        
        // 点击手势：点击唤起键盘
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        nativeTextView.addGestureRecognizer(tap)
        
        preferencesUpdated()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // HUD (响铃提示)
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

        // 快捷键
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

        // 计算可见区域大小
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
        // 更新字体 (修复了之前的编译错误)
        let fontSize = CGFloat(Preferences.shared.fontSize)
        // 尝试加载自定义字体，如果失败则使用系统等宽字体
        let fontName = Preferences.shared.fontName
        let font: UIFont
        if let customFont = UIFont(name: fontName, size: fontSize) {
            font = customFont
        } else {
            font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        nativeTextView.font = font
        
        // 重新计算屏幕大小
        state.fontMetrics = terminalController.fontMetrics
        updateScreenSize()
    }
    
    // MARK: - 粘贴功能
    override func paste(_ sender: Any?) {
        // 拦截系统的粘贴，将内容发送给终端
        if let string = UIPasteboard.general.string {
            terminalController.write(string.utf8Array)
        }
    }
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // 允许粘贴
        if action == #selector(paste(_:)) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

// MARK: - 核心渲染逻辑 (这里解决了白屏问题)
extension TerminalSessionViewController: TerminalControllerDelegate {

    // NewTerm 会调用这个方法来刷新 UI
    func refresh(lines: inout [AnyView]) {
        // 我们不使用传入的 [AnyView]，因为那是给 SwiftUI 用的。
        // 我们直接从 terminal 实例中拉取原始文本数据。
        
        guard let terminal = terminalController.terminal else { return }
        
        // 放在主线程更新 UI
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 构建全文本字符串
            var fullText = ""
            let bufferLines = terminal.buffer.lines
            
            // 遍历所有行
            for i in 0..<bufferLines.count {
                let line = bufferLines[i]
                var lineStr = ""
                // 遍历行内的字符
                for j in 0..<line.count {
                    let charData = line[j]
                    let char = charData.getCharacter()
                    // 替换空字符为空格，保持排版
                    if char == Character(UnicodeScalar(0)) {
                        lineStr.append(" ")
                    } else {
                        lineStr.append(char)
                    }
                }
                // 每行结束加换行符
                fullText += lineStr + "\n"
            }
            
            // 只有当内容发生变化时才更新，避免光标跳动
            if self.nativeTextView.text != fullText {
                // 检查是否需要自动滚动到底部
                let isAtBottom = self.nativeTextView.contentOffset.y >= (self.nativeTextView.contentSize.height - self.nativeTextView.bounds.height - 30)
                
                self.nativeTextView.text = fullText
                
                if isAtBottom {
                    let bottomRange = NSRange(location: self.nativeTextView.text.count - 1, length: 1)
                    self.nativeTextView.scrollRangeToVisible(bottomRange)
                }
            }
        }
    }
    
    // 这个方法是为了兼容性保留的，NewTerm 可能不会调用它
    func refresh(lines: inout [BufferLine], cursor: (Int,Int)) {
        // 留空
    }
    
    func scroll(animated: Bool = false) {
        // UITextView 自动处理滚动
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
