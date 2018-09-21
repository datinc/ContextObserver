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
    
}
