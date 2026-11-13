#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Objective-C exceptions from MapLibre's style API, turned into something
 Swift can handle.

 MapLibre on iOS reaches a style property through key-value coding and builds
 expressions with `NSExpression(mglJSONObject:)`. Both raise an
 `NSException` — for a key the layer does not have, and for style JSON its
 Objective-C bridge does not model ("MLN_FUNCTION is not a supported
 method"). Swift cannot catch an `NSException`, so without this the one
 provider that cannot set every spec key by name would take the app down
 instead of reporting what it could not do.

 Each function answers `nil`/`NO` and fills `message` rather than raising.
 */

/// Builds an expression from style JSON, or `nil` with `message` set.
NSExpression *_Nullable MCMapLibreExpression(id json, NSString *_Nullable *_Nullable message);

/// Builds a predicate from a style filter, or `nil` with `message` set.
NSPredicate *_Nullable MCMapLibrePredicate(id json, NSString *_Nullable *_Nullable message);

/// Sets a value by key, or answers `NO` with `message` set.
BOOL MCMapLibreSetValue(
    id object, NSString *key, id _Nullable value, NSString *_Nullable *_Nullable message);

NS_ASSUME_NONNULL_END
