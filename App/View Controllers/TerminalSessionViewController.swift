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

// 👇 新增一个自定义的 UITextView 子类，专门用来破解 iOS 的菜单限制
class TerminalTextView: UITextView {
    
    // 弱引用 controller，用来把粘贴的文字发送给终端进程
    weak var terminalController: TerminalController?

    // 重写这个方法：强制控制菜单显示什么选项
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // 1. 强制显示“粘贴” (只要剪贴板里有文字)
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings
        }
        // 2. 强制显示“全选” (只要屏幕上有文字)
        if action == #selector(selectAll(_:)) {
            return self.text.count > 0
        }
        // 3. 其他默认操作 (比如“复制”) 交给系统原本的逻辑
        return super.canPerformAction(action, withSender: sender)
    }

    // 重写粘贴行为：不往文本框里塞，而是把文字发给终端
    override func paste(_ sender: Any?) {
        if let pasteString = UIPasteboard.general.string {
            // 把剪贴板的文字转成字节数组，发给底层终端
            terminalController?.write(pasteString.utf8Array)
        }
    }
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

    // 👇 把原本的 UITextView 换成我们的自定义类
    private var textView: TerminalTextView!
    private var textViewTapGestureRecognizer: UITapGestureRecognizer!

    private var state = TerminalState()
    private var lines = [BufferLine]()
    private var cursor = (x: Int(-1), y: Int(-1))

    private var hudState = HUDViewState()
    private var hudView: UIHostingView<AnyView>!

    private var hasAppeared = false
    private var hasStarted = false
    private var failureError: Error?

    private var lastAutomaticScrollOffset = CGPoint.zero
    private var invertScrollToTop = false

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

        preferencesUpdated()

        // 👇 核心修改：使用升级版的 TerminalTextView
        textView = TerminalTextView()
        // 将 terminalController 传给文本框，以便它能执行粘贴操作
        textView.terminalController = self.terminalController

        // 🌟 让 textView 铺满整个屏幕
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.showsVerticalScrollIndicator = true

        // 👇 新增两行：消除内部留白，强制同步排版计算，防止异步引发的跳动
        textView.textContainer.lineFragmentPadding = 0
        textView.layoutManager.allowsNonContiguousLayout = false

        // 🌟 把 textView 真正贴到屏幕上
        view.addSubview(textView)

        // 配置原有的点击手势，确保唤起软键盘
        textViewTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleTextViewTap(_:)))
        textViewTapGestureRecognizer.delegate = self
        textView.addGestureRecognizer(textViewTapGestureRecognizer)

        keyInput.frame = view.bounds
        keyInput.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        keyInput.textView = textView
        keyInput.keyboardToolbarHeightChanged = { height in
            self.keyboardToolbarHeightChanged?(height)
        }
        keyInput.terminalInputDelegate = terminalController

        // 保持 keyInput 在最上层拦截输入事件
        view.addSubview(keyInput)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hudView = UIHostingView(rootView: AnyView(
            HUDView()
                .environmentObject(self.hudState)
        ))
        hudView.translatesAutoresizingMaskIntoConstraints = false
        hudView.shouldResizeToFitContent = true
        hudView.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        hudView.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
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
                                   modifierFlags: [.command]))
        #endif

        if UIApplication.shared.supportsMultipleScenes {
            NotificationCenter.default.addObserver(self, selector: #selector(self.sceneDidEnterBackground), name: UIWindowScene.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(self.sceneWillEnterForeground), name: UIWindowScene.willEnterForegroundNotification, object: nil)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(self.preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
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

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        NSLog("NewTermLog: viewWillTransition to \(size)")
        super.viewWillTransition(to: size, with: coordinator)
        if UIDevice.current.userInterfaceIdiom == .pad {
            if keyInput.isFirstResponder {
                keyInput.resignFirstResponder()
            }
        }
    }

    override func viewWillLayoutSubviews() {
        NSLog("NewTermLog: TerminalSessionViewController.viewWillLayoutSubviews \(self.view.frame) \(self.view.safeAreaInsets)")
        super.viewWillLayoutSubviews()
        updateScreenSize()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        NSLog("NewTermLog: TerminalSessionViewController.viewDidLayoutSubviews \(self.view.frame) \(self.view.safeAreaInsets)")
        NSLog("NewTermLog: textView frame=\(self.textView.frame) safeArea=\(self.textView.safeAreaInsets)")
    }

    override func viewSafeAreaInsetsDidChange() {
        NSLog("NewTermLog: TerminalSessionViewController.viewSafeAreaInsetsDidChange \(self.view.frame) \(view.safeAreaInsets)")
        super.viewSafeAreaInsetsDidChange()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        NSLog("NewTermLog: TerminalSessionViewController.traitCollectionDidChange \(self.view.frame) \(view.safeAreaInsets)")
        super.traitCollectionDidChange(previousTraitCollection)
    }

    override func removeFromParent() {
        if hasStarted {
            do {
                try terminalController.stopSubProcess()
            } catch {
                Logger().error("Failed to stop subprocess: \(String(describing: error))")
            }
        }

        super.removeFromParent()
    }

    // MARK: - Screen

    func updateScreenSize() {
        if isSplitViewResizing {
            return
        }

        var layoutSize = self.view.safeAreaLayoutGuide.layoutFrame.size
        layoutSize.width -= TerminalView.horizontalSpacing * 2
        layoutSize.height -= TerminalView.verticalSpacing * 2

        if layoutSize.width <= 0 || layoutSize.height <= 0 {
            return
        }

        let layoutFrame1 = self.view.safeAreaLayoutGuide.layoutFrame
        if layoutFrame1.origin.x < 0 || layoutFrame1.origin.y < 0 {
            return
        }
        let layoutFrame2 = self.textView.safeAreaLayoutGuide.layoutFrame
        if layoutFrame2.origin.x < 0 || layoutFrame2.origin.y < 0 {
            return
        }

        let glyphSize = terminalController.fontMetrics.boundingBox
        if glyphSize.width == 0 || glyphSize.height == 0 {
            fatalError("Failed to get glyph size")
        }

        NSLog("NewTermLog: TerminalSessionViewController.updateScreenSize self=\(self.view.safeAreaLayoutGuide.layoutFrame) textView=\(textView.safeAreaLayoutGuide.layoutFrame)")
        let newSize = ScreenSize(cols: UInt16(layoutSize.width / glyphSize.width),
                                 rows: UInt16(layoutSize.height / glyphSize.height.rounded(.up)),
                                 cellSize: glyphSize)
        if screenSize != newSize {
            screenSize = newSize
            delegate?.terminal(viewController: self, screenSizeDidChange: newSize)
        } else {
            // 👇 核心修复 1：注释掉或者删除这里的滚动代码！
            // 防止长按弹出菜单引起布局微调时，屏幕瞬间跳回最底部
            // self.scroll(animated: true)
        }
    }

    @objc func clearTerminal() {
        terminalController.clearTerminal()
    }

    private func updateIsSplitViewResizing() {
        NSLog("NewTermLog: TerminalSessionViewController.updateIsSplitViewResizing")
        state.isSplitViewResizing = isSplitViewResizing

        if !isSplitViewResizing {
            updateScreenSize()
        }
    }

    private func updateShowsTitleView() {
        NSLog("NewTermLog: TerminalSessionViewController.updateShowsTitleView")
        updateScreenSize()
    }

    // MARK: - Gestures

    @objc private func handleTextViewTap(_ gestureRecognizer: UITapGestureRecognizer) {
        if gestureRecognizer.state == .ended {
            
            // 👇 修复：如果检测到当前有选中的文本，强制将选中范围清零
            if textView.selectedRange.length > 0 {
                textView.selectedRange = NSRange(location: 0, length: 0)
            }
            
            // 正常唤起软键盘
            if !keyInput.isFirstResponder {
                keyInput.becomeFirstResponder()
                delegate?.terminalDidBecomeActive(viewController: self)
            }
        }
    }


    // MARK: - Lifecycle

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
        state.fontMetrics = terminalController.fontMetrics
        state.colorMap = terminalController.colorMap
    }
}

