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
    private var textView: UIView!
    private var tableView: UITableView!
    private var textViewTapGestureRecognizer: UITapGestureRecognizer!
    
    // Selection State
    private var selectionStart: (col: Int, row: Int)?
    private var selectionEnd: (col: Int, row: Int)?
    private var isSelecting = false
    private var longPressGesture: UILongPressGestureRecognizer!
    private var panGesture: UIPanGestureRecognizer!
    
    private var state = TerminalState()
    private var lines = [BufferLine]()
    private var cursor = (x:Int(-1), y:Int(-1))

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
        
        tableView = UITableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.separatorInset = .zero
        tableView.backgroundColor = .clear
        tableView.allowsSelection = false // Disable native table selection to handle it manually
        
        textView = tableView

        textViewTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleTextViewTap(_:)))
        textViewTapGestureRecognizer.delegate = self
        textView.addGestureRecognizer(textViewTapGestureRecognizer)
        
        // --- Add Selection Gestures ---
        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.5
        longPressGesture.delegate = self
        textView.addGestureRecognizer(longPressGesture)
        
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        textView.addGestureRecognizer(panGesture)
        // -----------------------------

        keyInput.frame = view.bounds
        keyInput.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        keyInput.textView = textView
        keyInput.keyboardToolbarHeightChanged = { height in
            self.keyboardToolbarHeightChanged?(height)
        }
        keyInput.terminalInputDelegate = terminalController
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
        
        // Add Copy Command support
        addKeyCommand(UIKeyCommand(title: .localize("COPY", comment: "Copy text"),
                                   image: UIImage(systemName: "doc.on.doc"),
                                   action: #selector(self.copy(_:)),
                                   input: "c",
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
        // NSLog("NewTermLog: viewWillTransition to \(size)")
        super.viewWillTransition(to: size, with: coordinator)
        if UIDevice.current.userInterfaceIdiom == .pad {
            if keyInput.isFirstResponder {
                //reload keyboardToolbar
                keyInput.resignFirstResponder()
            }
        }
    }
    
    override func viewWillLayoutSubviews() {
        // NSLog("NewTermLog: TerminalSessionViewController.viewWillLayoutSubviews \(self.view.frame) \(self.view.safeAreaInsets)")
        super.viewWillLayoutSubviews()
        updateScreenSize()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // NSLog("NewTermLog: TerminalSessionViewController.viewDidLayoutSubviews \(self.view.frame) \(self.view.safeAreaInsets)")
        // NSLog("NewTermLog: textView frame=\(self.textView.frame) safeArea=\(self.textView.safeAreaInsets)")
    }

    override func viewSafeAreaInsetsDidChange() {
        // NSLog("NewTermLog: TerminalSessionViewController.viewSafeAreaInsetsDidChange \(self.view.frame) \(view.safeAreaInsets)")
        super.viewSafeAreaInsetsDidChange()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        // NSLog("NewTermLog: TerminalSessionViewController.traitCollectionDidChange \(self.view.frame) \(view.safeAreaInsets)")
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

        // Determine the screen size based on the font size
        var layoutSize = self.view.safeAreaLayoutGuide.layoutFrame.size
        layoutSize.width -= TerminalView.horizontalSpacing * 2
        layoutSize.height -= TerminalView.verticalSpacing * 2

        if layoutSize.width <= 0 || layoutSize.height <= 0 {
            // Not laid out yet. We’ll be called again when we are.
            return
        }
        
        let layoutFrame1 = self.view.safeAreaLayoutGuide.layoutFrame
        if layoutFrame1.origin.x < 0 || layoutFrame1.origin.y < 0 {
            //in layouting
            return
        }
        let layoutFrame2 = self.textView.safeAreaLayoutGuide.layoutFrame
        if layoutFrame2.origin.x < 0 || layoutFrame2.origin.y < 0 {
            //in layouting
            return
        }

        let glyphSize = terminalController.fontMetrics.boundingBox
        
        // --- FIX: Prevent crash if glyph size is invalid ---
        if glyphSize.width <= 0.1 || glyphSize.height <= 0.1 {
            // Font metrics not ready yet, skip layout update
            return
        }
        // --------------------------------------------------
        
        // NSLog("NewTermLog: TerminalSessionViewController.updateScreenSize self=\(self.view.safeAreaLayoutGuide.layoutFrame) textView=\(textView.safeAreaLayoutGuide.layoutFrame)")
        let newSize = ScreenSize(cols: UInt16(layoutSize.width / glyphSize.width),
                                                         rows: UInt16(layoutSize.height / glyphSize.height.rounded(.up)),
                                                         cellSize: glyphSize)
        if screenSize != newSize {
            screenSize = newSize
            delegate?.terminal(viewController: self, screenSizeDidChange: newSize)
        }
        else {
            //when layout size changes, always scroll even if rows/columns don't change
            self.scroll(animated: true)
        }
    }

    @objc func clearTerminal() {
        terminalController.clearTerminal()
        clearSelection()
    }

    private func updateIsSplitViewResizing() {
        // NSLog("NewTermLog: TerminalSessionViewController.updateIsSplitViewResizing")
        state.isSplitViewResizing = isSplitViewResizing

        if !isSplitViewResizing {
            updateScreenSize()
        }
    }

    private func updateShowsTitleView() {
        // NSLog("NewTermLog: TerminalSessionViewController.updateShowsTitleView")
        updateScreenSize()
    }

    // MARK: - Gestures & Selection
    
    private func locationToGrid(point: CGPoint) -> (col: Int, row: Int)? {
        guard let indexPath = tableView.indexPathForRow(at: point),
              let cell = tableView.cellForRow(at: indexPath) else { return nil }
        
        let charWidth = terminalController.fontMetrics.boundingBox.width
        
        // --- FIX: Prevent crash if charWidth is 0 ---
        if charWidth <= 0 { return nil }
        // ------------------------------------------
        
        // Adjust point to be relative to the cell's content view
        let localPoint = tableView.convert(point, to: cell.contentView)
        
        let col = Int(localPoint.x / charWidth)
        let row = indexPath.row
        
        // Clamp column
        let maxCol = Int(terminalController.screenSize?.cols ?? 80)
        let clampedCol = max(0, min(col, maxCol - 1))
        
        return (clampedCol, row)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: tableView)
        
        switch gesture.state {
        case .began:
            if let gridPos = locationToGrid(point: point) {
                // Haptic feedback
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                
                isSelecting = true
                selectionStart = gridPos
                selectionEnd = gridPos
                
                // Show Menu Controller
                showMenuController(at: point)
                tableView.reloadData()
            }
        default:
            break
        }
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: tableView)
        
        switch gesture.state {
        case .began, .changed:
            if isSelecting {
                if let gridPos = locationToGrid(point: point) {
                    selectionEnd = gridPos
                    tableView.reloadData()
                    
                    // TODO: Handle auto-scrolling when dragging near edges
                }
            }
        case .ended:
            if isSelecting {
                 showMenuController(at: point)
            }
        default:
            break
        }
    }
    
    private func clearSelection() {
        selectionStart = nil
        selectionEnd = nil
        isSelecting = false
        tableView.reloadData()
        UIMenuController.shared.hideMenu()
    }
    
    private func showMenuController(at point: CGPoint) {
        guard let _ = selectionStart, let _ = selectionEnd else { return }
        
        becomeFirstResponder()
        let menu = UIMenuController.shared
        
        // Create a rectangle for the menu target
        let rect = CGRect(x: point.x, y: point.y - 20, width: 1, height: 1)
        
        if #available(iOS 13.0, *) {
            menu.showMenu(from: tableView, rect: rect)
        } else {
            // Fallback for older iOS
            menu.setTargetRect(rect, in: tableView)
            menu.setMenuVisible(true, animated: true)
        }
    }

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
    
    // MARK: - Copy / Paste Logic
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            return isSelecting
        }
        return super.canPerformAction(action, withSender: sender)
    }
    
    override func copy(_ sender: Any?) {
        guard let start = selectionStart, let end = selectionEnd else { return }
        
        let text = getSelectedText(start: start, end: end)
        UIPasteboard.general.string = text
    }
    
    private func getSelectedText(start: (col: Int, row: Int), end: (col: Int, row: Int)) -> String {
        // Normalize range
        let (minR, maxR, startCol, endCol) = normalizeSelection(start: start, end: end)
        
        var result = ""
        
        // Ensure bounds are safe
        let safeMinRow = max(0, minR)
        let safeMaxRow = min(lines.count - 1, maxR)
        
        if safeMinRow > safeMaxRow { return "" }
        
        for rowIndex in safeMinRow...safeMaxRow {
            // Need to extract text from BufferLine.
            // Using terminal instance since we made it public
            if let term = terminalController.terminal {
                // Buffer rows are scroll-invariant usually in SwiftTerm logic, need to check if we need yDisp adjustment.
                // In refresh() we get 'lines' which are BufferLine.
                // SwiftTerm lines in `refresh` are typically the visible ones.
                // Assuming `lines` array matches `rowIndex`.
                
                // Let's use the local lines variable which we refreshed.
                if rowIndex < lines.count {
                    let _ = lines[rowIndex]
                    // Fallback to a simple extraction if possible, or use terminal helper
                    // Note: terminal.getLine(row) expects absolute row index if I recall correctly, or relative.
                    // Since we have `lines` cached which are just data, we need a way to interpret them.
                    // For now, let's assume we can get the text from the terminal for the *visible* rows.
                    // The visible rows correspond to terminal.buffer.lines[terminal.buffer.yDisp + i]
                    
                    if let termLine = term.getLine(row: rowIndex + term.buffer.yDisp) {
                         let str = termLine.translateToString()
                         let len = str.count
                         var s = 0
                         var e = len
                         
                         if rowIndex == safeMinRow {
                             s = min(len, startCol)
                         }
                         if rowIndex == safeMaxRow {
                             e = min(len, endCol + 1)
                         }
                         
                         if s < e {
                             let startIdx = str.index(str.startIndex, offsetBy: s)
                             let endIdx = str.index(str.startIndex, offsetBy: e)
                             result += str[startIdx..<endIdx]
                         }
                    }
                }
            }
            
            if rowIndex != safeMaxRow {
                result += "\n"
            }
        }
        return result
    }
    
    // Helper to normalize selection (start could be after end)
    private func normalizeSelection(start: (col: Int, row: Int), end: (col: Int, row: Int)) -> (minRow: Int, maxRow: Int, startCol: Int, endCol: Int) {
        if start.row < end.row {
            return (start.row, end.row, start.col, end.col)
        } else if start.row > end.row {
            return (end.row, start.row, end.col, start.col)
        } else {
            // Same row
            return (start.row, start.row, min(start.col, end.col), max(start.col, end.col))
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
        tableView.reloadData()
    }
}

