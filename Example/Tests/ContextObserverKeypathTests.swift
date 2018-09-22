//
//  ContextObserverKeypathTests.swift
//  ContextObserver_Tests
//
//  Created by Peter Gulyas on 2018-09-21.
//  Copyright © 2018 CocoaPods. All rights reserved.
//

import XCTest
import CoreData
import ContextObserver

class ContextObserverKeypathTests: XCTestCase {
    
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
    
    func testKeypath() {
        let bgContext = container.newBackgroundContext()
        let observer = ContextObserver(context: container.viewContext)
        
        var id: NSManagedObjectID!
        
        bgContext.performAndWait {
            let entity0 = Entity0(context: bgContext)
            try! bgContext.save()
            id = entity0.objectID
        }
        
        let exp = expectation(description: "Wait for change")
        exp.assertForOverFulfill = false
        
        var change: ContextObserver.ValueChanged<String>?
        
        observer.add(observer: self, for: id, keyPath: \Entity0.stringValue) { (update) in
            change = update.change
            exp.fulfill()
        }
        
        bgContext.perform {
            let entity0 = bgContext.object(with: id) as! Entity0
            entity0.stringValue = "Test"
            try! bgContext.save()
        }
        
        waitForExpectations(timeout: 1.0)
        
        if let change = change {
            XCTAssertEqual(change.new, "Test")
            XCTAssertNil(change.old)
        } else {
            XCTFail("never changed")
        }
        
        observer.remove(self)
    }
    
    func testRelationships() {
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
        var change: ContextObserver.ValueChanged<String>?
        
        observer.add(observer: self, for: id1, keyPath: \Entity1.parent?.stringValue) { (update) in
            change = update.change
            exp.fulfill()
        }
        
        bgContext.perform {
            let entity0 = bgContext.object(with: id0) as! Entity0
            entity0.stringValue = "Test"
            try! bgContext.save()
        }
        
        waitForExpectations(timeout: 1.0)
        
        if let change = change {
            XCTAssertEqual(change.new, "Test")
            XCTAssertNil(change.old)
            let entity1 = bgContext.object(with: id1) as! Entity1
            XCTAssertEqual(entity1.parent?.stringValue, "Test")
        } else {
            XCTFail("never changed")
        }
        observer.remove(self)
    }
}
