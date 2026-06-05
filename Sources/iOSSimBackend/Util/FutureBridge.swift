// SPDX-License-Identifier: Apache-2.0
/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * Adapted for sim-use CLI.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore // This will be resolvable after Package.swift update
import Foundation
// import IDBCompanionUtilities // This import is from the original, likely not needed if FBFutureError is self-contained

enum FBFutureError: Error {
  /// This indicates an error in objc code where result callback was called but no error or result provided. In case of this, debug `FBFuture` implementation.
  case continuationFulfilledWithoutValues // Corrected typo from original

  /// This indicates an error in `BridgeFuture.values` implementation. In case of this, debug `BridgeFuture.values` implementation.
  case taskGroupReceivedNilResultInternalError

  /// This indicates an error in `BridgeFuture.values` implementation. In case of this, debug `BridgeFuture.values` implementation.
  case taskGroupDidNotProvideAnyResultInternalError
}

/// Swift compiler does not allow usage of generic parameters of objc classes in extension
/// so we need to create a bridge for convenience.
enum FutureBridge { // Renamed from BridgeFuture to avoid potential naming conflicts if old framework is still temporarily linked during transition

  /// Use this to receive results from multiple futures. The results are **ordered in the same order as passed futures**, so you can safely access them from
  /// array by indexes.
  /// - Note: We should *not* use @discardableResult, results should be dropped explicitly by the callee.
  static func values<T: AnyObject>(_ futures: FBFuture<T>...) async throws -> [T] {
    let futuresArr: [FBFuture<T>] = futures
    return try await values(futuresArr)
  }

  /// Use this to receive results from multiple futures. The results are **ordered in the same order as passed futures**, so you can safely access them from
  /// array by indexes.
  /// - Note: We should *not* use @discardableResult, results should be dropped explicitly by the callee.
  static func values<T: AnyObject>(_ futures: [FBFuture<T>]) async throws -> [T] {
    try await withThrowingTaskGroup(of: T?.self) { group in
      for future in futures {
        group.addTask {
          try await value(future)
        }
      }
      var results = [T]()
      for try await result in group {
        guard let result = result else {
          throw FBFutureError.taskGroupReceivedNilResultInternalError
        }
        results.append(result)
      }
      return results
    }
  }

  /// Awaitable value that waits for publishing from the wrapped future
  /// - Note: We should *not* use @discardableResult, results should be dropped explicitly by the callee.
  static func value<T: AnyObject>(_ future: FBFuture<T>) async throws -> T {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        future.onQueue(BridgeQueues.futureSerialFullfillmentQueue, notifyOfCompletion: { resolvedFuture in
          if let error = resolvedFuture.error {
            continuation.resume(throwing: error)
          } else if let value = resolvedFuture.result {
            continuation.resume(returning: value as! T)
          } else {
            continuation.resume(throwing: FBFutureError.continuationFulfilledWithoutValues)
          }
        })
      }
    } onCancel: {
      future.cancel()
    }
  }

  /// Awaitable value that waits for publishing from the wrapped future.
  /// This is convenient bridgeable overload for dealing with objc `NSArray`.
  /// - Warning: This operation not safe (as most of objc bridge). That means you should be sure that type bridging will succeed.
  static func value<T>(_ future: FBFuture<NSArray>) async throws -> [T] {
    let objcValue = try await value(future as FBFuture<NSArray_TypeHack>)
    // swiftlint:disable force_cast
    return objcValue as! [T]
    // swiftlint:enable force_cast
  }

  /// Awaitable value that waits for publishing from the wrapped future.
  /// This is convenient bridgeable overload for dealing with objc `NSDictionary`.
  /// - Warning: This operation not safe (as most of objc bridge). That means you should be sure that type bridging will succeed.
  static func value<T: Hashable, U>(_ future: FBFuture<NSDictionary>) async throws -> [T: U] {
    let objcValue = try await value(future)
    // swiftlint:disable force_cast
    return objcValue as! [T: U]
  }

  /// Special overload for FBFuture<NSNull> representing void.
  static func value(_ future: FBFuture<NSNull>) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        future.onQueue(BridgeQueues.futureSerialFullfillmentQueue, notifyOfCompletion: { resolvedFuture in
          if let error = resolvedFuture.error {
            continuation.resume(throwing: error)
          } else {
            // For NSNull futures, we just complete with void
            continuation.resume(returning: ())
          }
        })
      }
    } onCancel: {
      future.cancel()
    }
  }

  /// Special overload for FBFuture<NSNumber> representing Bool.
  static func value(_ future: FBFuture<NSNumber>) async throws -> Bool {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
        future.onQueue(BridgeQueues.futureSerialFullfillmentQueue, notifyOfCompletion: { resolvedFuture in
          if let error = resolvedFuture.error {
            continuation.resume(throwing: error)
          } else if let value = resolvedFuture.result {
            continuation.resume(returning: value.boolValue)
          } else {
            continuation.resume(throwing: FBFutureError.continuationFulfilledWithoutValues)
          }
        })
      }
    } onCancel: {
      future.cancel()
    }
  }

  /// Awaitable value that waits for publishing from the wrapped futureContext.
  /// This is convenient bridgeable overload for dealing with objc `NSArray`.
  static func value<T: AnyObject>(_ futureContext: FBFutureContext<T>) async throws -> T {
    return try await value(futureContext.future)
  }
}

// Typealias HACKS to satisfy AnyObject conformance for FBFuture generic constraints
// FBFuture<T> requires T to be AnyObject.
// NSArray, NSNull, NSNumber are AnyObjects.
private typealias NSArray_TypeHack = NSArray
private typealias NSNull_TypeHack = NSNull
private typealias NSNumber_TypeHack = NSNumber 