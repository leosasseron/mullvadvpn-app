//
//  AsyncOperation.swift
//  MullvadVPN
//
//  Created by pronebird on 01/06/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation

/// A base implementation of an asynchronous operation
class AsyncOperation: Operation {

    /// A state lock used for manipulating the operation state flags in a thread safe fashion.
    fileprivate let stateLock = NSRecursiveLock()

    /// Operation state flags.
    private var _isExecuting = false
    private var _isFinished = false
    private var _isCancelled = false

    override var isExecuting: Bool {
        return stateLock.withCriticalBlock { _isExecuting }
    }

    override var isFinished: Bool {
        return stateLock.withCriticalBlock { _isFinished }
    }

    override var isCancelled: Bool {
        return stateLock.withCriticalBlock { _isCancelled }
    }

    override var isAsynchronous: Bool {
        return true
    }

    override func start() {
        stateLock.withCriticalBlock {
            if self._isCancelled {
                self.finish()
            } else {
                self.setExecuting(true)
                self.main()
            }
        }
    }

    override func main() {
        // Override in subclasses
    }

    override func cancel() {
        stateLock.withCriticalBlock {
            if !self._isCancelled {
                self.setCancelled(true)

                // Subclasses should call `finish()` to complete the operation
            }
        }
    }

    func finish() {
        stateLock.withCriticalBlock {
            if self._isExecuting {
                self.setExecuting(false)
            }

            if !self._isFinished {
                self.setFinished(true)
            }
        }
    }

    private func setExecuting(_ value: Bool) {
        willChangeValue(for: \.isExecuting)
        _isExecuting = value
        didChangeValue(for: \.isExecuting)
    }

    private func setFinished(_ value: Bool) {
        willChangeValue(for: \.isFinished)
        _isFinished = value
        didChangeValue(for: \.isFinished)
    }

    private func setCancelled(_ value: Bool) {
        willChangeValue(for: \.isCancelled)
        _isCancelled = value
        didChangeValue(for: \.isCancelled)
    }

}

/// Asynchronous block operation
class AsyncBlockOperation: AsyncOperation {
    private let block: (@escaping () -> Void) -> Void

    init(block: @escaping (@escaping () -> Void) -> Void) {
        self.block = block
        super.init()
    }

    override func main() {
        self.block { [weak self] in
            self?.finish()
        }
    }
}

protocol OutputOperation {
    associatedtype Output

    var output: Output? { get }

    func finish(with output: Output)
}

class AsyncOutputOperation<Output>: AsyncOperation, OutputOperation {
    private var _output: Output?

    var output: Output? {
        return stateLock.withCriticalBlock { self._output }
    }

    func finish(with output: Output) {
        stateLock.withCriticalBlock {
            self._output = output
            self.finish()
        }
    }
}

class AsyncBlockOutputOperation<Output>: AsyncOutputOperation<Output> {

    private enum Executor {
        case callback((@escaping (Output) -> Void) -> Void)
        case transform(() -> Output)
    }

    private let executor: Executor

    private init(executor: Executor) {
        self.executor = executor
    }

    convenience init(block: @escaping (@escaping (Output) -> Void) -> Void) {
        self.init(executor: .callback(block))
    }

    convenience init(block: @escaping () -> Output) {
        self.init(executor: .transform(block))
    }

    override func main() {
        switch executor {
        case .callback(let block):
            block { [weak self] (result) in
                self?.finish(with: result)
            }

        case .transform(let block):
            self.finish(with: block())
        }
    }

}