extension TerminalSessionViewController: TerminalControllerDelegate {

    func refresh(lines: inout [AnyView]) {
        state.lines = lines
        self.scroll()
    }
    
    func refresh(lines: inout [BufferLine], cursor: (Int,Int)) {
        // NSLog("NewTermLog: refresh lines=\(lines.count)")
        self.lines = lines
        self.cursor = cursor
        self.tableView.reloadData()
        self.scroll()
    }
    
    func scroll(animated: Bool = false) {
        // Only scroll if we are not selecting
        if isSelecting { return }
        
        state.scroll += 1
        
        let lastRow = self.tableView.numberOfRows(inSection: 0) - 1
        if lastRow >= 0 {
            let indexPath = IndexPath(row: lastRow, section: 0)
            self.tableView.scrollToRow(at: indexPath, at: .bottom, animated: false)
            // NSLog("NewTermLog: scrollToRow \(indexPath)")
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
        // Prioritize selection gestures
        if gestureRecognizer == longPressGesture || gestureRecognizer == panGesture {
            return false
        }
        return gestureRecognizer == textViewTapGestureRecognizer
            && (!(otherGestureRecognizer is UITapGestureRecognizer) || keyInput.isFirstResponder)
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == panGesture && otherGestureRecognizer == tableView.panGestureRecognizer {
            return false // Disable scroll when selecting
        }
        return false
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
            // The system will clean up the temp directory for us eventually anyway, but still delete the
            // downloads temp directory now so the file doesn’t linger around till then.
            terminalController.deleteDownloadCache()
        }
    }

}

