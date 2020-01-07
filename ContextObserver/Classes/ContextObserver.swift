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
    
    private struct Update {
        let state: State
        let id: NSManagedObjectID
        let changes: [String: Changed]
    }
    
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
    
    private func valueFor(_ value: Any?) -> Any?{
        if let child = value as? NSManagedObject {
            if child.objectID.isTemporaryID {
                try? child.managedObjectContext?.obtainPermanentIDs(for: [child])
            }
            return child.objectID
        } else if let childSet = value as? NSSet {
            let result: [Any] = childSet.compactMap{ valueFor($0) }
            if let castResult = result as? [NSManagedObjectID] {
                return Set(castResult)
            } else {
                return NSSet(array: result)
            }
        } else if let childSet = value as? NSOrderedSet, childSet.firstObject is NSManagedObject {
            let result: [Any] = childSet.compactMap{ valueFor($0) }
            return result
        } else if value is NSNull{
            return nil
        } else {
            return value
        }
    }
    
    public func remove(_ observer: NSObject?) {
        for id in objectActions.keys {
            remove(objectAction: observer, for: id)
        }
        for id in keypathActions.keys {
            remove(keyPathAction: observer, for: id)
        }
    }
    
    private func remove(_ observer: NSObject?, for id: NSManagedObjectID) {
        remove(objectAction: observer, for: id)
        remove(keyPathAction: observer, for: id)
    }
    
    public func remove(_ observer: NSObject?, for object: NSManagedObject?) {
        if let id = object?.objectID {
            remove(observer, for: id)
        } else {
            remove(observer)
        }
    }
    
    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let context = context else { return }
        guard let id = (object as? NSManagedObject)?.objectID else { return }
        
        if context == &ContextObserver.keypathObserverContext {
            handleKeypathObserveValue(forKeyPath: keyPath, of: id, change: change)
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
   
        let objectActions = self.objectActions
        
        let filterd: [NSManagedObject] = allObjects.compactMap {
            guard objectActions[$0.objectID] != nil else { return nil }
            return $0
        }
        
        var updates = [Update]()
        
        for object in filterd {
            var state: State = []
            if insertedObjectsSet.contains(object) {
                state.insert(.inserted)
            }
            if updatedObjectsSet.contains(object) {
                state.insert(.updated)
            }
            if deletedObjectsSet.contains(object) {
                state.insert(.deleted)
            }
            if refreshedObjectsSet.contains(object) {
                state.insert(.refreshed)
            }
            let changes = changesFor(object: object)
            
            if changes.count != 0 || state != .refreshed {
                updates.append(Update(state: state, id: object.objectID, changes: changes))
            }
        }
        
        if updates.count == 0 {
            // nothing to do.
            return
        }
        
        context.perform { [weak self] in
            guard let this = self else { return }
            this.handleKeypathContextChange()
            this.handleObjectContextChange(updates)
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
    
    public func add<O: NSObject, T: NSManagedObject>(_ type: T.Type, observer: O, for id: NSManagedObjectID, state: State = .updated, _ block: @escaping ObjectCallbackBlock<O, T>) {
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
    
    private func handleObjectContextChange(_ updates: [Update]) {
        for update in updates {
            guard let actions = objectActions[update.id] else { continue }
            var cleanup = false
            var object: NSManagedObject? = nil
            //context.refresh(object, mergeChanges: true)
            
            for action in actions {
                guard let observer = action.observer else {
                    cleanup = true
                    continue
                }
                if action.state.intersection(update.state).rawValue > 0 {
                    if object == nil {
                        object = context.object(with: update.id)
                    }
                    action.block((observer, object!, update.changes, update.state))
                }
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
            
            var list = this.keypathActions[id] ?? []
            list.append(action)
            this.keypathActions[id] = list
            
            block((observer!, object, ValueChanged(old: nil, new: nil)))
        }
        
    }
    
    private func handleKeypathObserveValue(forKeyPath keyPath: String?, of id: NSManagedObjectID, change: [NSKeyValueChangeKey : Any]?) {
        let new = valueFor(change?[.newKey])
        let old = valueFor(change?[.oldKey])
        
        // check if there was a change
        if let objOld = old as? NSObject, let objNew = new as? NSObject, objOld.isEqual(objNew) {
            return
        } else if new == nil && old == nil {
            return
        }
        
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
    
    private func handleKeypathContextChange() {
        for actions in keypathActions.values {
            actions.forEach {
                $0.object.value(forKeyPath: $0.keyPath) // load keypath to trigger update
            }
        }
    }
}
