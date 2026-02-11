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

// 自定义 TextView，只读但支持粘贴
class TerminalTextView: UITextView {
    var onPaste: ((String) -> Void)?
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return true }
        return super.canPerformAction(action, withSender: sender)
    }
    
    override func paste(_ sender: Any?) {
        if let string = UIPasteboard.general.string {
            onPaste?(string)
        }
    }
}

class TerminalSessionViewController: BaseTerminalSplitViewControllerChild {

    var keyboardToolbarHeightChanged: ((Double) -> Void)?
    
    // 界面组件
    private var nativeTextView: TerminalTextView!
    private var terminalController = TerminalController()
    private var keyInput = TerminalKeyInput(frame: .zero)
    
    // 核心：直接引用底层的 SwiftTerm 终端对象
    private weak var rawTerminal: SwiftTerm.Terminal?
    
    // 核心：定时器，用于强制刷新屏幕
    private var refreshTimer: Timer?
    
    // 状态缓存
    private var lastTextContent: String = ""
    private var state = TerminalState()
    private var hudState = HUDViewState()
    private var hudView: UIHostingView<AnyView>!
    private var hasAppeared = false
    private var failureError: Error?
    private var initialCommand: String?
    private var isPickingFileForUpload = false
    
    // MARK: - Init & Load

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        terminalController.delegate = self
        
        // ---------------------------------------------------------
        // 黑科技：通过 Mirror 暴力获取 internal 属性 'terminal'
        // ---------------------------------------------------------
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

    override func loadView() {
        super.loadView()
        title = .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")

        // 1. 初始化原生的 UITextView
        nativeTextView = TerminalTextView()
        nativeTextView.isEditable = false
        nativeTextView.isSelectable = true
        nativeTextView.isScrollEnabled = true
        nativeTextView.showsVerticalScrollIndicator = true
        
        // 关键外观设置
        nativeTextView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0) // 深灰背景
        nativeTextView.textColor = UIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)     // 浅白文字
        nativeTextView.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nativeTextView.textContainerInset = UIEdgeInsets(top: 5, left: 5, bottom: 40, right: 5)
        
        // 粘贴回调
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
        
        // 2. 绑定键盘输入
        keyInput.frame = view.bounds
        keyInput.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        keyInput.textView = nativeTextView
        keyInput.terminalInputDelegate = terminalController
        
        keyInput.keyboardToolbarHeightChanged = { [weak self] height in
            guard let self = self else { return }
            self.keyboardToolbarHeightChanged?(height)
            // 调整边距防止键盘遮挡
            var insets = self.nativeTextView.contentInset
            insets.bottom = height
            self.nativeTextView.contentInset = insets
            self.nativeTextView.verticalScrollIndicatorInsets.bottom = height
        }
        view.addSubview(keyInput)
        
        // 点击手势
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        nativeTextView.addGestureRecognizer(tap)
        
        preferencesUpdated()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 启动定时刷新 (0.1秒一次)
        startRefreshTimer()

        // 设置 HUD
        hudView = UIHostingView(rootView: AnyView(HUDView().environmentObject(self.hudState)))
        hudView.translatesAutoresizingMaskIntoConstraints = false
        hudView.shouldResizeToFitContent = true
        hudView.backgroundColor = .clear
        view.addSubview(hudView)
        NSLayoutConstraint.activate([
            hudView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hudView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])

        // 注册通知
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
        
        // 注册快捷键
        addKeyCommand(UIKeyCommand(title: .localize("CLEAR_TERMINAL", comment: ""), image: UIImage(systemName: "text.badge.xmark"), action: #selector(clearTerminal), input: "k", modifierFlags: .command))
    }
    
    // MARK: - 核心逻辑：定时同步屏幕
    
    func startRefreshTimer() {
        refreshTimer?.invalidate()
        // 使用 Timer 轮询，保证即使 delegate 不回调，也能显示文字
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.syncTerminalContent()
        }
    }
    
    func syncTerminalContent() {
        guard let terminal = self.rawTerminal else { return }
        
        // 获取所有行的数据
        let bufferLines = terminal.buffer.lines
        var fullText = ""
        
        // 简单的文本拼接
        for i in 0..<bufferLines.count {
            let line = bufferLines[i]
            var lineStr = ""
            for j in 0..<line.count {
                let char = line[j].getCharacter()
                // 处理空字符，保持排版
                if char == Character(UnicodeScalar(0)) {
                    lineStr.append(" ")
                } else {
                    lineStr.append(char)
                }
            }
            // 去除行尾多余空格 (可选，看个人喜好)
            // lineStr = lineStr.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            fullText += lineStr + "\n"
        }
        
        // 只有内容变了才更新 UI
        if fullText != lastTextContent {
            lastTextContent = fullText
            
            DispatchQueue.main.async {
                // 检查是否在底部
                let isAtBottom = self.nativeTextView.contentOffset.y >= (self.nativeTextView.contentSize.height - self.nativeTextView.bounds.height - 50)
                
                // 更新文本 (保留选中状态很难，但为了显示内容这是必须的)
                // 如果用户正在选择文本，可以暂停更新，但这里为了简单先强制更新
                if !self.nativeTextView.isFirstResponder { // 简单的防抖：如果正在操作键盘可能就不更新? 不，还是得更新
                    self.nativeTextView.text = fullText
                } else {
                    // 尝试在更新时保留光标位置比较复杂，直接更新最稳妥
                    self.nativeTextView.text = fullText
                }
                
                // 自动滚动
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyInput.becomeFirstResponder()
        terminalController.terminalWillAppear()
        startRefreshTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        keyInput.resignFirstResponder()
        terminalController.terminalWillDisappear()
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

// MARK: - Delegate (保留空实现以满足协议)
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
        delegate?.terminal(viewController: self, titleDidChange: newTitle, isDirty: isDirty, hasBell: hasBell)
    }

    func currentFileDidChange(_ url: URL?, inWorkingDirectory workingDirectoryURL: URL?) {
        #if targetEnvironment(macCatalyst)
        if let windowScene = view.window?.windowScene { windowScene.titlebar?.representedURL = url }
        #endif
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
    
    func didReceiveError(error: Error) {}
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
