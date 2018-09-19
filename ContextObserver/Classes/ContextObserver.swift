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
    private var actions = [NSManagedObjectID: [Action]]()
    
    public typealias CallBackBlock = ((observer: NSObject, object: NSManagedObject, changes: [String: Changed], state: State)) -> ()
    
    public struct State: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        
        public static let inserted = State(rawValue: 1 << 0)
        public static let updated = State(rawValue: 1 << 1)
        public static let deleted = State(rawValue: 1 << 2)
        public static let refreshed = State(rawValue: 1 << 3)
        public static let all: State  = [inserted, updated, deleted]
    }
    
    public struct Changed {
        public let old: Any?
        public let new: Any?
    }
    
    private class Action {
        weak var observer: NSObject?
        let id: NSManagedObjectID
        let state: State
        let block: CallBackBlock
        init(_ observer: NSObject, _ id: NSManagedObjectID, _ state: State, _ block: @escaping CallBackBlock) {
            self.observer = observer
            self.id = id
            self.state = state
            self.block = block
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    public init(context: NSManagedObjectContext) {
        self.context = context
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleContextObjectDidChange(_:)), name: NSNotification.Name.NSManagedObjectContextObjectsDidChange, object: nil)
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
        
        let filterd: [(object: NSManagedObject, actions: [Action])] = allObjects.compactMap {
            guard let action = actions[$0.objectID] else { return nil }
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
            var shouldCleanUp = false
            
            for update in updates {
                guard let actions = this.actions[update.id] else { continue }
                let object = this.context.object(with: update.id)
                this.context.refresh(object, mergeChanges: true)
                
                for action in actions where action.state.intersection(update.state).rawValue > 0 {
                    guard let observer = action.observer else {
                        shouldCleanUp = true
                        continue
                    }
                    action.block((observer, object, update.changes, update.state))
                }
            }
            
            if shouldCleanUp {
                this.cleanupActions()
            }
        }
    }
    
    private func cleanupActions() {
        for id in actions.keys {
            guard let items = actions[id] else { continue }
            guard items.count > 0 else {
                print("Cleaned up \(id)")
                actions.removeValue(forKey: id)
                continue
            }
            
            let results = items.filter { $0.observer != nil }
            if results.count > 0 {
                if items.count != results.count {
                    actions[id] = results
                    print("Cleaned up \(id)")
                }
            } else {
                actions.removeValue(forKey: id)
                print("Cleaned up \(id)")
            }
        }
    }
    
    private func changesFor(object: NSManagedObject) -> [String: Changed] {
        
        var changes = [String: Changed]()
        
        func valueFor(_ value: Any?) -> Any?{
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
        
        for item in object.changedValues() {
            let new = valueFor(item.value)
            let old = valueFor(object.changedValuesForCurrentEvent()[item.key])
            let change = Changed(old: old, new: new)
            changes[item.key] = change
        }
        
        return changes
    }
    
    public func add(observer: NSObject, for id: NSManagedObjectID, state: State = .all, _ block: @escaping CallBackBlock) {
        let action = Action(observer, id, state, block)
        var list = actions[id] ?? []
        list.append(action)
        actions[id] = list
    }
    
    public func add<O: NSObject, T: NSManagedObject>(_ type: T.Type, observer: O, for id: NSManagedObjectID, state: State = .all, _ block: @escaping ((observer: O, object: T, changes: [String: Changed], state: State)) -> ()) {
        return add(observer: observer, for: id, state: state) { result in
            let object = result.object as! T
            let observer = result.observer as! O
            block((observer, object, result.changes, result.state))
        }
    }
    
    public func add<O: NSObject, T: NSManagedObject>(observer: O, for object: T, state: State = .all, _ block: @escaping ((observer: O, object: T, changes: [String: Changed], state: State)) -> ()) {
        return add(observer: observer, for: object.objectID, state: state) { result in
            let object = result.object as! T
            let observer = result.observer as! O
            block((observer, object, result.changes, result.state))
        }
    }
    
    public func remove(_ observer: NSObject) {
        for id in actions.keys {
            remove(observer, for: id)
        }
    }
    
    public func remove(_ observer: NSObject, for id: NSManagedObjectID) {
        guard let actions = actions[id] else { return }
        let result = actions.filter { $0.observer != observer }
        if result.count > 0 {
            self.actions[id] = result
        } else {
            self.actions.removeValue(forKey: id)
        }
    }
    
    public func remove(_ observer: NSObject, for object: NSManagedObject?) {
        if let id = object?.objectID {
            remove(observer, for: id)
        } else {
            remove(observer)
        }
    }
}
