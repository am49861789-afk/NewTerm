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

// 定义一个最基础的 Cell，用来承载 SwiftUI 内容和我们的选中效果
class SwiftUITableViewCell: UITableViewCell {
    static let identifier = "SwiftUITableViewCell"
    
    var hostingView: UIHostingView<AnyView>?
    var selectionView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.tintColor.withAlphaComponent(0.3) // 选中时的淡蓝色
        v.isHidden = true
        return v
    }()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        self.selectionStyle = .none
        
        // 添加选中层
        contentView.addSubview(selectionView)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func configure(view: AnyView, charWidth: CGFloat, lineHeight: CGFloat, selectionRange: Range<Int>?) {
        // 1. 设置 SwiftUI 视图
        if hostingView == nil {
            let hv = UIHostingView(rootView: view)
            hv.backgroundColor = .clear
            hv.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(hv)
            hostingView = hv
            
            // 充满整个 Cell
            NSLayoutConstraint.activate([
                hv.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hv.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hv.topAnchor.constraint(equalTo: contentView.topAnchor),
                hv.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        } else {
            hostingView?.rootView = view
        }
        
        // 确保选中层在文字下方
        contentView.sendSubviewToBack(selectionView)
        
        // 2. 更新选中状态
        if let range = selectionRange {
            selectionView.isHidden = false
            let startX = TerminalView.horizontalSpacing + (CGFloat(range.lowerBound) * charWidth)
            let width = CGFloat(range.count) * charWidth
            // 这里的 frame 高度直接取行高，确保对齐
            selectionView.frame = CGRect(x: startX, y: 0, width: width, height: lineHeight)
        } else {
            selectionView.isHidden = true
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
    private var textView: UIView!
    private var tableView: UITableView!
    private var textViewTapGestureRecognizer: UITapGestureRecognizer!
    
    private var state = TerminalState()
    private var lines = [BufferLine]()
    private var cursor = (x: Int(-1), y: Int(-1))

    private var hudState = HUDViewState()
    private var hudView: UIHostingView<AnyView>!

    private var hasAppeared = false
    private var hasStarted = false
    private var failureError: Error?
    
    private var isPickingFileForUpload = false

    // MARK: - 选中功能变量
    private var selectionStart: (col: Int, row: Int)?
    private var selectionEnd: (col: Int, row: Int)?
    private var isSelecting = false
    private var longPressGesture: UILongPressGestureRecognizer!
    private var panGesture: UIPanGestureRecognizer!

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

        // 初始化 TableView
        tableView = UITableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.separatorInset = .zero
        tableView.backgroundColor = .clear // 保持透明，使用 App 原有背景
        tableView.allowsSelection = false  // 禁用原生点击
        
        // 注册 Cell
        tableView.register(SwiftUITableViewCell.self, forCellReuseIdentifier: SwiftUITableViewCell.identifier)
        
        textView = tableView

        // 点击空白处
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
        view.addSubview(keyInput)
        
        // 修复闪退：确保 View 初始化完毕后再更新配置
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
                                   modifierFlags: [ .command ]))
        #endif

        if UIApplication.shared.supportsMultipleScenes {
            NotificationCenter.default.addObserver(self, selector: #selector(self.sceneDidEnterBackground), name: UIWindowScene.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(self.sceneWillEnterForeground), name: UIWindowScene.willEnterForegroundNotification, object: nil)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(self.preferencesUpdated), name: Preferences.didChangeNotification, object: nil)

        // 添加手势
        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.5
        longPressGesture.delegate = self
        tableView.addGestureRecognizer(longPressGesture)

        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        tableView.addGestureRecognizer(panGesture)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if !isSelecting {
            keyInput.becomeFirstResponder()
        }
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

    // MARK: - 屏幕更新逻辑
    func updateScreenSize() {
        if isSplitViewResizing { return }

        var layoutSize = self.view.safeAreaLayoutGuide.layoutFrame.size
        layoutSize.width -= TerminalView.horizontalSpacing * 2
        layoutSize.height -= TerminalView.verticalSpacing * 2

        if layoutSize.width <= 0 || layoutSize.height <= 0 { return }
        
        let glyphSize = terminalController.fontMetrics.boundingBox
        if glyphSize.width == 0 || glyphSize.height == 0 { return }
        
        let newSize = ScreenSize(cols: UInt16(layoutSize.width / glyphSize.width),
                                 rows: UInt16(layoutSize.height / glyphSize.height.rounded(.up)),
                                 cellSize: glyphSize)
        if screenSize != newSize {
            screenSize = newSize
            delegate?.terminal(viewController: self, screenSizeDidChange: newSize)
        } else {
            self.scroll(animated: true)
        }
    }

    @objc func clearTerminal() {
        terminalController.clearTerminal()
    }

    private func updateIsSplitViewResizing() {
        state.isSplitViewResizing = isSplitViewResizing
        if !isSplitViewResizing { updateScreenSize() }
    }

    private func updateShowsTitleView() {
        updateScreenSize()
    }

    // MARK: - 核心选中逻辑

    @objc private func handleTextViewTap(_ gestureRecognizer: UITapGestureRecognizer) {
        if gestureRecognizer.state == .ended {
            if isSelecting {
                clearSelection()
            }
            if !keyInput.isFirstResponder {
                keyInput.becomeFirstResponder()
                delegate?.terminalDidBecomeActive(viewController: self)
            }
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: tableView)
        
        switch gesture.state {
        case .began:
            if let coord = getTerminalCoordinate(at: point) {
                isSelecting = true
                selectionStart = coord
                selectionEnd = coord
                
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                
                self.becomeFirstResponder()
                tableView.reloadData()
            }
        case .changed:
            if let coord = getTerminalCoordinate(at: point) {
                // 单独比较属性，避免可选类型比较错误
                if selectionEnd?.col != coord.col || selectionEnd?.row != coord.row {
                    selectionEnd = coord
                    tableView.reloadData()
                }
            }
        case .ended:
            showMenu(at: point)
        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isSelecting else { return }
        let point = gesture.location(in: tableView)
        
        switch gesture.state {
        case .changed:
            if let coord = getTerminalCoordinate(at: point) {
                handleAutoScroll(at: point)
                if selectionEnd?.col != coord.col || selectionEnd?.row != coord.row {
                    selectionEnd = coord
                    tableView.reloadData()
                }
            }
        case .ended:
            showMenu(at: point)
        default:
            break
        }
    }

    private func getTerminalCoordinate(at point: CGPoint) -> (col: Int, row: Int)? {
        guard let indexPath = tableView.indexPathForRow(at: point) else { return nil }
        
        let localX = point.x - TerminalView.horizontalSpacing
        let charWidth = terminalController.fontMetrics.boundingBox.width
        guard charWidth > 0 else { return nil }
        
        let col = Int(round(localX / charWidth))
        let maxCols = Int(screenSize?.cols ?? 80)
        let constrainedCol = max(0, min(col, maxCols))
        
        return (col: constrainedCol, row: indexPath.row)
    }
    
    private func handleAutoScroll(at point: CGPoint) {
        let topMargin: CGFloat = 40
        let bottomMargin: CGFloat = tableView.bounds.height - 40
        let contentOffset = tableView.contentOffset
        
        if point.y - contentOffset.y < topMargin {
            tableView.setContentOffset(CGPoint(x: 0, y: max(0, contentOffset.y - 10)), animated: false)
        } else if point.y - contentOffset.y > bottomMargin {
            tableView.setContentOffset(CGPoint(x: 0, y: min(tableView.contentSize.height, contentOffset.y + 10)), animated: false)
        }
    }

    private func clearSelection() {
        isSelecting = false
        selectionStart = nil
        selectionEnd = nil
        tableView.reloadData()
        UIMenuController.shared.hideMenu()
    }

    private func showMenu(at point: CGPoint) {
        self.becomeFirstResponder()
        
        var targetRect = CGRect(x: point.x, y: point.y, width: 2, height: 20)
        if let end = selectionEnd {
             let indexPath = IndexPath(row: end.row, section: 0)
             let rowRect = tableView.rectForRow(at: indexPath)
             let charWidth = terminalController.fontMetrics.boundingBox.width
             let x = TerminalView.horizontalSpacing + CGFloat(end.col) * charWidth
             targetRect = CGRect(x: x, y: rowRect.origin.y, width: 2, height: rowRect.height)
        }

        let menu = UIMenuController.shared
        if #available(iOS 13.0, *) {
            menu.showMenu(from: tableView, rect: targetRect)
        } else {
            menu.setTargetRect(targetRect, in: tableView)
            menu.setMenuVisible(true, animated: true)
        }
    }

    // MARK: - 复制 / 粘贴

    override var canBecomeFirstResponder: Bool {
        return true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            return isSelecting && selectionStart != nil
        }
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
        guard let start = selectionStart, let end = selectionEnd else { return }
        
        let (p1, p2) = sortPositions(start, end)
        var resultText = ""
        
        for rowIndex in p1.row...p2.row {
            guard rowIndex >= 0 && rowIndex < lines.count else { continue }
            let line = lines[rowIndex]
            let lineLength = line.count
            let startCol = (rowIndex == p1.row) ? p1.col : 0
            let endCol = (rowIndex == p2.row) ? p2.col : lineLength
            
            let safeStart = max(0, min(startCol, lineLength))
            let safeEnd = max(0, min(endCol, lineLength))
            
            if safeStart < safeEnd {
                var lineStr = ""
                for i in safeStart..<safeEnd {
                    let charData = line[i] 
                    let char = charData.getCharacter() 
                    if char != Character(UnicodeScalar(0)) {
                        lineStr.append(char)
                    } else {
                        lineStr.append(" ")
                    }
                }
                resultText += lineStr
            }
            if rowIndex != p2.row {
                resultText += "\n"
            }
        }
        
        UIPasteboard.general.string = resultText
        clearSelection()
        keyInput.becomeFirstResponder()
    }

    override func paste(_ sender: Any?) {
        if let string = UIPasteboard.general.string {
            terminalController.write(string.utf8Array)
        }
        clearSelection()
        keyInput.becomeFirstResponder()
    }

    private func sortPositions(_ p1: (col: Int, row: Int), _ p2: (col: Int, row: Int)) -> ((col: Int, row: Int), (col: Int, row: Int)) {
        if p1.row < p2.row { return (p1, p2) }
        if p1.row > p2.row { return (p2, p1) }
        return p1.col < p2.col ? (p1, p2) : (p2, p1)
    }

    // MARK: - 生命周期与设置更新
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
        
        // 关键修复：设置全局行高。这样 TableView 就知道每个 Cell 该多高，避免空白。
        if let tableView = tableView {
            tableView.rowHeight = terminalController.fontMetrics.boundingBox.height
            tableView.reloadData()
        }
    }
}

// MARK: - TerminalControllerDelegate
extension TerminalSessionViewController: TerminalControllerDelegate {

    func refresh(lines: inout [AnyView]) {
        state.lines = lines
        self.scroll()
    }
    
    func refresh(lines: inout [BufferLine], cursor: (Int,Int)) {
        self.lines = lines
        self.cursor = cursor
        self.tableView.reloadData()
        self.scroll()
    }
    
    func scroll(animated: Bool = false) {
        guard !isSelecting else { return }
        
        state.scroll += 1
        
        let lastRow = self.tableView.numberOfRows(inSection: 0) - 1
        if lastRow >= 0 {
            let indexPath = IndexPath(row: lastRow, section: 0)
            self.tableView.scrollToRow(at: indexPath, at: .bottom, animated: false)
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
        if gestureRecognizer == textViewTapGestureRecognizer {
            return (!(otherGestureRecognizer is UITapGestureRecognizer) || keyInput.isFirstResponder)
        }
        if gestureRecognizer == panGesture {
            return isSelecting
        }
        return false
    }
    
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == panGesture {
            return isSelecting
        }
        return true
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

// MARK: - Table View Data Source (渲染逻辑)
extension TerminalSessionViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        self.lines.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: SwiftUITableViewCell.identifier, for: indexPath) as? SwiftUITableViewCell else {
            return UITableViewCell()
        }
        
        let line = self.lines[indexPath.row]
        let view = terminalController.stringSupplier.attributedString(line: line, cursorX: indexPath.row == cursor.y ? cursor.x : -1)
        
        var rangeInLine: Range<Int>? = nil
        if isSelecting, let start = selectionStart, let end = selectionEnd {
            let (p1, p2) = sortPositions(start, end)
            if indexPath.row >= p1.row && indexPath.row <= p2.row {
                let sCol = (indexPath.row == p1.row) ? p1.col : 0
                let eCol = (indexPath.row == p2.row) ? p2.col : 1000 
                if sCol < eCol {
                    rangeInLine = sCol..<eCol
                }
            }
        }
        
        let metrics = terminalController.fontMetrics.boundingBox
        cell.configure(view: view, charWidth: metrics.width, lineHeight: metrics.height, selectionRange: rangeInLine)
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        return nil
    }
}