// MARK: - Custom Cell for Selection
class SwiftUITableViewCell: UITableViewCell {
    private var hostingView: UIHostingView<AnyView>?
    private var selectionLayer: UIView!
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.backgroundColor = .clear
        self.contentView.backgroundColor = .clear
        self.selectionStyle = .none
        
        // Add selection layer
        selectionLayer = UIView()
        selectionLayer.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.3)
        selectionLayer.isHidden = true
        contentView.addSubview(selectionLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func configure(with view: AnyView, selectionRange: Range<Int>?, charWidth: CGFloat) {
        // Reuse hosting view if possible to save performance
        if let existingHostingView = hostingView {
            existingHostingView.rootView = view
        } else {
            let newHostingView = UIHostingView(rootView: view)
            newHostingView.translatesAutoresizingMaskIntoConstraints = false
            newHostingView.backgroundColor = .clear
            contentView.addSubview(newHostingView)
            self.hostingView = newHostingView
            
            NSLayoutConstraint.activate([
                newHostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                newHostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                newHostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }
        
        // Update selection layer
        if let range = selectionRange {
            let startX = CGFloat(range.lowerBound) * charWidth
            let width = CGFloat(range.count) * charWidth
            selectionLayer.frame = CGRect(x: startX, y: 0, width: width, height: contentView.bounds.height)
            selectionLayer.isHidden = false
            contentView.sendSubviewToBack(selectionLayer) // Ensure selection is behind text
        } else {
            selectionLayer.isHidden = true
        }
        
        // Ensure hosting view is frontmost
        if let host = hostingView {
            contentView.bringSubviewToFront(host)
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
    }
}

extension TerminalSessionViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        return nil
    }
}

extension TerminalSessionViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        self.lines.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell") as? SwiftUITableViewCell ?? SwiftUITableViewCell(style: .default, reuseIdentifier: "Cell")
        
        let line = self.lines[indexPath.row]
        let view = terminalController.stringSupplier.attributedString(line: line, cursorX: indexPath.row == cursor.y ? cursor.x : -1)
        
        // Calculate Selection Range for this row
        var selectionRange: Range<Int>? = nil
        if let start = selectionStart, let end = selectionEnd {
            let (minR, maxR, startCol, endCol) = normalizeSelection(start: start, end: end)
            
            if indexPath.row >= minR && indexPath.row <= maxR {
                // Determine cols for this row
                let sCol = (indexPath.row == minR) ? startCol : 0
                let eCol = (indexPath.row == maxR) ? endCol : Int.max // max selects till end
                
                let maxLineCols = Int(terminalController.screenSize?.cols ?? 80)
                let actualEnd = min(eCol, maxLineCols)
                
                if sCol <= actualEnd {
                     selectionRange = sCol..<(actualEnd + 1)
                }
            }
        }
        
        cell.configure(with: view, selectionRange: selectionRange, charWidth: terminalController.fontMetrics.boundingBox.width)
        return cell
    }
    
}