extension TerminalSessionViewController: TerminalControllerDelegate {

    // 👇 补回这个方法来满足 Protocol 协议的强制要求（哪怕我们里面什么都不干）
    func refresh(lines: inout [AnyView]) {
        state.lines = lines
    }

    func refresh(lines: inout [BufferLine], cursor: (Int, Int)) {
        NSLog("NewTermLog: refresh lines=\(lines.count)")
        self.lines = lines
        self.cursor = (x: cursor.0, y: cursor.1)

        let fullAttributedString = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let cursorX = (index == cursor.1) ? cursor.0 : -1
            let lineAttrStr = terminalController.stringSupplier.buildNSAttributedString(line: line, cursorX: cursorX)
            fullAttributedString.append(lineAttrStr)
            fullAttributedString.append(NSAttributedString(string: "\n"))
        }

        // 👇 修复跳动核心：在塞入几万字之前，临时关闭滚动，塞完再开，能完美消除高度重置产生的跳跃
        let wasScrollEnabled = self.textView.isScrollEnabled
        self.textView.isScrollEnabled = false
        
        self.textView.attributedText = fullAttributedString
        
        self.textView.isScrollEnabled = wasScrollEnabled
        self.scroll()
    }

    func scroll(animated: Bool = false) {
        state.scroll += 1

        guard self.textView.text.count > 0 else { return }
        
        // 👇 核心修复 2：加入“防打扰”拦截逻辑
        // 如果当前有选中的文字，或者用户正在触摸/滑动屏幕，绝对禁止代码自动滚到底部！
        if self.textView.selectedRange.length > 0 || self.textView.isTracking || self.textView.isDragging {
            return
        }
        
        let bottom = NSMakeRange(self.textView.text.count - 1, 1)
        
        // 强制关闭自动滚动的动画过程，让文字瞬间触底
        UIView.performWithoutAnimation {
            self.textView.scrollRangeToVisible(bottom)
        }
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

extension TerminalSessionViewController: UIGestureRecognizerDelegate {

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return gestureRecognizer == textViewTapGestureRecognizer
            && (!(otherGestureRecognizer is UITapGestureRecognizer) || keyInput.isFirstResponder)
    }
}

extension TerminalSessionViewController: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard isPickingFileForUpload,
              let url = urls.first else {
            return
        }
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
