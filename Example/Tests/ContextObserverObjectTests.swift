//
//  ContextObserverObjectTests.swift
//  ContextObserver_Tests
//
//  Created by Peter Gulyas on 2018-09-19.
//  Copyright © 2018 CocoaPods. All rights reserved.
//

import XCTest
import CoreData
import ContextObserver

class ContextObserverObjectTests: XCTestCase {
    private var container: NSPersistentContainer!
    override func setUp() {
        super.setUp()
        
        let container = NSPersistentContainer(name: "TestDB")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        })
        self.container = container
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }
    
    func testPropertyObserver() {
        let bgContext = container.newBackgroundContext()
        let observer = ContextObserver(context: container.viewContext)
        
        var id: NSManagedObjectID!
        
        bgContext.performAndWait {
            let entity0 = Entity0(context: bgContext)
            try! bgContext.save()
            id = entity0.objectID
        }
        
        let exp = expectation(description: "Wait for change")
        var state: ContextObserver.State!
        var entity0: Entity0!
        var changes: [String: ContextObserver.Changed]!
        
        observer.add(Entity0.self, observer: self, for: id) {
            state = $0.state
            entity0 = $0.object
            changes = $0.changes
            exp.fulfill()
        }
        
        bgContext.perform {
            let entity0 = bgContext.object(with: id) as! Entity0
            entity0.stringValue = "Test"
            try! bgContext.save()
        }
        
        waitForExpectations(timeout: 1.0)
        
        XCTAssertEqual(state, .updated)
        XCTAssertEqual(entity0.stringValue, "Test")
        XCTAssertEqual(changes["stringValue"]!.new as? String, "Test")
        XCTAssertNil(changes["stringValue"]!.old)
    }
    
    func testDelete() {
        let bgContext = container.newBackgroundContext()
        let observer = ContextObserver(context: container.viewContext)
        
        var id: NSManagedObjectID!
        
        bgContext.performAndWait {
            let entity0 = Entity0(context: bgContext)
            try! bgContext.save()
            id = entity0.objectID
        }
        
        let exp = expectation(description: "Wait for change")
        var state: ContextObserver.State!
        
        observer.add(Entity0.self, observer: self, for: id) {
            state = $0.state
            exp.fulfill()
        }
        
        bgContext.perform {
            let entity0 = bgContext.object(with: id) as! Entity0
            bgContext.delete(entity0)
            try! bgContext.save()
        }
        
        waitForExpectations(timeout: 1.0)
        
        XCTAssertEqual(state, .deleted)
    }
    
    func testAddChildObject() {
        let bgContext = container.newBackgroundContext()
        let observer = ContextObserver(context: container.viewContext)
        
        var id0: NSManagedObjectID!
        var id1: NSManagedObjectID!
        
        bgContext.performAndWait {
            let entity0 = Entity0(context: bgContext)
            try! bgContext.save()
            id0 = entity0.objectID
        }
        
        let exp = expectation(description: "Wait for change")
        var change: ContextObserver.Changed!
        
        observer.add(Entity0.self, observer: self, for: id0) { (update) in
            if let found = update.changes["entity1s"] {
                change = found
                exp.fulfill()
            }
        }
        
        bgContext.perform {
            let entity0 = bgContext.object(with: id0) as! Entity0
            let entity1 = Entity1(context: bgContext)
            
            entity1.parent = entity0
            
            try! bgContext.save()
            id1 = entity1.objectID
        }
        
        waitForExpectations(timeout: 1.0)
        
        let old = change.old as! Set<NSManagedObjectID>
        let new = change.new as! Set<NSManagedObjectID>
        
        XCTAssertEqual(old.count, 0)
        XCTAssertEqual(new.count, 1)
        XCTAssertTrue(new.first!.isEqual(id1))
        
        observer.remove(self)
    }
    
    func testRemoveChildObject() {
        let bgContext = container.newBackgroundContext()
        let observer = ContextObserver(context: container.viewContext)
        
        var id0: NSManagedObjectID!
        var id1: NSManagedObjectID!
        
        bgContext.performAndWait {
            let entity0 = Entity0(context: bgContext)
            let entity1 = Entity1(context: bgContext)
            entity1.parent = entity0
            
            try! bgContext.save()
            id0 = entity0.objectID
            id1 = entity1.objectID
        }
        
        let exp = expectation(description: "Wait for change")
        var change: ContextObserver.Changed!
        
        observer.add(Entity0.self, observer: self, for: id0) { (update) in
            if let found = update.changes["entity1s"] {
                change = found
                exp.fulfill()
            }
        }
        
        bgContext.perform {
            let entity1 = bgContext.object(with: id1) as! Entity1
            bgContext.delete(entity1)
            try! bgContext.save()
        }
        
        waitForExpectations(timeout: 100.0)
        
        let old = change.old as! Set<NSManagedObjectID>
        let new = change.new as! Set<NSManagedObjectID>
        
        XCTAssertEqual(old.count, 1)
        XCTAssertEqual(new.count, 0)
        XCTAssertTrue(old.first!.isEqual(id1))
        
        observer.remove(self)
    }

}
