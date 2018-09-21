# WIP: ContextObserver

[![CI Status](https://img.shields.io/travis/datinc/ContextObserver.svg?style=flat)](https://travis-ci.org/datinc/ContextObserver)
[![Version](https://img.shields.io/cocoapods/v/ContextObserver.svg?style=flat)](https://cocoapods.org/pods/ContextObserver)
[![License](https://img.shields.io/cocoapods/l/ContextObserver.svg?style=flat)](https://cocoapods.org/pods/ContextObserver)
[![Platform](https://img.shields.io/cocoapods/p/ContextObserver.svg?style=flat)](https://cocoapods.org/pods/ContextObserver)

ContextObserver is used to help observer NSManagedObjects. ContextObserver will let you observer:
1) Any changes on an NSManagedObject
2) A keypath of an NSManagedObject
3) A many to one relationship for an NSManagedObject (not implemented)

### Observer any changes on a NSManagedObject

```swift

let observer = ContextObserver(context: mainContext)
observer.add(observer: self, for: managedObject) { (change) in
    ...
})

...
observer.remove(self)

```

### Observer keypath of an NSManagedObject

```swift

let observer = ContextObserver(context: mainContext)
observer.add(observer: self, for: managedObject, keyPath: someKeyPath) { (change) in
...
})

...
observer.remove(self)

```

### Observer a many to one relationship for an NSManagedObject

Not iimplmented yet

```swift
...
```

## Example

To run the example project, clone the repo, and run `pod install` from the Example directory first.

## Requirements

## Installation

ContextObserver is available through [CocoaPods](https://cocoapods.org). To install
it, simply add the following line to your Podfile:

```ruby
pod 'ContextObserver'
```

## Author

datinc, peter@datinc.ca

## License

ContextObserver is available under the MIT license. See the LICENSE file for more info.
