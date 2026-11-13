#import "include/CMapLibreStyleTry.h"

/// `NSExpression(mglJSONObject:)` under the SDK's Swift name.
@interface NSExpression (MCMapLibreStyleTry)
+ (instancetype)expressionWithMLNJSONObject:(id)object;
@end

@interface NSPredicate (MCMapLibreStyleTry)
+ (instancetype)predicateWithMLNJSONObject:(id)object;
@end

NSExpression *MCMapLibreExpression(id json, NSString **message) {
    @try {
        return [NSExpression expressionWithMLNJSONObject:json];
    } @catch (NSException *exception) {
        if (message) {
            *message = exception.reason ?: exception.name;
        }
        return nil;
    }
}

NSPredicate *MCMapLibrePredicate(id json, NSString **message) {
    @try {
        return [NSPredicate predicateWithMLNJSONObject:json];
    } @catch (NSException *exception) {
        if (message) {
            *message = exception.reason ?: exception.name;
        }
        return nil;
    }
}

BOOL MCMapLibreSetValue(id object, NSString *key, id value, NSString **message) {
    @try {
        [object setValue:value forKey:key];
        return YES;
    } @catch (NSException *exception) {
        if (message) {
            *message = exception.reason ?: exception.name;
        }
        return NO;
    }
}
