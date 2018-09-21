//
//  ContextObserver.swift
//  ContextObserver
//
//  Created by Peter Gulyas on 2018-09-19.
//

import UIKit
import CoreData

public class ContextObserver: NSObject {
    
    let context: NSManagedObjectContext
    private var objectActions = [NSManagedObjectID: [ObjectAction]]()
    private var keypathActions = [NSManagedObjectID: [KeyPathAction]]()
    
    public struct State: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        
        public static let inserted = State(rawValue: 1 << 0)
        public static let updated = State(rawValue: 1 << 1)
        public static let deleted = State(rawValue: 1 << 2)
        public static let refreshed = State(rawValue: 1 << 3)
        public static let all: State  = [inserted, updated, deleted]
    }
    
    public struct ValueChanged<V> {
        public let old: V?
        public let new: V?
    }
    
    public typealias Changed = ValueChanged<Any>
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        
        if keypathActions.count > 0 {
            keypathActions.values.forEach {
                for action in $0 {
                    action.object.removeObserver(self, forKeyPath: action.keyPath, context: &(ContextObserver.keypathObserverContext))
                }
            }
        }
    }
    
    public init(context: NSManagedObjectContext) {
        self.context = context
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleContextObjectDidChange(_:)), name: NSNotification.Name.NSManagedObjectContextObjectsDidChange, object: nil)
    }
    
    private func cleanupActions() {
        objectActions.keys.forEach {
            remove(objectAction: nil, for: $0)
        }
        keypathActions.keys.forEach {
            remove(keyPathAction: nil, for: $0)
        }
    }
    
    private func valueFor(_ value: Any?) -> Any?{
        if let child = value as? NSManagedObject {
            return child.objectID
        } else if let childSet = value as? Set<NSManagedObject> {
            return Set<NSManagedObjectID>((childSet.map { $0.objectID }))
        } else if value is NSNull{
            return nil
        } else {
            return value
        }
    }
    
    public func remove(_ observer: NSObject) {
        for id in objectActions.keys {
            remove(observer, for: id)
        }
    }
    
    private func remove(_ observer: NSObject, for id: NSManagedObjectID) {
        remove(objectAction: observer, for: id)
        remove(keyPathAction: nil, for: id)
    }
    
    public func remove(_ observer: NSObject, for object: NSManagedObject?) {
        if let id = object?.objectID {
            remove(observer, for: id)
        } else {
            remove(observer)
        }
    }
    
    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let context = context else { return }
        if context == &ContextObserver.keypathObserverContext {
            handleKeypathObserveValue(forKeyPath: keyPath, of: object, change: change)
        }
    }
    
    private func changesFor(object: NSManagedObject) -> [String: Changed] {
        
        var changes = [String: Changed]()
        
        for item in object.changedValues() {
            let new = valueFor(item.value)
            let old = valueFor(object.changedValuesForCurrentEvent()[item.key])
            let change = Changed(old: old, new: new)
            changes[item.key] = change
        }
        
        return changes
    }
    
    @objc private func handleContextObjectDidChange(_ notification: Notification) {
        guard
            let incomingPersistentStoreCoordinator = (notification.object as? NSManagedObjectContext)?.persistentStoreCoordinator,
            let persistentStoreCoordinator = context.persistentStoreCoordinator,
            persistentStoreCoordinator == incomingPersistentStoreCoordinator else {
                return
        }
        
        let insertedObjectsSet = (notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? Set<NSManagedObject>())
        let updatedObjectsSet = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? Set<NSManagedObject>()
        let deletedObjectsSet = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? Set<NSManagedObject>()
        let refreshedObjectsSet = notification.userInfo?[NSRefreshedObjectsKey] as? Set<NSManagedObject> ?? Set<NSManagedObject>()
        
        let allObjects = insertedObjectsSet.union(updatedObjectsSet).union(deletedObjectsSet).union(refreshedObjectsSet)
        
        let filterd: [(object: NSManagedObject, actions: [ObjectAction])] = allObjects.compactMap {
            guard let action = objectActions[$0.objectID] else { return nil }
            return ($0, action)
        }
        var updates = [(state: State, id: NSManagedObjectID, changes: [String: Changed])]()
        
        for item in filterd {
            var state: State = []
            if insertedObjectsSet.contains(item.object) {
                state.insert(.inserted)
            }
            if updatedObjectsSet.contains(item.object) {
                state.insert(.updated)
            }
            if deletedObjectsSet.contains(item.object) {
                state.insert(.deleted)
            }
            if refreshedObjectsSet.contains(item.object) {
                state.insert(.refreshed)
            }
            let changes = changesFor(object: item.object)
            updates.append((state, item.object.objectID, changes))
        }
        
        context.perform { [weak self] in
            guard let this = self else { return }
            this.handleKeypathContextChange(notification, updatedObjectsSet)
            this.handleObjectContextChange(notification, updates)
        }
    }
    
}
// MARK: - Object Observation

extension ContextObserver {
    
    public typealias ObjectCallbackBlock<O: NSObject, T: NSManagedObject> = ((observer: O, object: T, changes: [String: Changed], state: State)) -> ()
    private typealias BaseObjectCallbackBlock = ObjectCallbackBlock<NSObject, NSManagedObject>
    
    private class ObjectAction {
        weak var observer: NSObject?
        let id: NSManagedObjectID
        let state: State
        let block: BaseObjectCallbackBlock
        init(_ observer: NSObject, _ id: NSManagedObjectID, _ state: State, _ block: @escaping BaseObjectCallbackBlock) {
            self.observer = observer
            self.id = id
            self.state = state
            self.block = block
        }
    }
    
