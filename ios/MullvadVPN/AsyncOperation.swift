//
//  AsyncOperation.swift
//  MullvadVPN
//
//  Created by pronebird on 01/06/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation

protocol OperationProtocol: Operation {
    func addObserver<T: OperationObserver>(_ observer: T) where T.OperationType == Self

    func finish()
}

protocol OperationObserver {
    associatedtype OperationType

    func operationWillFinish(_ operation: OperationType)
    func operationDidFinish(_ operation: OperationType)
}

protocol InputOperation: OperationProtocol {
    associatedtype Input

    var input: Input? { get set }
}

protocol OutputOperation: OperationProtocol {
    associatedtype Output

    var output: Output? { get set }

    func finish(with output: Output)
}

/// A container type for storing associated values
private final class AssociatedValue<T>: NSObject {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

private func getAssociatedValue<T>(object: Any, key: UnsafeRawPointer) -> T? {
    let container = objc_getAssociatedObject(object, key) as? AssociatedValue<T>
    return container?.value
}

private func setAssociatedValue<T>(object: Any, key: UnsafeRawPointer, value: T?) {
    objc_setAssociatedObject(
        object,
        key,
        value.flatMap { AssociatedValue($0) },
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
}

private var kInputOperationAssociatedValue = 0
extension InputOperation where Self: AsyncOperation {
    var input: Input? {
        get {
            return stateLock.withCriticalBlock {
                return getAssociatedValue(object: self, key: &kInputOperationAssociatedValue)
            }
        }
        set {
            stateLock.withCriticalBlock {
                setAssociatedValue(object: self, key: &kInputOperationAssociatedValue, value: newValue)
            }
        }
    }
}

private var kOutputOperationAssociatedValue = 0
extension OutputOperation where Self: AsyncOperation {
    var output: Output? {
        get {
            return stateLock.withCriticalBlock {
                return getAssociatedValue(object: self, key: &kOutputOperationAssociatedValue)
            }
        }
        set {
            stateLock.withCriticalBlock {
                setAssociatedValue(object: self, key: &kOutputOperationAssociatedValue, value: newValue)
            }
        }
    }
}

/// A base implementation of an asynchronous operation
class AsyncOperation: Operation, OperationProtocol {

    /// A state lock used for manipulating the operation state flags in a thread safe fashion.
    fileprivate let stateLock = NSRecursiveLock()

    /// Operation state flags.
    private var _isExecuting = false
    private var _isFinished = false
    private var _isCancelled = false

    final override var isExecuting: Bool {
        return stateLock.withCriticalBlock { _isExecuting }
    }

    final override var isFinished: Bool {
        return stateLock.withCriticalBlock { _isFinished }
    }

    final override var isCancelled: Bool {
        return stateLock.withCriticalBlock { _isCancelled }
    }

    final override var isAsynchronous: Bool {
        return true
    }

    final override func start() {
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

    /// Cancel operation
    /// Subclasses should override `operationDidCancel` instead
    final override func cancel() {
        stateLock.withCriticalBlock {
            if !self._isCancelled {
                self.setCancelled(true)

                self.operationDidCancel()
            }
        }
    }

    /// Override in subclasses to support task cancellation.
    /// Subclasses should call `finish()` to complete the operation
    func operationDidCancel() {
        // no-op
    }

    final func finish() {
        stateLock.withCriticalBlock {
            self.observers.forEach { $0.operationWillFinish(self) }

            if self._isExecuting {
                self.setExecuting(false)
            }

            if !self._isFinished {
                self.setFinished(true)
            }

            self.observers.forEach { $0.operationDidFinish(self) }
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

    // MARK: - Observation

    /// The operation observers.
    fileprivate var observers: [AnyOperationObserver<Operation>] = []

    fileprivate func addAnyObserver(_ observer: AnyOperationObserver<Operation>) {
        stateLock.withCriticalBlock {
            self.observers.append(observer)
        }
    }
}

extension OperationProtocol where Self: AsyncOperation {
    func addObserver<T: OperationObserver>(_ observer: T) where T.OperationType == Self {
        let transform = TransformOperationObserver<Operation, T.OperationType>(observer)
        let wrapped = AnyOperationObserver(transform)
        addAnyObserver(wrapped)
    }
}

extension OperationProtocol {
    func addDidFinishBlockObserver(_ block: @escaping (Self) -> Void) {
        addObserver(OperationBlockObserver(didFinish: block))
    }
}

extension OperationProtocol where Self: OutputOperation {
    func addDidFinishBlockObserver(_ block: @escaping (Self, Output) -> Void) {
        addDidFinishBlockObserver { (operation) in
            if let output = operation.output {
                block(operation, output)
            }
        }
    }
}

/// Asynchronous block operation
class AsyncBlockOperation: AsyncOperation {
    private let block: (@escaping () -> Void) -> Void

    init(_ block: @escaping (@escaping () -> Void) -> Void) {
        self.block = block
        super.init()
    }

    override func main() {
        self.block { [weak self] in
            self?.finish()
        }
    }
}

extension InputOperation {

    @discardableResult func inject<Dependency>(from dependency: Dependency, via block: @escaping (Dependency.Output) -> Input?) -> Self
        where Dependency: OutputOperation
    {
        let observer = OperationBlockObserver<Dependency>(willFinish: { [weak self] (operation) in
            guard let self = self else { return }

            if let output = operation.output {
                self.input = block(output)
            }
        })
        dependency.addObserver(observer)
        addDependency(dependency)

        return self
    }

    /// Inject
    @discardableResult func injectResult<Dependency>(from dependency: Dependency) -> Self
        where Dependency: OutputOperation, Dependency.Output == Input?
    {
        return self.inject(from: dependency, via: { $0 })
    }

    /// Inject input from operation that outputs `Result<Input, Failure>`
    @discardableResult func injectResult<Dependency, Failure>(from dependency: Dependency) -> Self
        where Dependency: OutputOperation, Failure: Error, Dependency.Output == Result<Input, Failure>
    {
        return self.inject(from: dependency) { (output) -> Input? in
            switch output {
            case .success(let value):
                return value
            case .failure:
                return nil
            }
        }
    }

    /// Inject input from operation that outputs `Result<Input, Never>`
    @discardableResult func injectResult<Dependency>(from dependency: Dependency) -> Self
        where Dependency: OutputOperation, Dependency.Output == Result<Input, Never>
    {
        return self.inject(from: dependency) { (output) -> Input? in
            switch output {
            case .success(let value):
                return value
            }
        }
    }

    /// Inject input from operation that outputs `Result<Input?, Never>`
    @discardableResult func injectResult<Dependency>(from dependency: Dependency) -> Self
        where Dependency: OutputOperation, Dependency.Output == Result<Input?, Never>
    {
        return self.inject(from: dependency) { (output) -> Input? in
            switch output {
            case .success(let value):
                return value
            }
        }
    }
}

extension OutputOperation {
    func finish(with output: Output) {
        self.output = output
        self.finish()
    }
}

class TransformOperation<Input, Output>: AsyncOperation, InputOperation, OutputOperation {
    private enum Executor {
        case callback((Input, @escaping (Output) -> Void) -> Void)
        case transform((Input) -> Output)
    }

    private let executor: Executor

    private init(input: Input? = nil, executor: Executor) {
        self.executor = executor

        super.init()
        self.input = input
    }

    convenience init(input: Input? = nil, _ block: @escaping (Input, @escaping (Output) -> Void) -> Void) {
        self.init(input: input, executor: .callback(block))
    }

    convenience init(input: Input? = nil, _ block: @escaping (Input) -> Output) {
        self.init(input: input, executor: .transform(block))
    }

    override func main() {
        guard let input = input else {
            self.finish()
            return
        }

        switch executor {
        case .callback(let block):
            block(input) { [weak self] (result) in
                self?.finish(with: result)
            }

        case .transform(let block):
            self.finish(with: block(input))
        }
    }
}

class ResultOperation<Success, Failure: Error>: AsyncOperation, OutputOperation {
    typealias Output = Result<Success, Failure>

    private enum Executor {
        case callback((@escaping (Result<Success, Failure>) -> Void) -> Void)
        case transform(() -> Result<Success, Failure>)
    }

    private let executor: Executor

    private init(_ executor: Executor) {
        self.executor = executor
    }

    convenience init(_ block: @escaping (@escaping (Output) -> Void) -> Void) {
        self.init(.callback(block))
    }

    convenience init(_ block: @escaping () -> Output) {
        self.init(.transform(block))
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

extension ResultOperation where Failure == Never {
    /// A convenience initializer for infallible `ResultOperation` that automatically wraps the
    /// return value of the given closure into `Result<Success, Never>`
    convenience init(_ block: @escaping () -> Success) {
        self.init(.transform({ .success(block()) }))
    }

    /// A convenience initializer for infallible `ResultOperation` that automatically wraps the
    /// value, passed to the given closure, into `Result<Success, Never>`
    convenience init(_ block: @escaping (@escaping (Success) -> Void) -> Void) {
        self.init(.callback({ (finish) in
            block {
                finish(.success($0))
            }
        }))
    }
}

class OperationBlockObserver<OperationType>: OperationObserver {
    private var willFinish: ((OperationType) -> Void)?
    private var didFinish: ((OperationType) -> Void)?

    init(willFinish: ((OperationType) -> Void)? = nil, didFinish: ((OperationType) -> Void)? = nil) {
        self.willFinish = willFinish
        self.didFinish = didFinish
    }

    func operationWillFinish(_ operation: OperationType) {
        self.willFinish?(operation)
    }

    func operationDidFinish(_ operation: OperationType) {
        self.didFinish?(operation)
    }
}

class AnyOperationObserver<OperationType>: OperationBlockObserver<OperationType> {
    init<T: OperationObserver>(_ observer: T) where T.OperationType == OperationType {
        super.init(willFinish: observer.operationWillFinish, didFinish: observer.operationDidFinish)
    }
}

private class TransformOperationObserver<SourceOperationType, TargetOperationType>: OperationObserver {
    private let willFinish: (SourceOperationType) -> Void
    private let didFinish: (SourceOperationType) -> Void

    init<T: OperationObserver>(_ observer: T) where T.OperationType == TargetOperationType {
        self.willFinish = Self.typeCastOperation({ observer.operationWillFinish($0) })
        self.didFinish = Self.typeCastOperation({ observer.operationDidFinish($0) })
    }

    func operationWillFinish(_ operation: SourceOperationType) {
        self.willFinish(operation)
    }

    func operationDidFinish(_ operation: SourceOperationType) {
        self.didFinish(operation)
    }

    private class func typeCastOperation(_ body: @escaping (TargetOperationType) -> Void) -> (SourceOperationType) -> Void {
        return { (operation: SourceOperationType) in
            if let transformed = operation as? TargetOperationType {
                body(transformed)
            } else {
                fatalError("\(Self.self) failed to cast \(SourceOperationType.self) to \(TargetOperationType.self)")
            }
        }
    }
}

class ExclusivityController<Category> where Category: Hashable {
    private let operationQueue: OperationQueue
    private let lock = NSRecursiveLock()

    private var operations: [Category: [Operation]] = [:]
    private var observers: [Operation: NSObjectProtocol] = [:]

    init(operationQueue: OperationQueue) {
        self.operationQueue = operationQueue
    }

    func addOperation(_ operation: Operation, categories: [Category]) {
        addOperations([operation], categories: categories)
    }

    func addOperations(_ operations: [Operation], categories: [Category]) {
        lock.withCriticalBlock {
            for operation in operations {
                for category in categories {
                    addDependencies(operation: operation, category: category)
                }

                observers[operation] = operation.observe(\.isFinished, options: [.initial, .new]) { [weak self] (op, change) in
                    if let isFinished = change.newValue, isFinished {
                        self?.operationDidFinish(op, categories: categories)
                    }
                }
            }

            operationQueue.addOperations(operations, waitUntilFinished: false)
        }
    }

    private func addDependencies(operation: Operation, category: Category) {
        var exclusiveOperations = self.operations[category] ?? []

        if let dependency = exclusiveOperations.last, !operation.dependencies.contains(dependency) {
            operation.addDependency(dependency)
        }

        exclusiveOperations.append(operation)
        self.operations[category] = exclusiveOperations
    }

    private func operationDidFinish(_ operation: Operation, categories: [Category]) {
        lock.withCriticalBlock {
            for category in categories {
                var exclusiveOperations = self.operations[category] ?? []

                exclusiveOperations.removeAll { (storedOperation) -> Bool in
                    return operation == storedOperation
                }

                self.operations[category] = exclusiveOperations
            }
            self.observers.removeValue(forKey: operation)
        }
    }
}