    public func add<O: NSObject, T: NSManagedObject>(_ type: T.Type, observer: O, for id: NSManagedObjectID, state: State = .all, _ block: @escaping ObjectCallbackBlock<O, T>) {
        let action = ObjectAction(observer, id, state) { result in
            let object = result.object as! T
            let observer = result.observer as! O
            block((observer, object, result.changes, result.state))
        }
        var list = objectActions[id] ?? []
        list.append(action)
        objectActions[id] = list
    }
    
    public func add<O: NSObject, T: NSManagedObject>(observer: O, for object: T, state: State = .all, _ block: @escaping ObjectCallbackBlock<O, T>) {
        add(T.self, observer: observer, for: object.objectID, block)
    }
    
    private func remove(objectAction observer: NSObject?, for id: NSManagedObjectID) {
        guard let actions = objectActions[id] else { return }
        let result = actions.filter { $0.observer != observer }
        if result.count > 0 {
            self.objectActions[id] = result
        } else {
            self.objectActions.removeValue(forKey: id)
        }
    }
    
    private func handleObjectContextChange(_ notification: Notification, _ updates: [(state: State, id: NSManagedObjectID, changes: [String: Changed])]) {
        for update in updates {
            guard let actions = objectActions[update.id] else { continue }
            var cleanup = false
            let object = context.object(with: update.id)
            context.refresh(object, mergeChanges: true)
            
            for action in actions where action.state.intersection(update.state).rawValue > 0 {
                guard let observer = action.observer else {
                    cleanup = true
                    continue
                }
                action.block((observer, object, update.changes, update.state))
            }
            if cleanup {
                remove(objectAction: nil, for: update.id)
            }
        }
    }
}

// MARK: - KeyPath Observation

extension ContextObserver {
    
    public typealias KeypathCallbackBlock<T: NSObject, O: NSManagedObject, V> = ((observer: T, object: O, change: ValueChanged<V>)) -> ()
    private typealias BasicKeypathCallbackBlock = KeypathCallbackBlock<NSObject, NSManagedObject, Any>
    
    private static var keypathObserverContext = "keypathObserverContext"
    
    private class KeyPathAction {
        weak var observer: NSObject?
        let object: NSManagedObject
        let keyPath: String
        let block: BasicKeypathCallbackBlock
        
        init(_ observer: NSObject, _ object: NSManagedObject, _ keyPath: String, _ block: @escaping BasicKeypathCallbackBlock) {
            self.observer = observer
            self.object = object
            self.keyPath = keyPath
            self.block = block
        }
    }
    
    public func add<O: NSObject, T: NSManagedObject, V>(observer: O, for object: T, keyPath: KeyPath<T, V?>, _ block: @escaping KeypathCallbackBlock<O, T, V>) {
        add(observer: observer, for: object.objectID, keyPath: keyPath, block)
    }
    
    public func add<O: NSObject, T: NSManagedObject, V>(observer: O, for id: NSManagedObjectID, keyPath: KeyPath<T, V?>, _ block: @escaping KeypathCallbackBlock<O, T, V>) {
        let keyPathStr = NSExpression(forKeyPath: keyPath).keyPath
        context.performAndWait { [weak self, weak observer] in
            guard let this = self else { return }
            let object = this.context.object(with: id) as! T
            object.addObserver(this, forKeyPath: keyPathStr, options: [.new, .old], context: &(ContextObserver.keypathObserverContext))
            let action = KeyPathAction(observer!, object, keyPathStr) { update in
                guard let observer = update.observer as? O else { return }
                guard let object = update.object as? T else { return }
                let valueChange = ValueChanged(old: update.change.old as? V, new: update.change.new as? V)
                
                block((observer, object, valueChange))
            }
            
            var list = self?.keypathActions[id] ?? []
            list.append(action)
            self?.keypathActions[id] = list
        }
    }
    
    private func handleKeypathObserveValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?) {
        guard let id = (object as? NSManagedObject)?.objectID else { return }
        
        let new = valueFor(change?[.newKey])
        let old = valueFor(change?[.oldKey])
        
        let change = ValueChanged(old: old, new: new)
        
        context.perform { [weak self] in
            guard let this = self else { return }
            guard let actions = (this.keypathActions[id]?.filter { $0.keyPath == keyPath}), actions.count > 0 else { return }
            var cleanup = false
            let object = this.context.object(with: id)
            this.context.refresh(object, mergeChanges: true)
            
            for action in actions {
                guard let observer = action.observer else {
                    cleanup = true
                    continue
                }
                action.block((observer, object, change))
            }
            if cleanup {
                this.remove(keyPathAction: nil, for: id)
            }
        }
    }

    private func remove(keyPathAction observer: NSObject?, for id: NSManagedObjectID) {
        context.performAndWait { [weak self] in
            guard let this = self else { return }
            guard let actions = this.keypathActions[id] else { return }
            let remove = actions.filter { $0.observer == observer }
            remove.forEach {
                $0.object.removeObserver(this, forKeyPath: $0.keyPath, context: &(ContextObserver.keypathObserverContext))
            }
            let result = actions.filter { $0.observer != observer }
            if result.count > 0 {
                this.keypathActions[id] = result
            } else {
                this.keypathActions.removeValue(forKey: id)
            }
        }
    }
    
    private func handleKeypathContextChange(_ notification: Notification, _ updatedObjectsSet: Set<NSManagedObject>) {
        for actions in keypathActions.values {
            actions.forEach {
                $0.object.value(forKeyPath: $0.keyPath) // load keypath to trigger update
            }
        }
    }
}

// MARK: - Relationship Observation

extension ContextObserver {
}
